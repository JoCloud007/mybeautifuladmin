import Foundation

/// Lectures typées de l'échantillon libre d'un hôte.
///
/// Le collecteur pousse un dictionnaire ouvert : des nombres pour les métriques,
/// et quelques tableaux structurés (systèmes de fichiers, capteurs, processus,
/// GPU). On les extrait ici, une fois, plutôt que d'éparpiller des accès
/// `sample["filesystems"]?[0]?["mount"]` dans les vues.
struct Filesystem: Identifiable, Hashable, Sendable {
    let device: String
    let mount: String
    let total: Double
    let used: Double
    let available: Double
    let percent: Double

    var id: String { mount }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue,
              let mount = object.string("mount"),
              let total = object.double("total"), total > 0 else { return nil }
        self.mount = mount
        self.total = total
        device = object.string("device") ?? "—"
        used = object.double("used") ?? 0
        available = object.double("available") ?? 0
        percent = object.double("percent") ?? (used / total * 100)
    }
}

struct ProcessEntry: Identifiable, Hashable, Sendable {
    let pid: Int
    let user: String
    let cpu: Double
    let memory: Double
    let rss: Double
    let name: String

    var id: Int { pid }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue, let pid = object.int("pid") else { return nil }
        self.pid = pid
        user = object.string("user") ?? "—"
        cpu = object.double("cpu") ?? 0
        memory = object.double("mem") ?? 0
        rss = object.double("rss") ?? 0
        name = object.string("name") ?? "—"
    }
}

struct GPUEntry: Identifiable, Hashable, Sendable {
    let name: String
    let busy: Double?
    let temperature: Double?
    let power: Double?
    let vramUsed: Double?
    let vramTotal: Double?
    let vramPercent: Double?
    /// Mémoire graphique partagée avec la RAM système (APU à mémoire unifiée).
    let gttUsed: Double?
    let gttTotal: Double?
    let clock: Double?

    var id: String { name }

    /// Sur un APU type Ryzen AI Max, la VRAM dédiée est minuscule et c'est la
    /// GTT qui porte la charge : les afficher ensemble évite de croire à un GPU
    /// sans mémoire.
    var hasUnifiedMemory: Bool { (gttTotal ?? 0) > 0 }

    init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        name = object.string("name") ?? object.string("card") ?? "GPU"
        busy = object.double("busy")
        temperature = object.double("temp")
        power = object.double("power")
        vramUsed = object.double("vram_used")
        vramTotal = object.double("vram_total")
        vramPercent = object.double("vram_percent")
        gttUsed = object.double("gtt_used")
        gttTotal = object.double("gtt_total")
        clock = object.double("sclk") ?? object.double("clock")
    }
}

extension [String: JSONValue] {
    var filesystems: [Filesystem] {
        (self["filesystems"]?.arrayValue ?? []).compactMap(Filesystem.init)
    }

    var processes: [ProcessEntry] {
        (self["processes"]?.arrayValue ?? []).compactMap(ProcessEntry.init)
    }

    var gpus: [GPUEntry] {
        (self["gpus"]?.arrayValue ?? []).compactMap(GPUEntry.init)
    }

    /// Capteurs nommés → valeur, triés pour un affichage stable d'un cycle à
    /// l'autre (un dictionnaire JSON n'a pas d'ordre).
    func sensors(_ key: String) -> [(name: String, value: Double)] {
        (self[key]?.objectValue ?? [:])
            .compactMap { entry in entry.value.doubleValue.map { (entry.key, $0) } }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    var temperatures: [(name: String, value: Double)] { sensors("temps") }
    var fans: [(name: String, value: Double)] { sensors("fans") }
    var powerSensors: [(name: String, value: Double)] { sensors("power_sensors") }

    /// Charge par cœur, dans l'ordre des cœurs.
    var cpuCores: [Double] {
        (self["cpu.cores"]?.arrayValue ?? []).compactMap(\.doubleValue)
    }

    /// Débit réseau par interface : `{"eth0": {"rx": …, "tx": …}}`.
    var networkInterfaces: [(name: String, rx: Double, tx: Double)] {
        (self["net.interfaces"]?.objectValue ?? [:])
            .compactMap { entry in
                guard let object = entry.value.objectValue else { return nil }
                return (entry.key, object.double("rx") ?? 0, object.double("tx") ?? 0)
            }
            .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }
}

// MARK: - Historique REST

/// Réponse de `GET /hosts/{id}/metrics` : des séries prêtes à tracer.
struct MetricHistory: Decodable, Sendable {
    let range: String
    let bucket: Int
    let series: [String: [[Double]]]

    func points(_ metric: String) -> [MetricPoint] {
        (series[metric] ?? []).compactMap { pair in
            guard pair.count == 2 else { return nil }
            return MetricPoint(date: Date(timeIntervalSince1970: pair[0]), value: pair[1])
        }
    }

    var isEmpty: Bool { series.values.allSatisfy(\.isEmpty) }
}

/// Fenêtres proposées par l'API (`RANGES` côté serveur).
enum MetricRange: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case sixHours = "6h"
    case day = "24h"
    case week = "7d"
    case month = "30d"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .oneHour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 j"
        case .month: "30 j"
        }
    }
}
