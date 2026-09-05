import Foundation

/// Réponse de `GET /security` : constats ouverts, notes par machine, synthèse.
struct SecurityOverview: Codable, Sendable {
    var findings: [SecurityFinding]
    var byHost: [HostScore]
    var summary: Summary

    enum CodingKeys: String, CodingKey {
        case findings, summary
        case byHost = "by_host"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        findings = (try? container.decode([SecurityFinding].self, forKey: .findings)) ?? []
        byHost = (try? container.decode([HostScore].self, forKey: .byHost)) ?? []
        summary = (try? container.decode(Summary.self, forKey: .summary)) ?? Summary()
    }

    struct Summary: Codable, Sendable {
        var score: Int = 100
        var total: Int = 0
        var bySeverity: [String: Int] = [:]
        var hostsAffected: Int = 0
        var hostsClean: Int = 0
        var muted: Int = 0
        var resolved7d: Int = 0

        enum CodingKeys: String, CodingKey {
            case score, total, muted
            case bySeverity = "by_severity"
            case hostsAffected = "hosts_affected"
            case hostsClean = "hosts_clean"
            case resolved7d = "resolved_7d"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            score = (try? container.decode(Int.self, forKey: .score)) ?? 100
            total = (try? container.decode(Int.self, forKey: .total)) ?? 0
            bySeverity = (try? container.decode([String: Int].self, forKey: .bySeverity)) ?? [:]
            hostsAffected = (try? container.decode(Int.self, forKey: .hostsAffected)) ?? 0
            hostsClean = (try? container.decode(Int.self, forKey: .hostsClean)) ?? 0
            muted = (try? container.decode(Int.self, forKey: .muted)) ?? 0
            resolved7d = (try? container.decode(Int.self, forKey: .resolved7d)) ?? 0
        }

        func count(_ severity: FindingSeverity) -> Int { bySeverity[severity.rawValue] ?? 0 }
    }

    /// Note d'une machine, tirée du poids des constats qui la visent.
    struct HostScore: Codable, Identifiable, Hashable, Sendable {
        var hostID: Int
        var name: String
        var kind: String
        var count: Int
        var score: Int
        var worst: FindingSeverity

        var id: Int { hostID }

        enum CodingKeys: String, CodingKey {
            case name, kind, count, score, worst
            case hostID = "host_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hostID = (try? container.decode(Int.self, forKey: .hostID)) ?? 0
            name = (try? container.decode(String.self, forKey: .name)) ?? "—"
            kind = (try? container.decode(String.self, forKey: .kind)) ?? "generic"
            count = (try? container.decode(Int.self, forKey: .count)) ?? 0
            score = (try? container.decode(Int.self, forKey: .score)) ?? 100
            worst = (try? container.decode(FindingSeverity.self, forKey: .worst)) ?? .info
        }

        var hostKind: HostKind { HostKind(rawValue: kind) ?? .generic }
    }
}

/// Un constat d'audit : un contrôle qui a échoué sur une machine ou un service.
struct SecurityFinding: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var hostID: Int?
    var hostName: String?
    var serviceID: Int?
    var serviceName: String?
    var code: String
    var severity: FindingSeverity
    var title: String
    var detail: String?
    var remediation: String?
    var muted: Bool
    var firstSeen: Date?
    var lastSeen: Date?
    var resolvedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, code, severity, title, detail, remediation, muted
        case hostID = "host_id"
        case hostName = "host_name"
        case serviceID = "service_id"
        case serviceName = "service_name"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case resolvedAt = "resolved_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        hostID = try container.decodeIfPresent(Int.self, forKey: .hostID)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        serviceID = try container.decodeIfPresent(Int.self, forKey: .serviceID)
        serviceName = try container.decodeIfPresent(String.self, forKey: .serviceName)
        code = (try? container.decode(String.self, forKey: .code)) ?? ""
        severity = (try? container.decode(FindingSeverity.self, forKey: .severity)) ?? .info
        title = (try? container.decode(String.self, forKey: .title)) ?? "—"
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        remediation = try container.decodeIfPresent(String.self, forKey: .remediation)
        muted = (try? container.decode(Bool.self, forKey: .muted)) ?? false
        firstSeen = try container.decodeIfPresent(Date.self, forKey: .firstSeen)
        lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
    }

    /// Ce que le constat désigne : une machine, ou le service sondé.
    var target: String? { hostName ?? serviceName }

    /// Famille du constat, déduite du préfixe de son code — c'est ce qui donne
    /// des sections lisibles plutôt qu'une liste de cent lignes à plat.
    var family: FindingFamily { FindingFamily(code: code) }

    /// Un correctif manquant se corrige depuis la fiche de la machine : c'est
    /// elle qui porte le bouton de mise à jour.
    var isFixableOnHost: Bool { code.hasPrefix("patch.") && hostID != nil }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [title, detail, hostName, serviceName, code]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }
}

enum FindingSeverity: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case critical, high, medium, low, info

    var id: String { rawValue }

    var label: String {
        switch self {
        case .critical: "Critique"
        case .high: "Élevé"
        case .medium: "Moyen"
        case .low: "Faible"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .high: "exclamationmark.triangle.fill"
        case .medium: "exclamationmark.circle.fill"
        case .low: "info.circle.fill"
        case .info: "info.circle"
        }
    }

    /// 0 = le plus grave, pour trier du pire au moindre.
    var rank: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .info: 4
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank > rhs.rank }
}

/// Regroupement des constats par préfixe de code, identique à la console web.
enum FindingFamily: String, CaseIterable, Identifiable, Sendable {
    case patch, endOfLife, ssh, network, account, hardware, service, tls, docker, other

    var id: String { rawValue }

    init(code: String) {
        self = switch code.prefix(while: { $0 != "." }) {
        case "patch": .patch
        case "os": .endOfLife
        case "ssh": .ssh
        case "net": .network
        case "account": .account
        case "hw": .hardware
        case "svc": .service
        case "tls": .tls
        case "docker": .docker
        default: .other
        }
    }

    var label: String {
        switch self {
        case .patch: "Correctifs et mises à jour"
        case .endOfLife: "Fin de support"
        case .ssh: "Accès SSH"
        case .network: "Exposition réseau"
        case .account: "Comptes"
        case .hardware: "Matériel"
        case .service: "Services"
        case .tls: "Certificats et chiffrement"
        case .docker: "Conteneurs"
        case .other: "Divers"
        }
    }

    var symbol: String {
        switch self {
        case .patch: "arrow.down.circle"
        case .endOfLife: "calendar.badge.exclamationmark"
        case .ssh: "key"
        case .network: "network.badge.shield.half.filled"
        case .account: "person.badge.key"
        case .hardware: "cpu"
        case .service: "gearshape.2"
        case .tls: "lock.shield"
        case .docker: "shippingbox"
        case .other: "questionmark.circle"
        }
    }
}

/// Corps de `POST /security/findings/{id}/mute`.
struct MutePayload: Encodable, Sendable {
    var muted: Bool
}
