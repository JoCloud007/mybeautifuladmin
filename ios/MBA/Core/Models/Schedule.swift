import Foundation

/// Réponse de `GET /schedules` : les planifications, le catalogue d'actions et
/// le fuseau dans lequel les expressions cron sont interprétées.
struct ScheduleList: Codable, Sendable {
    var schedules: [Schedule]
    var actions: [String: String]
    var timezone: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schedules = (try? c.decode([Schedule].self, forKey: .schedules)) ?? []
        actions = (try? c.decode([String: String].self, forKey: .actions)) ?? [:]
        timezone = (try? c.decode(String.self, forKey: .timezone)) ?? "UTC"
    }
}

/// Une tâche planifiée : une action, des cibles, une expression cron.
struct Schedule: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var action: String
    var targetKind: TargetKind
    var targetValue: String?
    var cron: String
    var enabled: Bool
    var running: Bool
    var nextRun: Date?
    var lastRun: Date?
    var lastStatus: String?
    var lastOutput: String?
    var createdAt: Date?
    /// Résolu par le serveur : nombre de machines réellement visées.
    var targets: Int
    var targetNames: [String]
    var targetValues: [String]
    /// Phrase toute faite du serveur — même formulation que le journal.
    var summary: String?

    enum CodingKeys: String, CodingKey {
        case id, name, action, cron, enabled, running, targets
        case targetKind = "target_kind"
        case targetValue = "target_value"
        case nextRun = "next_run"
        case lastRun = "last_run"
        case lastStatus = "last_status"
        case lastOutput = "last_output"
        case createdAt = "created_at"
        case targetNames = "target_names"
        case targetValues = "target_values"
        case summary = "description"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        action = (try? c.decode(String.self, forKey: .action)) ?? ""
        targetKind = (try? c.decode(TargetKind.self, forKey: .targetKind)) ?? .host
        targetValue = try c.decodeIfPresent(String.self, forKey: .targetValue)
        cron = (try? c.decode(String.self, forKey: .cron)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        running = (try? c.decode(Bool.self, forKey: .running)) ?? false
        nextRun = try c.decodeIfPresent(Date.self, forKey: .nextRun)
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        lastOutput = try c.decodeIfPresent(String.self, forKey: .lastOutput)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        targets = (try? c.decode(Int.self, forKey: .targets)) ?? 0
        targetNames = (try? c.decode([String].self, forKey: .targetNames)) ?? []
        targetValues = (try? c.decode([String].self, forKey: .targetValues)) ?? []
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }

    var scheduleAction: ScheduleAction { ScheduleAction(rawValue: action) ?? .command }

    /// Une planification active mais sans cible ne fera jamais rien : c'est le
    /// piège classique d'une étiquette renommée après coup.
    var hasNoTarget: Bool { enabled && targets == 0 }

    var lastSucceeded: Bool { lastStatus == "success" }
    var lastFailed: Bool { lastStatus != nil && lastStatus != "success" && lastStatus != "partial" }

    var targetSummary: String {
        switch targetKind {
        case .all: "tout le parc"
        case .host: targetNames.isEmpty ? "aucune cible" : targetNames.joined(separator: ", ")
        case .tag: "étiquettes " + targetValues.joined(separator: ", ")
        case .kind: "types " + targetValues.joined(separator: ", ")
        }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, cron, summary].compactMap { $0?.lowercased() }.contains { $0.contains(query) }
            || targetNames.contains { $0.lowercased().contains(query) }
    }
}

enum TargetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case host, tag, kind, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .host: "Machines"
        case .tag: "Étiquettes"
        case .kind: "Types"
        case .all: "Tout le parc"
        }
    }

    var symbol: String {
        switch self {
        case .host: "server.rack"
        case .tag: "tag"
        case .kind: "square.stack.3d.up"
        case .all: "globe"
        }
    }
}

/// Actions planifiables, telles que le serveur les expose dans `actions`.
enum ScheduleAction: String, CaseIterable, Identifiable, Sendable {
    case upgrade, reboot, shutdown, service, container, prune, command

    var id: String { rawValue }

    var label: String {
        switch self {
        case .upgrade: "Mise à jour des paquets"
        case .reboot: "Redémarrage"
        case .shutdown: "Extinction"
        case .service: "Redémarrage d'un service"
        case .container: "Action sur un conteneur"
        case .prune: "Purge Docker"
        case .command: "Commande personnalisée"
        }
    }

    var symbol: String {
        switch self {
        case .upgrade: "arrow.down.circle"
        case .reboot: "arrow.clockwise.circle"
        case .shutdown: "power"
        case .service: "gearshape.2"
        case .container: "shippingbox"
        case .prune: "trash"
        case .command: "terminal"
        }
    }

    /// Ce que le serveur exige dans `params` — sans quoi il refuse en 400.
    var requiredParameter: (key: String, label: String, placeholder: String)? {
        switch self {
        case .service: ("service", "Service systemd", "nginx")
        case .container: ("container", "Conteneur", "nom ou identifiant")
        case .command: ("command", "Commande", "/usr/local/bin/backup.sh")
        default: nil
        }
    }

    /// Une action qui coupe la machine mérite une confirmation appuyée.
    var isDisruptive: Bool {
        switch self {
        case .reboot, .shutdown: true
        default: false
        }
    }
}

/// Réponse de `POST /schedules/preview` : ce que la planification ferait.
struct SchedulePreview: Codable, Sendable {
    var targets: [Target]
    var nextRuns: [Date]

    enum CodingKeys: String, CodingKey {
        case targets
        case nextRuns = "next_runs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targets = (try? c.decode([Target].self, forKey: .targets)) ?? []
        nextRuns = (try? c.decode([Date].self, forKey: .nextRuns)) ?? []
    }

    struct Target: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        var name: String
        var kind: String

        var hostKind: HostKind { HostKind(rawValue: kind) ?? .generic }
    }
}

/// Corps de `POST /schedules` et `POST /schedules/preview`.
struct SchedulePayload: Encodable, Sendable {
    var name: String
    var action: String
    var targetKind: String
    var targetValue: String?
    var params: [String: String]
    var cron: String
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case name, action, params, cron, enabled
        case targetKind = "target_kind"
        case targetValue = "target_value"
    }
}

/// Corps de `PATCH /schedules/{id}` — tout est optionnel, seul ce qui change
/// est envoyé.
struct SchedulePatch: Encodable, Sendable {
    var enabled: Bool?
    var cron: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case enabled, cron, name
    }
}

/// Expressions cron courantes, pour ne pas avoir à en écrire une au clavier
/// tactile — de loin le pire endroit pour se tromper d'un champ.
struct CronPreset: Identifiable, Hashable, Sendable {
    let label: String
    let expression: String

    var id: String { expression }

    static let all: [CronPreset] = [
        CronPreset(label: "Toutes les heures", expression: "0 * * * *"),
        CronPreset(label: "Chaque nuit à 3 h", expression: "0 3 * * *"),
        CronPreset(label: "Chaque nuit à 4 h", expression: "0 4 * * *"),
        CronPreset(label: "Lundi à 3 h", expression: "0 3 * * 1"),
        CronPreset(label: "Dimanche à 5 h", expression: "0 5 * * 0"),
        CronPreset(label: "1er du mois à 4 h", expression: "0 4 1 * *"),
    ]

    static func label(for expression: String) -> String? {
        all.first { $0.expression == expression }?.label
    }
}
