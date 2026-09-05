import SwiftUI

/// Découverte réseau : lancer un balayage, et adopter ce qu'on y trouve.
struct DiscoveryView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<[DiscoveryResult]> = .idle
    @State private var suggestions: DiscoverySuggestions?
    @State private var search = ""
    @State private var runner = ActionRunner()
    @State private var isScanning = false
    @State private var adopting: DiscoveryResult?

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let results = state.value {
                summarySection(results)

                let visible = results.filter { $0.matches(normalizedSearch) }
                if visible.isEmpty {
                    Section {
                        EmptyState(
                            title: results.isEmpty ? "Rien de découvert" : "Aucun résultat",
                            message: results.isEmpty
                                ? "Lance un balayage pour repérer ce qui répond sur ton réseau. Les adresses trouvées peuvent ensuite être adoptées dans le parc."
                                : "Rien ne correspond à « \(search) ».",
                            symbol: "dot.radiowaves.left.and.right",
                            actionTitle: results.isEmpty ? "Lancer un balayage" : nil,
                            action: results.isEmpty ? { isScanning = true } : nil)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    let newcomers = visible.filter { !$0.isKnown }
                    let known = visible.filter(\.isKnown)

                    if !newcomers.isEmpty {
                        Section {
                            ForEach(newcomers) { result in
                                ResultRow(result: result)
                                    .swipeActions(edge: .trailing) {
                                        Button("Ignorer", systemImage: "eye.slash") {
                                            confirmIgnore(result)
                                        }
                                        .tint(Palette.idle)
                                        Button("Adopter", systemImage: "plus.circle") {
                                            adopting = result
                                        }
                                        .tint(.accentColor)
                                    }
                            }
                        } header: {
                            Text("Hors parc · \(newcomers.count)")
                        } footer: {
                            Text("Balaie vers la gauche pour adopter une adresse dans le parc, ou l'écarter des prochains résultats.")
                        }
                    }

                    if !known.isEmpty {
                        Section("Déjà supervisés · \(known.count)") {
                            ForEach(known) { result in
                                ResultRow(result: result)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if state.isEmptyLoading, !state.isFailed {
                ProgressView().controlSize(.large)
            } else if let error = state.error, state.value == nil {
                ErrorState(error: error) { Task { await load() } }
            }
        }
        .navigationTitle("Découverte")
        .searchable(text: $search, prompt: "Adresse, nom, port")
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Balayer", systemImage: "dot.radiowaves.left.and.right") {
                    isScanning = true
                }
                .disabled(suggestions == nil)
            }
        }
        .sheet(isPresented: $isScanning) {
            if let suggestions {
                ScanSheet(suggestions: suggestions) { payload in
                    try await scan(payload)
                }
            }
        }
        .sheet(item: $adopting) { result in
            AdoptSheet(result: result) { payload in
                try await adopt(payload)
            }
        }
        .actionResult(runner)
    }

    private func summarySection(_ results: [DiscoveryResult]) -> some View {
        let newcomers = results.filter { !$0.isKnown }
        return Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(value: "\(results.count)", label: "Adresses vues",
                         symbol: "dot.radiowaves.left.and.right")
                StatTile(value: "\(newcomers.count)", label: "À adopter",
                         symbol: "plus.circle",
                         tint: newcomers.isEmpty ? Palette.ok : Palette.warn)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } footer: {
            if let subnets = suggestions?.subnets, !subnets.isEmpty {
                Text("Sous-réseaux proposés : \(subnets.joined(separator: ", ")).")
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func scan(_ payload: DiscoveryScanPayload) async throws {
        guard let client = session.client else { return }
        // Le balayage est synchrone côté API : sur un /24 complet il peut durer
        // une dizaine de secondes, d'où le voile d'attente de l'ActionRunner.
        await runner.run("Balayage de \(payload.targets)") {
            let result: DiscoveryScanResult = try await client.post("/discovery/scan",
                                                                    body: payload)
            return result.count == 0
                ? "Aucune adresse n'a répondu."
                : "\(Format.plural(result.count, "adresse")) trouvée\(result.count > 1 ? "s" : "")."
        }
        await load()
    }

    private func adopt(_ payload: DiscoveryAdoptPayload) async throws {
        guard let client = session.client else { return }
        let _: JSONValue = try await client.post("/discovery/adopt", body: payload)
        await load()
    }

    private func confirmIgnore(_ result: DiscoveryResult) {
        runner.confirm(
            "Ignorer \(result.address) ?",
            message: "Cette adresse n'apparaîtra plus dans les résultats de découverte, ici comme dans la carte du réseau.",
            confirmLabel: "Ignorer",
            isDestructive: false
        ) { [client = session.client] in
            guard let client else { return nil }
            let encoded = result.address.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? result.address
            try await client.perform("/discovery/ignore/\(encoded)")
            return "\(result.address) sera passée sous silence."
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            await load()
        }
    }

    // MARK: - Réseau

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/discovery/results"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
        if suggestions == nil {
            suggestions = try? await client.get("/discovery/suggestions")
        }
    }
}

// MARK: - Ligne

private struct ResultRow: View {
    let result: DiscoveryResult

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.isKnown ? "checkmark.circle.fill" : result.kind.symbol)
                .foregroundStyle(result.isKnown ? Palette.ok : Palette.warn)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text([result.address == result.displayName ? nil : result.address,
                      "vue \(Format.ago(result.seenAt))"]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                let roles = WellKnownPort.labels(for: result.openPorts)
                if !roles.isEmpty {
                    HStack(spacing: 4) {
                        // « Générique » n'apprend rien et pousse les rôles hors
                        // champ : ce sont eux qui disent ce qu'est la machine.
                        if result.kind != .generic {
                            TagChip(text: result.kind.label, symbol: result.kind.symbol)
                        }
                        ForEach(roles.prefix(3), id: \.self) { TagChip(text: $0) }
                    }
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if !result.openPorts.isEmpty {
                Text(Format.plural(result.openPorts.count, "port"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Balayage

private struct ScanSheet: View {
    let suggestions: DiscoverySuggestions
    let onScan: (DiscoveryScanPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var targets = ""
    @State private var usesAllPorts = false
    @State private var isRunning = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.0/24", text: $targets)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                } header: {
                    Text("Cibles")
                } footer: {
                    Text("Un CIDR, une adresse ou une plage — plusieurs valeurs séparées par des virgules.")
                }

                if !suggestions.subnets.isEmpty {
                    Section("Proposés") {
                        ForEach(suggestions.subnets, id: \.self) { subnet in
                            Button {
                                targets = subnet
                            } label: {
                                HStack {
                                    Label(subnet, systemImage: "network")
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if targets == subnet {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Toggle("Tous les ports connus", isOn: $usesAllPorts)
                } footer: {
                    Text(usesAllPorts
                         ? "\(suggestions.ports.count) ports testés par adresse : plus complet, plus lent."
                         : "Le serveur choisit sa liste de ports par défaut.")
                }

                if let error {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Balayage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lancer") { Task { await run() } }
                        .disabled(cleanTargets.isEmpty || isRunning)
                }
            }
            .onAppear {
                if targets.isEmpty { targets = suggestions.subnets.first ?? "" }
            }
        }
    }

    private var cleanTargets: String {
        targets.trimmingCharacters(in: .whitespaces)
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            try await onScan(DiscoveryScanPayload(
                targets: cleanTargets,
                ports: usesAllPorts ? suggestions.ports : nil))
            dismiss()
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}

// MARK: - Adoption

private struct AdoptSheet: View {
    let result: DiscoveryResult
    let onAdopt: (DiscoveryAdoptPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: HostKind = .linux
    @State private var port = ""
    @State private var category = ""
    @State private var isSaving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledValue(label: "Adresse", value: result.address, monospaced: true)
                    if !result.openPorts.isEmpty {
                        LabeledValue(label: "Ports ouverts",
                                     value: result.openPorts.map(String.init)
                                        .joined(separator: ", "),
                                     monospaced: true)
                    }
                    let roles = WellKnownPort.labels(for: result.openPorts)
                    if !roles.isEmpty {
                        LabeledValue(label: "Semble être", value: roles.joined(separator: ", "))
                    }
                } header: {
                    Text("Ce qui a été trouvé")
                }

                Section("Déclaration") {
                    TextField("Nom", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Type", selection: $kind) {
                        ForEach(HostKind.allCases, id: \.self) { kind in
                            Label(kind.label, systemImage: kind.symbol).tag(kind)
                        }
                    }
                    TextField("Port (\(kind.defaultPort) par défaut)", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Catégorie (facultative)", text: $category)
                }

                Section {
                    Text("Les identifiants se règlent ensuite depuis la fiche de la machine, ou dans la console web : l'adoption ne fait que déclarer l'hôte.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Adopter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Adopter") { Task { await save() } }
                        .disabled(cleanName.isEmpty || isSaving)
                }
            }
            .onAppear {
                if name.isEmpty { name = result.hostname ?? result.address }
                kind = result.kind == .generic ? .linux : result.kind
            }
        }
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onAdopt(DiscoveryAdoptPayload(
                address: result.address,
                name: cleanName,
                kind: kind.rawValue,
                port: Int(port.trimmingCharacters(in: .whitespaces)),
                category: category.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : category.trimmingCharacters(in: .whitespaces)))
            dismiss()
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}
