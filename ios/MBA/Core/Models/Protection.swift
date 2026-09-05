import Foundation

/// Réponse de `GET /protection` : couverture des sauvegardes, écarts et risques,
/// agrégés sur toutes les sources connues (PBS, vzdump, Hyper Backup).
struct ProtectionOverview: Codable, Sendable {
    var protectedItems: [ProtectedItem]
    var gaps: [ProtectionGap]
    var risks: [ProtectionRisk]
    var datastores: [Datastore]
    var tasks: [BackupTask]
    var errors: [SourceError]
    var notices: [SourceNotice]
    var summary: Summary

    enum CodingKeys: String, CodingKey {
        case gaps, risks, datastores, tasks, errors, notices, summary
        case protectedItems = "protected"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protectedItems = (try? container.decode([ProtectedItem].self, forKey: .protectedItems)) ?? []
        gaps = (try? container.decode([ProtectionGap].self, forKey: .gaps)) ?? []
        risks = (try? container.decode([ProtectionRisk].self, forKey: .risks)) ?? []
        datastores = (try? container.decode([Datastore].self, forKey: .datastores)) ?? []
        tasks = (try? container.decode([BackupTask].self, forKey: .tasks)) ?? []
        errors = (try? container.decode([SourceError].self, forKey: .errors)) ?? []
        notices = (try? container.decode([SourceNotice].self, forKey: .notices)) ?? []
        summary = (try? container.decode(Summary.self, forKey: .summary)) ?? Summary()
    }

    struct Summary: Codable, Sendable {
        var offsite: Int = 0
        var protectedCount: Int = 0
        var fresh: Int = 0
        var stale: Int = 0
        var critical: Int = 0
        var gaps: Int = 0
        var risks: Int = 0
        var risksCritical: Int = 0
        var coverage: Double = 100
        var sources: Int = 0
        var totalSize: Double = 0

        enum CodingKeys: String, CodingKey {
            case offsite, fresh, stale, critical, gaps, risks, coverage, sources
            case protectedCount = "protected"
            case risksCritical = "risks_critical"
            case totalSize = "total_size"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            offsite = (try? container.decode(Int.self, forKey: .offsite)) ?? 0
            protectedCount = (try? container.decode(Int.self, forKey: .protectedCount)) ?? 0
            fresh = (try? container.decode(Int.self, forKey: .fresh)) ?? 0
            stale = (try? container.decode(Int.self, forKey: .stale)) ?? 0
            critical = (try? container.decode(Int.self, forKey: .critical)) ?? 0
            gaps = (try? container.decode(Int.self, forKey: .gaps)) ?? 0
            risks = (try? container.decode(Int.self, forKey: .risks)) ?? 0
            risksCritical = (try? container.decode(Int.self, forKey: .risksCritical)) ?? 0
            coverage = (try? container.decode(Double.self, forKey: .coverage)) ?? 100
            sources = (try? container.decode(Int.self, forKey: .sources)) ?? 0
            totalSize = (try? container.decode(Double.self, forKey: .totalSize)) ?? 0
        }
    }
}

/// Un objet effectivement sauvegardé quelque part.
struct ProtectedItem: Codable, Identifiable, Hashable, Sendable {
    var source: BackupSource
    var sourceHost: String
    var sourceHostID: Int?
    var name: String
    var kind: String
    var ref: String
    var store: String?
    var count: Int?
    var size: Double?
    var lastBackup: Date?
    var ageHours: Double?
    var freshness: Freshness
    var enabled: Bool?
    var offsite: Bool
    var lastResult: String?

    var id: String { "\(sourceHost):\(source.rawValue):\(ref):\(name)" }

    enum CodingKeys: String, CodingKey {
        case source, name, kind, ref, store, count, size, freshness, enabled, offsite
        case sourceHost = "source_host"
        case sourceHostID = "source_host_id"
        case lastBackup = "last_backup"
        case ageHours = "age_hours"
        case lastResult = "last_result"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = (try? container.decode(BackupSource.self, forKey: .source)) ?? .other
        sourceHost = (try? container.decode(String.self, forKey: .sourceHost)) ?? "—"
        sourceHostID = try container.decodeIfPresent(Int.self, forKey: .sourceHostID)
        name = (try? container.decode(String.self, forKey: .name)) ?? "—"
        kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        ref = (try? container.decode(String.self, forKey: .ref)) ?? ""
        store = try container.decodeIfPresent(String.self, forKey: .store)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        size = try container.decodeIfPresent(Double.self, forKey: .size)
        lastBackup = container.decodeLooseDate(forKey: .lastBackup)
        ageHours = try container.decodeIfPresent(Double.self, forKey: .ageHours)
        freshness = (try? container.decode(Freshness.self, forKey: .freshness)) ?? .unknown
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        offsite = (try? container.decode(Bool.self, forKey: .offsite)) ?? false
        lastResult = try container.decodeIfPresent(String.self, forKey: .lastResult)
    }

