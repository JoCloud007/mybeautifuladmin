import Foundation

/// Réponse de `GET /agents/catalog` : ce qu'un agent peut faire, et avec quoi.
struct AgentCatalog: Decodable, Sendable {
    var actions: [String: AgentAction]
    var roles: [String: AgentRole]
    var endpoints: [AgentEndpoint]
    /// Les trois régimes de liberté, décrits par le serveur lui-même.
    var modes: [String: String]

    enum CodingKeys: String, CodingKey {
        case actions, roles, endpoints, modes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actions = (try? c.decode([String: AgentAction].self, forKey: .actions)) ?? [:]
        roles = (try? c.decode([String: AgentRole].self, forKey: .roles)) ?? [:]
        endpoints = (try? c.decode([AgentEndpoint].self, forKey: .endpoints)) ?? []
        modes = (try? c.decode([String: String].self, forKey: .modes)) ?? [:]
    }

    /// Actions triées par gravité puis par libellé — on veut voir en premier ce
    /// qu'on accorde de plus lourd.
    var sortedActions: [(key: String, action: AgentAction)] {
        actions.map { (key: $0.key, action: $0.value) }
            .sorted {
                if $0.action.level != $1.action.level { return $0.action.level < $1.action.level }
                return $0.action.label.localizedStandardCompare($1.action.label) == .orderedAscending
            }
    }

    var sortedRoles: [(key: String, role: AgentRole)] {
        roles.map { (key: $0.key, role: $0.value) }
            .sorted { $0.role.label.localizedStandardCompare($1.role.label) == .orderedAscending }
    }
}

/// Une action que l'agent a le droit de proposer.
struct AgentAction: Decodable, Hashable, Sendable {
    var label: String
    /// Vrai si l'action est assez réversible pour être exécutée sans validation
    /// en mode automatique.
    var auto: Bool
    var severity: FindingSeverity
    var params: [String]
    var help: String?

    enum CodingKeys: String, CodingKey {
        case label, auto, severity, params, help
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? "—"
        auto = (try? c.decode(Bool.self, forKey: .auto)) ?? false
        severity = (try? c.decode(FindingSeverity.self, forKey: .severity)) ?? .medium
        params = (try? c.decode([String].self, forKey: .params)) ?? []
        help = try c.decodeIfPresent(String.self, forKey: .help)
    }

    var level: Int { severity.rank }
}

/// Un rôle préconfiguré : une mission, une invite système, un jeu d'actions.
struct AgentRole: Decodable, Hashable, Sendable {
    var label: String
    var description: String?
    var actions: [String]
    var prompt: String?

    enum CodingKeys: String, CodingKey {
        case label, description, actions, prompt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? c.decode(String.self, forKey: .label)) ?? "—"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        actions = (try? c.decode([String].self, forKey: .actions)) ?? []
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
    }
}

/// Un serveur d'inférence utilisable par un agent, avec ses modèles.
struct AgentEndpoint: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var url: String
    var status: String
    var models: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, url, status, models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        models = (try? c.decode([String].self, forKey: .models)) ?? []
    }

    var isOnline: Bool { status == "online" }
}

/// Réponse de `GET /agents`.
struct AgentList: Decodable, Sendable {
    var agents: [Agent]
    /// Les propositions qui attendent une décision, tous agents confondus.
    var pending: [AgentProposal]
    var actions: [String: AgentAction]

    enum CodingKeys: String, CodingKey {
        case agents, pending, actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = (try? c.decode([Agent].self, forKey: .agents)) ?? []
        pending = (try? c.decode([AgentProposal].self, forKey: .pending)) ?? []
        actions = (try? c.decode([String: AgentAction].self, forKey: .actions)) ?? [:]
    }
}

/// Le régime de liberté accordé à un agent.
enum AgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case observe, suggest, auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .observe: "Observation"
        case .suggest: "Proposition"
        case .auto: "Automatique"
        }
    }

    var symbol: String {
        switch self {
        case .observe: "eye"
        case .suggest: "hand.raised"
        case .auto: "bolt.fill"
        }
    }

    /// L'agent peut-il toucher à quoi que ce soit sans qu'on l'ait validé ?
    var actsAlone: Bool { self == .auto }
}

