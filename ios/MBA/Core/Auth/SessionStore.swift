import Foundation
import Observation

struct CurrentUser: Codable, Hashable, Sendable {
    let id: Int
    let username: String
    let role: String
}

struct ServerHealth: Codable, Sendable {
    let status: String
    let database: Bool
    let workers: Int

    var isHealthy: Bool { status == "ok" }
}

/// Serveurs enregistrés, session en cours, et client d'API associé.
///
/// Toutes les vues passent par là pour obtenir un `APIClient` : il n'y a jamais
/// qu'un seul jeton valide en mémoire, et une expiration se traduit par un
/// retour immédiat à l'écran de connexion plutôt que par une cascade de 401.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case launching
        /// Aucun serveur enregistré : on demande l'URL et le compte.
        case onboarding
        /// Serveur connu, jeton absent ou expiré.
        case locked(ServerProfile)
        case authenticated(ServerProfile, CurrentUser)
    }

    private(set) var phase: Phase = .launching
    private(set) var profiles: [ServerProfile] = []
    private(set) var client: APIClient?
    private(set) var isWorking = false

    private let defaults = UserDefaults.standard
    private let profilesKey = "mba.servers"
    private let activeKey = "mba.servers.active"

    var activeProfile: ServerProfile? {
        switch phase {
        case .locked(let profile): profile
        case .authenticated(let profile, _): profile
        default: profiles.first { $0.id.uuidString == defaults.string(forKey: activeKey) } ?? profiles.first
        }
    }

    var currentUser: CurrentUser? {
        if case .authenticated(_, let user) = phase { return user }
        return nil
    }

    var isAuthenticated: Bool {
        if case .authenticated = phase { return true }
        return false
    }

    // MARK: - Démarrage

    func restore() async {
        profiles = loadProfiles()
        guard let profile = activeProfile else {
            phase = .onboarding
            return
        }
        guard profile.token != nil else {
            await unlockIfPossible(profile)
            return
        }
        let client = APIClient(profile: profile)
        do {
            let user: CurrentUser = try await client.get("/auth/me")
            self.client = client
            phase = .authenticated(profile, user)
        } catch {
            // Jeton périmé : on retente silencieusement avec le mot de passe
            // enregistré, sinon on redemande à l'utilisateur.
            profile.token = nil
            await unlockIfPossible(profile)
        }
    }

    private func unlockIfPossible(_ profile: ServerProfile) async {
        if let password = profile.storedPassword {
            do {
                try await login(profile: profile, password: password, rememberPassword: true)
                return
            } catch {
                profile.storedPassword = nil
            }
        }
        phase = .locked(profile)
    }

    // MARK: - Connexion

    struct ProbeResult: Sendable {
        let health: ServerHealth
        /// Adresse réellement retenue, qui peut différer de la saisie.
        let baseURL: String
        var wasAdjusted: Bool = false
    }

    /// Sonde `/health` avant d'enregistrer quoi que ce soit : mieux vaut dire
    /// « ce n'est pas un serveur MBA » que « identifiants invalides ».
    ///
    /// Trois adresses sont tentées, parce que trois sont légitimes : l'API en
    /// direct (8080), l'API derrière l'interface web (`/api`, que nginx relaie
    /// WebSockets compris), et le port 8080 du même hôte. Taper l'adresse de la
    /// console web est l'erreur la plus naturelle — autant la rattraper.
    func probe(baseURL: String, allowsUntrustedCertificates: Bool) async throws -> ProbeResult {
        guard let normalized = ServerProfile.normalize(baseURL) else {
            throw APIError(kind: .transport, message: "Adresse invalide",
                           hint: "Exemple : mba.local:8080 ou https://mba.mondomaine.fr")
        }

        var firstError: APIError?
        for (index, candidate) in Self.candidates(for: normalized).enumerated() {
            let profile = ServerProfile(name: "", baseURL: candidate, username: "",
                                        allowsUntrustedCertificates: allowsUntrustedCertificates)
            do {
                let health: ServerHealth = try await APIClient(profile: profile).get("/health")
                return ProbeResult(health: health, baseURL: candidate, wasAdjusted: index > 0)
            } catch let error as APIError {
                if firstError == nil { firstError = error }
                // Un refus d'authentification prouve qu'on parle bien à l'API :
                // inutile d'aller chercher ailleurs.
                if error.kind == .unauthorized { throw error }
            }
        }
        throw firstError ?? APIError.decoding
    }

    static func candidates(for normalized: String) -> [String] {
        var results = [normalized]

        if !normalized.hasSuffix("/api") {
            results.append(normalized + "/api")
        }
        if var components = URLComponents(string: normalized), components.port != 8080 {
            components.port = 8080
            components.path = ""
            if let url = components.url?.absoluteString { results.append(url) }
        }
        return results
    }

    @discardableResult
    func login(profile: ServerProfile, password: String, rememberPassword: Bool) async throws -> CurrentUser {
        isWorking = true
        defer { isWorking = false }

        struct Credentials: Encodable, Sendable {
            let username: String
            let password: String
        }
        struct LoginResponse: Decodable, Sendable {
            let token: String
        }

        // Le client de connexion part sans jeton ; celui qui servira ensuite est
        // recréé une fois le jeton rangé dans le trousseau.
        let anonymous = APIClient(profile: profile)
        let response: LoginResponse = try await anonymous.post(
            "/auth/login", body: Credentials(username: profile.username, password: password))

        profile.token = response.token
        profile.storedPassword = rememberPassword ? password : nil

        let client = APIClient(profile: profile)
        let user: CurrentUser = try await client.get("/auth/me")

        upsert(profile)
        defaults.set(profile.id.uuidString, forKey: activeKey)
        self.client = client
        phase = .authenticated(profile, user)
        return user
    }

    func logout(forgetServer: Bool = false) {
        let profile = activeProfile
        profile?.token = nil
        profile?.storedPassword = nil
        client = nil
        if forgetServer, let profile {
            remove(profile)
        } else if let profile {
            phase = .locked(profile)
        } else {
            phase = .onboarding
        }
    }

    func changePassword(current: String, new: String) async throws {
        guard let client else { throw APIError(kind: .unauthorized, message: "Session absente") }
        struct Payload: Encodable, Sendable {
            let current_password: String
            let new_password: String
        }
        let _: JSONValue = try await client.post("/auth/password",
                                                 body: Payload(current_password: current, new_password: new))
        // Le serveur ne révoque pas le jeton en cours ; on met à jour le mot de
        // passe mémorisé pour que les réveils en arrière-plan continuent.
        if activeProfile?.storedPassword != nil { activeProfile?.storedPassword = new }
    }

    /// Un 401 rencontré n'importe où dans l'app ramène ici.
    func handleUnauthorized() {
        guard let profile = activeProfile else { return }
        profile.token = nil
        client = nil
        phase = .locked(profile)
    }

    // MARK: - Serveurs enregistrés

    func select(_ profile: ServerProfile) async {
        defaults.set(profile.id.uuidString, forKey: activeKey)
        client = nil
        phase = .launching
        await restore()
    }

    func upsert(_ profile: ServerProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    func remove(_ profile: ServerProfile) {
        profile.clearSecrets()
        profiles.removeAll { $0.id == profile.id }
        saveProfiles()
        if defaults.string(forKey: activeKey) == profile.id.uuidString {
            defaults.removeObject(forKey: activeKey)
        }
        client = nil
        if let next = profiles.first {
            defaults.set(next.id.uuidString, forKey: activeKey)
            phase = .locked(next)
        } else {
            phase = .onboarding
        }
    }

    func beginAddingServer() {
        phase = .onboarding
    }

    // MARK: - Persistance

    private func loadProfiles() -> [ServerProfile] {
        guard let data = defaults.data(forKey: profilesKey),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
    }
}
