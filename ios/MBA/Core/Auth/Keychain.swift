import Foundation
import Security
import Synchronization

/// Petit coffre au-dessus du trousseau iOS.
///
/// Le jeton JWT vaut un accès administrateur complet à l'infrastructure : il n'a
/// rien à faire dans `UserDefaults`. `kSecAttrAccessibleAfterFirstUnlock` laisse
/// les réveils en arrière-plan (rafraîchissement, notifications) lire le jeton
/// alors que l'écran est verrouillé.
///
/// Le trousseau n'est pas toujours disponible : un build de développement sans
/// équipe de signature n'a pas d'entitlement `application-identifier` et se voit
/// refuser tout accès (`errSecMissingEntitlement`). Sans repli, la connexion
/// échouerait sans explication — le jeton serait écrit, jamais relu, et l'appel
/// suivant repartirait sans en-tête d'autorisation. On garde donc une copie en
/// mémoire pour la durée du lancement, et on signale que rien ne survivra à la
/// fermeture de l'app.
enum Keychain {
    private static let service = "com.mybeautifuladmin.app.tokens"

    /// Repli volatile, utilisé uniquement quand le trousseau refuse l'accès.
    private static let volatileStore = Mutex<[String: String]>([:])
    private static let degraded = Mutex<Bool>(false)

    /// Faux dès qu'une écriture a dû basculer en mémoire : la session ne
    /// survivra pas au prochain lancement.
    static var isPersistent: Bool { !degraded.withLock { $0 } }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        guard let value, !value.isEmpty else {
            remove(account)
            return true
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }

        if status == errSecSuccess {
            volatileStore.withLock { $0[account] = value }
            return true
        }

        volatileStore.withLock { $0[account] = value }
        degraded.withLock { $0 = true }
        log(status, action: "écriture", account: account)
        return false
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        if status != errSecItemNotFound {
            degraded.withLock { $0 = true }
            log(status, action: "lecture", account: account)
        }
        return volatileStore.withLock { $0[account] }
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        volatileStore.withLock { $0[account] = nil }
    }

    private static func log(_ status: OSStatus, action: String, account: String) {
        #if DEBUG
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        print("⚠️ Trousseau indisponible (\(action) de « \(account) ») : \(reason). "
              + "Repli en mémoire — la session ne survivra pas à la fermeture de l'app.")
        #endif
    }
}
