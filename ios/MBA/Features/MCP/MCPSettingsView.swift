import SwiftUI

/// Configuration du serveur MCP et gestion des policies.
///
/// Les policies définissent ce que les assistants IA externes peuvent faire
/// via le protocole MCP. L'écran liste les policies existantes et permet
/// d'en créer, modifier ou supprimer.
struct MCPSettingsView: View {
    @Environment(SessionStore.self) private var session

    @State private var policiesState: Loadable<[MCPPolicy]> = .idle
    @State private var configState: Loadable<MCPServerConfig> = .idle
    @State private var runner = ActionRunner()
    @State private var isCreating = false
    @State private var editingPolicy: MCPPolicy?
    @State private var isEditingConfig = false

    var body: some View {
        List {
            if let error = policiesState.error, policiesState.value != nil {
                InlineErrorBanner(error: error) { Task { await loadPolicies() } }
                    .listRowBackground(Color.clear)
            }

            configSection

            if let policies = policiesState.value {
                if policies.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucune policy",
                            message: "Crée une policy pour définir les capabilities du MCP server.",
                            symbol: "network.badge.shield.half.filled")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Policies · \(policies.count)") {
                        ForEach(policies) { policy in
                            PolicyRow(policy: policy)
                                .contentShape(.rect)
                                .onTapGesture { editingPolicy = policy }
                                .swipeActions(edge: .trailing) {
                                    if policy.name != "default" {
                                        Button("Supprimer", systemImage: "trash", role: .destructive) {
                                            confirmDelete(policy)
                                        }
                                    }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if policiesState.isEmptyLoading, !policiesState.isFailed {
                ProgressView().controlSize(.large)
            } else if let error = policiesState.error, policiesState.value == nil {
                ErrorState(error: error) { Task { await loadPolicies() } }
            }
        }
        .navigationTitle("MCP Server")
        .refreshable {
            await loadPolicies()
            await loadConfig()
        }
        .task {
            await loadPolicies()
            await loadConfig()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Nouvelle policy", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            PolicyEditor(onSave: { payload in
                guard let client = session.client else { return }
                let _: JSONValue = try await client.post("/mcp/policies", body: payload)
                await loadPolicies()
            })
        }
        .sheet(item: $editingPolicy) { policy in
            PolicyEditor(policy: policy, onSave: { payload in
                guard let client = session.client else { return }
                let _: JSONValue = try await client.patch("/mcp/policies/\(policy.id)", body: payload)
                await loadPolicies()
            })
        }
        .actionResult(runner)
    }

    // MARK: - Configuration serveur

