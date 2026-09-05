import Foundation

/// Un hyperviseur (ou cluster) Proxmox, tel que `GET /proxmox/hosts` le rend :
/// la ligne d'hôte habituelle, enrichie du dernier échantillon du flux.
struct PVECluster: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var address: String
    var status: HostStatus
    var nodes: [PVENode]
    var storages: [PVEStorage]
    var guests: [PVEGuest]

    enum CodingKeys: String, CodingKey {
        case id, name, address, status, nodes, storages, guests
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        address = (try? c.decode(String.self, forKey: .address)) ?? ""
        status = (try? c.decode(HostStatus.self, forKey: .status)) ?? .unknown
        nodes = (try? c.decode([PVENode].self, forKey: .nodes)) ?? []
        storages = (try? c.decode([PVEStorage].self, forKey: .storages)) ?? []
        guests = (try? c.decode([PVEGuest].self, forKey: .guests)) ?? []
    }

    var runningGuests: Int { guests.filter(\.isRunning).count }

    /// Un cluster dont le flux n'a encore rien poussé : la fiche s'ouvre quand
    /// même, mais l'inventaire viendra de la base.
    var hasLiveSample: Bool { !nodes.isEmpty || !guests.isEmpty }
}

/// Un nœud de l'hyperviseur.
struct PVENode: Codable, Identifiable, Hashable, Sendable {
    var node: String
    var status: String
    var cpu: Double
    var cpuCount: Int
    var cpuModel: String?
    var memUsed: Double
    var memTotal: Double
    var diskUsed: Double
    var diskTotal: Double
    var uptime: Double
    var loadavg: [Double]
    var version: String?

    var id: String { node }

    enum CodingKeys: String, CodingKey {
        case node, status, cpu, uptime, loadavg, version
        case cpuCount = "cpu_count"
        case cpuModel = "cpu_model"
        case memUsed = "mem_used"
        case memTotal = "mem_total"
        case diskUsed = "disk_used"
        case diskTotal = "disk_total"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = (try? c.decode(String.self, forKey: .node)) ?? "—"
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        cpu = (try? c.decode(Double.self, forKey: .cpu)) ?? 0
        cpuCount = (try? c.decode(Int.self, forKey: .cpuCount)) ?? 0
        cpuModel = try c.decodeIfPresent(String.self, forKey: .cpuModel)
        memUsed = (try? c.decode(Double.self, forKey: .memUsed)) ?? 0
        memTotal = (try? c.decode(Double.self, forKey: .memTotal)) ?? 0
        diskUsed = (try? c.decode(Double.self, forKey: .diskUsed)) ?? 0
        diskTotal = (try? c.decode(Double.self, forKey: .diskTotal)) ?? 0
        uptime = (try? c.decode(Double.self, forKey: .uptime)) ?? 0
        loadavg = (try? c.decode([Double].self, forKey: .loadavg)) ?? []
        version = try c.decodeIfPresent(String.self, forKey: .version)
    }

    var isOnline: Bool { status == "online" }
    var memPercent: Double { memTotal > 0 ? 100 * memUsed / memTotal : 0 }
    var diskPercent: Double { diskTotal > 0 ? 100 * diskUsed / diskTotal : 0 }

    /// Charge normalisée par cœur : au-delà de 1, le nœud est en file d'attente.
    var loadPerCore: Double? {
        guard let load = loadavg.first, cpuCount > 0 else { return nil }
        return load / Double(cpuCount)
    }

    /// La version de `pve-manager` sans le hachage de build, illisible ici.
    var shortVersion: String? {
        version?.split(separator: "/").dropFirst().first.map(String.init)
    }
}

struct PVEStorage: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var node: String
    var used: Double
    var total: Double
    var percent: Double
    var status: String

    var id: String { "\(node):\(name)" }

    /// Un stockage déclaré mais non monté rapporte une taille nulle : l'afficher
    /// à 0 % le ferait passer pour sain.
    var isAvailable: Bool { status == "available" && total > 0 }
}

