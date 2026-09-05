import SwiftUI

/// IA & accélérateurs : les serveurs d'inférence du parc et les cartes qui les
/// portent.
///
/// Deux questions traversent l'écran : qu'est-ce qui est chargé en mémoire — la
/// VRAM est la ressource rare — et qu'est-ce qui reste sur le disque. Le
/// dialogue avec un modèle est accessible d'ici, ce qui fait du téléphone une
/// console d'essai autant qu'une console de supervision.
struct AIView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<AIOverview> = .idle
    @State private var search = ""

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let overview = state.value {
                if overview.endpoints.isEmpty && overview.accelerators.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucun serveur d'inférence",
                            message: "Rattache un serveur Ollama ou une API compatible OpenAI (vLLM) pour suivre ses modèles depuis MBA, et dialoguer avec eux.\n\nL'ajout se fait depuis la console web.",
                            symbol: "brain")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    summarySection(overview)
                    endpointsSection(overview)
                    acceleratorsSection(overview)
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
        .navigationTitle("IA & accélérateurs")
        .searchable(text: $search, prompt: "Serveur, modèle")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: AIEndpoint.self) { endpoint in
            EndpointDetailView(endpoint: endpoint, onChange: { await load() })
        }
    }

    // MARK: - Synthèse

    private func summarySection(_ overview: AIOverview) -> some View {
        let summary = overview.summary
        return Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(value: "\(summary.endpointsOnline)", label: "Serveurs en ligne",
                         symbol: "server.rack",
                         tint: summary.endpointsOnline > 0 ? Palette.ok : Palette.danger,
                         trailing: "/ \(overview.endpoints.count)")
                StatTile(value: Format.integer(summary.modelsTotal), label: "Modèles",
                         symbol: "shippingbox")
                StatTile(value: Format.integer(summary.modelsLoaded), label: "En mémoire",
                         symbol: "memorychip",
                         tint: summary.modelsLoaded > 0 ? Palette.ok : Palette.idle)
                StatTile(value: Format.bytes(summary.vramLoaded), label: "VRAM occupée",
                         symbol: "gauge.with.dots.needle.bottom.50percent")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Serveurs

    @ViewBuilder
    private func endpointsSection(_ overview: AIOverview) -> some View {
        let visible = overview.endpoints.filter { $0.matches(normalizedSearch) }
        if !visible.isEmpty {
            Section("Serveurs d'inférence") {
                ForEach(visible) { endpoint in
                    NavigationLink(value: endpoint) {
                        EndpointRow(endpoint: endpoint)
                    }
                }
            }
        }
    }

    // MARK: - Accélérateurs

    @ViewBuilder
    private func acceleratorsSection(_ overview: AIOverview) -> some View {
        let visible = overview.accelerators.filter {
            normalizedSearch.isEmpty || $0.label.lowercased().contains(normalizedSearch)
        }
        if !visible.isEmpty {
            Section {
                ForEach(visible) { accelerator in
                    AcceleratorCard(accelerator: accelerator)
                }
            } header: {
                Text("Accélérateurs")
            } footer: {
                Text("La VRAM est la ressource qui décide de ce qu'on peut faire tourner : un modèle qui n'y tient pas déborde sur le processeur et devient très lent.")
            }
        }
    }

    // MARK: - Données

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/ai/overview"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

// MARK: - Lignes

private struct EndpointRow: View {
    let endpoint: AIEndpoint

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain")
                .foregroundStyle(endpoint.isOnline ? Palette.ok : Palette.danger)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(endpoint.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    StatusBadge(text: endpoint.isOnline ? "en ligne" : "injoignable",
                                color: endpoint.isOnline ? Palette.ok : Palette.danger)
                    if !endpoint.loaded.isEmpty {
                        StatusBadge(text: "\(endpoint.loaded.count) en mémoire",
                                    color: Palette.ok, symbol: "memorychip")
                    }
                    if let version = endpoint.version, !version.isEmpty {
                        TagChip(text: "v\(version)")
                    }
                    if endpoint.kind != "ollama" {
                        TagChip(text: endpoint.kindLabel ?? endpoint.kind)
                    }
                }

                if let error = endpoint.error, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(endpoint.models.count)")
                    .font(.caption.monospacedDigit())
                Text("modèles")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct AcceleratorCard: View {
    let accelerator: Accelerator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(accelerator.label)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 6)
                if accelerator.unified {
                    TagChip(text: "mémoire unifiée")
                }
            }

            HStack(spacing: 18) {
                MetricRing(value: accelerator.busy, label: "Calcul")
                MetricRing(value: accelerator.vramPercent, label: "VRAM",
                           caption: accelerator.vramTotal.map { Format.bytes($0) })
                VStack(alignment: .leading, spacing: 4) {
                    if let temp = accelerator.temp, temp > 0 {
                        Label(Format.temperature(temp), systemImage: "thermometer.medium")
                            .foregroundStyle(Palette.severity(temp, warn: 75, critical: 90))
                    }
                    if let power = accelerator.powerLabel {
                        Label(power, systemImage: "bolt.fill")
                    }
                    if let clock = accelerator.sclk, clock > 0 {
                        Label(Format.frequency(clock), systemImage: "speedometer")
                    }
                    if let fan = accelerator.fan, fan > 0 {
                        Label(Format.rpm(fan), systemImage: "fan")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Sur mémoire unifiée, la VRAM sort de la RAM système : afficher le
            // GTT évite de croire qu'il reste de la place quand il n'y en a plus.
            if accelerator.unified, let used = accelerator.gttUsed, let total = accelerator.gttTotal,
               total > 0 {
                MetricBar(title: "Mémoire partagée (GTT)",
                          value: used / total * 100,
                          detail: "\(Format.bytes(used)) / \(Format.bytes(total))")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Fiche d'un serveur

private struct EndpointDetailView: View {
    let endpoint: AIEndpoint
    let onChange: () async -> Void

    @Environment(SessionStore.self) private var session

    @State private var runner = ActionRunner()
    @State private var search = ""
    @State private var chatModel: String?

    var body: some View {
        List {
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: endpoint.isOnline ? "En ligne" : "Injoignable",
                             label: "État", symbol: "bolt.horizontal",
                             tint: endpoint.isOnline ? Palette.ok : Palette.danger)
                    StatTile(value: "\(endpoint.models.count)", label: "Modèles",
                             symbol: "shippingbox",
                             trailing: Format.bytes(endpoint.diskUsed))
                    StatTile(value: "\(endpoint.loaded.count)", label: "En mémoire",
                             symbol: "memorychip",
                             tint: endpoint.loaded.isEmpty ? Palette.idle : Palette.ok,
                             trailing: endpoint.loaded.isEmpty
                                 ? nil : Format.bytes(endpoint.vramUsed))
                    StatTile(value: endpoint.version.map { "v\($0)" } ?? Format.placeholder,
                             label: "Version", symbol: "number")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            } footer: {
                Text(endpoint.url)
                    .font(.caption.monospaced())
            }
            .listRowBackground(Color.clear)

            if !endpoint.loaded.isEmpty {
                Section {
                    ForEach(endpoint.loaded) { model in
                        LoadedRow(model: model)
                            .swipeActions(edge: .trailing) {
                                if endpoint.can("unload") {
                                    Button("Décharger", systemImage: "eject") {
                                        confirmUnload(model)
                                    }
                                    .tint(Palette.warn)
                                }
                            }
                    }
                } header: {
                    Text("Résidents en mémoire")
                } footer: {
                    Text(endpoint.can("unload")
                         ? "Un modèle résident répond sans délai de chargement. Ollama le décharge de lui-même après quelques minutes d'inactivité."
                         : "Ce serveur garde son modèle résident tant qu'il tourne : rien à charger ni à décharger.")
                }
            }

            let visible = endpoint.models.filter { $0.matches(normalizedSearch) }
            Section("Modèles · \(visible.count)") {
                if visible.isEmpty {
                    Text(endpoint.models.isEmpty
                         ? "Aucun modèle installé sur ce serveur."
                         : "Aucun modèle ne correspond à « \(search) ».")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visible) { model in
                        ModelRow(model: model, isLoaded: endpoint.isLoaded(model))
                            .contentShape(.rect)
                            .onTapGesture { chatModel = model.name }
                            .swipeActions(edge: .leading) {
                                Button("Discuter", systemImage: "bubble.left.and.bubble.right") {
                                    chatModel = model.name
                                }
                                .tint(.accentColor)
                            }
                            .swipeActions(edge: .trailing) {
                                if endpoint.can("delete") {
                                    Button("Supprimer", systemImage: "trash", role: .destructive) {
                                        confirmDelete(model)
                                    }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(endpoint.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Modèle")
        .sheet(item: Binding(get: { chatModel.map(ChatTarget.init) },
                             set: { chatModel = $0?.model })) { target in
            ChatView(endpoint: endpoint, model: target.model)
        }
        .actionResult(runner)
    }

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func confirmUnload(_ model: LoadedModel) {
        runner.confirm(
            "Décharger « \(model.name) » ?",
            message: "Le modèle libère \(Format.bytes(model.sizeVRAM)) de mémoire. La prochaine requête le rechargera, ce qui prendra quelques secondes.",
            confirmLabel: "Décharger",
            isDestructive: false
        ) { [client = session.client, id = endpoint.id] in
            guard let client else { return nil }
            try await client.perform("/ai/endpoints/\(id)/unload/\(Self.escape(model.name))")
            return "« \(model.name) » a quitté la mémoire."
        }
        Task { await reloadSoon() }
    }

    private func confirmDelete(_ model: AIModel) {
        runner.confirm(
            "Supprimer « \(model.name) » ?",
            message: "Le modèle est effacé du disque du serveur (\(Format.bytes(model.size))). Il faudra le retélécharger pour s'en resservir.",
            confirmLabel: "Supprimer"
        ) { [client = session.client, id = endpoint.id] in
            guard let client else { return nil }
            try await client.delete("/ai/endpoints/\(id)/models/\(Self.escape(model.name))")
            return "« \(model.name) » supprimé."
        }
        Task { await reloadSoon() }
    }

    /// Un nom de modèle contient « : » et parfois « / » : sans échappement, il
    /// casserait le chemin de l'URL.
    private static func escape(_ model: String) -> String {
        model.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))
            ?? model
    }

    private func reloadSoon() async {
        try? await Task.sleep(for: .seconds(2))
        await onChange()
    }
}

/// `sheet(item:)` réclame un `Identifiable` : le nom du modèle en tient lieu.
private struct ChatTarget: Identifiable {
    let model: String
    var id: String { model }

    init(_ model: String) {
        self.model = model
    }
}

private struct LoadedRow: View {
    let model: LoadedModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(model.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Format.bytes(model.sizeVRAM))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                if model.isFullyOnGPU {
                    StatusBadge(text: "entièrement sur la carte", color: Palette.ok)
                } else if let share = model.vramShare {
                    // Un modèle à cheval entre carte et processeur explique à lui
                    // seul une génération qui traîne.
                    StatusBadge(text: "\(Format.percent(share, digits: 0)) sur la carte",
                                color: Palette.warn, symbol: "exclamationmark.triangle.fill")
                }
                if let expires = model.expiresAt {
                    TagChip(text: "expire \(Format.ago(expires))")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ModelRow: View {
    let model: AIModel
    let isLoaded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isLoaded ? "memorychip.fill" : "shippingbox")
                .foregroundStyle(isLoaded ? Palette.ok : .secondary)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !model.signature.isEmpty {
                    Text(model.signature)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(model.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let modified = model.modified {
                    Text(Format.ago(modified))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
