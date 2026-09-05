import Foundation

/// Réponse de `GET /updates` : trois familles de mises à jour côte à côte, qui
/// n'ont ni le même rythme ni la même façon d'être appliquées.
struct UpdateOverview: Codable, Sendable {
    var hosts: [UpdateHost]
    var stacks: [ComposeStack]
    var synology: [SynologyUpdateState]
    var summary: Summary

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = (try? container.decode([UpdateHost].self, forKey: .hosts)) ?? []
        stacks = (try? container.decode([ComposeStack].self, forKey: .stacks)) ?? []
        synology = (try? container.decode([SynologyUpdateState].self, forKey: .synology)) ?? []
        summary = (try? container.decode(Summary.self, forKey: .summary)) ?? Summary()
    }

    struct Summary: Codable, Sendable {
        var hosts: Int = 0
        var hostsPending: Int = 0
        var packages: Int = 0
        var security: Int = 0
        var rebootRequired: Int = 0
        var autoUpdates: Int = 0
        var offline: Int = 0
        var stacks: Int = 0
        var floatingImages: Int = 0
        var synoPackages: Int = 0
        var dsmPending: Int = 0

        enum CodingKeys: String, CodingKey {
            case hosts, packages, security, offline, stacks
            case hostsPending = "hosts_pending"
            case rebootRequired = "reboot_required"
            case autoUpdates = "auto_updates"
            case floatingImages = "floating_images"
            case synoPackages = "syno_packages"
            case dsmPending = "dsm_pending"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hosts = (try? c.decode(Int.self, forKey: .hosts)) ?? 0
            hostsPending = (try? c.decode(Int.self, forKey: .hostsPending)) ?? 0
            packages = (try? c.decode(Int.self, forKey: .packages)) ?? 0
            security = (try? c.decode(Int.self, forKey: .security)) ?? 0
            rebootRequired = (try? c.decode(Int.self, forKey: .rebootRequired)) ?? 0
            autoUpdates = (try? c.decode(Int.self, forKey: .autoUpdates)) ?? 0
            offline = (try? c.decode(Int.self, forKey: .offline)) ?? 0
            stacks = (try? c.decode(Int.self, forKey: .stacks)) ?? 0
            floatingImages = (try? c.decode(Int.self, forKey: .floatingImages)) ?? 0
            synoPackages = (try? c.decode(Int.self, forKey: .synoPackages)) ?? 0
            dsmPending = (try? c.decode(Int.self, forKey: .dsmPending)) ?? 0
        }
    }
}

/// Une machine et son retard de correctifs.
struct UpdateHost: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var kind: String
    var address: String
    var status: String
    var tags: [String]
    var os: String?
    var updates: Int
    var securityUpdates: Int
    var rebootRequired: Bool
    var kernelStale: Bool
    var kernelRunning: String?
    var kernelInstalled: String?
    var autoUpdates: Bool
    var lastSeen: Date?
    /// Vrai quand MBA sait appliquer les correctifs lui-même, par SSH.
    var upgradable: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, kind, address, status, tags, os, updates, upgradable
        case securityUpdates = "security_updates"
        case rebootRequired = "reboot_required"
        case kernelStale = "kernel_stale"
        case kernelRunning = "kernel_running"
        case kernelInstalled = "kernel_installed"
        case autoUpdates = "auto_updates"
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
        os = try c.decodeIfPresent(String.self, forKey: .os)
        updates = (try? c.decode(Int.self, forKey: .updates)) ?? 0
        securityUpdates = (try? c.decode(Int.self, forKey: .securityUpdates)) ?? 0
        rebootRequired = (try? c.decode(Bool.self, forKey: .rebootRequired)) ?? false
        kernelStale = (try? c.decode(Bool.self, forKey: .kernelStale)) ?? false
        kernelRunning = try c.decodeIfPresent(String.self, forKey: .kernelRunning)
        kernelInstalled = try c.decodeIfPresent(String.self, forKey: .kernelInstalled)
        autoUpdates = (try? c.decode(Bool.self, forKey: .autoUpdates)) ?? false
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        upgradable = (try? c.decode(Bool.self, forKey: .upgradable)) ?? false
    }

    var hostKind: HostKind { HostKind(rawValue: kind) ?? .generic }
    var hostStatus: HostStatus { HostStatus(rawValue: status) ?? .unknown }
    var isOffline: Bool { status == "offline" }

    /// Une machine injoignable ne peut pas être mise à jour, même si son type
    /// s'y prête : inutile de proposer une action qui échouera.
    var canUpgradeNow: Bool { upgradable && !isOffline && updates > 0 }
    var canRebootNow: Bool { upgradable && !isOffline }

    var isUpToDate: Bool { updates == 0 && !rebootRequired }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, address, os].compactMap { $0?.lowercased() }.contains { $0.contains(query) }
            || tags.contains { $0.lowercased().contains(query) }
    }
}