/// Une VM (`qemu`) ou un conteneur (`lxc`).
struct PVEGuest: Codable, Identifiable, Hashable, Sendable {
    var vmid: Int
    var name: String
    var type: GuestKind
    var node: String
    var status: String
    var cpu: Double
    var maxCPU: Int
    var mem: Double
    var maxMem: Double
    var memPercent: Double
    var disk: Double
    var maxDisk: Double
    var uptime: Double
    var tags: [String]

    var id: String { "\(node):\(type.rawValue):\(vmid)" }

    enum CodingKeys: String, CodingKey {
        case vmid, name, type, node, status, cpu, mem, disk, uptime, tags
        case maxCPU = "maxcpu"
        case maxMem = "maxmem"
        case memPercent = "mem_percent"
        case maxDisk = "maxdisk"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmid = (try? c.decode(Int.self, forKey: .vmid)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        type = (try? c.decode(GuestKind.self, forKey: .type)) ?? .qemu
        node = (try? c.decode(String.self, forKey: .node)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        cpu = (try? c.decode(Double.self, forKey: .cpu)) ?? 0
        maxCPU = (try? c.decode(Int.self, forKey: .maxCPU)) ?? 0
        mem = (try? c.decode(Double.self, forKey: .mem)) ?? 0
        maxMem = (try? c.decode(Double.self, forKey: .maxMem)) ?? 0
        memPercent = (try? c.decode(Double.self, forKey: .memPercent)) ?? 0
        disk = (try? c.decode(Double.self, forKey: .disk)) ?? 0
        maxDisk = (try? c.decode(Double.self, forKey: .maxDisk)) ?? 0
        uptime = (try? c.decode(Double.self, forKey: .uptime)) ?? 0
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
    }

    var isRunning: Bool { status == "running" }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.lowercased().contains(query)
            || String(vmid).contains(query)
            || tags.contains { $0.lowercased().contains(query) }
    }
}

enum GuestKind: String, Codable, Sendable {
    case qemu, lxc

    var label: String {
        switch self {
        case .qemu: "VM"
        case .lxc: "LXC"
        }
    }

    var symbol: String {
        switch self {
        case .qemu: "desktopcomputer"
        case .lxc: "shippingbox"
        }
    }

    /// Un conteneur LXC ne connaît ni suspension ni `reset` matériel.
    var supportsSuspend: Bool { self == .qemu }
}

/// Réponse de `GET /proxmox/{id}/guests`.
struct PVEInventory: Codable, Sendable {
    var guests: [PVEGuest]
    var nodes: [PVENode]
    var storages: [PVEStorage]
    var summary: Summary

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guests = (try? c.decode([PVEGuest].self, forKey: .guests)) ?? []
        nodes = (try? c.decode([PVENode].self, forKey: .nodes)) ?? []
        storages = (try? c.decode([PVEStorage].self, forKey: .storages)) ?? []
        summary = (try? c.decode(Summary.self, forKey: .summary)) ?? Summary()
    }

    struct Summary: Codable, Sendable {
        var total: Int = 0
        var running: Int = 0
        var qemu: Int = 0
        var lxc: Int = 0

        init() {}
    }
}

/// Réponse de `GET /proxmox/{id}/guests/{kind}/{vmid}`.
struct PVEGuestDetail: Codable, Sendable {
    var node: String
    var vmid: Int
    var kind: GuestKind
    var status: String?
    var live: Live
    var config: PVEGuestConfig
    var snapshots: [PVESnapshot]
    var history: [PVEHistoryPoint]
    var backups: [PVEBackup]
    var backupStorages: [PVEBackupStorage]
    var consoleURL: String?

    enum CodingKeys: String, CodingKey {
        case node, vmid, kind, status, live, config, snapshots, history, backups
        case backupStorages = "backup_storages"
        case consoleURL = "console_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        node = (try? c.decode(String.self, forKey: .node)) ?? ""
        vmid = (try? c.decode(Int.self, forKey: .vmid)) ?? 0
        kind = (try? c.decode(GuestKind.self, forKey: .kind)) ?? .qemu
        status = try c.decodeIfPresent(String.self, forKey: .status)
        live = (try? c.decode(Live.self, forKey: .live)) ?? Live()
        config = (try? c.decode(PVEGuestConfig.self, forKey: .config)) ?? PVEGuestConfig()
        snapshots = (try? c.decode([PVESnapshot].self, forKey: .snapshots)) ?? []
        history = (try? c.decode([PVEHistoryPoint].self, forKey: .history)) ?? []
        backups = (try? c.decode([PVEBackup].self, forKey: .backups)) ?? []
        backupStorages = (try? c.decode([PVEBackupStorage].self, forKey: .backupStorages)) ?? []
        consoleURL = try c.decodeIfPresent(String.self, forKey: .consoleURL)
    }

