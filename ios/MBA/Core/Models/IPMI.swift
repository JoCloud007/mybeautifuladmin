import Foundation

/// Réponse de `GET /ipmi` : les contrôleurs hors-bande du parc.
struct BMCList: Decodable, Sendable {
    var bmcs: [BMC]
    /// Libellés d'action renvoyés par le serveur. On garde les nôtres à l'écran —
    /// ils portent une mise en garde — mais ceux-ci nomment l'action dans les
    /// comptes rendus, au mot près comme le journal du serveur.
    var actions: [String: String]

    enum CodingKeys: String, CodingKey {
        case bmcs, actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bmcs = (try? c.decode([BMC].self, forKey: .bmcs)) ?? []
        actions = (try? c.decode([String: String].self, forKey: .actions)) ?? [:]
    }
}

/// Un contrôleur de gestion hors-bande.
///
/// L'API renvoie la ligne `hosts` complète, augmentée du dernier échantillon du
/// bus temps réel : on décode donc l'hôte tel quel et on ajoute ce qui n'existe
/// que pour un BMC.
struct BMC: Decodable, Identifiable, Hashable, Sendable {
    var host: Host
    var info: BMCInfo
    var temps: [String: Double]
    var fans: [String: Double]
    /// La machine supervisée qui tourne derrière ce contrôleur, quand les deux
    /// vues ont été reliées — un BMC et son OS sont deux hôtes distincts.
    var server: LinkedHost?
    /// « redfish » (HTTPS direct) ou « ipmitool » (relayé en SSH).
    var mode: String

    var id: Int { host.id }
    var name: String { host.name }

    enum CodingKeys: String, CodingKey {
        case bmc, temps, fans, server, mode
    }

    init(from decoder: Decoder) throws {
        host = try Host(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = (try? c.decode(BMCInfo.self, forKey: .bmc)) ?? BMCInfo()
        temps = (try? c.decode([String: Double].self, forKey: .temps)) ?? [:]
        fans = (try? c.decode([String: Double].self, forKey: .fans)) ?? [:]
        server = try c.decodeIfPresent(LinkedHost.self, forKey: .server)
        mode = (try? c.decode(String.self, forKey: .mode)) ?? "redfish"
    }

    /// Adresse de l'interface de gestion — distincte de celle de l'OS.
    var address: String { host.bmcAddress ?? host.address }

    var modeLabel: String { mode == "ipmitool" ? "ipmitool" : "Redfish" }

    /// Le capteur le plus chaud : c'est lui qui décide de la couleur de la carte.
    var hottest: (name: String, value: Double)? {
        temps.max { $0.value < $1.value }.map { (name: $0.key, value: $0.value) }
    }

    var fastestFan: Double? { fans.values.max() }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, address, info.model, info.manufacturer, server?.name]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }

    /// Réapplique le dernier échantillon poussé par le flux temps réel.
    ///
    /// `GET /ipmi` fige l'état au moment de la requête ; entre deux
    /// chargements, c'est le flux qui porte la température et l'alimentation.
    /// Seul ce qui bouge est réécrit : l'identité du matériel, elle, ne change
    /// pas entre deux redémarrages.
    func applying(_ sample: [String: JSONValue]) -> BMC {
        guard !sample.isEmpty else { return self }
        var copy = self
        if let temps = sample["temps"]?.objectValue {
            copy.temps = temps.compactMapValues(\.doubleValue)
        }
        if let fans = sample["fans"]?.objectValue {
            copy.fans = fans.compactMapValues(\.doubleValue)
        }
        if let live = sample["bmc"]?.objectValue {
            copy.info.powerState = live.string("power_state") ?? copy.info.powerState
            copy.info.powerWatts = live.double("power_watts") ?? copy.info.powerWatts
            copy.info.health = live.string("health") ?? copy.info.health
            copy.info.indicatorLED = live.string("indicator_led") ?? copy.info.indicatorLED
        }
        return copy
    }
}

/// L'instantané Redfish/IPMI du contrôleur.
struct BMCInfo: Decodable, Hashable, Sendable {
    var powerState: String?
    var health: String?
    var model: String?
    var manufacturer: String?
    var serial: String?
    var bios: String?
    var hostName: String?
    var cpuCount: Int?
    var cpuModel: String?
    var memTotal: Double?
    var bmcFirmware: String?
    var bmcModel: String?
    var powerWatts: Double?
    var psus: [PowerSupply]
    /// Les actions que ce BMC déclare accepter. Vide quand il ne les annonce
    /// pas : on propose alors tout, c'est au contrôleur de refuser.
    var supportedActions: [String]
    var consoleURL: String?
    var indicatorLED: String?
    var chassisModel: String?
    var chassisManufacturer: String?
    var chassisSerial: String?

