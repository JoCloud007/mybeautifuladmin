import Foundation

/// Réponse de `GET /inventory` : le parc avec sa fiche matérielle.
struct InventoryList: Codable, Sendable {
    var hosts: [InventoryItem]
    var tags: [TagCount]
    var categories: [CategoryCount]
    var summary: Summary

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = (try? c.decode([InventoryItem].self, forKey: .hosts)) ?? []
        tags = (try? c.decode([TagCount].self, forKey: .tags)) ?? []
        categories = (try? c.decode([CategoryCount].self, forKey: .categories)) ?? []
        summary = (try? c.decode(Summary.self, forKey: .summary)) ?? Summary()
    }

    struct TagCount: Codable, Identifiable, Hashable, Sendable {
        var tag: String
        var count: Int
        var id: String { tag }
    }

    struct CategoryCount: Codable, Identifiable, Hashable, Sendable {
        var category: String
        var count: Int
        var id: String { category }
    }

    struct Summary: Codable, Sendable {
        var total: Int = 0
        var byKind: [String: Int] = [:]
        var byCategory: [String: Int] = [:]
        var untagged: Int = 0
        var updates: Int = 0
        var rebootRequired: Int = 0

        enum CodingKeys: String, CodingKey {
            case total, untagged, updates
            case byKind = "by_kind"
            case byCategory = "by_category"
            case rebootRequired = "reboot_required"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = (try? c.decode(Int.self, forKey: .total)) ?? 0
            byKind = (try? c.decode([String: Int].self, forKey: .byKind)) ?? [:]
            byCategory = (try? c.decode([String: Int].self, forKey: .byCategory)) ?? [:]
            untagged = (try? c.decode(Int.self, forKey: .untagged)) ?? 0
            updates = (try? c.decode(Int.self, forKey: .updates)) ?? 0
            rebootRequired = (try? c.decode(Int.self, forKey: .rebootRequired)) ?? 0
        }
    }
}

/// Une machine du parc, avec sa fiche matérielle relevée automatiquement.
struct InventoryItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var kind: String
    var address: String
    var status: String
    var tags: [String]
    var enabled: Bool
    var category: String?
    var location: String?
    var notes: String?
    var credentialName: String?
    var lastSeen: Date?
    var containers: Int
    var identity: HardwareIdentity

    enum CodingKeys: String, CodingKey {
        case id, name, kind, address, status, tags, enabled
        case category, location, notes, containers, identity
        case credentialName = "credential_name"
        case lastSeen = "last_seen"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "generic"
        address = (try? c.decode(String.self, forKey: .address)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        category = try c.decodeIfPresent(String.self, forKey: .category)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        credentialName = try c.decodeIfPresent(String.self, forKey: .credentialName)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        containers = (try? c.decode(Int.self, forKey: .containers)) ?? 0
        identity = (try? c.decode(HardwareIdentity.self, forKey: .identity)) ?? HardwareIdentity()
    }

    var hostKind: HostKind { HostKind(rawValue: kind) ?? .generic }
    var hostStatus: HostStatus { HostStatus(rawValue: status) ?? .unknown }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, address, category, location, identity.model, identity.vendor,
                identity.serial]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
            || tags.contains { $0.lowercased().contains(query) }
    }
}

/// Fiche matérielle : ce que la collecte a relevé, et ce qui a été corrigé
/// à la main par-dessus.
struct HardwareIdentity: Codable, Hashable, Sendable {
    var vendor: String?
    var model: String?
    var version: String?
    var serial: String?
    var kernel: String?
    var cpuModel: String?
    var cpuCount: Int?
    var memTotal: Double?
    var diskTotal: Double?
    var macs: [String: String] = [:]
    var bios: String?
    var chassis: String?
    var virt: String?
    var updates: Int?
    var securityUpdates: Int?
    var rebootRequired: Bool = false
    var uptime: Double?
    /// Champs corrigés à la main : ils priment sur le relevé automatique.
    var overridden: [String] = []

    enum CodingKeys: String, CodingKey {
        case vendor, model, version, serial, kernel, macs, bios, chassis, virt, updates, uptime
        case cpuModel = "cpu_model"
        case cpuCount = "cpu_count"
        case memTotal = "mem_total"
        case diskTotal = "disk_total"
        case securityUpdates = "security_updates"
        case rebootRequired = "reboot_required"
        case overridden = "_overridden"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor)?.trimmedOrNil
        model = try c.decodeIfPresent(String.self, forKey: .model)?.trimmedOrNil
        version = try c.decodeIfPresent(String.self, forKey: .version)?.trimmedOrNil
        serial = try c.decodeIfPresent(String.self, forKey: .serial)?.trimmedOrNil
        kernel = try c.decodeIfPresent(String.self, forKey: .kernel)?.trimmedOrNil
        cpuModel = try c.decodeIfPresent(String.self, forKey: .cpuModel)?.trimmedOrNil
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount)
        memTotal = try c.decodeIfPresent(Double.self, forKey: .memTotal)
        diskTotal = try c.decodeIfPresent(Double.self, forKey: .diskTotal)
        macs = (try? c.decode([String: String].self, forKey: .macs)) ?? [:]
        bios = try c.decodeIfPresent(String.self, forKey: .bios)?.trimmedOrNil
        chassis = try c.decodeIfPresent(String.self, forKey: .chassis)?.trimmedOrNil
        virt = try c.decodeIfPresent(String.self, forKey: .virt)?.trimmedOrNil
        updates = try c.decodeIfPresent(Int.self, forKey: .updates)
        securityUpdates = try c.decodeIfPresent(Int.self, forKey: .securityUpdates)
        rebootRequired = (try? c.decode(Bool.self, forKey: .rebootRequired)) ?? false
        uptime = try c.decodeIfPresent(Double.self, forKey: .uptime)
        overridden = (try? c.decode([String].self, forKey: .overridden)) ?? []
    }

    /// Une machine dont rien n'a été relevé : la fiche n'a rien à montrer.
    var isEmpty: Bool {
        vendor == nil && model == nil && serial == nil && cpuModel == nil
            && memTotal == nil && diskTotal == nil && macs.isEmpty
    }

    func isOverridden(_ field: String) -> Bool { overridden.contains(field) }
}

private extension String {
    /// Le BIOS d'une carte mère renvoie souvent « » ou « System Serial Number » :
    /// une chaîne vide déguisée vaut mieux affichée comme absente.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Corps de `PATCH /inventory/{id}` — seuls les champs envoyés sont modifiés.
struct InventoryPatch: Encodable, Sendable {
    var category: String?
    var location: String?
    var notes: String?
    var tags: [String]?
    var enabled: Bool?
}

/// Corps de `POST /inventory/bulk`.
struct InventoryBulkPatch: Encodable, Sendable {
    var hostIDs: [Int]
    var category: String?
    var location: String?
    var addTags: [String] = []
    var removeTags: [String] = []

    enum CodingKeys: String, CodingKey {
        case category, location
        case hostIDs = "host_ids"
        case addTags = "add_tags"
        case removeTags = "remove_tags"
    }
}
