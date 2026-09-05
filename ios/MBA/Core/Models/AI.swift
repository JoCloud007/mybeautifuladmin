import Foundation

/// Réponse de `GET /ai/overview` : les serveurs d'inférence et les cartes qui
/// les font tourner.
struct AIOverview: Decodable, Sendable {
    var endpoints: [AIEndpoint]
    var accelerators: [Accelerator]
    var summary: AISummary

    enum CodingKeys: String, CodingKey {
        case endpoints, accelerators, summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoints = (try? c.decode([AIEndpoint].self, forKey: .endpoints)) ?? []
        accelerators = (try? c.decode([Accelerator].self, forKey: .accelerators)) ?? []
        summary = (try? c.decode(AISummary.self, forKey: .summary)) ?? AISummary()
    }
}

struct AISummary: Decodable, Hashable, Sendable {
    var endpointsOnline: Int = 0
    var modelsTotal: Int = 0
    var modelsLoaded: Int = 0
    /// Somme de la VRAM occupée par les modèles résidents, tous serveurs
    /// confondus.
    var vramLoaded: Double = 0

    enum CodingKeys: String, CodingKey {
        case endpointsOnline = "endpoints_online"
        case modelsTotal = "models_total"
        case modelsLoaded = "models_loaded"
        case vramLoaded = "vram_loaded"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpointsOnline = (try? c.decode(Int.self, forKey: .endpointsOnline)) ?? 0
        modelsTotal = (try? c.decode(Int.self, forKey: .modelsTotal)) ?? 0
        modelsLoaded = (try? c.decode(Int.self, forKey: .modelsLoaded)) ?? 0
        vramLoaded = (try? c.decode(Double.self, forKey: .vramLoaded)) ?? 0
    }
}

/// Un serveur d'inférence : Ollama, ou une API compatible OpenAI (vLLM, TGI,
/// LM Studio, passerelle). Le second dialecte ne sait que servir un modèle
/// déjà chargé : `capabilities` dit ce que l'écran peut proposer.
struct AIEndpoint: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var url: String
    var hostID: Int?
    var hostName: String?
    var kind: String
    /// Libellé lisible du type, fourni par l'API (« vLLM / API OpenAI »).
    var kindLabel: String?
    /// Gestes acceptés : chat · pull · delete · unload.
    var capabilities: [String]
    var enabled: Bool
    var status: String
    var error: String?
    var version: String?
    var models: [AIModel]
    /// Les modèles actuellement résidents en mémoire : ce sont eux qui
    /// répondent sans délai de chargement.
    var loaded: [LoadedModel]

    enum CodingKeys: String, CodingKey {
        case id, name, url, kind, capabilities, enabled, status, error, version, models, loaded
        case hostID = "host_id"
        case hostName = "host_name"
        case kindLabel = "kind_label"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "ollama"
        kindLabel = try? c.decodeIfPresent(String.self, forKey: .kindLabel)
        // Une API plus ancienne ne renvoie pas le champ : on suppose Ollama,
        // qui sait tout faire, plutôt que de griser des gestes disponibles.
        capabilities = (try? c.decode([String].self, forKey: .capabilities))
            ?? ["chat", "pull", "delete", "unload"]
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        error = try c.decodeIfPresent(String.self, forKey: .error)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        models = (try? c.decode([AIModel].self, forKey: .models)) ?? []
        loaded = (try? c.decode([LoadedModel].self, forKey: .loaded)) ?? []
    }

    var isOnline: Bool { status == "online" }

    /// Ce serveur accepte-t-il ce geste ?
    func can(_ capability: String) -> Bool { capabilities.contains(capability) }

    var diskUsed: Double { models.compactMap(\.size).reduce(0, +) }
    var vramUsed: Double { loaded.map(\.sizeVRAM).reduce(0, +) }

    func isLoaded(_ model: AIModel) -> Bool {
        loaded.contains { $0.name == model.name }
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, url, hostName].compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
            || models.contains { $0.matches(query) }
    }
}

