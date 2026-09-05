import Foundation

/// Réponse de `GET /network` : tout ce que MBA voit sur le réseau, supervisé
/// ou simplement aperçu par la découverte.
struct NetworkOverview: Codable, Sendable {
    var assets: [NetworkAsset]
    var groups: [NetworkGroup]
    var groupBy: String
    var summary: Summary

    enum CodingKeys: String, CodingKey {
        case assets, groups, summary
        case groupBy = "group_by"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assets = (try? c.decode([NetworkAsset].self, forKey: .assets)) ?? []
        groups = (try? c.decode([NetworkGroup].self, forKey: .groups)) ?? []
        groupBy = (try? c.decode(String.self, forKey: .groupBy)) ?? "subnet"
        summary = (try? c.decode(Summary.self, forKey: .summary)) ?? Summary()
    }

    struct Summary: Codable, Sendable {
        var total: Int = 0
        var supervised: Int = 0
        var unmanaged: Int = 0
        var online: Int = 0
        var subnets: Int = 0
        var tailscale: Int = 0

        init() {}
    }
}

/// Un groupe d'équipements — sous-réseau, étiquette, lieu, type ou catégorie
/// selon le regroupement demandé.
struct NetworkGroup: Codable, Identifiable, Hashable, Sendable {
    var key: String
    var count: Int
    var online: Int
    var supervised: Int
    var assets: [NetworkAsset]

    var id: String { key }

    /// Des équipements vus mais non supervisés : c'est là que se cachent les
    /// machines qu'on a oublié de déclarer.
    var unmanaged: Int { count - supervised }
}

/// Un équipement : machine déclarée dans MBA, ou adresse repérée par la
/// découverte réseau et jamais adoptée.
struct NetworkAsset: Codable, Identifiable, Hashable, Sendable {
    var kind: String
    var hostID: Int?
    var name: String
    var address: String
    var subnet: String
    var hostKind: String
    var status: String
    var tags: [String]
    var category: String?
    var location: String?
    var macs: [String: String]
    var os: String?
    var model: String?
    var ports: [Int]
    /// Rôles déduits des ports ouverts : « PostgreSQL », « SSH »…
    var roles: [String]
    var supervised: Bool
    var firstSeen: Date?
    var lastSeen: Date?
    var uptime: Double?
    var tailscale: Bool

    /// Une adresse découverte n'a pas d'identifiant : l'adresse fait l'affaire.
    var id: String { hostID.map { "host-\($0)" } ?? "found-\(address)" }

    enum CodingKeys: String, CodingKey {
        case kind, name, address, subnet, status, tags, category, location
        case macs, os, model, ports, roles, supervised, uptime, tailscale
        case hostID = "id"
        case hostKind = "host_kind"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "host"
        hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        address = (try? c.decode(String.self, forKey: .address)) ?? ""
        subnet = (try? c.decode(String.self, forKey: .subnet)) ?? "—"
        hostKind = (try? c.decode(String.self, forKey: .hostKind)) ?? "generic"
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        macs = (try? c.decode([String: String].self, forKey: .macs)) ?? [:]
        os = try c.decodeIfPresent(String.self, forKey: .os)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        ports = (try? c.decode([Int].self, forKey: .ports)) ?? []
        roles = (try? c.decode([String].self, forKey: .roles)) ?? []
        supervised = (try? c.decode(Bool.self, forKey: .supervised)) ?? false
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        uptime = try c.decodeIfPresent(Double.self, forKey: .uptime)
        tailscale = (try? c.decode(Bool.self, forKey: .tailscale)) ?? false
    }

    var hostStatus: HostStatus { HostStatus(rawValue: status) ?? .unknown }
    var kindIcon: HostKind { HostKind(rawValue: hostKind) ?? .generic }
    var isDiscovered: Bool { kind != "host" }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, address, os, model, subnet].compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
            || roles.contains { $0.lowercased().contains(query) }
            || ports.contains { String($0).contains(query) }
    }
}

/// Regroupements acceptés par `GET /network?group_by=`.
enum NetworkGrouping: String, CaseIterable, Identifiable, Sendable {
    case subnet, kind, tag, location, category

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subnet: "Sous-réseau"
        case .kind: "Type"
        case .tag: "Étiquette"
        case .location: "Lieu"
        case .category: "Catégorie"
        }
    }
}
