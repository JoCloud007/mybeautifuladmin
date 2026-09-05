import Foundation

/// Réponse de `GET /remediation/catalog` : ce qu'une règle peut surveiller et
/// ce qu'elle peut faire.
struct RemediationCatalog: Codable, Sendable {
    var triggers: [String: Trigger]
    var actions: [String: Action]
    var agents: [Agent]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        triggers = (try? c.decode([String: Trigger].self, forKey: .triggers)) ?? [:]
        actions = (try? c.decode([String: Action].self, forKey: .actions)) ?? [:]
        agents = (try? c.decode([Agent].self, forKey: .agents)) ?? []
    }

    struct Trigger: Codable, Hashable, Sendable {
        var label: String
        var help: String?
    }

    struct Action: Codable, Hashable, Sendable {
        var label: String
        /// Paramètres que le serveur exige — sans eux, il refuse en 400.
        var params: [String]
        /// Une action destructive coupe un service : la règle doit l'autoriser
        /// explicitement pour avoir le droit de l'employer.
        var destructive: Bool
    }

    struct Agent: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        var name: String
        var mode: String
    }

    /// Déclencheurs triés par libellé, pour un sélecteur stable d'un affichage
    /// à l'autre — un dictionnaire n'a pas d'ordre.
    var sortedTriggers: [(key: String, trigger: Trigger)] {
        triggers.map { (key: $0.key, trigger: $0.value) }
            .sorted { $0.trigger.label.localizedStandardCompare($1.trigger.label) == .orderedAscending }
    }

    var sortedActions: [(key: String, action: Action)] {
        actions.map { (key: $0.key, action: $0.value) }
            .sorted { $0.action.label.localizedStandardCompare($1.action.label) == .orderedAscending }
    }
}

/// Réponse de `GET /remediation` : les règles et leurs exécutions récentes.
struct RemediationList: Codable, Sendable {
    var rules: [RemediationRule]
    var runs: [RemediationRun]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = (try? c.decode([RemediationRule].self, forKey: .rules)) ?? []
        runs = (try? c.decode([RemediationRun].self, forKey: .runs)) ?? []
    }
}

/// Une règle : quand ceci se produit, fais cela — sous conditions.
struct RemediationRule: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var description: String?
    var trigger: String
    var action: String
    var triggerLabel: String
    var actionLabel: String
    var scopeKind: String
    var scopeValue: String?
    /// Délai avant qu'un symptôme soit considéré comme confirmé — c'est lui qui
    /// évite de redémarrer une machine pour une coupure de trois secondes.
    var confirmSeconds: Int
    var cooldownSeconds: Int
    var maxPerDay: Int
    var allowDestructive: Bool
    var enabled: Bool
    var lastRun: Date?
    var lastStatus: String?
    var stats: Stats

    enum CodingKeys: String, CodingKey {
        case id, name, description, trigger, action, enabled, stats
        case triggerLabel = "trigger_label"
        case actionLabel = "action_label"
        case scopeKind = "scope_kind"
        case scopeValue = "scope_value"
        case confirmSeconds = "confirm_seconds"
        case cooldownSeconds = "cooldown_seconds"
        case maxPerDay = "max_per_day"
        case allowDestructive = "allow_destructive"
        case lastRun = "last_run"
        case lastStatus = "last_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        trigger = (try? c.decode(String.self, forKey: .trigger)) ?? ""
        action = (try? c.decode(String.self, forKey: .action)) ?? ""
        triggerLabel = (try? c.decode(String.self, forKey: .triggerLabel)) ?? trigger
        actionLabel = (try? c.decode(String.self, forKey: .actionLabel)) ?? action
        scopeKind = (try? c.decode(String.self, forKey: .scopeKind)) ?? "all"
        scopeValue = try c.decodeIfPresent(String.self, forKey: .scopeValue)
        confirmSeconds = (try? c.decode(Int.self, forKey: .confirmSeconds)) ?? 300
        cooldownSeconds = (try? c.decode(Int.self, forKey: .cooldownSeconds)) ?? 1800
        maxPerDay = (try? c.decode(Int.self, forKey: .maxPerDay)) ?? 3
        allowDestructive = (try? c.decode(Bool.self, forKey: .allowDestructive)) ?? false
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        stats = (try? c.decode(Stats.self, forKey: .stats)) ?? Stats()
    }

    struct Stats: Codable, Hashable, Sendable {
        var total: Int = 0
        var ok: Int = 0
        /// Exécutions des 24 dernières heures : c'est ce compteur que `maxPerDay`
        /// plafonne.
        var today: Int = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = (try? c.decode(Int.self, forKey: .total)) ?? 0
            ok = (try? c.decode(Int.self, forKey: .ok)) ?? 0
            today = (try? c.decode(Int.self, forKey: .today)) ?? 0
        }
    }

    var scope: TargetKind { TargetKind(rawValue: scopeKind) ?? .all }

    var scopeSummary: String {
        switch scope {
        case .all: "tout le parc"
        case .host: scopeValue.map { "machines \($0)" } ?? "aucune cible"
        case .tag: scopeValue.map { "étiquettes \($0)" } ?? "aucune cible"
        case .kind: scopeValue.map { "types \($0)" } ?? "aucune cible"
        }
    }

    /// La règle a atteint son plafond quotidien : elle ne fera plus rien avant
    /// demain, même si le symptôme persiste.
    var isCapped: Bool { stats.today >= maxPerDay }

    var lastSucceeded: Bool? {
        guard let lastStatus else { return nil }
        return lastStatus == "success"
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, description, triggerLabel, actionLabel]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }
}