    var isRunning: Bool { status == "running" }

    struct Live: Codable, Sendable {
        var cpu: Double?
        var mem: Double?
        var maxmem: Double?
        var memPercent: Double?
        var uptime: Double?

        enum CodingKeys: String, CodingKey {
            case cpu, mem, maxmem, uptime
            case memPercent = "mem_percent"
        }

        init() {}
    }

    var cpuPoints: [MetricPoint] {
        history.map { MetricPoint(date: $0.date, value: $0.cpu) }
    }

    /// Le RRD donne des octets : le pourcentage se recalcule ici, faute d'être
    /// fourni, et sans lui la courbe mémoire n'est pas comparable au CPU.
    var memoryPoints: [MetricPoint] {
        history.compactMap { point in
            guard point.maxMem > 0 else { return nil }
            return MetricPoint(date: point.date, value: 100 * point.mem / point.maxMem)
        }
    }
}

struct PVEGuestConfig: Codable, Sendable {
    var name: String?
    var cores: Int?
    var sockets: Int?
    var memory: Double?
    var balloon: Double?
    var onboot: Bool = false
    var description: String = ""
    var tags: [String] = []
    var ostype: String?
    var boot: String?
    var disks: [Disk] = []
    var networks: [Network] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        cores = (try? c.decode(Int.self, forKey: .cores))
            ?? (try? c.decode(String.self, forKey: .cores)).flatMap(Int.init)
        sockets = (try? c.decode(Int.self, forKey: .sockets))
            ?? (try? c.decode(String.self, forKey: .sockets)).flatMap(Int.init)
        // Proxmox rend `memory` tantôt en nombre, tantôt en chaîne selon la
        // version de l'API et le type d'invité.
        memory = (try? c.decode(Double.self, forKey: .memory))
            ?? (try? c.decode(String.self, forKey: .memory)).flatMap(Double.init)
        balloon = (try? c.decode(Double.self, forKey: .balloon))
            ?? (try? c.decode(String.self, forKey: .balloon)).flatMap(Double.init)
        onboot = (try? c.decode(Bool.self, forKey: .onboot)) ?? false
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        ostype = try c.decodeIfPresent(String.self, forKey: .ostype)
        boot = try c.decodeIfPresent(String.self, forKey: .boot)
        disks = (try? c.decode([Disk].self, forKey: .disks)) ?? []
        networks = (try? c.decode([Network].self, forKey: .networks)) ?? []
    }

    /// Mio → octets, pour passer par le même formateur que le reste.
    var memoryBytes: Double? { memory.map { $0 * 1024 * 1024 } }

    var totalCores: Int? {
        guard let cores else { return nil }
        return cores * (sockets ?? 1)
    }

    struct Disk: Codable, Identifiable, Hashable, Sendable {
        var slot: String
        var size: String?
        var spec: String

        var id: String { slot }
        /// `none` est le lecteur optique vide d'une VM : rien à afficher.
        var isPresent: Bool { spec != "none" }
    }

    struct Network: Codable, Identifiable, Hashable, Sendable {
        var slot: String
        var bridge: String?
        var mac: String?
        var spec: String

        var id: String { slot }
    }
}

struct PVESnapshot: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var description: String
    var created: Date?
    var parent: String?
    var vmstate: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, description, created, parent, vmstate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        created = c.decodeLooseDate(forKey: .created)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        vmstate = (try? c.decode(Bool.self, forKey: .vmstate)) ?? false
    }
}

struct PVEHistoryPoint: Codable, Identifiable, Sendable {
    var time: Double
    var cpu: Double
    var mem: Double
    var maxMem: Double

