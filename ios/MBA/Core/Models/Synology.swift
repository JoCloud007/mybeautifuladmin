import Foundation

/// Un NAS Synology, tel que `GET /synology/hosts` le rend : la ligne d'hôte,
/// enrichie du dernier échantillon du flux (volumes, disques, groupes).
struct SynologyHost: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var address: String
    var status: HostStatus
    var volumes: [SynoVolume]
    var disks: [SynoDisk]
    var pools: [SynoPool]
    var info: SynoInfo
    var live: [String: Double]

    enum CodingKeys: String, CodingKey {
        case id, name, address, status, volumes, disks, pools, info, live
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        address = (try? c.decode(String.self, forKey: .address)) ?? ""
        status = (try? c.decode(HostStatus.self, forKey: .status)) ?? .unknown
        volumes = (try? c.decode([SynoVolume].self, forKey: .volumes)) ?? []
        disks = (try? c.decode([SynoDisk].self, forKey: .disks)) ?? []
        pools = (try? c.decode([SynoPool].self, forKey: .pools)) ?? []
        info = (try? c.decode(SynoInfo.self, forKey: .info)) ?? SynoInfo()
        live = (try? c.decode([String: Double].self, forKey: .live)) ?? [:]
    }

    /// Le volume le plus rempli : c'est lui qui décidera du jour où le NAS
    /// refusera d'écrire.
    var fullestVolume: SynoVolume? {
        volumes.max { $0.percent < $1.percent }
    }

    /// Un disque dont le SMART n'est plus « normal » condamne tout le groupe.
    var failingDisks: [SynoDisk] {
        disks.filter { !$0.isHealthy }
    }

    var hottestDisk: SynoDisk? {
        disks.compactMap { $0.temp == nil ? nil : $0 }.max { ($0.temp ?? 0) < ($1.temp ?? 0) }
    }

    var uptime: Double? { live["uptime"] }
    var cpuUsage: Double? { live["cpu.usage"] }
    var memoryPercent: Double? { live["mem.percent"] }
}

struct SynoInfo: Codable, Hashable, Sendable {
    var model: String?
    var serial: String?
    var dsmVersion: String?
    var temperature: Double?
    var tempWarn: Bool = false
    var ntp: String?
    var time: String?

    enum CodingKeys: String, CodingKey {
        case model, serial, ntp, time, temperature
        case dsmVersion = "dsm_version"
        case tempWarn = "temp_warn"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        dsmVersion = try c.decodeIfPresent(String.self, forKey: .dsmVersion)
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        tempWarn = (try? c.decode(Bool.self, forKey: .tempWarn)) ?? false
        ntp = try c.decodeIfPresent(String.self, forKey: .ntp)
        time = try c.decodeIfPresent(String.self, forKey: .time)
    }
}

struct SynoVolume: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var fs: String?
    var status: String
    var total: Double
    var used: Double
    var percent: Double
    var raid: String?

    var isHealthy: Bool { status == "normal" }
    var free: Double { max(0, total - used) }
}

struct SynoDisk: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var model: String?
    var vendor: String?
    var size: Double
    var temp: Double?
    var status: String
    var smart: String?
    var type: String?

    /// DSM distingue l'état du disque et le verdict SMART : les deux doivent
    /// être « normal » pour qu'on puisse dormir tranquille.
    var isHealthy: Bool {
        status == "normal" && (smart == nil || smart == "normal")
    }

    var label: String {
        [vendor, model].compactMap { $0 }.joined(separator: " ")
    }
}

struct SynoPool: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var raid: String?
    var status: String
    var size: Double

    var isHealthy: Bool { status == "normal" }
}

/// Un dossier partagé.
struct SynoShare: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var desc: String?
    var uuid: String?
    var volPath: String?
    var isUSBShare: Bool

    var id: String { uuid ?? name }

    enum CodingKeys: String, CodingKey {
        case name, desc, uuid
        case volPath = "vol_path"
        case isUSBShare = "is_usb_share"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        desc = try c.decodeIfPresent(String.self, forKey: .desc)
        uuid = try c.decodeIfPresent(String.self, forKey: .uuid)
        volPath = try c.decodeIfPresent(String.self, forKey: .volPath)
        isUSBShare = (try? c.decode(Bool.self, forKey: .isUSBShare)) ?? false
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.lowercased().contains(query)
            || (desc?.lowercased().contains(query) ?? false)
    }
}

/// Réponse de `GET /synology/{id}/services`.
///
/// `reason` porte l'explication quand DSM refuse : selon la version, l'API
/// existe mais renvoie une erreur 103 au lieu d'une liste.
struct SynoServicesResponse: Codable, Sendable {
    var services: [SynoService]
    var reason: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        services = (try? c.decode([SynoService].self, forKey: .services)) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

struct SynoService: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String?
    var enabled: Bool
    var status: String?
    var packagename: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, status, packagename
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status)
        packagename = try c.decodeIfPresent(String.self, forKey: .packagename)
    }

    var label: String { name ?? id }
}