    @ViewBuilder
    private var configSection: some View {
        if let config = configState.value {
            Section {
                VStack(alignment: .leading, spacing: Metrics.spacing) {
                    HStack {
                        Text("Configuration du serveur")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !isEditingConfig {
                            Button("Modifier") { isEditingConfig = true }
                                .font(.caption)
                        }
                    }

                    if isEditingConfig {
                        ConfigEditor(config: config, onSave: { payload in
                            guard let client = session.client else { return }
                            let _: JSONValue = try await client.put("/mcp/config", body: payload)
                            isEditingConfig = false
                            await loadConfig()
                        }, onCancel: { isEditingConfig = false })
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            StatTile(value: "\(config.port)", label: "Port",
                                     symbol: "number")
                            StatTile(value: config.displayTransport, label: "Transport",
                                     symbol: "network",
                                     tint: config.isHTTP ? Palette.ok : .secondary)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))

                        Text("Host : \(config.host)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        if config.isHTTP {
                            Text("Le MCP server écoute sur http://\(config.host):\(config.port). Configure ton client MCP avec cette URL.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Le MCP server communique via stdin/stdout. Il est démarré par le client MCP (Claude Desktop, Cursor…).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            }
            .listRowBackground(Color.clear)
        }
    }

    // MARK: - Actions

    private func confirmDelete(_ policy: MCPPolicy) {
        runner.confirm(
            "Supprimer « \(policy.name) » ?",
            message: "La policy sera définitivement supprimée.",
            confirmLabel: "Supprimer"
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.delete("/mcp/policies/\(policy.id)")
            return "Policy supprimée."
        }
    }

    // MARK: - Données

    private func loadPolicies() async {
        guard let client = session.client else { return }
        policiesState.begin()
        do {
            policiesState = .loaded(try await client.get("/mcp/policies"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { policiesState = .failed(error) }
        } catch {
            policiesState = .failed(APIError.transport(error))
        }
    }

    private func loadConfig() async {
        guard let client = session.client else { return }
        configState.begin()
        do {
            configState = .loaded(try await client.get("/mcp/config"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { configState = .failed(error) }
        } catch {
            configState = .failed(APIError.transport(error))
        }
    }

    private func reloadSoon() async {
        try? await Task.sleep(for: .seconds(1))
        await loadPolicies()
    }
}

// MARK: - Ligne de policy

private struct PolicyRow: View {
    let policy: MCPPolicy

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(policy.enabled ? Color.accentColor : .secondary)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(policy.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if policy.enabled {
                        StatusBadge(text: "Active", color: Palette.ok)
                    }
                    if policy.readOnly {
                        StatusBadge(text: "RO", color: Palette.warn)
                    }
                    if policy.name == "default" {
                        TagChip(text: "défaut")
                    }
                }

                if let desc = policy.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    if policy.readOnly {
                        StatusBadge(text: "Read-only", color: Palette.warn, symbol: "lock")
                    } else {
                        let domainCount = restrictionDomains(policy).count
                        if domainCount > 0 {
                            TagChip(text: "\(domainCount) domaines")
                        }
                    }
                }

                if let updated = policy.updatedAt {
                    Text("Modifiée \(Format.ago(updated))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .opacity(policy.enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private func restrictionDomains(_ policy: MCPPolicy) -> [String] {
        policy.restrictions.keys.filter { key in
            guard let items = policy.restrictions[key] else { return false }
            return items.contains(where: { $0.value == false })
        }
    }
}

// MARK: - Éditeur de policy

private struct PolicyEditor: View {
    var policy: MCPPolicy?
    let onSave: (MCPPolicyPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var readOnly = false
    @State private var enabled = true
    @State private var restrictions: [String: [String: Bool]] = [:]
    @State private var busy = false
    @State private var errorMessage: String?

    private var isEditing: Bool { policy != nil }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Palette.danger)
                    }
                    .listRowBackground(Palette.danger.opacity(0.08))
                }

                Section("Général") {
                    TextField("Nom", text: $name)
                    TextField("Description", text: $description)
                }

                Section("Mode") {
                    Toggle("Read-only global", isOn: $readOnly)
                    Toggle("Activée", isOn: $enabled)
                }

                if readOnly {
                    Section {
                        Label("En mode read-only, toutes les mutations sont bloquées. Seules les lectures sont autorisées.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Palette.warn)
                    }
                } else {
                    Section("Restrictions par domaine") {
                        ForEach(MCPRestrictionGroup.allCases) { group in
                            DisclosureGroup(group.label) {
                                ForEach(group.items) { item in
                                    Toggle(item.label, isOn: binding(for: group.key, item: item.key))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Modifier la policy" : "Nouvelle policy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        Task { await save() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
            .task {
                if let policy {
                    name = policy.name
                    description = policy.description ?? ""
                    readOnly = policy.readOnly
                    enabled = policy.enabled
                    restrictions = policy.restrictions
                }
            }
        }
    }

    private func binding(for group: String, item: String) -> Binding<Bool> {
        Binding(
            get: { restrictions[group]?[item] ?? true },
            set: { newValue in
                var groupDict = restrictions[group] ?? [:]
                groupDict[item] = newValue
                restrictions[group] = groupDict
            }
        )
    }

    private func save() async {
        busy = true
        errorMessage = nil
        let payload = MCPPolicyPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            description: description.isEmpty ? nil : description,
            readOnly: readOnly,
            restrictions: restrictions,
            enabled: enabled
        )
        do {
            try await onSave(payload)
            busy = false
            dismiss()
        } catch let error as APIError {
            busy = false
            errorMessage = error.message
        } catch {
            busy = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Groupes de restrictions

private struct MCPRestrictionItem: Identifiable {
    let key: String
    let label: String
    var id: String { key }
}

private enum MCPRestrictionGroup: String, CaseIterable, Identifiable {
    case hosts, proxmox, docker, services, ai, credentials, inventory

    var id: String { rawValue }

    var key: String { rawValue }

    var label: String {
        switch self {
        case .hosts: "Hôtes"
        case .proxmox: "Proxmox"
        case .docker: "Docker"
        case .services: "Services web"
        case .ai: "IA"
        case .credentials: "Identifiants"
        case .inventory: "Inventaire"
        }
    }

    var items: [MCPRestrictionItem] {
        switch self {
        case .hosts:
            [
                .init(key: "allow_create", label: "Créer des hôtes"),
                .init(key: "allow_update", label: "Modifier des hôtes"),
                .init(key: "allow_delete", label: "Supprimer des hôtes"),
                .init(key: "allow_power", label: "Actions power"),
                .init(key: "allow_exec", label: "Exécuter des commandes SSH"),
                .init(key: "allow_upgrade", label: "Mise à jour automatique"),
            ]
        case .proxmox:
            [
                .init(key: "allow_guest_power", label: "Power VM/LXC"),
                .init(key: "allow_config", label: "Modifier config VM/LXC"),
                .init(key: "allow_snapshots", label: "Créer des snapshots"),
                .init(key: "allow_delete_snapshots", label: "Supprimer des snapshots"),
                .init(key: "allow_rollback", label: "Rollback snapshot"),
                .init(key: "allow_clone", label: "Cloner VM/LXC"),
                .init(key: "allow_migrate", label: "Migrer VM/LXC"),
            ]
        case .docker:
            [
                .init(key: "allow_container_action", label: "Start/stop/restart conteneurs"),
                .init(key: "allow_compose_update", label: "Docker compose pull + up -d"),
                .init(key: "allow_prune", label: "Docker system prune"),
            ]
        case .services:
            [
                .init(key: "allow_manage", label: "CRUD services web"),
            ]
        case .ai:
            [
                .init(key: "allow_chat", label: "Chat avec modèles"),
                .init(key: "allow_pull", label: "Télécharger des modèles"),
                .init(key: "allow_delete_model", label: "Supprimer des modèles"),
            ]
        case .credentials:
            [
                .init(key: "allow_manage", label: "Gérer les identifiants"),
            ]
        case .inventory:
            [
                .init(key: "allow_manage", label: "Gérer l'inventaire"),
            ]
        }
    }
}

// MARK: - Éditeur de config

private struct ConfigEditor: View {
    let config: MCPServerConfig
    let onSave: (MCPServerConfigPayload) async throws -> Void
    let onCancel: () -> Void

    @State private var port: String
    @State private var transport: String
    @State private var host: String
    @State private var busy = false
    @State private var errorMessage: String?

    init(config: MCPServerConfig, onSave: @escaping (MCPServerConfigPayload) async throws -> Void, onCancel: @escaping () -> Void) {
        self.config = config
        self.onSave = onSave
        self.onCancel = onCancel
        _port = State(initialValue: String(config.port))
        _transport = State(initialValue: config.transport)
        _host = State(initialValue: config.host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Palette.danger)
                    .padding(8)
                    .background(Palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Port")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("3000", text: $port)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Transport")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $transport) {
                        Text("stdio").tag("stdio")
                        Text("HTTP/SSE").tag("http")
                    }
                    .pickerStyle(.segmented)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0.0.0.0", text: $host)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Le changement de port ou de transport nécessite un redémarrage du conteneur MCP.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("Annuler", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Enregistrer") {
                    Task {
                        busy = true
                        errorMessage = nil
                        let portInt = Int(port) ?? 3000
                        do {
                            try await onSave(MCPServerConfigPayload(port: portInt, transport: transport, host: host))
                            busy = false
                        } catch let error as APIError {
                            busy = false
                            errorMessage = error.message
                        } catch {
                            busy = false
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
    }
}
