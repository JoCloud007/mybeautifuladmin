import Foundation

/// Session shell vivante côté serveur.
///
/// L'intérêt du modèle : le shell survit à la fermeture de l'app. Se détacher ne
/// tue pas le processus, et le tampon des dernières lignes est rejoué au
/// rattachement — un `apt upgrade` lancé dans le métro se retrouve intact.
struct TerminalSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var hostID: Int
    var hostName: String?
    var container: String?
    var label: String
    var owner: String?
    /// Délai de survie après détachement, en secondes. 0 = sans limite.
    var ttl: Int
    var created: Date?
    var attached: Int
    var detachedSince: Date?
    var buffered: Int
    var closed: Bool
    var exitReason: String?

    enum CodingKeys: String, CodingKey {
        case id, container, label, owner, ttl, created, attached, buffered, closed
        case hostID = "host_id"
        case hostName = "host_name"
        case detachedSince = "detached_since"
        case exitReason = "exit_reason"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        hostID = (try? values.decode(Int.self, forKey: .hostID)) ?? 0
        hostName = try values.decodeIfPresent(String.self, forKey: .hostName)
        container = try values.decodeIfPresent(String.self, forKey: .container)
        label = (try? values.decode(String.self, forKey: .label)) ?? "Session"
        owner = try values.decodeIfPresent(String.self, forKey: .owner)
        ttl = (try? values.decode(Int.self, forKey: .ttl)) ?? 0
        attached = (try? values.decode(Int.self, forKey: .attached)) ?? 0
        buffered = (try? values.decode(Int.self, forKey: .buffered)) ?? 0
        closed = (try? values.decode(Bool.self, forKey: .closed)) ?? false
        exitReason = try values.decodeIfPresent(String.self, forKey: .exitReason)
        // Ces deux horodatages sont des `time.time()` bruts, pas de l'ISO 8601 :
        // le décodeur de dates global échouerait dessus.
        created = (try? values.decode(Double.self, forKey: .created))
            .map { Date(timeIntervalSince1970: $0) }
        detachedSince = (try? values.decode(Double.self, forKey: .detachedSince))
            .map { Date(timeIntervalSince1970: $0) }
    }

    var isAttached: Bool { attached > 0 }

    var ttlLabel: String {
        ttl == 0 ? "Sans limite" : Format.duration(Double(ttl))
    }

    /// Temps restant avant que le serveur ferme la session détachée.
    var expiresIn: TimeInterval? {
        guard ttl > 0, let detachedSince else { return nil }
        return max(0, Double(ttl) - Date.now.timeIntervalSince(detachedSince))
    }
}

struct TerminalSessionsResponse: Codable, Sendable {
    var sessions: [TerminalSession]
    var ttlChoices: [String: Int]

    enum CodingKeys: String, CodingKey {
        case sessions
        case ttlChoices = "ttl_choices"
    }
}

/// Durées de survie proposées, dans l'ordre du serveur (`TTL_CHOICES`).
enum TerminalTTL: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = "5m"
    case thirtyMinutes = "30m"
    case twoHours = "2h"
    case eightHours = "8h"
    case day = "24h"
    /// `keep` est interprété côté serveur comme « ne ferme jamais ».
    case keep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .thirtyMinutes: "30 minutes"
        case .twoHours: "2 heures"
        case .eightHours: "8 heures"
        case .day: "24 heures"
        case .keep: "Sans limite"
        }
    }

    var shortLabel: String {
        switch self {
        case .keep: "∞"
        default: rawValue
        }
    }
}