/// Une pile Docker Compose, vue depuis les conteneurs qui la composent.
struct ComposeStack: Codable, Identifiable, Hashable, Sendable {
    var hostID: Int
    var hostName: String
    var project: String
    var tags: [String]
    var total: Int
    var running: Int
    /// Conteneurs sur une image `:latest` — impossible de savoir s'ils sont à
    /// jour sans tirer l'image, d'où le signalement.
    var floating: Int
    var updatedAt: Date?

    var id: String { "\(hostID):\(project)" }

    enum CodingKeys: String, CodingKey {
        case project, tags, total, running, floating
        case hostID = "host_id"
        case hostName = "host_name"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = (try? c.decode(Int.self, forKey: .hostID)) ?? 0
        hostName = (try? c.decode(String.self, forKey: .hostName)) ?? "—"
        project = (try? c.decode(String.self, forKey: .project)) ?? "—"
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        total = (try? c.decode(Int.self, forKey: .total)) ?? 0
        running = (try? c.decode(Int.self, forKey: .running)) ?? 0
        floating = (try? c.decode(Int.self, forKey: .floating)) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var isFullyRunning: Bool { running == total && total > 0 }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return project.lowercased().contains(query) || hostName.lowercased().contains(query)
    }
}

/// Paquets et DSM d'un NAS Synology.
struct SynologyUpdateState: Codable, Identifiable, Hashable, Sendable {
    var hostID: Int
    var name: String
    var tags: [String]
    var packages: [SynologyPackage]
    var dsm: DSMUpdate?
    /// Explication du NAS quand il ne propose rien (catalogue indisponible…).
    var reason: String?
    var error: String?

    var id: Int { hostID }

    enum CodingKeys: String, CodingKey {
        case name, tags, packages, dsm, reason, error
        case hostID = "host_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = (try? c.decode(Int.self, forKey: .hostID)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        packages = (try? c.decode([SynologyPackage].self, forKey: .packages)) ?? []
        dsm = try? c.decodeIfPresent(DSMUpdate.self, forKey: .dsm)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    var hasWork: Bool { !packages.isEmpty || (dsm?.available ?? false) }
}

struct SynologyPackage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var version: String
    var installedVersion: String?
    var security: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, version, security
        case installedVersion = "installed_version"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        version = (try? c.decode(String.self, forKey: .version)) ?? "—"
        installedVersion = try c.decodeIfPresent(String.self, forKey: .installedVersion)
        security = (try? c.decode(Bool.self, forKey: .security)) ?? false
    }
}

/// État de la mise à jour de DSM lui-même.
struct DSMUpdate: Codable, Hashable, Sendable {
    var current: String?
    var available: Bool
    var version: String?
    var reboot: String?
    var canDownload: Bool
    var canInstall: Bool
    var download: Download?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case current, available, version, reboot, download, reason
        case canDownload = "can_download"
        case canInstall = "can_install"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = try c.decodeIfPresent(String.self, forKey: .current)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? false
        version = try c.decodeIfPresent(String.self, forKey: .version)
        // DSM renvoie tantôt un libellé, tantôt un booléen « redémarrage requis ».
        reboot = (try? c.decode(String.self, forKey: .reboot))
            ?? (try? c.decode(Bool.self, forKey: .reboot)).map { $0 ? "requis" : "non" }
        canDownload = (try? c.decode(Bool.self, forKey: .canDownload)) ?? false
        canInstall = (try? c.decode(Bool.self, forKey: .canInstall)) ?? false
        download = try? c.decodeIfPresent(Download.self, forKey: .download)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    struct Download: Codable, Hashable, Sendable {
        var status: String?
        var percent: Double?
        var finished: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = try c.decodeIfPresent(String.self, forKey: .status)
            percent = try c.decodeIfPresent(Double.self, forKey: .percent)
            finished = (try? c.decode(Bool.self, forKey: .finished)) ?? false
        }

