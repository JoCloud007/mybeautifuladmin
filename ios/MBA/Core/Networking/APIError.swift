import Foundation

/// Erreur d'API présentable telle quelle à l'utilisateur.
///
/// L'API MBA renvoie parfois un `detail` structuré (message + piste de
/// résolution) plutôt qu'une chaîne : les diagnostics Proxmox et IPMI en
/// dépendent, et les perdre reviendrait à afficher « Erreur 502 » là où le
/// serveur explique précisément quoi corriger.
struct APIError: LocalizedError, Sendable {
    enum Kind: Sendable, Equatable {
        case unauthorized
        case notFound
        case conflict
        case server(Int)
        case transport
        case decoding
        case offline
        case cancelled
    }

    let kind: Kind
    let message: String
    /// Piste de résolution renvoyée par le serveur, quand elle existe.
    var hint: String?
    var status: Int?

    var errorDescription: String? { message }
    var recoverySuggestion: String? { hint }

    static func http(status: Int, message: String, hint: String? = nil) -> APIError {
        let kind: Kind
        switch status {
        case 401, 403: kind = .unauthorized
        case 404: kind = .notFound
        case 409: kind = .conflict
        default: kind = .server(status)
        }
        return APIError(kind: kind, message: message, hint: hint, status: status)
    }

    static func transport(_ error: Error) -> APIError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return APIError(kind: .cancelled, message: "Requête annulée")
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return APIError(kind: .offline, message: "Pas de réseau",
                                hint: "Vérifie le Wi-Fi ou le VPN qui donne accès au serveur.")
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
                return APIError(kind: .transport, message: "Serveur injoignable",
                                hint: "Le serveur ne répond pas à cette adresse. S'il est sur ton réseau domestique, active le VPN.")
            case NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return APIError(kind: .transport, message: "Certificat TLS refusé",
                                hint: "Ce serveur présente un certificat auto-signé. Active « Accepter le certificat » dans la fiche du serveur.")
            default:
                break
            }
        }
        return APIError(kind: .transport, message: nsError.localizedDescription)
    }

    static let decoding = APIError(kind: .decoding, message: "Réponse illisible du serveur",
                                   hint: "L'API a répondu dans un format inattendu — vérifie que le serveur est à jour.")

    /// Répondu en HTML là où on attendait du JSON.
    ///
    /// Le cas courant : l'adresse pointe sur l'interface web (nginx, port 8888)
    /// et non sur l'API. Le SPA renvoie `index.html` en 200 pour n'importe quel
    /// chemin, ce qui ressemble à un serveur en bonne santé jusqu'au décodage.
    static func notAnAPI(contentType: String?) -> APIError {
        let isHTML = contentType?.contains("html") ?? false
        return APIError(
            kind: .decoding,
            message: isHTML ? "Cette adresse sert l'interface web, pas l'API"
                            : "Cette adresse ne répond pas en JSON",
            hint: "L'API est sur le port 8080, ou derrière l'interface web au chemin /api — par exemple « localhost:8888/api ».")
    }

    var isCancellation: Bool { kind == .cancelled }
}
