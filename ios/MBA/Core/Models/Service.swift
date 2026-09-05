import Foundation

/// Sonde HTTP sur un service web.
struct WebService: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var url: String
    var hostID: Int?
    var hostName: String?
    var method: String
    var expectStatus: Int
    var expectBody: String?
    var intervalSeconds: Int
    var icon: String?
    var groupName: String?
    var enabled: Bool
    var status: String
    var lastLatencyMilliseconds: Double?
    var lastChecked: Date?
    var sslExpiresAt: Date?
    var sslIssuer: String?
    var uptime24h: Double
    var averageLatency: Double

    enum CodingKeys: String, CodingKey {
        case id, name, url, method, icon, enabled, status
        case hostID = "host_id"
        case hostName = "host_name"
        case expectStatus = "expect_status"
        case expectBody = "expect_body"
        case intervalSeconds = "interval_s"
        case groupName = "group_name"
        case lastLatencyMilliseconds = "last_latency_ms"
        case lastChecked = "last_checked"
        case sslExpiresAt = "ssl_expires_at"
        case sslIssuer = "ssl_issuer"
        case uptime24h = "uptime_24h"
        case averageLatency = "avg_latency"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = (try? container.decode(String.self, forKey: .name)) ?? "—"
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        hostID = try container.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        method = (try? container.decode(String.self, forKey: .method)) ?? "GET"
        expectStatus = (try? container.decode(Int.self, forKey: .expectStatus)) ?? 200
        expectBody = try container.decodeIfPresent(String.self, forKey: .expectBody)
        intervalSeconds = (try? container.decode(Int.self, forKey: .intervalSeconds)) ?? 30
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
        lastLatencyMilliseconds = try container.decodeIfPresent(Double.self, forKey: .lastLatencyMilliseconds)
        lastChecked = try container.decodeIfPresent(Date.self, forKey: .lastChecked)
        sslExpiresAt = try container.decodeIfPresent(Date.self, forKey: .sslExpiresAt)
        sslIssuer = try container.decodeIfPresent(String.self, forKey: .sslIssuer)
        uptime24h = (try? container.decode(Double.self, forKey: .uptime24h)) ?? 0
        averageLatency = (try? container.decode(Double.self, forKey: .averageLatency)) ?? 0
    }

    var isUp: Bool { status == "up" }

    var host: String {
        URL(string: url)?.host() ?? url
    }

    /// Jours avant expiration du certificat. Négatif s'il est déjà expiré.
    var certificateDaysRemaining: Int? {
        guard let sslExpiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: .now, to: sslExpiresAt).day
    }

    /// Un certificat qui expire sous 21 jours mérite d'être signalé — c'est le
    /// délai en dessous duquel un renouvellement Let's Encrypt qui échoue en
    /// silence commence à devenir un incident.
    var certificateNeedsAttention: Bool {
        guard let days = certificateDaysRemaining else { return false }
        return days < 21
    }
}

struct ServiceHistory: Codable, Sendable {
    var points: [Point]
    var incidents: [Incident]

    struct Point: Codable, Identifiable, Sendable {
        var t: Double
        var latency: Double
        var uptime: Double

        var id: Double { t }
        var date: Date { Date(timeIntervalSince1970: t) }
    }

    struct Incident: Codable, Identifiable, Hashable, Sendable {
        var time: Date?
        var statusCode: Int?
        var error: String?

        var id: String { "\(time?.timeIntervalSince1970 ?? 0)-\(statusCode ?? 0)" }

        enum CodingKeys: String, CodingKey {
            case time, error
            case statusCode = "status_code"
        }
    }

    var latencyPoints: [MetricPoint] {
        points.map { MetricPoint(date: $0.date, value: $0.latency) }
    }

    var uptimePoints: [MetricPoint] {
        points.map { MetricPoint(date: $0.date, value: $0.uptime) }
    }
}

/// Fenêtres acceptées par `GET /services/{id}/history`.
enum ServiceRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1h", day = "24h", week = "7d", month = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: "1 h"
        case .day: "24 h"
        case .week: "7 j"
        case .month: "30 j"
        }
    }
}
