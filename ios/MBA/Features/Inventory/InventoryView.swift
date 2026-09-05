import SwiftUI

/// Inventaire du parc : la fiche matérielle de chaque machine, et le classement
/// qu'on lui donne (catégorie, lieu, étiquettes).
struct InventoryView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<InventoryList> = .idle
    @State private var search = ""
    @State private var grouping: InventoryGrouping = .category
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let list = state.value {
                summarySection(list)

                let groups = grouped(list.hosts)
                if groups.isEmpty {
                    Section {
                        EmptyState(title: list.hosts.isEmpty ? "Parc vide" : "Aucun résultat",
                                   message: list.hosts.isEmpty
                                       ? "Aucune machine déclarée dans MBA."
                                       : "Aucune machine ne correspond à « \(search) ».",
                                   symbol: "list.clipboard")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(groups, id: \.key) { group in
                        Section("\(group.key) · \(group.items.count)") {
                            ForEach(group.items) { item in
                                NavigationLink(value: item) {
                                    InventoryRow(item: item)
                                }
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
        .navigationTitle("Inventaire")
        .searchable(text: $search, prompt: "Nom, modèle, série, lieu")
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Sous forme de `Picker` nu, la barre lui réserve toute la
                // largeur de son libellé et mord sur le titre.
                Menu {
                    Picker("Regrouper par", selection: $grouping) {
                        ForEach(InventoryGrouping.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Regrouper", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .navigationDestination(for: InventoryItem.self) { item in
            InventoryDetailView(item: item) { patch in
                try await update(item, patch)
            } onRefresh: {
                await refreshHardware(item)
            }
        }
        .actionResult(runner)
    }

    private func summarySection(_ list: InventoryList) -> some View {
        Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(list.summary.total)", label: "Machines",
                             symbol: "server.rack")
                    StatTile(value: "\(list.summary.untagged)", label: "Sans étiquette",
                             symbol: "tag.slash",
                             tint: list.summary.untagged > 0 ? Palette.warn : Palette.ok)
                }

                if !list.summary.byKind.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(list.summary.byKind.sorted(by: { $0.value > $1.value }),
                                    id: \.key) { kind, count in
                                TagChip(text: "\(HostKind(rawValue: kind)?.label ?? kind) \(count)",
                                        symbol: HostKind(rawValue: kind)?.symbol)
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    private func grouped(_ items: [InventoryItem]) -> [(key: String, items: [InventoryItem])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = items.filter { $0.matches(query) }
        return Dictionary(grouping: visible) { item in
            switch grouping {
            case .category: item.category ?? "Sans catégorie"
            case .kind: item.hostKind.label
            case .location: item.location ?? "Sans lieu"
            }
        }
        .map { (key: $0.key, items: $0.value.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
        // Les « sans … » ferment la marche : ce sont des restes, pas une catégorie.
        .sorted { first, second in
            let firstIsNone = first.key.hasPrefix("Sans ")
            let secondIsNone = second.key.hasPrefix("Sans ")
            if firstIsNone != secondIsNone { return secondIsNone }
            return first.key.localizedStandardCompare(second.key) == .orderedAscending
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/inventory"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    private func update(_ item: InventoryItem, _ patch: InventoryPatch) async throws {
        guard let client = session.client else { return }
        let _: JSONValue = try await client.patch("/inventory/\(item.id)", body: patch)
        await load()
    }

    private func refreshHardware(_ item: InventoryItem) async {
        guard let client = session.client else { return }
        await runner.run("Relevé matériel de \(item.name)") {
            try await client.perform("/inventory/\(item.id)/refresh")
            return "Relevé relancé. La fiche se met à jour au prochain cycle lent."
        }
        await load()
    }
}

enum InventoryGrouping: String, CaseIterable, Identifiable {
    case category, kind, location

    var id: String { rawValue }

    var label: String {
        switch self {
        case .category: "Catégorie"
        case .kind: "Type"
        case .location: "Lieu"
        }
    }
}

// MARK: - Ligne

private struct InventoryRow: View {
    let item: InventoryItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.hostKind.symbol)
                .foregroundStyle(item.hostStatus.color)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if !item.enabled {
                        TagChip(text: "désactivée", symbol: "pause.circle")
                    }
                }
                Text([item.identity.model, item.identity.cpuModel, item.address]
                    .compactMap { $0 }.first ?? item.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.tags.isEmpty || item.location != nil {
                    HStack(spacing: 4) {
                        if let location = item.location {
                            TagChip(text: location, symbol: "mappin")
                        }
                        ForEach(item.tags.prefix(3), id: \.self) { TagChip(text: $0) }
                    }
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if let memory = item.identity.memTotal {
                    Text(Format.bytes(memory))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let cores = item.identity.cpuCount, cores > 0 {
                    Text(Format.plural(cores, "cœur"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fiche

private struct InventoryDetailView: View {
    let item: InventoryItem
    let onSave: (InventoryPatch) async throws -> Void
    let onRefresh: () async -> Void

    @State private var isEditing = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                SectionBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(item.hostKind.label, systemImage: item.hostKind.symbol)
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 6)
                            StatusBadge(text: item.hostStatus.rawValue,
                                        color: item.hostStatus.color)
                        }
                        LabeledValue(label: "Adresse", value: item.address, monospaced: true)
                        LabeledValue(label: "Vue", value: Format.ago(item.lastSeen))
                        if item.containers > 0 {
                            LabeledValue(label: "Conteneurs", value: "\(item.containers)")
                        }
                    }
                }

                classification

                if item.identity.isEmpty {
                    SectionBox("Matériel", symbol: "cpu") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Aucun relevé matériel pour cette machine. Le cycle lent le remplit dès qu'un accès SSH ou une API le permet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Relancer le relevé", systemImage: "arrow.clockwise") {
                                Task { await onRefresh() }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    hardware
                }

                if !item.identity.macs.isEmpty { interfaces }

                if let notes = item.notes, !notes.isEmpty {
                    SectionBox("Notes", symbol: "note.text") {
                        Text(notes)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Classer", systemImage: "square.and.pencil") { isEditing = true }
                    Button("Relancer le relevé", systemImage: "arrow.clockwise") {
                        Task { await onRefresh() }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            ClassificationEditor(item: item, onSave: onSave)
        }
    }

    private var classification: some View {
        SectionBox("Classement", symbol: "tag",
                   accessory: AnyView(
                    Button("Modifier") { isEditing = true }
                        .font(.caption.weight(.semibold)))) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledValue(label: "Catégorie", value: item.category)
                LabeledValue(label: "Lieu", value: item.location)
                if item.tags.isEmpty {
                    LabeledValue(label: "Étiquettes", value: nil)
                } else {
                    HStack(spacing: 4) {
                        Text("Étiquettes")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Spacer(minLength: 12)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(item.tags, id: \.self) { TagChip(text: $0) }
                            }
                        }
                        .scrollClipDisabled()
                    }
                }
            }
        }
    }

    private var hardware: some View {
        SectionBox("Matériel", symbol: "cpu") {
            VStack(spacing: 10) {
                identityRow("Constructeur", item.identity.vendor, field: "vendor")
                identityRow("Modèle", item.identity.model, field: "model")
                identityRow("Numéro de série", item.identity.serial, field: "serial")
                identityRow("Processeur", item.identity.cpuModel, field: "cpu_model")
                if let cores = item.identity.cpuCount, cores > 0 {
                    LabeledValue(label: "Cœurs", value: "\(cores)")
                }
                if let memory = item.identity.memTotal {
                    LabeledValue(label: "Mémoire", value: Format.bytes(memory))
                }
                if let disk = item.identity.diskTotal {
                    LabeledValue(label: "Stockage", value: Format.bytes(disk))
                }
                identityRow("Noyau", item.identity.kernel, field: "kernel")
                identityRow("BIOS", item.identity.bios, field: "bios")
                identityRow("Châssis", item.identity.chassis, field: "chassis")
                identityRow("Virtualisation", item.identity.virt, field: "virt")
            }
        }
    }

    /// Un champ corrigé à la main porte une pastille : sans elle, on ne sait pas
    /// si la valeur vient de la machine ou de quelqu'un.
    @ViewBuilder
    private func identityRow(_ label: String, _ value: String?, field: String) -> some View {
        if let value {
            LabeledValue(label: item.identity.isOverridden(field) ? "\(label) ✎" : label,
                         value: value)
        }
    }

    private var interfaces: some View {
        SectionBox("Interfaces", symbol: "network") {
            VStack(spacing: 10) {
                ForEach(item.identity.macs.sorted(by: { $0.key < $1.key }), id: \.key) { name, mac in
                    LabeledValue(label: name, value: mac, monospaced: true)
                }
            }
        }
    }
}

// MARK: - Classement

private struct ClassificationEditor: View {
    let item: InventoryItem
    let onSave: (InventoryPatch) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var category = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var enabled = true
    @State private var isSaving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Classement") {
                    TextField("Catégorie", text: $category)
                    TextField("Lieu", text: $location)
                }

                Section {
                    ForEach(tags, id: \.self) { tag in
                        HStack {
                            Label(tag, systemImage: "tag")
                            Spacer()
                            Button {
                                tags.removeAll { $0 == tag }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Palette.danger)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Nouvelle étiquette", text: $newTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addTag)
                        Button("Ajouter", action: addTag)
                            .disabled(cleanedTag.isEmpty)
                    }
                } header: {
                    Text("Étiquettes")
                } footer: {
                    Text("Les étiquettes servent de cible aux planifications et aux lots de mise à jour.")
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section {
                    Toggle("Machine supervisée", isOn: $enabled)
                } footer: {
                    Text("Désactivée, la machine reste dans l'inventaire mais n'est plus collectée ni alertée.")
                }

                if let error {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Classer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .onAppear {
                category = item.category ?? ""
                location = item.location ?? ""
                notes = item.notes ?? ""
                tags = item.tags
                enabled = item.enabled
            }
        }
    }

    private var cleanedTag: String {
        newTag.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func addTag() {
        let tag = cleanedTag
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
        newTag = ""
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // Une chaîne vidée signifie « efface la valeur », pas « ne touche à rien » :
        // le serveur distingue les deux par la présence de la clé.
        let patch = InventoryPatch(
            category: category.trimmingCharacters(in: .whitespaces),
            location: location.trimmingCharacters(in: .whitespaces),
            notes: notes,
            tags: tags,
            enabled: enabled)
        do {
            try await onSave(patch)
            dismiss()
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}