/// Un modèle présent sur le disque du serveur.
struct AIModel: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var size: Double?
    var modified: Date?
    var family: String?
    /// Nombre de paramètres, tel qu'Ollama l'annonce (« 8B », « 70B »).
    var parameters: String?
    var quantization: String?
    var digest: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, modified, family, parameters, quantization, digest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        size = try? c.decodeIfPresent(Double.self, forKey: .size)
        modified = try? c.decodeIfPresent(Date.self, forKey: .modified)
        family = try c.decodeIfPresent(String.self, forKey: .family)
        parameters = try c.decodeIfPresent(String.self, forKey: .parameters)
        quantization = try c.decodeIfPresent(String.self, forKey: .quantization)
        digest = try c.decodeIfPresent(String.self, forKey: .digest)
    }

    /// « llama · 8B · Q4_K_M » — la carte d'identité du modèle en une ligne.
    var signature: String {
        [family, parameters, quantization].compactMap { $0 }.joined(separator: " · ")
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, family, parameters].compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }
}

/// Un modèle résident en mémoire.
struct LoadedModel: Decodable, Identifiable, Hashable, Sendable {
    var name: String
    var size: Double
    var sizeVRAM: Double
    /// Ollama décharge le modèle passé cette date, sauf nouvelle sollicitation.
    var expiresAt: Date?
    var context: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, context
        case sizeVRAM = "size_vram"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        size = (try? c.decode(Double.self, forKey: .size)) ?? 0
        sizeVRAM = (try? c.decode(Double.self, forKey: .sizeVRAM)) ?? 0
        expiresAt = try? c.decodeIfPresent(Date.self, forKey: .expiresAt)
        context = try c.decodeIfPresent(String.self, forKey: .context)
    }

    /// Quelle part du modèle tient sur la carte : le reste tourne sur le
    /// processeur, bien plus lentement.
    var vramShare: Double? {
        guard size > 0 else { return nil }
        return min(100, sizeVRAM / size * 100)
    }

    var isFullyOnGPU: Bool {
        guard size > 0 else { return false }
        return sizeVRAM >= size * 0.99
    }
}

/// Une carte graphique vue par un collecteur Linux.
struct Accelerator: Decodable, Identifiable, Hashable, Sendable {
    var hostID: Int?
    var hostName: String?
    var card: String
    var busy: Double?
    var temp: Double?
    var power: Double?
    var powerCap: Double?
    var vramUsed: Double?
    var vramTotal: Double?
    var vramPercent: Double?
    var gttUsed: Double?
    var gttTotal: Double?
    var sclk: Double?
    var mclk: Double?
    var fan: Double?
    /// Vrai sur un APU à mémoire unifiée : la VRAM annoncée est de la RAM
    /// système, et le total à surveiller n'est pas le même.
    var unified: Bool
    var cpuModel: String?
    var memTotal: Double?

    var id: String { "\(hostID ?? 0)-\(card)" }

    enum CodingKeys: String, CodingKey {
        case card, busy, temp, power, sclk, mclk, fan, unified
        case hostID = "host_id"
        case hostName = "host_name"
        case powerCap = "power_cap"
        case vramUsed = "vram_used"
        case vramTotal = "vram_total"
        case vramPercent = "vram_percent"
        case gttUsed = "gtt_used"
        case gttTotal = "gtt_total"
        case cpuModel = "cpu_model"
        case memTotal = "mem_total"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName)
        card = (try? c.decode(String.self, forKey: .card)) ?? "card0"
        busy = try? c.decodeIfPresent(Double.self, forKey: .busy)
        temp = try? c.decodeIfPresent(Double.self, forKey: .temp)
        power = try? c.decodeIfPresent(Double.self, forKey: .power)
        powerCap = try? c.decodeIfPresent(Double.self, forKey: .powerCap)
        vramUsed = try? c.decodeIfPresent(Double.self, forKey: .vramUsed)
        vramTotal = try? c.decodeIfPresent(Double.self, forKey: .vramTotal)
        vramPercent = try? c.decodeIfPresent(Double.self, forKey: .vramPercent)
        gttUsed = try? c.decodeIfPresent(Double.self, forKey: .gttUsed)
        gttTotal = try? c.decodeIfPresent(Double.self, forKey: .gttTotal)
        sclk = try? c.decodeIfPresent(Double.self, forKey: .sclk)
        mclk = try? c.decodeIfPresent(Double.self, forKey: .mclk)
        fan = try? c.decodeIfPresent(Double.self, forKey: .fan)
        unified = (try? c.decode(Bool.self, forKey: .unified)) ?? false
        cpuModel = try c.decodeIfPresent(String.self, forKey: .cpuModel)
        memTotal = try? c.decodeIfPresent(Double.self, forKey: .memTotal)
    }

    var label: String { [hostName, card].compactMap { $0 }.joined(separator: " · ") }

    /// Le plafond de consommation atteint dit qu'on est limité par le
    /// « power budget », pas par le calcul.
    var powerShare: Double? {
        guard let power, let powerCap, powerCap > 0 else { return nil }
        return power / powerCap * 100
    }

    /// « 11 W / 120 W », ou « 11 W » quand la carte n'annonce pas de plafond —
    /// les APU renvoient couramment un plafond nul.
    var powerLabel: String? {
        guard let power, power > 0 else { return nil }
        guard let powerCap, powerCap > 0 else { return Format.watts(power) }
        return "\(Format.watts(power)) / \(Format.watts(powerCap))"
    }
}

