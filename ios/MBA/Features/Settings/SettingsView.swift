import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var isAddingServer = false
    @State private var isChangingPassword = false
    @State private var confirmsLogout = false

    var body: some View {
        List {
            if let profile = session.activeProfile {
                Section("Serveur") {
                    LabeledContent("Nom", value: profile.name)
                    LabeledContent("Adresse", value: profile.displayHost)
                    LabeledContent("Compte", value: session.currentUser?.username ?? profile.username)
                    if let role = session.currentUser?.role {
                        LabeledContent("Rôle", value: role)
                    }
                    LabeledContent("Flux temps réel") {
                        StatusBadge(text: live.isConnected ? "Connecté" : "Interrompu",
                                    color: live.isConnected ? Palette.ok : Palette.warn)
                    }
                    if let error = live.lastConnectionError, !live.isConnected {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if session.profiles.count > 1 {
                Section("Autres serveurs") {
                    ForEach(session.profiles.filter { $0.id != session.activeProfile?.id }) { profile in
                        Button {
                            Task { await session.select(profile) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text("\(profile.username) · \(profile.displayHost)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Ajouter un serveur", systemImage: "plus.circle") {
                    isAddingServer = true
                }
                Button("Changer le mot de passe", systemImage: "key") {
                    isChangingPassword = true
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("À propos", systemImage: "info.circle")
                }
            }

            Section {
                Button("Se déconnecter", systemImage: "rectangle.portrait.and.arrow.right",
                       role: .destructive) {
                    confirmsLogout = true
                }
            } footer: {
                Text("La déconnexion efface le jeton et le mot de passe enregistrés sur cet appareil. Le serveur n'est pas modifié.")
            }
        }
        .navigationTitle("Réglages")
        .sheet(isPresented: $isAddingServer) {
            OnboardingView(isAdditional: true)
        }
        .sheet(isPresented: $isChangingPassword) {
            ChangePasswordView()
        }
        .confirmationDialog("Se déconnecter ?", isPresented: $confirmsLogout, titleVisibility: .visible) {
            Button("Se déconnecter", role: .destructive) {
                live.reset()
                session.logout()
            }
            Button("Annuler", role: .cancel) {}
        }
    }
}

private struct ChangePasswordView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var current = ""
    @State private var updated = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var error: String?

    private var isValid: Bool {
        !current.isEmpty && updated.count >= 8 && updated == confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Mot de passe actuel", text: $current)
                        .textContentType(.password)
                }
                Section {
                    SecureField("Nouveau mot de passe", text: $updated)
                        .textContentType(.newPassword)
                    SecureField("Confirmation", text: $confirmation)
                        .textContentType(.newPassword)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(Palette.danger)
                    } else if !updated.isEmpty && updated.count < 8 {
                        Text("Le serveur exige au moins 8 caractères.")
                    } else if !confirmation.isEmpty && updated != confirmation {
                        Text("Les deux saisies diffèrent.")
                    }
                }
            }
            .navigationTitle("Mot de passe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { Task { await save() } }
                        .disabled(!isValid || isWorking)
                }
            }
        }
    }

    private func save() async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            try await session.changePassword(current: current, new: updated)
            dismiss()
        } catch let apiError as APIError {
            error = apiError.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AboutView: View {
    private var version: String {
        let bundle = Bundle.main
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(.tint)
                    Text("MyBeautifulAdmin")
                        .font(.title3.weight(.semibold))
                    Text("Version \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }
            Section {
                Text("Console de supervision et d'administration pour infrastructure domestique : serveurs Linux, hyperviseurs Proxmox, NAS Synology, conteneurs Docker, contrôleurs IPMI et endpoints Ollama.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("À propos")
        .navigationBarTitleDisplayMode(.inline)
    }
}
