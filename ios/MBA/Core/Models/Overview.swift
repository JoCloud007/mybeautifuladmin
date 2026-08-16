import Foundation

/// Réponse de `GET /overview` : tout ce qu'affiche le tableau de bord en un appel.
struct Overview: Codable, Sendable {
    var hosts: [Host]
    var summary: Summary
    var alerts: [Alert]
    var events: [EventItem]

    struct Summary: Codable, Sendable {
        var hostsTotal: Int
        var hostsOnline: Int
        var hostsOffline: Int
        var containersRunning: Int
        var containersTotal: Int
        var services: [String: Int]
        var alertsFiring: Int
        var updatesPending: Int
        var cpuAverage: Double
        var memoryAverage: Double

        enum CodingKeys: String, CodingKey {
            case services
            case hostsTotal = "hosts_total"
            case hostsOnline = "hosts_online"
            case hostsOffline = "hosts_offline"
            case containersRunning = "containers_running"
            case containersTotal = "containers_total"
            case alertsFiring = "alerts_firing"
            case updatesPending = "updates_pending"
            case cpuAverage = "cpu_avg"
            case memoryAverage = "mem_avg"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hostsTotal = (try? container.decode(Int.self, forKey: .hostsTotal)) ?? 0
            hostsOnline = (try? container.decode(Int.self, forKey: .hostsOnline)) ?? 0
            hostsOffline = (try? container.decode(Int.self, forKey: .hostsOffline)) ?? 0
            containersRunning = (try? container.decode(Int.self, forKey: .containersRunning)) ?? 0
            containersTotal = (try? container.decode(Int.self, forKey: .containersTotal)) ?? 0
            services = (try? container.decode([String: Int].self, forKey: .services)) ?? [:]
            alertsFiring = (try? container.decode(Int.self, forKey: .alertsFiring)) ?? 0
            updatesPending = (try? container.decode(Int.self, forKey: .updatesPending)) ?? 0
            cpuAverage = (try? container.decode(Double.self, forKey: .cpuAverage)) ?? 0
            memoryAverage = (try? container.decode(Double.self, forKey: .memoryAverage)) ?? 0
        }

        var servicesUp: Int { services["up"] ?? 0 }
        var servicesDown: Int { services["down"] ?? 0 }
        var servicesTotal: Int { services.values.reduce(0, +) }
    }
}

// MARK: - Alertes

enum AlertSeverity: String, Codable, Sendable, Comparable {
    case critical, warning, info

    var label: String {
        switch self {
        case .critical: "Critique"
        case .warning: "Avertissement"
        case .info: "Information"
        }
    }

    var symbol: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var rank: Int {
        switch self {
        case .critical: 2
        case .warning: 1
        case .info: 0
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

struct Alert: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var ruleID: Int?
    var hostID: Int?
    var hostName: String?
    var ruleName: String?
    var severity: AlertSeverity
    var message: String
    var value: Double?
    var state: String
    var startedAt: Date?
    var resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, severity, message, value, state
        case ruleID = "rule_id"
        case hostID = "host_id"
        case hostName = "host_name"
        case ruleName = "rule_name"
        case startedAt = "started_at"
        case resolvedAt = "resolved_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        ruleID = try container.decodeIfPresent(Int.self, forKey: .ruleID)
        hostID = try container.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        ruleName = try container.decodeIfPresent(String.self, forKey: .ruleName)
        severity = (try? container.decode(AlertSeverity.self, forKey: .severity)) ?? .warning
        message = (try? container.decode(String.self, forKey: .message)) ?? ""
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        state = (try? container.decode(String.self, forKey: .state)) ?? "firing"
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }

    var isFiring: Bool { state == "firing" }
}

// MARK: - Journal

enum EventLevel: String, Codable, Sendable {
    case info, warning, critical, error

    var label: String {
        switch self {
        case .info: "Info"
        case .warning: "Avertissement"
        case .critical: "Critique"
        case .error: "Erreur"
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical, .error: "exclamationmark.octagon"
        }
    }
}

struct EventItem: Codable, Identifiable, Hashable, Sendable {
    var time: Date?
    var level: EventLevel
    var source: String
    var message: String
    var hostID: Int?
    var hostName: String?
    var data: [String: JSONValue]?

    /// Le journal n'a pas d'identifiant stable exposé par l'API : la paire
    /// (instant, message) suffit à distinguer deux lignes dans une liste.
    var id: String { "\(time?.timeIntervalSince1970 ?? 0)-\(source)-\(message.hashValue)" }

    enum CodingKeys: String, CodingKey {
        case time, level, source, message, data
        case hostID = "host_id"
        case hostName = "host_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decodeIfPresent(Date.self, forKey: .time)
        level = (try? container.decode(EventLevel.self, forKey: .level)) ?? .info
        source = (try? container.decode(String.self, forKey: .source)) ?? "system"
        message = (try? container.decode(String.self, forKey: .message)) ?? ""
        hostID = try container.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        data = try container.decodeIfPresent([String: JSONValue].self, forKey: .data)
    }
}

struct EventsResponse: Codable, Sendable {
    var events: [EventItem]
    var sources: [SourceCount]
    var levels: [String: Int]

    struct SourceCount: Codable, Hashable, Sendable, Identifiable {
        var source: String
        var count: Int
        var id: String { source }
    }
}
