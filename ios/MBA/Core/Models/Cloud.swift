import Foundation

/// Réponse de `GET /cloud` : les comptes de cloud public et leurs ressources.
struct CloudOverview: Decodable, Sendable {
    var accounts: [CloudAccount]
    var resources: [CloudResource]
    var summary: CloudSummary

    enum CodingKeys: String, CodingKey {
        case accounts, resources, summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try? c.decode([CloudAccount].self, forKey: .accounts)) ?? []
        resources = (try? c.decode([CloudResource].self, forKey: .resources)) ?? []
        summary = (try? c.decode(CloudSummary.self, forKey: .summary)) ?? CloudSummary()
    }
}

struct CloudSummary: Decodable, Hashable, Sendable {
    var accounts: Int = 0
    var accountsOnline: Int = 0
    var buckets: Int = 0
    var storedBytes: Double = 0
    var objects: Double = 0
    /// Dépense constatée depuis le début du mois, et projection à fin de mois
    /// telle que le fournisseur l'annonce.
    var costCurrent: Double = 0
    var costForecast: Double = 0
    var currency: String = "EUR"
    /// Buckets adossés à un datastore Proxmox Backup Server.
    var linkedPBS: Int = 0
    var byKind: [String: Int] = [:]
    var byRegion: [String: Int] = [:]

    enum CodingKeys: String, CodingKey {
        case accounts, buckets, objects, currency
        case accountsOnline = "accounts_online"
        case storedBytes = "stored_bytes"
        case costCurrent = "cost_current"
        case costForecast = "cost_forecast"
        case linkedPBS = "linked_pbs"
        case byKind = "by_kind"
        case byRegion = "by_region"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = (try? c.decode(Int.self, forKey: .accounts)) ?? 0
        accountsOnline = (try? c.decode(Int.self, forKey: .accountsOnline)) ?? 0
        buckets = (try? c.decode(Int.self, forKey: .buckets)) ?? 0
        storedBytes = (try? c.decode(Double.self, forKey: .storedBytes)) ?? 0
        objects = (try? c.decode(Double.self, forKey: .objects)) ?? 0
        costCurrent = (try? c.decode(Double.self, forKey: .costCurrent)) ?? 0
        costForecast = (try? c.decode(Double.self, forKey: .costForecast)) ?? 0
        currency = (try? c.decode(String.self, forKey: .currency)) ?? "EUR"
        linkedPBS = (try? c.decode(Int.self, forKey: .linkedPBS)) ?? 0
        byKind = (try? c.decode([String: Int].self, forKey: .byKind)) ?? [:]
        byRegion = (try? c.decode([String: Int].self, forKey: .byRegion)) ?? [:]
    }
}

/// Un compte — un projet Public Cloud chez un fournisseur.
struct CloudAccount: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var provider: String
    var endpoint: String
    var projectID: String?
    var credentialID: Int?
    var credentialName: String?
    var enabled: Bool
    var syncMinutes: Int
    var status: String
    var lastError: String?
    var lastSync: Date?
    var meta: [String: JSONValue]
    var resourcesCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, provider, endpoint, enabled, status, meta
        case projectID = "project_id"
        case credentialID = "credential_id"
        case credentialName = "credential_name"
        case syncMinutes = "sync_minutes"
        case lastError = "last_error"
        case lastSync = "last_sync"
        case resourcesCount = "resources_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        provider = (try? c.decode(String.self, forKey: .provider)) ?? "ovh"
        endpoint = (try? c.decode(String.self, forKey: .endpoint)) ?? "ovh-eu"
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        credentialID = try c.decodeIfPresent(Int.self, forKey: .credentialID)
        credentialName = try c.decodeIfPresent(String.self, forKey: .credentialName)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        syncMinutes = (try? c.decode(Int.self, forKey: .syncMinutes)) ?? 30
        status = (try? c.decode(String.self, forKey: .status)) ?? "unknown"
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        meta = (try? c.decode([String: JSONValue].self, forKey: .meta)) ?? [:]
        resourcesCount = try c.decodeIfPresent(Int.self, forKey: .resourcesCount)
    }

    var isOnline: Bool { status == "online" }

    /// Le coût du mois, tel que le fournisseur le rapporte au dernier sync.
    var costCurrent: Double? { meta["cost"]?["current"]?.doubleValue }
    var costForecast: Double? { meta["cost"]?["forecast"]?.doubleValue }
    var currency: String { meta["cost"]?["currency"]?.stringValue ?? "EUR" }

    /// Un compte sans projet ne peut rien synchroniser : le serveur refuse.
    var needsProject: Bool { projectID?.isEmpty ?? true }
}

