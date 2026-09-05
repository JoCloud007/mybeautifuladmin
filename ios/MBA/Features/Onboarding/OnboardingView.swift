import SwiftUI

/// Ajout d'un serveur : adresse, puis compte.
///
/// L'adresse est vérifiée avant toute chose (`GET /health`). Distinguer « ce
/// n'est pas un serveur MBA » de « mot de passe refusé » évite le grand
/// classique du dépannage à l'aveugle.
struct OnboardingView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Présenté en modale quand un serveur existe déjà.
    var isAdditional: Bool = false

    @State private var address = ""
    @State private var name = ""
    @State private var username = "admin"
    @State private var password = ""
    @State private var allowsUntrusted = false
    @State private var rememberPassword = true

    @State private var probed: SessionStore.ProbeResult?
    @State private var isProbing = false
    @State private var isConnecting = false
    @State private var error: APIError?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case address, username, password }

    private var canProbe: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty && !isProbing
    }

    private var canConnect: Bool {
        probed != nil && !username.isEmpty && !password.isEmpty && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isAdditional {
                    Section {
                        header
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 16, trailing: 0))
                    }
                }

                serverSection
                if probed != nil { accountSection }
                if let error { errorSection(error) }
            }
            .navigationTitle(isAdditional ? "Ajouter un serveur" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isAdditional {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Annuler") { dismiss() }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            BrandMark(size: 76)
            Text("MyBeautifulAdmin")
                .font(.title2.weight(.semibold))
            Text("Connecte-toi à ton serveur central pour superviser et administrer ton infrastructure.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
    }

    private var serverSection: some View {
        Section {
            TextField("mba.local:8080", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .address)
                .submitLabel(.go)
                .onSubmit { Task { await probe() } }
                .onChange(of: address) { _, _ in probed = nil }

            Toggle("Accepter le certificat auto-signé", isOn: $allowsUntrusted)
                .onChange(of: allowsUntrusted) { _, _ in probed = nil }

            if let probed {
                LabeledContent("Serveur") {
                    StatusBadge(
                        text: probed.health.isHealthy ? "Prêt" : "Dégradé",
                        color: probed.health.isHealthy ? Palette.ok : Palette.warn,
                        symbol: probed.health.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                LabeledContent("Collecteurs actifs", value: Format.integer(probed.health.workers))
                if probed.wasAdjusted {
                    Label {
                        Text("L'API a été trouvée sur **\(probed.baseURL)**.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "wand.and.sparkles")
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task { await probe() }
                } label: {
                    HStack {
                        Text("Vérifier l'adresse")
                        Spacer()
                        if isProbing { ProgressView() }
                    }
                }
                .disabled(!canProbe)
            }
        } header: {
            Text("Adresse du serveur")
        } footer: {
            Text("L'adresse de l'API, pas celle de l'interface web — par défaut le port 8080. Si le serveur n'est joignable qu'en VPN, active-le avant de continuer.")
        }
    }

    private var accountSection: some View {
        Group {
            Section("Compte") {
                TextField("Identifiant", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }

                SecureField("Mot de passe", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await connect() } }
            }

            Section {
                TextField("Nom du serveur", text: $name, prompt: Text(defaultName))
                Toggle("Rester connecté", isOn: $rememberPassword)
            } footer: {
                Text("« Rester connecté » conserve le mot de passe dans le trousseau chiffré de l'appareil. Sans lui, la session expire au bout de 7 jours et les réveils en arrière-plan cessent de rapporter les alertes.")
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Spacer()
                        if isConnecting {
                            ProgressView().tint(.white)
                        } else {
                            Text("Se connecter").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canConnect)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
    }

    private func errorSection(_ error: APIError) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.danger)
                if let hint = error.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var defaultName: String {
        let source = probed?.baseURL ?? ServerProfile.normalize(address)
        return source.flatMap { URL(string: $0)?.host() } ?? "Mon infra"
    }

    // MARK: - Actions

    private func probe() async {
        focus = nil
        isProbing = true
        error = nil
        defer { isProbing = false }
        do {
            probed = try await session.probe(baseURL: address,
                                             allowsUntrustedCertificates: allowsUntrusted)
            focus = .username
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }

    private func connect() async {
        // L'adresse retenue est celle que la sonde a validée, pas la saisie
        // brute : c'est elle qui porte l'éventuel /api ou le port corrigé.
        guard let normalized = probed?.baseURL else { return }
        focus = nil
        isConnecting = true
        error = nil
        defer { isConnecting = false }

        let profile = ServerProfile(
            name: name.isEmpty ? defaultName : name,
            baseURL: normalized,
            username: username,
            allowsUntrustedCertificates: allowsUntrusted)
        do {
            try await session.login(profile: profile, password: password,
                                    rememberPassword: rememberPassword)
            if isAdditional { dismiss() }
        } catch let apiError as APIError {
            // Un 401 ici ne peut venir que des identifiants : l'adresse vient
            // d'être validée par /health.
            error = apiError.kind == .unauthorized
                ? APIError(kind: .unauthorized, message: "Identifiants refusés",
                           hint: "Vérifie l'identifiant et le mot de passe du compte MBA.")
                : apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}

/// Réouverture d'une session sur un serveur déjà enregistré.
struct LoginView: View {
    @Environment(SessionStore.self) private var session
    let profile: ServerProfile

    @State private var password = ""
    @State private var rememberPassword = true
    @State private var isConnecting = false
    @State private var error: APIError?
    @State private var isAddingServer = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        BrandMark(size: 64)
                        Text(profile.name)
                            .font(.title3.weight(.semibold))
                        Text("\(profile.username) · \(profile.displayHost)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    SecureField("Mot de passe", text: $password)
                        .textContentType(.password)
                        .focused($isFocused)
                        .submitLabel(.go)
                        .onSubmit { Task { await connect() } }
                    Toggle("Rester connecté", isOn: $rememberPassword)
                } footer: {
                    if let error {
                        Text(error.message)
                            .foregroundStyle(Palette.danger)
                    } else {
                        Text("La session précédente a expiré.")
                    }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Déverrouiller").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(password.isEmpty || isConnecting)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    Button("Changer de serveur", systemImage: "arrow.left.arrow.right") {
                        isAddingServer = true
                    }
                    Button("Oublier ce serveur", systemImage: "trash", role: .destructive) {
                        session.remove(profile)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $isAddingServer) {
            OnboardingView(isAdditional: true)
        }
        .task { isFocused = true }
    }

    private func connect() async {
        isFocused = false
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            try await session.login(profile: profile, password: password,
                                    rememberPassword: rememberPassword)
        } catch let apiError as APIError {
            error = apiError.kind == .unauthorized
                ? APIError(kind: .unauthorized, message: "Mot de passe refusé")
                : apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}