/// Réponse de `GET /synology/{id}/access` : qui peut entrer, qui est entré.
struct SynoAccess: Codable, Sendable {
    var users: [SynoUser]
    var connections: [SynoConnection]
    var usersReason: String?
    var connectionsReason: String?

    enum CodingKeys: String, CodingKey {
        case users, connections
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Chaque bloc est lui-même enveloppé par le collecteur, avec sa propre
        // explication en cas de refus de DSM.
        let userBlock = try? c.decode(UserBlock.self, forKey: .users)
        let connectionBlock = try? c.decode(ConnectionBlock.self, forKey: .connections)
        users = userBlock?.users ?? []
        usersReason = userBlock?.reason
        connections = connectionBlock?.connections ?? []
        connectionsReason = connectionBlock?.reason
    }

    private struct UserBlock: Decodable {
        var users: [SynoUser] = []
        var reason: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            users = (try? c.decode([SynoUser].self, forKey: .users)) ?? []
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }

        enum CodingKeys: String, CodingKey { case users, reason }
    }

    private struct ConnectionBlock: Decodable {
        var connections: [SynoConnection] = []
        var reason: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            connections = (try? c.decode([SynoConnection].self, forKey: .connections)) ?? []
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }

        enum CodingKeys: String, CodingKey { case connections, reason }
    }

    var admins: [SynoUser] { users.filter(\.admin) }
}

struct SynoUser: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var description: String?
    var email: String?
    var expired: String?
    var admin: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, description, email, expired, admin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        expired = try c.decodeIfPresent(String.self, forKey: .expired)
        admin = (try? c.decode(Bool.self, forKey: .admin)) ?? false
    }

    /// DSM renvoie « now » pour un compte désactivé, « normal » pour un compte
    /// valide — un vocabulaire qui ne se devine pas.
    var isDisabled: Bool { expired == "now" }
}

struct SynoConnection: Codable, Identifiable, Hashable, Sendable {
    var who: String?
    var from: String
    var type: String
    var descr: String?
    var time: String?

    var id: String { "\(from)-\(type)-\(time ?? "")" }

    enum CodingKeys: String, CodingKey {
        case who, from, type, descr, time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        who = try c.decodeIfPresent(String.self, forKey: .who)
        from = (try? c.decode(String.self, forKey: .from)) ?? "—"
        type = (try? c.decode(String.self, forKey: .type)) ?? "—"
        descr = try c.decodeIfPresent(String.self, forKey: .descr)
        time = try c.decodeIfPresent(String.self, forKey: .time)
    }

    /// Un montage NFS n'a pas d'utilisateur : le champ revient vide.
    var user: String {
        let trimmed = who?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "anonyme" : trimmed
    }

    var detail: String? {
        let trimmed = descr?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty || trimmed == "-" ? nil : trimmed
    }
}

/// Réponse de `GET /synology/{id}/tasks` : le planificateur de DSM.
struct SynoTasksResponse: Codable, Sendable {
    var tasks: [SynoTask]
    var reason: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = (try? c.decode([SynoTask].self, forKey: .tasks)) ?? []
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }
}

struct SynoTask: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var owner: String?
    var type: String?
    var enabled: Bool
    var schedule: String?
    /// Tantôt une date « 2026-08-19 05:00 », tantôt un déclencheur « bootup » :
    /// DSM mélange les deux dans le même champ, on le garde tel quel.
    var nextRun: String?
    var lastRun: String?
    var lastStatus: String?
    var canRun: Bool
    var canEdit: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, owner, type, enabled, schedule
        case nextRun = "next_run"
        case lastRun = "last_run"
        case lastStatus = "last_status"
        case canRun = "can_run"
        case canEdit = "can_edit"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule)
        nextRun = try c.decodeIfPresent(String.self, forKey: .nextRun)
        lastRun = try c.decodeIfPresent(String.self, forKey: .lastRun)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        canRun = (try? c.decode(Bool.self, forKey: .canRun)) ?? false
        canEdit = (try? c.decode(Bool.self, forKey: .canEdit)) ?? false
    }

    var typeLabel: String {
        switch type {
        case "script": "Script"
        case "event_script": "Au démarrage"
        case "custom": "Système"
        case "service": "Service"
        default: type ?? "Tâche"
        }
    }

    var lastSucceeded: Bool? {
        guard let lastStatus else { return nil }
        return lastStatus.lowercased() == "success" || lastStatus == "0"
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.lowercased().contains(query)
            || (owner?.lowercased().contains(query) ?? false)
    }
}

/// Corps de `POST /synology/{id}/tasks`.
struct SynoTaskPayload: Encodable, Sendable {
    var taskID: Int
    var action: String

    enum CodingKeys: String, CodingKey {
        case action
        case taskID = "task_id"
    }
}