/// Une ressource facturée : un bucket, un conteneur objet, une instance, un
/// volume.
struct CloudResource: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var accountID: Int
    var accountName: String?
    var provider: String?
    var kind: String
    var extID: String
    var name: String
    var region: String?
    var status: String?
    var sizeBytes: Double?
    var objects: Double?
    var priceMonth: Double?
    /// Seuil de surveillance saisi à la main : le fournisseur ne le connaît pas.
    var quotaBytes: Double?
    var hostID: Int?
    var linkRef: String?
    var pbsName: String?
    var notes: String?
    var firstSeen: Date?
    var lastSeen: Date?
    var trend: CloudTrend
    /// Jours restants avant d'atteindre le seuil, au rythme observé.
    var daysToQuota: Double?

    enum CodingKeys: String, CodingKey {
        case id, kind, name, region, status, objects, notes, trend, provider
        case accountID = "account_id"
        case accountName = "account_name"
        case extID = "ext_id"
        case sizeBytes = "size_bytes"
        case priceMonth = "price_month"
        case quotaBytes = "quota_bytes"
        case hostID = "host_id"
        case linkRef = "link_ref"
        case pbsName = "pbs_name"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case daysToQuota = "days_to_quota"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        accountID = (try? c.decode(Int.self, forKey: .accountID)) ?? 0
        accountName = try c.decodeIfPresent(String.self, forKey: .accountName)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "bucket"
        extID = (try? c.decode(String.self, forKey: .extID)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        region = try c.decodeIfPresent(String.self, forKey: .region)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        sizeBytes = try? c.decodeIfPresent(Double.self, forKey: .sizeBytes)
        objects = try? c.decodeIfPresent(Double.self, forKey: .objects)
        priceMonth = try? c.decodeIfPresent(Double.self, forKey: .priceMonth)
        quotaBytes = try? c.decodeIfPresent(Double.self, forKey: .quotaBytes)
        hostID = try c.decodeIfPresent(Int.self, forKey: .hostID)
        linkRef = try c.decodeIfPresent(String.self, forKey: .linkRef)
        pbsName = try c.decodeIfPresent(String.self, forKey: .pbsName)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        trend = (try? c.decode(CloudTrend.self, forKey: .trend)) ?? CloudTrend()
        daysToQuota = try? c.decodeIfPresent(Double.self, forKey: .daysToQuota)
    }

    var isBucket: Bool { CloudResource.bucketKinds.contains(kind) }

    /// Le fournisseur ne la voit plus : elle a été supprimée de son côté.
    var isGone: Bool { status == "disparu" }

    static let bucketKinds: Set<String> = ["bucket", "container"]

    var kindLabel: String {
        switch kind {
        case "bucket", "container": "Stockage objet"
        case "instance": "Instance"
        case "volume": "Volume"
        default: kind.capitalized
        }
    }

    var symbol: String {
        switch kind {
        case "bucket", "container": "externaldrive.badge.icloud"
        case "instance": "server.rack"
        case "volume": "internaldrive"
        default: "cube"
        }
    }

    /// Occupation du seuil, quand un seuil a été fixé.
    var quotaPercent: Double? {
        guard let quotaBytes, quotaBytes > 0, let sizeBytes else { return nil }
        return sizeBytes / quotaBytes * 100
    }

    /// Le bucket sert de dépôt à un PBS : le supprimer emporterait des
    /// sauvegardes.
    var isBackupStore: Bool { linkRef != nil }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [name, region, accountName, linkRef, notes, kind]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }
}

/// La croissance d'une ressource, mesurée sur l'historique réel.
struct CloudTrend: Decodable, Hashable, Sendable {
    /// Octets par jour. `nil` quand l'historique est trop court pour qu'une
    /// pente veuille dire quelque chose.
    var perDay: Double?
    var delta: Double?
    var spanDays: Double?

