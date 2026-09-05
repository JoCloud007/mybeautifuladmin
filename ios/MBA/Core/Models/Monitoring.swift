import Foundation

/// Réponse de `GET /monitoring/catalog` : qui est supervisé, et avec quoi.
///
/// Le serveur ne liste que les métriques réellement vues dans les 30 dernières
/// minutes : proposer `gpu.busy` sur une machine sans carte graphique n'aurait
/// donné qu'un graphique vide.
struct MonitoringCatalog: Codable, Sendable {
    var hosts: [CatalogHost]
    var catalog: [MetricDescriptor]
    var extraMetrics: [String]
    var ranges: [String]

    enum CodingKeys: String, CodingKey {
        case hosts, catalog, ranges
        case extraMetrics = "extra_metrics"
    }

    struct CatalogHost: Codable, Identifiable, Hashable, Sendable {
        let id: Int
        var name: String
        var kind: String
        var status: String
        var tags: [String]
        var metrics: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            name = (try? container.decode(String.self, forKey: .name)) ?? "—"
            kind = (try? container.decode(String.self, forKey: .kind)) ?? "generic"
            status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
            tags = (try? container.decode([String].self, forKey: .tags)) ?? []
            metrics = (try? container.decode([String].self, forKey: .metrics)) ?? []
        }

        var hostStatus: HostStatus { HostStatus(rawValue: status) ?? .unknown }
        var hostKind: HostKind { HostKind(rawValue: kind) ?? .generic }
    }

    struct MetricDescriptor: Codable, Identifiable, Hashable, Sendable {
        var metric: String
        var label: String
        var unit: String
        var max: Double?

        var id: String { metric }

        /// Une métrique bornée à 100 se trace sur une échelle fixe ; un débit
        /// réseau doit s'adapter, sinon la courbe reste collée au bas du cadre.
        var isPercentage: Bool { max == 100 }

        func format(_ value: Double?) -> String {
            switch unit {
            case "%": Format.percent(value, digits: 1)
            case "B/s": Format.bitrate(value)
            case "°C": Format.temperature(value)
            case "W": Format.watts(value)
            default: Format.number(value, digits: 1)
            }
        }
    }

    /// Descripteur d'une métrique hors catalogue, pour l'afficher proprement.
    static func descriptor(for metric: String, in catalog: [MetricDescriptor]) -> MetricDescriptor {
        if let known = catalog.first(where: { $0.metric == metric }) { return known }
        let unit: String
        if metric.hasSuffix(".percent") || metric.contains("percent") {
            unit = "%"
        } else if metric.hasPrefix("net.") || metric.hasPrefix("disk.read") || metric.hasPrefix("disk.write") {
            unit = "B/s"
        } else if metric.hasPrefix("temp.") || metric.hasPrefix("sensor.") {
            unit = "°C"
        } else if metric.hasPrefix("power.") {
            unit = "W"
        } else {
            unit = ""
        }
        return MetricDescriptor(metric: metric, label: metric, unit: unit,
                                max: unit == "%" ? 100 : nil)
    }
}

/// Réponse de `GET /monitoring/series` : séries clefées `hostID:metric`.
struct MultiSeries: Codable, Sendable {
    var range: String
    var bucket: Int
    var series: [String: [[Double]]]
    var hosts: [String: String]

    func points(host: Int, metric: String) -> [MetricPoint] {
        (series["\(host):\(metric)"] ?? []).compactMap { pair in
            guard pair.count == 2 else { return nil }
            return MetricPoint(date: Date(timeIntervalSince1970: pair[0]), value: pair[1])
        }
    }

    func name(of hostID: Int) -> String { hosts["\(hostID)"] ?? "Hôte \(hostID)" }

    var isEmpty: Bool { series.values.allSatisfy(\.isEmpty) }
}

// MARK: - Capteurs

struct SensorsResponse: Codable, Sendable {
    var readings: [SensorReading]
    var summary: Summary

    struct Summary: Codable, Sendable {
        var sensors: Int
        var temperatures: Int
        var hottest: SensorReading?
        var critical: Int
        var warning: Int
        var fans: Int
        var powerTotal: Double

        enum CodingKeys: String, CodingKey {
            case sensors, temperatures, hottest, critical, warning, fans
            case powerTotal = "power_total"
        }
    }
}

struct SensorReading: Codable, Identifiable, Hashable, Sendable {
    var hostID: Int
    var hostName: String?
    var metric: String
    var name: String
    var kind: String
    var value: Double
    var label: String
    var critical: Bool
    var warning: Bool

    var id: String { "\(hostID):\(metric)" }

    enum CodingKeys: String, CodingKey {
        case metric, name, kind, value, label, critical, warning
        case hostID = "host_id"
        case hostName = "host_name"
    }

    enum Kind: String {
        case temperature, fan, power
    }

    var sensorKind: Kind { Kind(rawValue: kind) ?? .temperature }

    var formatted: String {
        switch sensorKind {
        case .temperature: Format.temperature(value)
        case .fan: Format.rpm(value)
        case .power: Format.watts(value)
        }
    }

    var symbol: String {
        switch sensorKind {
        case .temperature: "thermometer.medium"
        case .fan: "fan"
        case .power: "bolt"
        }
    }
}