// MARK: - Dialogue

/// Un tour de conversation.
struct ChatMessage: Identifiable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    let id = UUID()
    var role: Role
    var content: String
    /// Le message que le modèle est en train d'écrire : il grandit à chaque
    /// fragment reçu.
    var isStreaming: Bool = false
    var stats: ChatStats?
}

/// Ce que le serveur d'inférence rapporte à la fin d'une réponse.
struct ChatStats: Hashable, Sendable {
    var promptTokens: Int?
    var responseTokens: Int?
    /// Durée d'évaluation, en secondes — Ollama la compte en nanosecondes.
    var duration: Double?

    var tokensPerSecond: Double? {
        guard let responseTokens, let duration, duration > 0 else { return nil }
        return Double(responseTokens) / duration
    }

    /// « 128 jetons · 24,3 j/s » — la mesure qui dit si la carte suit.
    var summary: String? {
        guard let responseTokens else { return nil }
        guard let rate = tokensPerSecond else {
            return "\(Format.integer(responseTokens)) jetons"
        }
        return "\(Format.integer(responseTokens)) jetons · \(Format.number(rate, digits: 1)) j/s"
    }

    /// Lit les compteurs du dernier fragment Ollama, qui les porte tous.
    init?(chunk: JSONValue) {
        guard let object = chunk.objectValue,
              object["eval_count"] != nil || object["prompt_eval_count"] != nil
        else { return nil }
        promptTokens = object.int("prompt_eval_count")
        responseTokens = object.int("eval_count")
        duration = object.double("eval_duration").map { $0 / 1_000_000_000 }
    }
}

/// Corps de `POST /ai/endpoints/{id}/chat`.
struct ChatRequest: Encodable, Sendable {
    var model: String
    var messages: [[String: String]]
    var temperature: Double?
    var numCtx: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case numCtx = "num_ctx"
    }

    init(model: String, history: [ChatMessage], temperature: Double? = nil, numCtx: Int? = nil) {
        self.model = model
        // Seuls le rôle et le texte voyagent : le reste n'appartient qu'à
        // l'affichage.
        self.messages = history
            .filter { !$0.content.isEmpty }
            .map { ["role": $0.role.rawValue, "content": $0.content] }
        self.temperature = temperature
        self.numCtx = numCtx
    }
}

/// Corps de `POST /ai/endpoints/{id}/pull`.
struct ModelPullRequest: Encodable, Sendable {
    var model: String
}

/// Un fragment du flux de téléchargement d'un modèle.
struct PullProgress: Sendable {
    var status: String?
    var completed: Double?
    var total: Double?
    var error: String?
    var done: Bool

    init(chunk: JSONValue) {
        status = chunk["status"]?.stringValue
        completed = chunk["completed"]?.doubleValue
        total = chunk["total"]?.doubleValue
        error = chunk["error"]?.stringValue
        done = chunk["done"]?.boolValue ?? false
    }

    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, completed / total)
    }

    /// « téléchargement · 1,2 Go / 4,7 Go »
    var label: String {
        guard let status else { return "Téléchargement…" }
        guard let completed, let total, total > 0 else { return status }
        return "\(status) · \(Format.bytes(completed)) / \(Format.bytes(total))"
    }
}