    enum CodingKeys: String, CodingKey {
        case delta
        case perDay = "per_day"
        case spanDays = "span_days"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        perDay = try? c.decodeIfPresent(Double.self, forKey: .perDay)
        delta = try? c.decodeIfPresent(Double.self, forKey: .delta)
        spanDays = try? c.decodeIfPresent(Double.self, forKey: .spanDays)
    }

    var isGrowing: Bool { (perDay ?? 0) > 0 }
    var isShrinking: Bool { (perDay ?? 0) < 0 }

    /// « +1,2 Go/j » — la pente en une expression.
    var label: String? {
        guard let perDay, perDay != 0 else { return nil }
        let sign = perDay > 0 ? "+" : "−"
        return "\(sign)\(Format.bytes(abs(perDay)))/j"
    }
}

/// Réponse de `GET /cloud/resources/{id}`.
struct CloudResourceDetail: Decodable, Sendable {
    var resource: CloudResource
    var history: [CloudUsagePoint]
    var trend7d: CloudTrend
    var trend30d: CloudTrend

    enum CodingKeys: String, CodingKey {
        case resource, history
        case trend7d = "trend_7d"
        case trend30d = "trend_30d"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resource = try c.decode(CloudResource.self, forKey: .resource)
        history = (try? c.decode([CloudUsagePoint].self, forKey: .history)) ?? []
        trend7d = (try? c.decode(CloudTrend.self, forKey: .trend7d)) ?? CloudTrend()
        trend30d = (try? c.decode(CloudTrend.self, forKey: .trend30d)) ?? CloudTrend()
    }

    /// La série de volumétrie, prête à tracer.
    var storagePoints: [MetricPoint] {
        history
            .filter { $0.metric == "storage.bytes" }
            .map { MetricPoint(date: Date(timeIntervalSince1970: $0.time), value: $0.value) }
    }

    var objectPoints: [MetricPoint] {
        history
            .filter { $0.metric == "storage.objects" }
            .map { MetricPoint(date: Date(timeIntervalSince1970: $0.time), value: $0.value) }
    }
}

/// Un relevé d'usage horodaté.
struct CloudUsagePoint: Decodable, Sendable {
    /// Instant Unix — le serveur renvoie un flottant, pas une date ISO.
    var time: Double
    var metric: String
    var value: Double

    enum CodingKeys: String, CodingKey {
        case t, metric, value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = (try? c.decode(Double.self, forKey: .t)) ?? 0
        metric = (try? c.decode(String.self, forKey: .metric)) ?? ""
        value = (try? c.decode(Double.self, forKey: .value)) ?? 0
    }
}

/// Corps de `PATCH /cloud/resources/{id}` — ce que l'exploitant sait et que le
/// fournisseur ignore.
struct CloudResourcePatch: Encodable, Sendable {
    var quotaBytes: Double?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case notes
        case quotaBytes = "quota_bytes"
    }
}

/// Corps de `PATCH /cloud/accounts/{id}`.
struct CloudAccountPatch: Encodable, Sendable {
    var enabled: Bool?
    var syncMinutes: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case syncMinutes = "sync_minutes"
    }
}

/// Réponse de `POST /cloud/accounts/{id}/sync`.
struct CloudSyncResult: Decodable, Sendable {
    var resources: Int
    var errors: [String]
    var linkedPBS: Int

    enum CodingKeys: String, CodingKey {
        case resources, errors
        case linkedPBS = "linked_pbs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resources = (try? c.decode(Int.self, forKey: .resources)) ?? 0
        errors = (try? c.decode([String].self, forKey: .errors)) ?? []
        linkedPBS = (try? c.decode(Int.self, forKey: .linkedPBS)) ?? 0
    }

    /// Le compte rendu d'une synchronisation, en une phrase.
    var report: String {
        var lines = ["\(Format.plural(resources, "ressource")) relevée\(resources > 1 ? "s" : "")."]
        if linkedPBS > 0 {
            lines.append("\(Format.plural(linkedPBS, "bucket")) relié\(linkedPBS > 1 ? "s" : "") à un datastore PBS.")
        }
        if !errors.isEmpty {
            lines.append("Avertissements :\n" + errors.prefix(5).joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }
}

extension Format {
    /// Un montant dans la devise du fournisseur.
    static func money(_ value: Double?, currency: String = "EUR") -> String {
        guard let value, value.isFinite else { return placeholder }
        return value.formatted(.currency(code: currency).locale(Locale(identifier: "fr_FR")))
    }
}