    var id: Double { time }
    var date: Date { Date(timeIntervalSince1970: time) }

    enum CodingKeys: String, CodingKey {
        case time, cpu, mem
        case maxMem = "maxmem"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = (try? c.decode(Double.self, forKey: .time)) ?? 0
        cpu = (try? c.decode(Double.self, forKey: .cpu)) ?? 0
        mem = (try? c.decode(Double.self, forKey: .mem)) ?? 0
        maxMem = (try? c.decode(Double.self, forKey: .maxMem)) ?? 0
    }
}

struct PVEBackup: Codable, Identifiable, Hashable, Sendable {
    var volid: String
    var storage: String
    var vmid: Int?
    var size: Double
    var created: Date?
    var format: String?
    var notes: String?
    var isProtected: Bool

    var id: String { volid }

    enum CodingKeys: String, CodingKey {
        case volid, storage, vmid, size, created, format, notes
        case isProtected = "protected"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volid = (try? c.decode(String.self, forKey: .volid)) ?? ""
        storage = (try? c.decode(String.self, forKey: .storage)) ?? ""
        vmid = try c.decodeIfPresent(Int.self, forKey: .vmid)
        size = (try? c.decode(Double.self, forKey: .size)) ?? 0
        created = c.decodeLooseDate(forKey: .created)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        isProtected = (try? c.decode(Bool.self, forKey: .isProtected)) ?? false
    }
}

struct PVEBackupStorage: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var type: String
    var available: Double
    var total: Double

    var id: String { name }

    var usedPercent: Double {
        total > 0 ? 100 * (total - available) / total : 0
    }
}

/// Une tâche du nœud (`GET /proxmox/{id}/tasks`).
struct PVETask: Codable, Identifiable, Hashable, Sendable {
    var upid: String
    var type: String
    var vmid: String?
    var user: String?
    var status: String?
    var started: Date?
    var ended: Date?
    var node: String?

    var id: String { upid }

    enum CodingKeys: String, CodingKey {
        case upid, type, vmid, user, status, started, ended, node
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upid = (try? c.decode(String.self, forKey: .upid)) ?? UUID().uuidString
        type = (try? c.decode(String.self, forKey: .type)) ?? "—"
        // `vmid` sort en chaîne dans la liste des tâches, en nombre ailleurs.
        vmid = (try? c.decode(String.self, forKey: .vmid))
            ?? (try? c.decode(Int.self, forKey: .vmid)).map { String($0) }
        user = try c.decodeIfPresent(String.self, forKey: .user)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        started = c.decodeLooseDate(forKey: .started)
        ended = c.decodeLooseDate(forKey: .ended)
        node = try c.decodeIfPresent(String.self, forKey: .node)
    }

    var isRunning: Bool { ended == nil && status == nil || status == "running" }
    var succeeded: Bool { status == "OK" }

    var duration: Double? {
        guard let started, let ended, ended > started else { return nil }
        return ended.timeIntervalSince(started)
    }

    /// « vzdump », « qmstart »… traduits quand on sait, laissés bruts sinon.
    var label: String {
        switch type {
        case "vzdump": "Sauvegarde"
        case "qmstart", "vzstart": "Démarrage"
        case "qmstop", "vzstop": "Arrêt"
        case "qmshutdown", "vzshutdown": "Extinction"
        case "qmreboot", "vzreboot": "Redémarrage"
        case "qmsnapshot": "Snapshot"
        case "qmrollback": "Restauration de snapshot"
        case "qmclone", "vzclone": "Clonage"
        case "qmigrate", "vzmigrate": "Migration"
        case "imgdel": "Suppression de disque"
        case "srvreload": "Rechargement de service"
        default: type
        }
    }
}

// MARK: - Corps de requête

struct PVESnapshotPayload: Encodable, Sendable {
    var name: String
    var description: String
    var vmstate: Bool
}

struct PVEBackupPayload: Encodable, Sendable {
    var storage: String
    var mode: String
    var compress: String
    var notes: String
}

struct PVEConfigPayload: Encodable, Sendable {
    var cores: Int?
    var memory: Int?
    var name: String?
    var onboot: Bool?
}