/// Un agent : un modèle, un périmètre, un mandat.
struct Agent: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var description: String?
    var role: String
    var endpointID: Int?
    var endpointName: String?
    var endpointStatus: String?
    var model: String
    var systemPrompt: String?
    var mode: AgentMode
    var scopeKind: String
    var scopeValue: String?
    var allowedActions: [String]
    /// Plafond de propositions par exécution — le garde-fou contre un modèle
    /// qui s'emballe.
    var maxActions: Int
    var cron: String?
    var enabled: Bool
    var running: Bool
    var nextRun: Date?
    var lastRun: Date?
    var lastStatus: String?
    /// Nombre de machines que le périmètre désigne aujourd'hui.
    var scopeCount: Int
    var pending: Int

    enum CodingKeys: String, CodingKey {
        case id, name, description, role, model, mode, cron, enabled, running, pending
        case endpointID = "endpoint_id"
        case endpointName = "endpoint_name"
        case endpointStatus = "endpoint_status"
        case systemPrompt = "system_prompt"
        case scopeKind = "scope_kind"
        case scopeValue = "scope_value"
        case allowedActions = "allowed_actions"
        case maxActions = "max_actions"
        case nextRun = "next_run"
        case lastRun = "last_run"
        case lastStatus = "last_status"
        case scopeCount = "scope_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        role = (try? c.decode(String.self, forKey: .role)) ?? "custom"
        endpointID = try c.decodeIfPresent(Int.self, forKey: .endpointID)
        endpointName = try c.decodeIfPresent(String.self, forKey: .endpointName)
        endpointStatus = try c.decodeIfPresent(String.self, forKey: .endpointStatus)
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        mode = (try? c.decode(AgentMode.self, forKey: .mode)) ?? .observe
        scopeKind = (try? c.decode(String.self, forKey: .scopeKind)) ?? "all"
        scopeValue = try c.decodeIfPresent(String.self, forKey: .scopeValue)
        allowedActions = (try? c.decode([String].self, forKey: .allowedActions)) ?? []
        maxActions = (try? c.decode(Int.self, forKey: .maxActions)) ?? 3
        cron = try c.decodeIfPresent(String.self, forKey: .cron)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        running = (try? c.decode(Bool.self, forKey: .running)) ?? false
        nextRun = try c.decodeIfPresent(Date.self, forKey: .nextRun)
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        scopeCount = (try? c.decode(Int.self, forKey: .scopeCount)) ?? 0
        pending = (try? c.decode(Int.self, forKey: .pending)) ?? 0
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

    /// Un agent sans cron ne part que sur commande.
    var isScheduled: Bool { !(cron?.isEmpty ?? true) }

    var lastSucceeded: Bool? {
        guard let lastStatus else { return nil }
        return lastStatus == "success"
    }

    /// Le serveur d'inférence dont dépend l'agent est-il joignable ? Sans lui,
    /// l'agent échouera quoi qu'il arrive.
    var endpointReachable: Bool { endpointStatus == "online" }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, description, model, endpointName, role]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }
}

