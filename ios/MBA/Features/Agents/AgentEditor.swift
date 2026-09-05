import SwiftUI

/// Création d'un agent.
///
/// Le formulaire suit l'ordre des décisions : qui pense (serveur et modèle), au
/// nom de quoi (rôle), sur quoi (périmètre), et jusqu'où il a le droit d'aller.
/// L'aperçu, en bas, montre ce que l'agent verrait — c'est la seule façon de
/// vérifier qu'un périmètre désigne bien ce qu'on croit avant de le lancer.
struct AgentEditor: View {
    let catalog: AgentCatalog
    let onSave: (AgentPayload) async throws -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var endpointID: Int?
    @State private var model = ""
    @State private var role = ""
    @State private var mode: AgentMode = .observe
    @State private var scopeKind: TargetKind = .all
    @State private var scopeValue = ""
    @State private var allowedActions: Set<String> = []
    @State private var maxActions = 3
    @State private var cron = ""

    @State private var preview: AgentPreview?
    @State private var previewError: APIError?
    @State private var isSaving = false
    @State private var saveError: APIError?

    private var endpoint: AgentEndpoint? {
        catalog.endpoints.first { $0.id == endpointID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom", text: $name)

                    Picker("Serveur", selection: $endpointID) {
                        Text("Choisir…").tag(Int?.none)
                        ForEach(catalog.endpoints) { endpoint in
                            Text(endpoint.isOnline ? endpoint.name : "\(endpoint.name) (muet)")
                                .tag(Int?.some(endpoint.id))
                        }
                    }

                    if let endpoint {
                        if endpoint.models.isEmpty {
                            // Le catalogue lit les modèles sur le flux temps
                            // réel : tant qu'il n'a rien relevé, la liste est
                            // vide alors que le serveur en héberge. On laisse
                            // donc saisir le nom à la main plutôt que de
                            // bloquer le formulaire.
                            TextField("Modèle (ex. llama3.1:8b)", text: $model)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.callout.monospaced())
                        } else {
                            Picker("Modèle", selection: $model) {
                                ForEach(endpoint.models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    if endpoint?.models.isEmpty == true {
                        Text("Ce serveur n'a pas encore annoncé ses modèles. Saisis le nom exact tel qu'il apparaît dans la section « IA & accélérateurs ».")
                    }
                }

                Section {
                    Picker("Rôle", selection: $role) {
                        ForEach(catalog.sortedRoles, id: \.key) { entry in
                            Text(entry.role.label).tag(entry.key)
                        }
                    }
                } header: {
                    Text("Mission")
                } footer: {
                    if let description = catalog.roles[role]?.description {
                        Text(description)
                    }
                }

                modeSection
                scopeSection
                actionsSection

                Section {
                    Stepper("Au plus \(maxActions) actions par exécution",
                            value: $maxActions, in: 1...10)
                    TextField("Cron (vide = sur commande)", text: $cron)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                } header: {
                    Text("Garde-fous")
                } footer: {
                    Text("Le plafond borne ce qu'une seule analyse peut déclencher, même si le modèle voit plus de problèmes. Sans cron, l'agent ne part que lorsqu'on le lui demande.")
                }

                previewSection

                if let saveError {
                    Section {
                        Text(saveError.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { Task { await save() } }
                        .disabled(!isValid || isSaving)
                }
            }
            .onAppear(perform: prefill)
            .onChange(of: role) { _, newRole in
                // Changer de rôle réaligne les actions sur celles que ce rôle
                // prévoit : c'est tout l'intérêt d'un préréglage.
                if let actions = catalog.roles[newRole]?.actions {
                    allowedActions = Set(actions)
                }
            }
            .onChange(of: endpointID) { _, _ in
                if let first = endpoint?.models.first, !(endpoint?.models.contains(model) ?? false) {
                    model = first
                }
            }
            .task(id: previewKey) { await loadPreview() }
        }
    }

    // MARK: - Sections

    private var modeSection: some View {
        Section {
            Picker("Régime", selection: $mode) {
                ForEach(AgentMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode.actsAlone {
                Label("L'agent exécutera seul les actions réversibles autorisées. Les autres attendront quand même ta validation.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
        } header: {
            Text("Liberté d'action")
        } footer: {
            if let help = catalog.modes[mode.rawValue] {
                Text(help)
            }
        }
    }

    private var scopeSection: some View {
        Section {
            Picker("Portée", selection: $scopeKind) {
                ForEach(TargetKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if scopeKind != .all {
                TextField(scopeKind == .tag ? "prod, edge" : "linux, docker", text: $scopeValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Périmètre")
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(catalog.sortedActions, id: \.key) { entry in
                Toggle(isOn: Binding(
                    get: { allowedActions.contains(entry.key) },
                    set: { isOn in
                        if isOn { allowedActions.insert(entry.key) }
                        else { allowedActions.remove(entry.key) }
                    })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.action.label)
                            if !entry.action.auto {
                                // Une action non réversible ne sera jamais
                                // exécutée sans validation, même en automatique.
                                Image(systemName: "hand.raised.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Palette.warn)
                            }
                        }
                        if let help = entry.action.help {
                            Text(help)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Actions autorisées")
        } footer: {
            Text("L'agent ne peut proposer que ces actions. Celles marquées d'une main levée exigent toujours ta validation, quel que soit le régime.")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if let previewError {
                Label(previewError.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.warn)
            } else if let preview {
                LabeledValue(label: "Machines visées", value: "\(preview.hosts.count)")
                if !preview.hosts.isEmpty {
                    Text(preview.hosts.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledValue(label: "Taille de l'invite",
                             value: "\(Format.integer(preview.estimatedChars)) caractères")
            } else if isValid {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Calcul de l'aperçu…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Complète le nom, le modèle et le périmètre pour voir l'aperçu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Aperçu")
        } footer: {
            Text("Le contexte réellement envoyé au modèle. Une invite trop longue est la première cause d'échec sur un petit modèle.")
        }
    }

    // MARK: - État

    private func prefill() {
        if endpointID == nil {
            // On s'ouvre sur un serveur qui répond : sinon le formulaire naît
            // condamné à échouer.
            endpointID = catalog.endpoints.first(where: \.isOnline)?.id
                ?? catalog.endpoints.first?.id
        }
        if model.isEmpty { model = endpoint?.models.first ?? "" }
        if role.isEmpty {
            role = catalog.sortedRoles.first?.key ?? "custom"
            allowedActions = Set(catalog.roles[role]?.actions ?? [])
        }
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard endpointID != nil, !model.isEmpty, !role.isEmpty else { return false }
        if scopeKind != .all && scopeValue.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    private var payload: AgentPayload {
        let trimmedCron = cron.trimmingCharacters(in: .whitespaces)
        return AgentPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            description: catalog.roles[role]?.description,
            role: role,
            endpointID: endpointID ?? 0,
            model: model,
            systemPrompt: nil,
            mode: mode.rawValue,
            scopeKind: scopeKind.rawValue,
            scopeValue: scopeKind == .all ? nil : scopeValue.trimmingCharacters(in: .whitespaces),
            allowedActions: allowedActions.sorted(),
            maxActions: maxActions,
            cron: trimmedCron.isEmpty ? nil : trimmedCron,
            enabled: true)
    }

    private var previewKey: String {
        "\(role)|\(scopeKind.rawValue)|\(scopeValue)|\(model)|\(endpointID ?? 0)|\(isValid)"
    }

    private func loadPreview() async {
        guard isValid, let client = session.client else {
            preview = nil
            previewError = nil
            return
        }
        do {
            preview = try await client.post("/agents/preview", body: payload)
            previewError = nil
        } catch let error as APIError {
            guard !error.isCancellation else { return }
            preview = nil
            previewError = error
        } catch {
            preview = nil
            previewError = APIError.transport(error)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(payload)
            dismiss()
        } catch let error as APIError {
            saveError = error
        } catch {
            saveError = APIError.transport(error)
        }
    }
}