/// Une exécution de règle.
struct RemediationRun: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var ruleID: Int?
    var ruleName: String?
    var hostID: Int?
    var hostName: String?
    var trigger: String?
    var status: String
    var detail: String?
    var startedAt: Date?
    var endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, trigger, status, detail
        case ruleID = "rule_id"
        case ruleName = "rule_name"
        case hostID = "host_id"
        case hostName = "host_name"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        ruleID = try c.decodeIfPresent(Int.self, forKey: .ruleID)
        ruleName = try c.decodeIfPresent(String.self, forKey: .ruleName)
        hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }

    var isRunning: Bool { status == "running" }
    var succeeded: Bool { status == "success" }
    /// « skipped » : la règle a bien vu le symptôme mais s'est abstenue — plafond
    /// atteint, délai de garde non écoulé, ou cible déjà traitée.
    var wasSkipped: Bool { status == "skipped" }

    var statusLabel: String {
        switch status {
        case "success": "réussie"
        case "failed": "en échec"
        case "running": "en cours"
        case "skipped": "ignorée"
        default: status
        }
    }
}

/// Réponse de `POST /remediation/preview` : ce que la règle traiterait
/// maintenant, sans rien appliquer.
struct RemediationPreview: Codable, Sendable {
    var targets: [Target]
    var count: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = (try? c.decode([Target].self, forKey: .targets)) ?? []
        count = (try? c.decode(Int.self, forKey: .count)) ?? 0
    }

    struct Target: Codable, Identifiable, Hashable, Sendable {
        var id: Int?
        var name: String?
        var detail: String?

        var label: String { name ?? detail ?? "—" }
    }
}

/// Corps de `POST /remediation` et `POST /remediation/preview`.
struct RemediationPayload: Encodable, Sendable {
    var name: String
    var description: String?
    var trigger: String
    var action: String
    var params: [String: String]
    var scopeKind: String
    var scopeValue: String?
    var confirmSeconds: Int
    var cooldownSeconds: Int
    var maxPerDay: Int
    var allowDestructive: Bool
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case name, description, trigger, action, params, enabled
        case scopeKind = "scope_kind"
        case scopeValue = "scope_value"
        case confirmSeconds = "confirm_seconds"
        case cooldownSeconds = "cooldown_seconds"
        case maxPerDay = "max_per_day"
        case allowDestructive = "allow_destructive"
    }
}

/// Corps de `PATCH /remediation/{id}` — seul ce qui change est envoyé.
struct RemediationPatch: Encodable, Sendable {
    var enabled: Bool?
}
