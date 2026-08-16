import Foundation

/// Nature d'une machine supervisée. Détermine ce qui est collecté, ce qui est
/// affiché sur sa fiche et les actions proposées.
enum HostKind: String, Codable, CaseIterable, Sendable {
    case linux, proxmox, synology, docker, pbs, homeassistant, ipmi, generic

    var label: String {
        switch self {
        case .linux: "Linux"
        case .proxmox: "Proxmox"
        case .synology: "Synology"
        case .docker: "Docker"
        case .pbs: "Backup Server"
        case .homeassistant: "Home Assistant"
        case .ipmi: "IPMI / BMC"
        case .generic: "Générique"
        }
    }

    var symbol: String {
        switch self {
        case .linux: "terminal"
        case .proxmox: "square.stack.3d.up"
        case .synology: "externaldrive.connected.to.line.below"
        case .docker: "shippingbox"
        case .pbs: "archivebox"
        case .homeassistant: "house"
        case .ipmi: "cpu"
        case .generic: "network"
        }
    }

    var defaultPort: Int {
        switch self {
        case .linux, .docker: 22
        case .proxmox: 8006
        case .synology: 5001
        case .pbs: 8007
        case .homeassistant: 8123
        case .ipmi: 443
        case .generic: 80
        }
    }

    /// Un BMC n'a ni processeur ni système de fichiers : sa fiche ne montre pas
    /// les mêmes choses qu'un serveur Linux.
    var hasSystemMetrics: Bool { self != .ipmi && self != .generic }
    var supportsTerminal: Bool { self == .linux || self == .docker }
    var supportsPackageUpgrade: Bool { self == .linux || self == .docker }
}

enum HostStatus: String, Codable, Sendable {
    case online, offline, warning, unknown

    var label: String {
        switch self {
        case .online: "En ligne"
        case .offline: "Hors ligne"
        case .warning: "Dégradé"
        case .unknown: "Inconnu"
        }
    }
}

struct Host: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var kind: HostKind
    var address: String
    var port: Int?
    var credentialID: Int?
    var parentID: Int?
    var tags: [String]
    var enabled: Bool
    var status: HostStatus
    var lastSeen: Date?
    var lastError: String?
    var meta: [String: JSONValue]
    var category: String?
    var location: String?
    var notes: String?
    var bmcAddress: String?

    /// Dernier échantillon numérique, injecté par l'API depuis le bus temps réel.
    var live: [String: Double]
    /// Échantillon complet (tableaux compris) — présent sur `GET /hosts/{id}`.
    var sample: [String: JSONValue]?
    var children: [HostChild]?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, address, port, tags, enabled, status, meta
        case category, location, notes, live, sample, children
        case credentialID = "credential_id"
        case parentID = "parent_id"
        case lastSeen = "last_seen"
        case lastError = "last_error"
        case bmcAddress = "bmc_address"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Un collecteur peut introduire un type que cette version d'app ignore ;
        // mieux vaut l'afficher en « générique » que refuser toute la liste.
        kind = (try? container.decode(HostKind.self, forKey: .kind)) ?? .generic
        address = try container.decode(String.self, forKey: .address)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        credentialID = try container.decodeIfPresent(Int.self, forKey: .credentialID)
        parentID = try container.decodeIfPresent(Int.self, forKey: .parentID)
        tags = (try? container.decode([String].self, forKey: .tags)) ?? []
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        status = (try? container.decode(HostStatus.self, forKey: .status)) ?? .unknown
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        meta = (try? container.decode([String: JSONValue].self, forKey: .meta)) ?? [:]
        category = try container.decodeIfPresent(String.self, forKey: .category)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        bmcAddress = try container.decodeIfPresent(String.self, forKey: .bmcAddress)
        live = (try? container.decode([String: Double].self, forKey: .live)) ?? [:]
        sample = try container.decodeIfPresent([String: JSONValue].self, forKey: .sample)
        children = try container.decodeIfPresent([HostChild].self, forKey: .children)
    }

    // MARK: - Lectures pratiques

    var cpuUsage: Double? { live["cpu.usage"] }
    var memoryPercent: Double? { live["mem.percent"] }
    var swapPercent: Double? { live["swap.percent"] }
    var uptime: Double? { live["uptime"] }
    var loadAverage: Double? { live["load.1"] }
    var temperature: Double? { live["temp.max"] ?? live["temp.cpu"] }
    var pendingUpdates: Int? { meta.int("updates") }

    /// Occupation du système de fichiers racine, la plus parlante des jauges disque.
    var rootDiskPercent: Double? {
        live["disk.percent./"] ?? live.first { $0.key.hasPrefix("disk.percent.") }?.value
    }

    var displayAddress: String {
        guard let port, port != kind.defaultPort, port != 0 else { return address }
        return "\(address):\(port)"
    }

    var isReachable: Bool { status == .online }
}

struct HostChild: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let kind: String
    let status: String
}
