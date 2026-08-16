import Foundation

/// Un serveur MBA enregistré sur l'appareil.
///
/// L'app est multi-serveurs : la même installation supervise volontiers une
/// infra maison et un labo. Le jeton ne vit jamais ici — il est rangé dans le
/// trousseau sous la clé `tokenAccount`.
struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    /// Racine de l'API, sans slash final : `https://mba.local:8080`.
    var baseURL: String
    var username: String
    /// Les équipements MBA (BMC, DSM, Proxmox) sont en certificat auto-signé et
    /// le serveur lui-même l'est souvent aussi derrière un VPN.
    var allowsUntrustedCertificates: Bool = false
    var createdAt: Date = .now

    var tokenAccount: String { "token.\(id.uuidString)" }
    var passwordAccount: String { "password.\(id.uuidString)" }

    var token: String? {
        get { Keychain.get(tokenAccount) }
        nonmutating set { Keychain.set(newValue, for: tokenAccount) }
    }

    /// Conservé uniquement si l'utilisateur demande la reconnexion automatique :
    /// le JWT expire au bout de 7 jours et un réveil en arrière-plan n'a
    /// personne pour ressaisir le mot de passe.
    var storedPassword: String? {
        get { Keychain.get(passwordAccount) }
        nonmutating set { Keychain.set(newValue, for: passwordAccount) }
    }

    var url: URL? { URL(string: baseURL) }

    var displayHost: String {
        guard let url, let host = url.host() else { return baseURL }
        if let port = url.port, port != 80, port != 443 { return "\(host):\(port)" }
        return host
    }

    func webSocketURL(path: String, query: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(string: baseURL + path) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items.sorted { $0.name < $1.name }
        return components.url
    }

    func clearSecrets() {
        Keychain.remove(tokenAccount)
        Keychain.remove(passwordAccount)
    }

    /// Normalise ce que l'utilisateur tape : `mba.local`, `mba.local:8080`,
    /// `http://mba.local:8080/` doivent tous mener au même endroit.
    static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            // Sans schéma : http pour une IP ou un .local, https sinon.
            let isLocal = text.hasPrefix("10.") || text.hasPrefix("192.168.")
                || text.hasPrefix("172.") || text.hasPrefix("100.")
                || text.lowercased().contains(".local")
                || text.lowercased().hasPrefix("localhost")
            text = (isLocal ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return text
    }
}
