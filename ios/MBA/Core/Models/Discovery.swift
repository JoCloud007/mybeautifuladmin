import Foundation

/// Une adresse repérée par la découverte réseau.
struct DiscoveryResult: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var address: String
    var hostname: String?
    var guessedKind: String
    var openPorts: [Int]
    var adopted: Bool
    var ignored: Bool
    var seenAt: Date?
    var source: String?
    /// Renseigné quand une machine du parc porte déjà cette adresse.
    var hostID: Int?

    enum CodingKeys: String, CodingKey {
        case id, address, hostname, adopted, ignored, source
        case guessedKind = "guessed_kind"
        case openPorts = "open_ports"
        case seenAt = "seen_at"
        case hostID = "host_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        address = (try? c.decode(String.self, forKey: .address)) ?? "—"
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        guessedKind = (try? c.decode(String.self, forKey: .guessedKind)) ?? "generic"
        openPorts = (try? c.decode([Int].self, forKey: .openPorts)) ?? []
        adopted = (try? c.decode(Bool.self, forKey: .adopted)) ?? false
        ignored = (try? c.decode(Bool.self, forKey: .ignored)) ?? false
        seenAt = try c.decodeIfPresent(Date.self, forKey: .seenAt)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
    }

    var kind: HostKind { HostKind(rawValue: guessedKind) ?? .generic }
    /// Déjà dans le parc : la proposer à l'adoption n'aurait pas de sens.
    var isKnown: Bool { adopted || hostID != nil }
    var displayName: String { hostname?.isEmpty == false ? hostname! : address }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return address.lowercased().contains(query)
            || (hostname?.lowercased().contains(query) ?? false)
            || openPorts.contains { String($0).contains(query) }
    }
}

/// Réponse de `GET /discovery/suggestions` : quoi scanner, et sur quels ports.
struct DiscoverySuggestions: Codable, Sendable {
    var subnets: [String]
    var ports: [Int]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subnets = (try? c.decode([String].self, forKey: .subnets)) ?? []
        ports = (try? c.decode([Int].self, forKey: .ports)) ?? []
    }
}

/// Réponse de `POST /discovery/scan`.
struct DiscoveryScanResult: Codable, Sendable {
    var count: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }
}

/// Corps de `POST /discovery/scan`.
struct DiscoveryScanPayload: Encodable, Sendable {
    var targets: String
    var ports: [Int]?
    var concurrency: Int = 256
}

/// Corps de `POST /discovery/adopt`.
struct DiscoveryAdoptPayload: Encodable, Sendable {
    var address: String
    var name: String?
    var kind: String?
    var port: Int?
    var tags: [String] = []
    var category: String?

    enum CodingKeys: String, CodingKey {
        case address, name, kind, port, tags, category
    }
}

/// Ports que MBA sait interpréter, pour deviner ce qui tourne derrière une
/// adresse inconnue.
enum WellKnownPort {
    static let roles: [Int: String] = [
        22: "SSH", 80: "HTTP", 443: "HTTPS", 445: "SMB", 548: "AFP",
        1883: "MQTT", 2375: "Docker", 2376: "Docker TLS", 3000: "Grafana",
        3306: "MySQL", 5000: "DSM", 5001: "DSM TLS", 5432: "PostgreSQL",
        6379: "Redis", 8006: "Proxmox", 8080: "HTTP alt", 8123: "Home Assistant",
        8443: "HTTPS alt", 9090: "Prometheus", 11434: "Ollama", 32400: "Plex",
    ]

    static func label(_ port: Int) -> String? { roles[port] }

    /// Rôles déduits d'une liste de ports, sans doublon et dans un ordre stable.
    static func labels(for ports: [Int]) -> [String] {
        Array(Set(ports.compactMap { roles[$0] })).sorted()
    }
}