    enum CodingKeys: String, CodingKey {
        case health, model, manufacturer, serial, bios, psus
        case powerState = "power_state"
        case hostName = "host_name"
        case cpuCount = "cpu_count"
        case cpuModel = "cpu_model"
        case memTotal = "mem_total"
        case bmcFirmware = "bmc_firmware"
        case bmcModel = "bmc_model"
        case powerWatts = "power_watts"
        case supportedActions = "supported_actions"
        case consoleURL = "console_url"
        case indicatorLED = "indicator_led"
        case chassisModel = "chassis_model"
        case chassisManufacturer = "chassis_manufacturer"
        case chassisSerial = "chassis_serial"
    }

    init() {
        psus = []
        supportedActions = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        powerState = try c.decodeIfPresent(String.self, forKey: .powerState)
        health = try c.decodeIfPresent(String.self, forKey: .health)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer)
        serial = try c.decodeIfPresent(String.self, forKey: .serial)
        bios = try c.decodeIfPresent(String.self, forKey: .bios)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount)
        cpuModel = try c.decodeIfPresent(String.self, forKey: .cpuModel)
        memTotal = try c.decodeIfPresent(Double.self, forKey: .memTotal)
        bmcFirmware = try c.decodeIfPresent(String.self, forKey: .bmcFirmware)
        bmcModel = try c.decodeIfPresent(String.self, forKey: .bmcModel)
        powerWatts = try c.decodeIfPresent(Double.self, forKey: .powerWatts)
        psus = (try? c.decode([PowerSupply].self, forKey: .psus)) ?? []
        supportedActions = (try? c.decode([String].self, forKey: .supportedActions)) ?? []
        consoleURL = try c.decodeIfPresent(String.self, forKey: .consoleURL)
        indicatorLED = try c.decodeIfPresent(String.self, forKey: .indicatorLED)
        chassisModel = try c.decodeIfPresent(String.self, forKey: .chassisModel)
        chassisManufacturer = try c.decodeIfPresent(String.self, forKey: .chassisManufacturer)
        chassisSerial = try c.decodeIfPresent(String.self, forKey: .chassisSerial)
    }

    /// Le BMC répond toujours, même machine éteinte : c'est tout l'intérêt du
    /// hors-bande, et c'est pourquoi cet état ne se déduit pas du statut d'hôte.
    var isPoweredOn: Bool { powerState?.lowercased() == "on" }

    var powerLabel: String {
        switch powerState?.lowercased() {
        case "on": "Allumé"
        case "off": "Éteint"
        case nil, "": Format.placeholder
        case "paused": "Suspendu"
        default: powerState ?? Format.placeholder
        }
    }

    /// Le châssis porte souvent l'identité que le système ne déclare pas —
    /// fréquent sur les cartes ASUS.
    var displayModel: String? { Self.meaningful(model) ?? Self.meaningful(chassisModel) }
    var displayManufacturer: String? {
        Self.meaningful(manufacturer) ?? Self.meaningful(chassisManufacturer)
    }
    var displaySerial: String? { Self.meaningful(serial) ?? Self.meaningful(chassisSerial) }

    /// Beaucoup de BMC remplissent leurs champs d'identité avec du vide ou une
    /// valeur d'usine (« Default string », « System Serial Number »). Les
    /// afficher ferait croire à une information là où il n'y en a pas.
    private static let placeholders: Set<String> = [
        "default string", "system serial number", "to be filled by o.e.m.",
        "not specified", "unknown", "n/a", "none",
    ]

    private static func meaningful(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !placeholders.contains(trimmed.lowercased())
        else { return nil }
        return trimmed
    }

    /// « OK » n'est pas une anomalie : seule une santé différente mérite d'être
    /// signalée à l'écran.
    var healthWarning: String? {
        guard let health, !health.isEmpty, health.uppercased() != "OK" else { return nil }
        return health
    }

    var isIdentifying: Bool {
        guard let indicatorLED else { return false }
        return ["lit", "blinking"].contains(indicatorLED.lowercased())
    }
}

/// Une alimentation du châssis.
struct PowerSupply: Decodable, Identifiable, Hashable, Sendable {
    var name: String?
    var status: String?
    var state: String?
    var model: String?
    var capacity: Double?
    var input: Double?

    var id: String { name ?? model ?? UUID().uuidString }

    /// Une alimentation « Absent » est un emplacement vide, pas une panne.
    var isAbsent: Bool { state?.lowercased() == "absent" }
    var isHealthy: Bool { status?.uppercased() == "OK" }
}

/// L'autre hôte auquel ce contrôleur est rattaché.
struct LinkedHost: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var kind: String
    var status: String
}

/// Une entrée du journal matériel (SEL).
struct BMCLogEntry: Decodable, Identifiable, Hashable, Sendable {
    let id = UUID()
    /// Horodatage brut : Redfish renvoie de l'ISO 8601, ipmitool un format
    /// américain. On garde la chaîne et on la traduit quand elle est lisible.
    var time: String?
    var severity: String
    var message: String?
    var sensor: String?