    /// Là où la copie est posée : le datastore quand il est connu, sinon la
    /// machine qui la détient.
    var location: String { store?.isEmpty == false ? store! : sourceHost }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, store, sourceHost]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }
}

/// Fraîcheur d'une sauvegarde, telle que le serveur la juge (36 h / 7 j).
enum Freshness: String, Codable, Sendable {
    case fresh, stale, critical, unknown

    var label: String {
        switch self {
        case .fresh: "à jour"
        case .stale: "en retard"
        case .critical: "périmée"
        case .unknown: "inconnue"
        }
    }

    var symbol: String {
        switch self {
        case .fresh: "checkmark.circle.fill"
        case .stale: "clock.badge.exclamationmark.fill"
        case .critical: "exclamationmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}

/// Origine d'une sauvegarde ou d'un risque.
enum BackupSource: String, Codable, Sendable {
    case pbs, vzdump, hyperbackup, c2, global, other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .other
    }

    var label: String {
        switch self {
        case .pbs: "Proxmox Backup Server"
        case .vzdump: "vzdump (PVE)"
        case .hyperbackup: "Hyper Backup"
        case .c2: "Synology C2"
        case .global: "Analyse globale"
        case .other: "Autre"
        }
    }

    var shortLabel: String {
        switch self {
        case .pbs: "PBS"
        case .vzdump: "vzdump"
        case .hyperbackup: "Hyper Backup"
        case .c2: "C2"
        case .global: "Global"
        case .other: "Autre"
        }
    }
}

/// Un objet connu qui n'apparaît dans aucune sauvegarde.
struct ProtectionGap: Codable, Identifiable, Hashable, Sendable {
    var kind: String
    var name: String
    var ref: String
    var detail: String?
    var hostID: Int?
    var severity: FindingSeverity

    var id: String { "\(kind):\(ref)" }

    enum CodingKeys: String, CodingKey {
        case kind, name, ref, detail, severity
        case hostID = "host_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? "—"
        ref = (try? container.decode(String.self, forKey: .ref)) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        hostID = try container.decodeIfPresent(Int.self, forKey: .hostID)
        severity = (try? container.decode(FindingSeverity.self, forKey: .severity)) ?? .medium
    }

    var isGuest: Bool { kind == "guest" }
    var kindLabel: String { isGuest ? "VM / LXC" : "Machine" }
}

/// Un risque identifié sur la chaîne de sauvegarde.
struct ProtectionRisk: Codable, Identifiable, Hashable, Sendable {
    var severity: FindingSeverity
    var title: String
    var detail: String?
    var remediation: String?
    var target: String?
    var source: BackupSource

    var id: String { "\(severity.rawValue):\(title)" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        severity = (try? container.decode(FindingSeverity.self, forKey: .severity)) ?? .medium
        title = (try? container.decode(String.self, forKey: .title)) ?? "—"
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        remediation = try container.decodeIfPresent(String.self, forKey: .remediation)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        source = (try? container.decode(BackupSource.self, forKey: .source)) ?? .other
    }
}

/// Datastore PBS : c'est lui qui sature en premier quand la rétention dérive.
struct Datastore: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var total: Double
    var used: Double
    var available: Double
    var percent: Double
    var estimatedFull: Date?
    var sourceHost: String
    var source: BackupSource

    var id: String { "\(sourceHost):\(name)" }

    enum CodingKeys: String, CodingKey {
        case name, total, used, available, percent, source
        case estimatedFull = "estimated_full"
        case sourceHost = "source_host"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? "—"
        total = (try? container.decode(Double.self, forKey: .total)) ?? 0
        used = (try? container.decode(Double.self, forKey: .used)) ?? 0
        available = (try? container.decode(Double.self, forKey: .available)) ?? 0
        percent = (try? container.decode(Double.self, forKey: .percent)) ?? 0
        estimatedFull = container.decodeLooseDate(forKey: .estimatedFull)
        sourceHost = (try? container.decode(String.self, forKey: .sourceHost)) ?? "—"
        source = (try? container.decode(BackupSource.self, forKey: .source)) ?? .pbs
    }
}

/// Exécution de sauvegarde remontée par une source.
struct BackupTask: Codable, Identifiable, Hashable, Sendable {
    var upid: String?
    var type: String?
    var target: String?
    var user: String?
    var status: String?
    var started: Date?
    var ended: Date?
    var schedule: String?
    var next: Date?
    var sourceHost: String
    var source: BackupSource

    var id: String {
        upid ?? "\(sourceHost):\(target ?? type ?? "?"):\(started?.timeIntervalSince1970 ?? 0)"
    }

    enum CodingKeys: String, CodingKey {
        case upid, type, target, user, status, started, ended, schedule, next, source
        case sourceHost = "source_host"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        upid = try container.decodeIfPresent(String.self, forKey: .upid)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        user = try container.decodeIfPresent(String.self, forKey: .user)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        started = container.decodeLooseDate(forKey: .started)
        ended = container.decodeLooseDate(forKey: .ended)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        next = container.decodeLooseDate(forKey: .next)
        sourceHost = (try? container.decode(String.self, forKey: .sourceHost)) ?? "—"
        source = (try? container.decode(BackupSource.self, forKey: .source)) ?? .other
    }