        /// « none » veut dire qu'aucun téléchargement n'a commencé.
        var isIdle: Bool { status == nil || status == "none" }
    }
}

/// Réponse de `GET /updates/activity` : ce que MBA applique en ce moment.
struct UpdateActivity: Codable, Sendable {
    var entries: [Entry]
    var running: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decode([Entry].self, forKey: .entries)) ?? []
        running = (try? c.decode(Int.self, forKey: .running)) ?? 0
    }

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        var hostID: Int?
        var hostName: String?
        var target: String?
        var action: String
        var status: String
        var startedAt: Date?
        var endedAt: Date?
        var excerpt: String?

        enum CodingKeys: String, CodingKey {
            case id, target, action, status, excerpt
            case hostID = "host_id"
            case hostName = "host_name"
            case startedAt = "started_at"
            case endedAt = "ended_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
            hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
            target = try c.decodeIfPresent(String.self, forKey: .target)
            action = (try? c.decode(String.self, forKey: .action)) ?? "—"
            status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
            excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
        }

        var isRunning: Bool { status == "running" }
        var succeeded: Bool { status == "success" }

        var duration: Double? {
            guard let startedAt else { return nil }
            return (endedAt ?? .now).timeIntervalSince(startedAt)
        }

        var label: String {
            switch action {
            case "upgrade": "Mise à jour des paquets"
            case "reboot": "Redémarrage"
            case "compose update": "Mise à jour de la pile"
            case "docker pull": "Récupération d'images"
            default: action
            }
        }

        var symbol: String {
            switch action {
            case "upgrade": "arrow.down.circle"
            case "reboot": "arrow.clockwise.circle"
            case "compose update", "docker pull": "shippingbox"
            default: "terminal"
            }
        }
    }
}

// MARK: - Corps de requête

struct HostBatchPayload: Encodable, Sendable {
    var hostIDs: [Int]
    var action: String

    enum CodingKeys: String, CodingKey {
        case action
        case hostIDs = "host_ids"
    }
}

struct StackBatchPayload: Encodable, Sendable {
    var targets: [Target]

    struct Target: Encodable, Sendable {
        var hostID: Int
        var project: String

        enum CodingKeys: String, CodingKey {
            case project
            case hostID = "host_id"
        }
    }
}

/// Réponse commune des deux lots : ce qui part, et ce qui est écarté.
struct BatchResult: Decodable, Sendable {
    var started: [Started]
    var skipped: [Skipped]

    // Déclarées à la main : le compilateur ne synthétise `CodingKeys` que s'il a
    // lui-même un `init(from:)` à écrire, ce qui n'est pas le cas ici.
    enum CodingKeys: String, CodingKey {
        case started, skipped
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        started = (try? c.decode([Started].self, forKey: .started)) ?? []
        skipped = (try? c.decode([Skipped].self, forKey: .skipped)) ?? []
    }

    struct Started: Decodable, Sendable {
        var name: String?
        var project: String?
        var hostName: String?

        enum CodingKeys: String, CodingKey {
            case name, project
            case hostName = "host_name"
        }

        var label: String { name ?? project ?? hostName ?? "?" }
    }

    struct Skipped: Decodable, Sendable {
        var name: String?
        var project: String?
        var reason: String

        var label: String { name ?? project ?? "?" }
    }

    /// Compte rendu prêt à afficher, écarts compris — c'est là que se voit une
    /// machine hors ligne qu'on croyait avoir relancée.
    var report: String {
        var lines = [started.isEmpty
                     ? "Aucune opération lancée."
                     : "\(Format.plural(started.count, "opération")) lancée\(started.count > 1 ? "s" : "") : \(started.map(\.label).joined(separator: ", "))."]
        if !skipped.isEmpty {
            lines.append("Écarté : " + skipped.map { "\($0.label) — \($0.reason)" }
                .joined(separator: " ; ") + ".")
        }
        return lines.joined(separator: "\n\n")
    }
}
