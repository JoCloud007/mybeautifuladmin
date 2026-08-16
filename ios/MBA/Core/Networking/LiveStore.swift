import Foundation
import Observation

/// Série temporelle bornée, alimentée par le flux temps réel.
///
/// Un tampon circulaire de taille fixe : à 5 points/seconde sur des dizaines de
/// machines, faire croître un tableau indéfiniment finirait par saturer la
/// mémoire d'un iPhone en quelques heures d'écran allumé.
struct MetricSeries: Sendable {
    static let capacity = 240

    private(set) var timestamps: [Double] = []
    private(set) var values: [Double] = []

    mutating func append(time: Double, value: Double) {
        if timestamps.count >= Self.capacity {
            timestamps.removeFirst()
            values.removeFirst()
        }
        timestamps.append(time)
        values.append(value)
    }

    var isPlottable: Bool { values.count > 1 }
    var latest: Double? { values.last }

    var points: [MetricPoint] {
        zip(timestamps, values).map { MetricPoint(date: Date(timeIntervalSince1970: $0), value: $1) }
    }
}

struct MetricPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double
    var id: Double { date.timeIntervalSince1970 }
}

/// État temps réel partagé par toute l'application.
///
/// Un seul WebSocket alimente le tableau de bord, les fiches d'hôte, le mur de
/// monitoring et la bannière d'alerte. Ouvrir une connexion par écran ferait
/// autant de sessions SSH côté serveur qu'il y a d'onglets ouverts.
@MainActor
@Observable
final class LiveStore {
    private(set) var isConnected = false
    private(set) var lastConnectionError: String?

    /// Dernier échantillon complet par hôte, valeurs non numériques comprises
    /// (systèmes de fichiers, GPU, top processus).
    private(set) var samples: [Int: [String: JSONValue]] = [:]
    private(set) var statuses: [Int: HostStatus] = [:]
    private(set) var services: [Int: JSONValue] = [:]
    private(set) var aiEndpoints: [Int: JSONValue] = [:]
    private(set) var events: [EventItem] = []
    /// Dernière alerte reçue — sert la bannière éphémère en haut d'écran.
    private(set) var latestAlert: Alert?

    private var seriesStore: [String: MetricSeries] = [:]
    /// Incrémenté à chaque salve : les vues qui lisent `series` s'y abonnent
    /// pour se rafraîchir sans que chaque point ne déclenche un rendu.
    private(set) var tick: Int = 0

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var delegate: LiveTLSDelegate?
    private var receiveTask: Task<Void, Never>?
    private var retryCount = 0
    private var profile: ServerProfile?
    private var isStopped = true

    // MARK: - Cycle de vie

    func connect(profile: ServerProfile) {
        if self.profile?.id == profile.id, socket != nil, isConnected { return }
        disconnect()
        self.profile = profile
        isStopped = false
        openSocket()
    }

    func disconnect() {
        isStopped = true
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        isConnected = false
    }

    /// Vide tout — changement de serveur ou déconnexion du compte.
    func reset() {
        disconnect()
        profile = nil
        samples = [:]
        statuses = [:]
        services = [:]
        aiEndpoints = [:]
        events = []
        latestAlert = nil
        seriesStore = [:]
        retryCount = 0
        lastConnectionError = nil
    }

    func dismissAlertBanner() { latestAlert = nil }

    // MARK: - Lecture

    func sample(for hostID: Int) -> [String: JSONValue] { samples[hostID] ?? [:] }

    func metric(_ name: String, for hostID: Int) -> Double? {
        samples[hostID]?[name]?.doubleValue
    }

    func series(_ name: String, for hostID: Int) -> MetricSeries? {
        seriesStore["\(hostID):\(name)"]
    }

    func hasSeries(_ name: String, for hostID: Int) -> Bool {
        seriesStore["\(hostID):\(name)"]?.isPlottable ?? false
    }

    // MARK: - Connexion

    private func openSocket() {
        guard let profile, let url = profile.webSocketURL(path: "/ws/stream") else { return }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0   // un flux ne « dépasse » pas
        configuration.shouldUseExtendedBackgroundIdleMode = true

        let session: URLSession
        if profile.allowsUntrustedCertificates {
            let delegate = LiveTLSDelegate(host: profile.url?.host())
            self.delegate = delegate
            session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
        self.session = session

        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: task)
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                if !isConnected {
                    isConnected = true
                    lastConnectionError = nil
                    retryCount = 0
                }
                switch message {
                case .string(let text):
                    handle(text: text)
                case .data(let data):
                    handle(text: String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled, !isStopped else { return }
                isConnected = false
                lastConnectionError = (error as NSError).localizedDescription
                await scheduleReconnect()
                return
            }
        }
    }

    private func scheduleReconnect() async {
        guard !isStopped else { return }
        retryCount = min(retryCount + 1, 6)
        // 0,5 s puis doublement jusqu'à 32 s : un serveur qui redémarre est
        // retrouvé vite, un serveur éteint n'est pas martelé.
        let delay = 0.5 * pow(2, Double(retryCount))
        try? await Task.sleep(for: .seconds(delay))
        guard !isStopped else { return }
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        openSocket()
    }

    // MARK: - Décodage du flux

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? APIClient.decoder.decode(StreamMessage.self, from: data)
        else { return }

        if message.topic == "snapshot" {
            for (topic, payload) in message.data.objectValue ?? [:] {
                apply(topic: topic, payload: payload)
            }
            tick &+= 1
            return
        }
        guard message.topic != "ping" else { return }
        apply(topic: message.topic, payload: message.data)
        tick &+= 1
    }

    private func apply(topic: String, payload: JSONValue) {
        if topic.hasPrefix("metrics.") {
            guard let object = payload.objectValue else { return }
            let hostID = object.int("_host_id") ?? Int(topic.dropFirst("metrics.".count)) ?? -1
            guard hostID >= 0 else { return }
            samples[hostID] = object
            let time = object.double("_ts") ?? Date().timeIntervalSince1970
            for (name, value) in object {
                guard !name.hasPrefix("_"), case .number(let number) = value else { continue }
                seriesStore["\(hostID):\(name)", default: MetricSeries()].append(time: time, value: number)
            }
        } else if topic == "host.status" {
            guard let object = payload.objectValue, let hostID = object.int("host_id") else { return }
            statuses[hostID] = HostStatus(rawValue: object.string("status") ?? "") ?? .unknown
        } else if topic == "service" {
            guard let id = payload["id"]?.intValue else { return }
            services[id] = payload
        } else if topic.hasPrefix("ai.") {
            guard let id = payload["id"]?.intValue else { return }
            aiEndpoints[id] = payload
        } else if topic == "event" {
            guard let data = try? JSONEncoder().encode(payload),
                  let item = try? APIClient.decoder.decode(EventItem.self, from: data) else { return }
            events.insert(item, at: 0)
            if events.count > 200 { events.removeLast(events.count - 200) }
        } else if topic == "alert" {
            guard let data = try? JSONEncoder().encode(payload),
                  let alert = try? APIClient.decoder.decode(Alert.self, from: data) else { return }
            latestAlert = alert
        }
    }

    private struct StreamMessage: Decodable {
        let topic: String
        let data: JSONValue
    }
}

private final class LiveTLSDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let host: String?

    init(host: String?) {
        self.host = host
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              challenge.protectionSpace.host == host
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