    var label: String { target?.isEmpty == false ? target! : (type ?? "tâche") }

    /// Une tâche encore en cours n'est pas un échec : elle n'a simplement pas
    /// fini de rendre son verdict.
    var succeeded: Bool {
        guard let status, !status.isEmpty else { return true }
        return status == "OK" || status == "running"
    }

    var duration: Double? {
        guard let started, let ended, ended > started else { return nil }
        return ended.timeIntervalSince(started)
    }
}

/// Source injoignable au moment de l'agrégation.
struct SourceError: Codable, Identifiable, Hashable, Sendable {
    var host: String
    var kind: String
    var error: String

    var id: String { "\(host):\(kind)" }
}

/// Information non bloquante remontée par une source (Hyper Backup absent…).
struct SourceNotice: Codable, Identifiable, Hashable, Sendable {
    var host: String
    var kind: String
    var level: String
    var message: String

    var id: String { "\(host):\(message)" }

    var isWarning: Bool { level == "warning" }
}

/// Réponse de `GET /protection/sources` : sources déclarées et seuils du moteur.
struct ProtectionSources: Codable, Sendable {
    var sources: [Source]
    var hasPBS: Bool
    var thresholds: Thresholds

    enum CodingKeys: String, CodingKey {
        case sources, thresholds
        case hasPBS = "has_pbs"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = (try? container.decode([Source].self, forKey: .sources)) ?? []
        hasPBS = (try? container.decode(Bool.self, forKey: .hasPBS)) ?? false
        thresholds = (try? container.decode(Thresholds.self, forKey: .thresholds)) ?? Thresholds()
    }

    struct Source: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        var name: String
        var kind: String
        var address: String?
        var status: String?

        var hostKind: HostKind { HostKind(rawValue: kind) ?? .generic }
    }

    struct Thresholds: Codable, Sendable {
        var staleHours: Double = 36
        var criticalHours: Double = 168
        var storeWarn: Double = 80
        var storeCritical: Double = 92

        enum CodingKeys: String, CodingKey {
            case staleHours = "stale_hours"
            case criticalHours = "critical_hours"
            case storeWarn = "store_warn"
            case storeCritical = "store_crit"
        }

        init() {}
    }

    /// Le PBS qui détient un datastore donné, pour ouvrir ses instantanés.
    func pbsHost(named name: String) -> Source? {
        sources.first { $0.kind == "pbs" && $0.name == name }
    }
}

/// Un instantané d'un datastore PBS — `GET /protection/{host}/snapshots/{store}`.
struct PBSSnapshot: Codable, Identifiable, Hashable, Sendable {
    var store: String
    var backupType: String?
    var backupID: String?
    var time: Date?
    var size: Double
    var owner: String?
    var isProtected: Bool
    var verified: String?
    var comment: String?
    var files: Int

    var id: String { "\(store):\(backupType ?? "")/\(backupID ?? "")@\(time?.timeIntervalSince1970 ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case store, time, size, owner, verified, comment, files
        case backupType = "backup_type"
        case backupID = "backup_id"
        case isProtected = "protected"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        store = (try? container.decode(String.self, forKey: .store)) ?? ""
        backupType = try container.decodeIfPresent(String.self, forKey: .backupType)
        // PBS numérote les invités : `backup-id` sort en nombre pour une VM.
        backupID = (try? container.decode(String.self, forKey: .backupID))
            ?? (try? container.decode(Int.self, forKey: .backupID)).map { String($0) }
        time = container.decodeLooseDate(forKey: .time)
        size = (try? container.decode(Double.self, forKey: .size)) ?? 0
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        isProtected = (try? container.decode(Bool.self, forKey: .isProtected)) ?? false
        verified = try container.decodeIfPresent(String.self, forKey: .verified)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        files = (try? container.decode(Int.self, forKey: .files)) ?? 0
    }

    var group: String { "\(backupType ?? "?")/\(backupID ?? "?")" }
    var isVerified: Bool { verified == "ok" }
}

// MARK: - Dates hétérogènes

extension KeyedDecodingContainer {
    /// Les sources de sauvegarde datent chacune à leur façon : PBS et vzdump en
    /// époque Unix, DSM tantôt en époque tantôt en chaîne. Le décodeur global ne
    /// sait lire que des chaînes, d'où cette lecture tolérante.
    func decodeLooseDate(forKey key: Key) -> Date? {
        if let seconds = try? decodeIfPresent(Double.self, forKey: key) {
            // 0 vaut « jamais » côté PBS comme côté DSM.
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        if let text = try? decodeIfPresent(String.self, forKey: key), !text.isEmpty {
            return DateParsing.parse(text)
        }
        return nil
    }
}
