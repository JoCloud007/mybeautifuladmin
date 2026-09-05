import Foundation

/// Réponse de `GET /home` : les instances Home Assistant et leurs entités.
struct HomeOverview: Decodable, Sendable {
    var hubs: [HomeHub]
    /// Libellés français des domaines, tenus côté serveur pour que la console
    /// web et l'application nomment « light » de la même façon.
    var domainLabels: [String: String]

    enum CodingKeys: String, CodingKey {
        case hubs
        case domainLabels = "domain_labels"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hubs = (try? c.decode([HomeHub].self, forKey: .hubs)) ?? []
        domainLabels = (try? c.decode([String: String].self, forKey: .domainLabels)) ?? [:]
    }
}

/// Une instance Home Assistant, avec l'état de toutes ses entités.
struct HomeHub: Decodable, Identifiable, Hashable, Sendable {
    var host: Host
    var entities: [HomeEntity]
    var byDomain: [String: Int]
    var stats: HomeStats

    var id: Int { host.id }
    var name: String { host.name }

    enum CodingKeys: String, CodingKey {
        case entities, stats
        case byDomain = "by_domain"
    }

    init(from decoder: Decoder) throws {
        host = try Host(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entities = (try? c.decode([HomeEntity].self, forKey: .entities)) ?? []
        byDomain = (try? c.decode([String: Int].self, forKey: .byDomain)) ?? [:]
        stats = (try? c.decode(HomeStats.self, forKey: .stats)) ?? HomeStats()
    }

    var version: String? { host.meta.string("version") }
    var location: String? { host.meta.string("location") }

    /// Les domaines présents, du plus fourni au moins fourni — l'ordre dans
    /// lequel ils intéressent, plutôt que l'ordre alphabétique des clés.
    func domains(labels: [String: String]) -> [String] {
        byDomain.keys.sorted { left, right in
            let countLeft = byDomain[left] ?? 0
            let countRight = byDomain[right] ?? 0
            if countLeft != countRight { return countLeft > countRight }
            return HomeEntity.label(for: left, labels: labels)
                .localizedStandardCompare(HomeEntity.label(for: right, labels: labels))
                == .orderedAscending
        }
    }
}

/// Le décompte que le collecteur tient à jour à chaque cycle.
struct HomeStats: Decodable, Hashable, Sendable {
    var entities: Int = 0
    var domains: Int = 0
    var unavailable: Int = 0
    var lowBattery: Int = 0
    var updates: Int = 0
    var automationsOff: Int = 0
    var lightsOn: Int = 0
    var switchesOn: Int = 0

    enum CodingKeys: String, CodingKey {
        case entities, domains, unavailable, updates
        case lowBattery = "low_battery"
        case automationsOff = "automations_off"
        case lightsOn = "lights_on"
        case switchesOn = "switches_on"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entities = (try? c.decode(Int.self, forKey: .entities)) ?? 0
        domains = (try? c.decode(Int.self, forKey: .domains)) ?? 0
        unavailable = (try? c.decode(Int.self, forKey: .unavailable)) ?? 0
        lowBattery = (try? c.decode(Int.self, forKey: .lowBattery)) ?? 0
        updates = (try? c.decode(Int.self, forKey: .updates)) ?? 0
        automationsOff = (try? c.decode(Int.self, forKey: .automationsOff)) ?? 0
        lightsOn = (try? c.decode(Int.self, forKey: .lightsOn)) ?? 0
        switchesOn = (try? c.decode(Int.self, forKey: .switchesOn)) ?? 0
    }
}

/// Une entité Home Assistant : une lampe, un capteur, une automatisation.
struct HomeEntity: Decodable, Identifiable, Hashable, Sendable {
    var entityID: String
    var domain: String
    var name: String
    var state: String?
    var unit: String?
    var deviceClass: String?
    var battery: Double?
    var available: Bool
    var controllable: Bool
    var changed: Date?
    var area: String?

    var id: String { entityID }

    enum CodingKeys: String, CodingKey {
        case domain, name, state, unit, battery, available, controllable, changed, area
        case entityID = "entity_id"
        case deviceClass = "device_class"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entityID = (try? c.decode(String.self, forKey: .entityID)) ?? ""
        domain = (try? c.decode(String.self, forKey: .domain)) ?? "autre"
        name = (try? c.decode(String.self, forKey: .name)) ?? entityID
        state = try c.decodeIfPresent(String.self, forKey: .state)
        unit = try c.decodeIfPresent(String.self, forKey: .unit)
        deviceClass = try c.decodeIfPresent(String.self, forKey: .deviceClass)
        battery = try? c.decodeIfPresent(Double.self, forKey: .battery)
        available = (try? c.decode(Bool.self, forKey: .available)) ?? true
        controllable = (try? c.decode(Bool.self, forKey: .controllable)) ?? false
        changed = try? c.decodeIfPresent(Date.self, forKey: .changed)
        area = try c.decodeIfPresent(String.self, forKey: .area)
    }

