import Foundation
import Observation

/// Client WebSocket d'une session terminal.
///
/// Le protocole du serveur est minimal : `{"t":"o","d":…}` pour la sortie,
/// `{"t":"i","d":…}` pour l'entrée, `{"t":"r",…}` pour le redimensionnement.
/// L'identifiant de session renvoyé à la connexion permet de se rattacher plus
/// tard au même shell — c'est ce qui fait survivre un `apt upgrade` à la mise en
/// arrière-plan de l'app.
@MainActor
@Observable
final class TerminalConnection {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected(resumed: Bool)
        case closed(reason: String?)
    }

    private(set) var phase: Phase = .idle
    private(set) var sessionID: String?
    private(set) var label: String?
    let emulator: TerminalEmulator

    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var delegate: TerminalTLSDelegate?
    private var receiveTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pendingOutput = ""

    init(columns: Int = 80, rows: Int = 24) {
        emulator = TerminalEmulator(columns: columns, rows: rows)
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    // MARK: - Cycle de vie

    func connect(profile: ServerProfile, hostID: Int, container: String? = nil,
                 ttl: TerminalTTL = .thirtyMinutes, resuming existing: String? = nil) {
        disconnect()
        phase = .connecting

        var query = [
            "cols": String(emulator.columns),
            "rows": String(emulator.rows),
            "ttl": ttl.rawValue,
        ]
        if let container { query["container"] = container }
        if let existing { query["session"] = existing }

        guard let url = profile.webSocketURL(path: "/ws/terminal/\(hostID)", query: query) else {
            phase = .closed(reason: "Adresse de serveur invalide")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 0
        configuration.shouldUseExtendedBackgroundIdleMode = true

        let urlSession: URLSession
        if profile.allowsUntrustedCertificates {
            let delegate = TerminalTLSDelegate(host: profile.url?.host())
            self.delegate = delegate
            urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        } else {
            urlSession = URLSession(configuration: configuration)
        }
        session = urlSession

        let task = urlSession.webSocketTask(with: url)
        socket = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(on: task)
        }
        startFlushing()
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        flushTask?.cancel()
        flushTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        if isConnected { phase = .idle }
    }

    // MARK: - Émission

    func send(_ text: String) {
        send(payload: ["t": "i", "d": text])
    }

    /// Séquence d'échappement d'une touche spéciale (flèches, Ctrl, Tab…).
    func sendKey(_ key: TerminalKey) {
        send(key.sequence)
    }

    func resize(columns: Int, rows: Int) {
        guard columns != emulator.columns || rows != emulator.rows else { return }
        emulator.resize(columns: columns, rows: rows)
        send(payload: ["t": "r", "cols": columns, "rows": rows])
    }

    func setTTL(_ ttl: TerminalTTL) {
        send(payload: ["t": "ttl", "value": ttl.rawValue])
    }

    private func send(payload: [String: Any]) {
        guard let socket, isConnected || phase == .connecting,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: - Réception

    private func receiveLoop(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): handle(text)
                case .data(let data): handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
            } catch {
                guard !Task.isCancelled else { return }
                flushPending()
                // Un code 4404 / 4500 vient du serveur avec son propre message,
                // déjà écrit dans le terminal : inutile de le paraphraser.
                phase = .closed(reason: closureReason(for: task, error: error))
                return
            }
        }
    }

    private func closureReason(for task: URLSessionWebSocketTask, error: Error) -> String? {
        switch task.closeCode {
        case .normalClosure, .goingAway: return nil
        case .invalid:
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain
                ? APIError.transport(error).message
                : nil
        default:
            switch task.closeCode.rawValue {
            case 4401: return "Session expirée — reconnecte-toi."
            case 4404, 4500: return nil     // message déjà affiché par le serveur
            case 4000: return "Session fermée."
            default: return "Connexion interrompue."
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = payload["t"] as? String
        else { return }

        switch kind {
        case "o", "e":
            pendingOutput += (payload["d"] as? String) ?? ""
        case "session":
            sessionID = payload["id"] as? String
            label = payload["label"] as? String
            phase = .connected(resumed: (payload["resumed"] as? Bool) ?? false)
        case "pong":
            break
        default:
            break
        }
    }

    /// Regroupe la sortie avant de la donner à l'émulateur.
    ///
    /// Un `cat` sur un gros fichier arrive en dizaines de messages par seconde ;
    /// les appliquer un par un déclencherait autant de rendus SwiftUI.
    private func startFlushing() {
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled else { return }
                flushPending()
            }
        }
    }

    private func flushPending() {
        guard !pendingOutput.isEmpty else { return }
        let chunk = pendingOutput
        pendingOutput = ""
        emulator.feed(chunk)
    }
}

/// Touches qui n'ont pas de représentation sur un clavier iOS.
enum TerminalKey: Identifiable, Hashable, Sendable {
    case up, down, left, right
    case tab, escape, enter, backspace
    case home, end, pageUp, pageDown
    case control(Character)

    var id: String { label }

    var sequence: String {
        switch self {
        case .up: "\u{1B}[A"
        case .down: "\u{1B}[B"
        case .right: "\u{1B}[C"
        case .left: "\u{1B}[D"
        case .tab: "\t"
        case .escape: "\u{1B}"
        case .enter: "\r"
        case .backspace: "\u{7F}"
        case .home: "\u{1B}[H"
        case .end: "\u{1B}[F"
        case .pageUp: "\u{1B}[5~"
        case .pageDown: "\u{1B}[6~"
        case .control(let character): Self.controlSequence(for: character)
        }
    }

    /// Ctrl+A vaut 0x01, Ctrl+Z vaut 0x1A : on masque les bits hauts.
    private static func controlSequence(for character: Character) -> String {
        guard let ascii = character.uppercased().unicodeScalars.first?.value,
              ascii >= 64, ascii < 128 else { return "" }
        return String(UnicodeScalar(UInt8(ascii & 0x1F)))
    }

    var label: String {
        switch self {
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .tab: "⇥"
        case .escape: "esc"
        case .enter: "⏎"
        case .backspace: "⌫"
        case .home: "⇱"
        case .end: "⇲"
        case .pageUp: "⇞"
        case .pageDown: "⇟"
        case .control(let character): "^\(character.uppercased())"
        }
    }
}

private final class TerminalTLSDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
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
