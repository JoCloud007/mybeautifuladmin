import Foundation

/// Client HTTP de l'API MBA.
///
/// Immuable et lié à un `ServerProfile` : changer de serveur ou de jeton crée un
/// nouveau client plutôt que de muter celui-ci, ce qui évite toute synchro et le
/// rend `Sendable` sans effort.
final class APIClient: Sendable {
    let profile: ServerProfile
    private let session: URLSession
    private let delegate: TLSDelegate?

    init(profile: ServerProfile) {
        self.profile = profile
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        // Les réponses de supervision sont périssables : un cache HTTP ne ferait
        // qu'afficher des valeurs mortes après un retour de veille.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        if profile.allowsUntrustedCertificates {
            let delegate = TLSDelegate(host: profile.url?.host())
            self.delegate = delegate
            self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        } else {
            self.delegate = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Codage

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = DateParsing.parse(text) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Date illisible : \(text)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: - Verbes

    func get<T: Decodable & Sendable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try await send(path, method: "GET", query: query, body: Optional<Empty>.none)
    }

    @discardableResult
    func post<T: Decodable & Sendable>(_ path: String, body: (some Encodable & Sendable)? = Optional<Empty>.none,
                                       query: [String: String?] = [:]) async throws -> T {
        try await send(path, method: "POST", query: query, body: body)
    }

    @discardableResult
    func patch<T: Decodable & Sendable>(_ path: String, body: some Encodable & Sendable) async throws -> T {
        try await send(path, method: "PATCH", query: [:], body: body)
    }

    @discardableResult
    func put<T: Decodable & Sendable>(_ path: String, body: some Encodable & Sendable) async throws -> T {
        try await send(path, method: "PUT", query: [:], body: body)
    }

    func delete(_ path: String) async throws {
        let _: Empty = try await send(path, method: "DELETE", query: [:], body: Optional<Empty>.none)
    }

    /// Variante sans corps de réponse exploité — évite d'inventer un type à
    /// chaque action qui répond `{"ok": true}`.
    @discardableResult
    func perform(_ path: String, method: String = "POST",
                 body: (some Encodable & Sendable)? = Optional<Empty>.none) async throws -> JSONValue {
        try await send(path, method: method, query: [:], body: body)
    }

    // MARK: - Envoi

    private func send<T: Decodable & Sendable>(
        _ path: String, method: String, query: [String: String?],
        body: (some Encodable & Sendable)?
    ) async throws -> T {
        let request = try makeRequest(path: path, method: method, query: query, body: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.decoding }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.decodeError(data: data, status: http.statusCode)
        }

        // 204, ou corps vide sur une action qui ne renvoie rien.
        if http.statusCode == 204 || data.isEmpty {
            if let empty = Empty() as? T { return empty }
            if let null = JSONValue.null as? T { return null }
        }

        // Un SPA répond `index.html` en 200 sur n'importe quel chemin : sans ce
        // contrôle, l'erreur remonterait en « réponse illisible » sans dire que
        // l'adresse désigne l'interface web plutôt que l'API.
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        if let contentType, !contentType.contains("json") {
            throw APIError.notAnAPI(contentType: contentType)
        }

        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            #if DEBUG
            print("⚠️ Décodage \(T.self) sur \(path) : \(error)")
            #endif
            throw APIError.decoding
        }
    }

    func makeRequest(path: String, method: String, query: [String: String?] = [:],
                     body: (some Encodable & Sendable)? = Optional<Empty>.none) throws -> URLRequest {
        guard var components = URLComponents(string: profile.baseURL + path) else {
            throw APIError(kind: .transport, message: "Adresse de serveur invalide")
        }
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        guard let url = components.url else {
            throw APIError(kind: .transport, message: "Adresse de serveur invalide")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = profile.token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        return request
    }

    /// Reproduit la lecture d'erreur du client web : `detail` peut être une
    /// chaîne, ou un objet portant `message` / `hint` / `note`.
    static func decodeError(data: Data, status: Int) -> APIError {
        guard let root = try? decoder.decode(JSONValue.self, from: data) else {
            return .http(status: status, message: "Erreur \(status)")
        }
        let detail = root["detail"] ?? root
        if let text = detail.stringValue, !text.isEmpty {
            return .http(status: status, message: text)
        }
        if let object = detail.objectValue {
            let message = object.string("message") ?? object.string("error") ?? "Erreur \(status)"
            let hint = [object.string("hint"), object.string("note")]
                .compactMap { $0 }
                .joined(separator: "\n\n")
            return .http(status: status, message: message, hint: hint.isEmpty ? nil : hint)
        }
        return .http(status: status, message: "Erreur \(status)")
    }

    // MARK: - Flux SSE

    /// POST qui répond en `text/event-stream`, consommé ligne à ligne.
    /// Sert au dialogue Ollama et aux sorties d'action diffusées en direct.
    func stream(_ path: String, body: some Encodable & Sendable) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(path: path, method: "POST", body: body)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.decoding }
                    guard (200..<300).contains(http.statusCode) else {
                        var payload = Data()
                        for try await byte in bytes { payload.append(byte) }
                        throw Self.decodeError(data: payload, status: http.statusCode)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let raw = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !raw.isEmpty,
                              let value = try? Self.decoder.decode(JSONValue.self, from: Data(raw.utf8))
                        else { continue }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error as? APIError ?? APIError.transport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Télécharge un corps brut (export CSV de l'inventaire, journaux).
    func data(_ path: String, query: [String: String?] = [:]) async throws -> Data {
        let request = try makeRequest(path: path, method: "GET", query: query)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.decoding }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.decodeError(data: data, status: http.statusCode)
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }
}

/// Corps vide encodable/décodable — évite `Optional<Never>` dans les signatures.
struct Empty: Codable, Sendable {}

// MARK: - TLS

/// Accepte le certificat du serveur configuré, et de lui seul.
///
/// MBA tourne presque toujours derrière un certificat auto-signé sur un réseau
/// privé. Refuser tout net obligerait à installer un profil de confiance ; on
/// laisse donc le choix, mais l'exception est bornée à l'hôte du profil : un
/// autre domaine reste validé normalement.
private final class TLSDelegate: NSObject, URLSessionDelegate, Sendable {
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

// MARK: - Dates

enum DateParsing {
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// PostgreSQL renvoie tantôt `...T10:00:00+00:00`, tantôt avec des
    /// microsecondes, tantôt sans fuseau quand la colonne est naïve.
    static func parse(_ text: String) -> Date? {
        if let date = withFraction.date(from: text) { return date }
        if let date = plain.date(from: text) { return date }
        if !text.hasSuffix("Z") && !text.contains("+") {
            let utc = text + "Z"
            if let date = withFraction.date(from: utc) { return date }
            if let date = plain.date(from: utc) { return date }
        }
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }
}