/// Une action proposée par un agent, en attente ou déjà tranchée.
struct AgentProposal: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var runID: Int?
    var agentID: Int?
    var agentName: String?
    var action: String
    /// Libellé résolu par le serveur depuis son catalogue d'actions.
    var label: String?
    var hostID: Int?
    var hostName: String?
    var params: [String: JSONValue]
    var reason: String?
    var severity: FindingSeverity
    var state: String
    var result: String?
    var decidedBy: String?
    var createdAt: Date?
    var decidedAt: Date?
    /// Vrai si l'action est de celles qu'un agent en mode automatique aurait pu
    /// exécuter seul.
    var autoCapable: Bool

    enum CodingKeys: String, CodingKey {
        case id, action, label, params, reason, severity, state, result
        case runID = "run_id"
        case agentID = "agent_id"
        case agentName = "agent_name"
        case hostID = "host_id"
        case hostName = "host_name"
        case decidedBy = "decided_by"
        case createdAt = "created_at"
        case decidedAt = "decided_at"
        case autoCapable = "auto_capable"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        runID = try c.decodeIfPresent(Int.self, forKey: .runID)
        agentID = try c.decodeIfPresent(Int.self, forKey: .agentID)
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        action = (try? c.decode(String.self, forKey: .action)) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label)
        hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        params = (try? c.decode([String: JSONValue].self, forKey: .params)) ?? [:]
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        severity = (try? c.decode(FindingSeverity.self, forKey: .severity)) ?? .medium
        state = (try? c.decode(String.self, forKey: .state)) ?? "pending"
        result = try c.decodeIfPresent(String.self, forKey: .result)
        decidedBy = try c.decodeIfPresent(String.self, forKey: .decidedBy)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        autoCapable = (try? c.decode(Bool.self, forKey: .autoCapable)) ?? false
    }

    var displayLabel: String { label ?? action }

    var isPending: Bool { state == "pending" }

    var stateLabel: String {
        switch state {
        case "pending": "en attente"
        case "executed": "exécutée"
        case "rejected": "refusée"
        case "failed": "en échec"
        case "skipped": "ignorée"
        default: state
        }
    }

    /// « redémarrer nginx sur srv-web » — l'action, ses paramètres et sa cible
    /// en une phrase.
    var summary: String {
        let arguments = params
            .sorted { $0.key < $1.key }
            .compactMap { $0.value.stringValue }
            .joined(separator: " ")
        return [displayLabel, arguments.isEmpty ? nil : arguments, hostName.map { "sur \($0)" }]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// Une exécution d'agent : son analyse et ce qu'elle a proposé.
struct AgentRun: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var trigger: String
    var status: String
    var summary: String?
    /// Le raisonnement complet du modèle — c'est lui qu'on lit pour décider si
    /// l'agent mérite plus de liberté.
    var analysis: String?
    var error: String?
    var duration: Double?
    var startedAt: Date?
    var endedAt: Date?
    var proposals: [AgentProposal]

    enum CodingKeys: String, CodingKey {
        case id, trigger, status, summary, analysis, error, proposals
        case duration = "duration_s"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        trigger = (try? c.decode(String.self, forKey: .trigger)) ?? "manual"
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        analysis = try c.decodeIfPresent(String.self, forKey: .analysis)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        duration = try? c.decodeIfPresent(Double.self, forKey: .duration)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        proposals = (try? c.decode([AgentProposal].self, forKey: .proposals)) ?? []
    }

    var succeeded: Bool { status == "success" }
    var isRunning: Bool { status == "running" }

    var statusLabel: String {
        switch status {
        case "success": "réussie"
        case "failed": "en échec"
        case "running": "en cours"
        default: status
        }
    }

    var triggerLabel: String {
        switch trigger {
        case "manuel", "manual": "manuelle"
        case "cron", "planifie": "planifiée"
        default: trigger
        }
    }
}

// MARK: - Écritures

/// Corps de `POST /agents` et `POST /agents/preview`.
struct AgentPayload: Encodable, Sendable {
    var name: String
    var description: String?
    var role: String
    var endpointID: Int
    var model: String
    var systemPrompt: String?
    var mode: String
    var scopeKind: String
    var scopeValue: String?
    var allowedActions: [String]
    var maxActions: Int
    var cron: String?
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case name, description, role, model, mode, cron, enabled
        case endpointID = "endpoint_id"
        case systemPrompt = "system_prompt"
        case scopeKind = "scope_kind"
        case scopeValue = "scope_value"
        case allowedActions = "allowed_actions"
        case maxActions = "max_actions"
    }
}

/// Corps de `PATCH /agents/{id}` — seul ce qui change est envoyé.
struct AgentUpdate: Encodable, Sendable {
    var enabled: Bool?
    var mode: String?
}

/// Corps de `POST /agents/proposals/{id}/decide`.
struct AgentDecision: Encodable, Sendable {
    var approve: Bool
}

/// Réponse de `POST /agents/preview` : ce que l'agent verrait, sans rien lancer.
struct AgentPreview: Decodable, Sendable {
    var hosts: [PreviewHost]
    var systemPrompt: String?
    /// Taille approximative de l'invite, en caractères — un contexte trop gros
    /// est la première cause d'échec sur un petit modèle.
    var estimatedChars: Int

    enum CodingKeys: String, CodingKey {
        case hosts
        case systemPrompt = "system_prompt"
        case estimatedChars = "estimated_chars"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = (try? c.decode([PreviewHost].self, forKey: .hosts)) ?? []
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        estimatedChars = (try? c.decode(Int.self, forKey: .estimatedChars)) ?? 0
    }

    struct PreviewHost: Decodable, Identifiable, Hashable, Sendable {
        let id: Int
        var name: String
        var kind: String
    }
}
