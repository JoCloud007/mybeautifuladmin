import Foundation

/// Conteneur Docker, ou invité LXC/QEMU vu comme tel.
struct Container: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    var hostID: Int
    var hostName: String?
    var hostKind: String?
    var extID: String
    var name: String
    var kind: String
    var image: String?
    var state: String?
    var status: String?
    var project: String?
    var service: String?
    var ports: [JSONValue]
    var stats: [String: JSONValue]
    var labels: [String: JSONValue]
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, image, state, status, project, service, ports, stats, labels
        case hostID = "host_id"
        case hostName = "host_name"
        case hostKind = "host_kind"
        case extID = "ext_id"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        hostID = try container.decode(Int.self, forKey: .hostID)
        hostName = try container.decodeIfPresent(String.self, forKey: .hostName)
        hostKind = try container.decodeIfPresent(String.self, forKey: .hostKind)
        extID = (try? container.decode(String.self, forKey: .extID)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? "—"
        kind = (try? container.decode(String.self, forKey: .kind)) ?? "docker"
        image = try container.decodeIfPresent(String.self, forKey: .image)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        ports = (try? container.decode([JSONValue].self, forKey: .ports)) ?? []
        stats = (try? container.decode([String: JSONValue].self, forKey: .stats)) ?? [:]
        labels = (try? container.decode([String: JSONValue].self, forKey: .labels)) ?? [:]
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var isRunning: Bool { state == "running" }
    var isDocker: Bool { kind == "docker" }

    var cpu: Double? { stats.double("cpu") }
    var memory: Double? { stats.double("mem") }
    var memoryPercent: Double? { stats.double("mem_percent") }

    /// Image sans son registre ni son digest : `ghcr.io/org/app:1.2@sha…` → `app:1.2`.
    var shortImage: String? {
        guard let image else { return nil }
        let withoutDigest = image.split(separator: "@").first.map(String.init) ?? image
        return withoutDigest.split(separator: "/").last.map(String.init) ?? withoutDigest
    }

    /// Ports publiés, dédoublonnés et lisibles : `8080→80/tcp`.
    var publishedPorts: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in ports {
            guard let object = entry.objectValue else { continue }
            let privatePort = object.int("PrivatePort") ?? object.int("private_port")
            guard let privatePort else { continue }
            let publicPort = object.int("PublicPort") ?? object.int("public_port")
            let type = object.string("Type") ?? object.string("type") ?? "tcp"
            let text = publicPort.map { "\($0)→\(privatePort)/\(type)" } ?? "\(privatePort)/\(type)"
            if seen.insert(text).inserted { result.append(text) }
        }
        return result
    }

    /// Actions acceptées par l'API pour ce conteneur, selon son état.
    var availableActions: [ContainerAction] {
        isRunning ? [.restart, .stop, .pause] : [.start, .remove]
    }
}

enum ContainerAction: String, Identifiable, CaseIterable, Sendable {
    case start, stop, restart, pause, unpause, remove

    var id: String { rawValue }

    var label: String {
        switch self {
        case .start: "Démarrer"
        case .stop: "Arrêter"
        case .restart: "Redémarrer"
        case .pause: "Suspendre"
        case .unpause: "Reprendre"
        case .remove: "Supprimer"
        }
    }

    var symbol: String {
        switch self {
        case .start: "play"
        case .stop: "stop"
        case .restart: "arrow.clockwise"
        case .pause: "pause"
        case .unpause: "play.fill"
        case .remove: "trash"
        }
    }

    /// Une action destructrice demande confirmation avant d'être envoyée.
    var isDestructive: Bool {
        switch self {
        case .stop, .remove, .restart: true
        default: false
        }
    }

    var confirmationMessage: String {
        switch self {
        case .stop: "Le conteneur s'arrête et le service qu'il rend devient indisponible."
        case .restart: "Le service sera brièvement interrompu."
        case .remove: "Le conteneur est supprimé. Ses volumes sont conservés, mais il faudra le recréer."
        default: ""
        }
    }
}

// MARK: - Piles compose

struct ContainerProject: Codable, Identifiable, Hashable, Sendable {
    var project: String?
    var hostID: Int
    var hostName: String
    var total: Int
    var running: Int
    var cpu: Double
    var memory: Double
    var updatedAt: Date?

    /// Les conteneurs hors pile sont regroupés sous une entrée sans nom : la clé
    /// doit rester unique par hôte.
    var id: String { "\(hostID):\(project ?? "~orphans")" }

    enum CodingKeys: String, CodingKey {
        case project, total, running, cpu
        case hostID = "host_id"
        case hostName = "host_name"
        case memory = "mem"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        hostID = try container.decode(Int.self, forKey: .hostID)
        hostName = (try? container.decode(String.self, forKey: .hostName)) ?? "—"
        total = (try? container.decode(Int.self, forKey: .total)) ?? 0
        running = (try? container.decode(Int.self, forKey: .running)) ?? 0
        cpu = (try? container.decode(Double.self, forKey: .cpu)) ?? 0
        memory = (try? container.decode(Double.self, forKey: .memory)) ?? 0
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var isComplete: Bool { running == total && total > 0 }
    var displayName: String { project ?? "Sans pile" }
}

struct ProjectsResponse: Codable, Sendable {
    var projects: [ContainerProject]
    var summary: Summary

    struct Summary: Codable, Sendable {
        var projects: Int
        var orphans: Int
    }
}

// MARK: - Ménage Docker

struct DockerUsage: Codable, Sendable {
    var usage: [String: Category]
    var reclaimableTotal: Double
    var sizeTotal: Double

    struct Category: Codable, Sendable {
        var count: Int
        var size: Double
        var reclaimable: Double
    }

    enum CodingKeys: String, CodingKey {
        case usage
        case reclaimableTotal = "reclaimable_total"
        case sizeTotal = "size_total"
    }

    /// Ordre d'affichage stable, du plus gros gain potentiel au plus anodin.
    static let order = ["images", "containers", "volumes", "build_cache"]

    static func label(_ key: String) -> String {
        switch key {
        case "images": "Images"
        case "containers": "Conteneurs arrêtés"
        case "volumes": "Volumes orphelins"
        case "build_cache": "Cache de construction"
        case "networks": "Réseaux"
        default: key
        }
    }
}

/// Cibles de purge acceptées par `POST /hosts/{id}/docker/prune`.
enum PruneTarget: String, CaseIterable, Identifiable, Sendable {
    case containers, images, imagesAll = "images_all", volumes, networks, buildCache = "build_cache"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .containers: "Conteneurs arrêtés"
        case .images: "Images sans conteneur"
        case .imagesAll: "Toutes les images inutilisées"
        case .volumes: "Volumes orphelins"
        case .networks: "Réseaux inutilisés"
        case .buildCache: "Cache de construction"
        }
    }

    /// Vrai quand la purge peut détruire des données qu'on ne récupère pas.
    var isRisky: Bool {
        switch self {
        case .volumes: true      // un volume orphelin peut porter des données
        case .imagesAll: true    // il faudra tout retélécharger
        default: false
        }
    }

    var caution: String? {
        switch self {
        case .volumes: "Un volume orphelin peut contenir les données d'un conteneur recréé récemment. Vérifie avant de purger."
        case .imagesAll: "Toutes les images non utilisées seront supprimées, y compris celles que tu comptais réutiliser hors ligne."
        default: nil
        }
    }
}