    enum CodingKeys: String, CodingKey {
        case time, severity, message, sensor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        severity = ((try? c.decode(String.self, forKey: .severity)) ?? "ok").lowercased()
        message = try c.decodeIfPresent(String.self, forKey: .message)
        sensor = try c.decodeIfPresent(String.self, forKey: .sensor)
    }

    var date: Date? { time.flatMap(DateParsing.parse) }

    /// L'horodatage affiché : la date reformatée quand on sait la lire, la
    /// chaîne du contrôleur sinon — jamais rien.
    var displayTime: String {
        if let date { return Format.dateTime(date) }
        return time ?? Format.placeholder
    }

    var isCritical: Bool { severity == "critical" }
    var isWarning: Bool { severity == "warning" }
}

/// Une étape du diagnostic de connexion, telle que `POST /ipmi/{id}/test` la
/// déroule : DNS, port, TLS, authentification, Redfish.
struct BMCDiagnosticStep: Decodable, Identifiable, Hashable, Sendable {
    var step: String
    var ok: Bool
    var detail: String
    var hint: String?

    var id: String { step }

    enum CodingKeys: String, CodingKey {
        case step, ok, detail, hint
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        step = (try? c.decode(String.self, forKey: .step)) ?? "?"
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        let hint = try c.decodeIfPresent(String.self, forKey: .hint)
        self.hint = (hint?.isEmpty ?? true) ? nil : hint
    }

    var label: String {
        switch step {
        case "dns": "Résolution du nom"
        case "tcp": "Ouverture du port"
        case "tls": "Poignée de main TLS"
        case "auth": "Authentification"
        case "redfish": "Service Redfish"
        default: step
        }
    }
}

/// Réponse de `POST /ipmi/{id}/test`.
struct BMCTestResult: Decodable, Sendable {
    var ok: Bool
    var detail: String?
    var steps: [BMCDiagnosticStep]

    enum CodingKeys: String, CodingKey {
        case ok, detail, steps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        steps = (try? c.decode([BMCDiagnosticStep].self, forKey: .steps)) ?? []
    }

    /// Le compte rendu tient en un texte : l'étape qui casse, puis sa piste.
    var report: String {
        guard let failed = steps.first(where: { !$0.ok }) else {
            return detail ?? (ok ? "Contrôleur joignable." : "Contrôleur muet.")
        }
        return [failed.label + " : " + failed.detail, failed.hint]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }
}

/// Les gestes d'alimentation d'un contrôleur hors-bande.
///
/// Ils s'appliquent au matériel, sans passer par le système : d'où les
/// avertissements, plus fermes qu'ailleurs dans l'application.
enum BMCPowerAction: String, CaseIterable, Identifiable, Sendable {
    case on, graceful, restart, cycle, off, nmi

    var id: String { rawValue }

    var label: String {
        switch self {
        case .on: "Allumer"
        case .graceful: "Arrêt propre"
        case .restart: "Redémarrage forcé"
        case .cycle: "Cycle d'alimentation"
        case .off: "Coupure forcée"
        case .nmi: "Interruption NMI"
        }
    }

    var hint: String {
        switch self {
        case .on: "Met la machine sous tension."
        case .graceful: "Demande au système de s'arrêter de lui-même (ACPI)."
        case .restart: "Équivalent du bouton reset : le système n'est pas prévenu."
        case .cycle: "Coupe le courant, puis le rétablit."
        case .off: "Coupe le courant sans prévenir le système."
        case .nmi: "Force un vidage noyau, pour diagnostiquer une machine figée."
        }
    }

    var symbol: String {
        switch self {
        case .on: "power"
        case .graceful: "moon.zzz"
        case .restart, .cycle: "arrow.triangle.2.circlepath"
        case .off: "bolt.slash"
        case .nmi: "exclamationmark.octagon"
        }
    }

    /// Tout sauf l'allumage interrompt ce qui tourne.
    var isDestructive: Bool { self != .on }

    /// L'avertissement propre à l'action, ajouté au message de confirmation.
    var warning: String? {
        switch self {
        case .off, .cycle:
            "Une coupure brutale peut corrompre les systèmes de fichiers montés en écriture."
        case .restart:
            "Le système n'aura pas le temps de vider ses caches sur disque."
        case .nmi:
            "La machine sera figée le temps du vidage mémoire."
        default:
            nil
        }
    }

    /// Allumer une machine allumée n'a pas de sens, et l'éteindre deux fois non
    /// plus : l'état courant décide de ce qui reste proposé.
    func isRelevant(poweredOn: Bool) -> Bool {
        self == .on ? !poweredOn : poweredOn
    }
}