    /// L'état tel qu'on l'affiche : traduit quand c'est un mot d'état connu,
    /// suivi de son unité quand c'est une mesure.
    var displayState: String {
        guard let state, !state.isEmpty else { return Format.placeholder }
        if let unit, !unit.isEmpty, Double(state) != nil {
            return "\(Format.number(Double(state), digits: 1)) \(unit)"
        }
        return switch state {
        case "on": "allumé"
        case "off": "éteint"
        case "open": "ouvert"
        case "closed": "fermé"
        case "locked": "verrouillé"
        case "unlocked": "déverrouillé"
        case "home": "présent"
        case "not_home": "absent"
        case "playing": "en lecture"
        case "paused": "en pause"
        case "idle": "au repos"
        case "unavailable": "indisponible"
        case "unknown": "inconnu"
        default: state
        }
    }

    var isOn: Bool { state == "on" || state == "open" || state == "playing" }

    /// Une mesure exploitable en courbe — les capteurs numériques seulement.
    var numericValue: Double? { state.flatMap(Double.init) }
    var hasHistory: Bool { numericValue != nil }

    var isLowBattery: Bool {
        guard let battery else { return false }
        return battery <= 20
    }

    /// Une entité « update » à « on » annonce une mise à jour disponible.
    var announcesUpdate: Bool { domain == "update" && state == "on" }

    var symbol: String { Self.symbol(for: domain, on: isOn) }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, entityID, area, state]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }

    // MARK: - Commandes

    /// Ce que MBA peut demander à cette entité.
    ///
    /// La liste est volontairement courte : le serveur n'autorise que des gestes
    /// réversibles, et une serrure ne se déverrouille pas depuis cette
    /// application.
    var commands: [HomeCommand] {
        guard available else { return [] }
        switch domain {
        case "light", "switch", "fan", "input_boolean", "media_player":
            return [HomeCommand(service: "toggle", label: isOn ? "Éteindre" : "Allumer",
                                symbol: "power")]
        case "automation":
            return [HomeCommand(service: "toggle",
                                label: isOn ? "Désactiver" : "Activer", symbol: "power"),
                    HomeCommand(service: "trigger", label: "Déclencher",
                                symbol: "play.fill", isSensitive: true)]
        case "script":
            return [HomeCommand(service: "turn_on", label: "Exécuter",
                                symbol: "play.fill", isSensitive: true)]
        case "scene":
            return [HomeCommand(service: "turn_on", label: "Activer la scène",
                                symbol: "wand.and.stars")]
        case "button":
            return [HomeCommand(service: "press", label: "Appuyer",
                                symbol: "hand.tap", isSensitive: true)]
        case "cover":
            return [HomeCommand(service: "open_cover", label: "Ouvrir",
                                symbol: "arrow.up", isSensitive: true),
                    HomeCommand(service: "close_cover", label: "Fermer",
                                symbol: "arrow.down", isSensitive: true),
                    HomeCommand(service: "stop_cover", label: "Arrêter",
                                symbol: "stop.fill")]
        default:
            return []
        }
    }

    // MARK: - Libellés

    static func label(for domain: String, labels: [String: String]) -> String {
        labels[domain] ?? domain.capitalized
    }

    static func symbol(for domain: String, on: Bool = false) -> String {
        switch domain {
        case "light": on ? "lightbulb.fill" : "lightbulb"
        case "switch", "input_boolean": on ? "switch.2" : "switch.2"
        case "sensor": "gauge.with.dots.needle.bottom.50percent"
        case "binary_sensor": "dot.radiowaves.right"
        case "climate": "thermometer.snowflake"
        case "cover": "blinds.horizontal.closed"
        case "media_player": "play.rectangle"
        case "automation": "arrow.triangle.branch"
        case "script": "scroll"
        case "scene": "wand.and.stars"
        case "person", "device_tracker": "person.fill"
        case "camera": "video.fill"
        case "lock": on ? "lock.open.fill" : "lock.fill"
        case "vacuum": "vacuum"
        case "update": "arrow.down.circle"
        case "sun": "sun.max.fill"
        case "weather": "cloud.sun.fill"
        case "fan": "fan"
        case "number", "select": "slider.horizontal.3"
        case "button": "hand.tap"
        case "zone": "mappin.and.ellipse"
        default: "square.grid.2x2"
        }
    }
}

/// Un appel de service proposé à l'écran.
struct HomeCommand: Identifiable, Hashable, Sendable {
    var service: String
    var label: String
    var symbol: String
    /// Un geste qui bouge quelque chose dans la maison — un volet, un script :
    /// on le fait confirmer, contrairement à l'allumage d'une lampe.
    var isSensitive: Bool = false

    var id: String { service }
}

/// Corps de `POST /home/{id}/call`.
struct HomeServiceCall: Encodable, Sendable {
    var entityID: String
    var service: String

    enum CodingKeys: String, CodingKey {
        case service
        case entityID = "entity_id"
    }
}

/// Un point de `GET /home/{id}/history/{entity}`.
struct HomeHistoryPoint: Decodable, Sendable {
    var time: Date?
    var value: Double

    enum CodingKeys: String, CodingKey {
        case time, value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try? c.decodeIfPresent(Date.self, forKey: .time)
        value = (try? c.decode(Double.self, forKey: .value)) ?? 0
    }
}

extension [HomeHistoryPoint] {
    /// Les points exploitables par une courbe — sans horodatage, un relevé ne
    /// se place nulle part.
    var metricPoints: [MetricPoint] {
        compactMap { point in
            point.time.map { MetricPoint(date: $0, value: point.value) }
        }
    }
}
