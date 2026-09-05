#if DEBUG
import Foundation

/// Connexion automatique pilotée par l'environnement, pour les campagnes de
/// test sur simulateur.
///
/// Jamais compilée en Release. Elle évite d'avoir à ressaisir adresse et mot de
/// passe à chaque réinstallation quand on inspecte les journaux écran par écran :
///
/// Les `SIMCTL_CHILD_*` doivent précéder la commande : placés après le bundle
/// id, `simctl` les passe en arguments et l'application ne les voit jamais.
///
/// ```
/// SIMCTL_CHILD_MBA_SERVER=http://localhost:8888/api \
///   SIMCTL_CHILD_MBA_USER=admin SIMCTL_CHILD_MBA_PASSWORD=… \
///   xcrun simctl launch <device> com.mybeautifuladmin.app
/// ```
enum DebugLaunch {
    /// Écran ouvert au démarrage, pour inspecter les journaux vue par vue
    /// sans avoir à naviguer à la main : `SIMCTL_CHILD_MBA_SCREEN=monitoring`.
    static var startScreen: Destination? {
        ProcessInfo.processInfo.environment["MBA_SCREEN"].flatMap(Destination.init(rawValue:))
    }

    /// Ouvre directement un shell sur cette machine : `MBA_TERMINAL_HOST=3`.
    /// C'est la seule façon d'atteindre l'émulateur sans piloter les taps.
    static var terminalHostID: Int? {
        ProcessInfo.processInfo.environment["MBA_TERMINAL_HOST"].flatMap(Int.init)
    }
}

extension SessionStore {
    func autoLoginIfRequested() async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["MBA_SERVER"],
              let user = environment["MBA_USER"],
              let password = environment["MBA_PASSWORD"],
              let normalized = ServerProfile.normalize(server)
        else { return false }

        // Un profil éphémère, recréé à chaque lancement : le test part toujours
        // du même état, sans traîner le trousseau d'une exécution précédente.
        let profile = ServerProfile(name: "Test", baseURL: normalized, username: user,
                                    allowsUntrustedCertificates: true)
        do {
            try await login(profile: profile, password: password, rememberPassword: false)
            return true
        } catch {
            print("⚠️ Connexion automatique impossible : \(error)")
            return false
        }
    }
}
#endif
