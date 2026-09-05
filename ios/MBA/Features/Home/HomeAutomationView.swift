import SwiftUI

/// Domotique : les instances Home Assistant rattachées à MBA.
///
/// L'écran n'essaie pas de remplacer l'application Home Assistant. Il répond à
/// la question qu'on se pose depuis la console d'administration : est-ce que la
/// maison va bien — entités injoignables, piles à plat, automatisations
/// désactivées — et permet les quelques gestes réversibles que le serveur
/// autorise.
struct HomeAutomationView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<HomeOverview> = .idle
    @State private var selectedHubID: Int?
    @State private var search = ""
    @State private var filter: HomeFilter = .all
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let overview = state.value {
                if overview.hubs.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucune instance",
                            message: "Rattache une instance Home Assistant pour suivre l'état de la maison depuis MBA.\n\nL'ajout demande un jeton d'accès longue durée : il se fait depuis la console web.",
                            symbol: "house")
                            .listRowBackground(Color.clear)
                    }
                } else if let hub = activeHub(overview) {
                    hubPicker(overview)
                    summarySection(hub)
                    entitySections(hub: hub, labels: overview.domainLabels)
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
        .navigationTitle("Domotique")
        .searchable(text: $search, prompt: "Entité, pièce, état")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: HomeEntity.self) { entity in
            if let hub = state.value.flatMap(activeHub) {
                EntityDetailView(hub: hub, entity: entity,
                                 labels: state.value?.domainLabels ?? [:],
                                 onCall: { command in call(command, on: entity, hub: hub) })
            }
        }
        .actionResult(runner)
    }

    // MARK: - En-tête

    @ViewBuilder
    private func hubPicker(_ overview: HomeOverview) -> some View {
        // Un seul hub est le cas courant : le sélecteur ne s'affiche que
        // lorsqu'il y a vraiment un choix à faire.
        if overview.hubs.count > 1 {
            Section {
                Picker("Instance", selection: Binding(
                    get: { selectedHubID ?? overview.hubs.first?.id ?? 0 },
                    set: { selectedHubID = $0 })
                ) {
                    ForEach(overview.hubs) { hub in
                        Text(hub.name).tag(hub.id)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func summarySection(_ hub: HomeHub) -> some View {
        let stats = hub.stats
        return Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: Format.integer(stats.entities), label: "Entités",
                             symbol: "square.grid.2x2",
                             trailing: "\(stats.domains) domaines")
                    StatTile(value: Format.integer(stats.lightsOn + stats.switchesOn),
                             label: "Allumés", symbol: "lightbulb.fill",
                             tint: stats.lightsOn + stats.switchesOn > 0 ? Palette.warn : Palette.idle)
                    if stats.unavailable > 0 {
                        StatTile(value: Format.integer(stats.unavailable),
                                 label: "Indisponibles",
                                 symbol: "exclamationmark.triangle.fill", tint: Palette.danger)
                    }
                    if stats.lowBattery > 0 {
                        StatTile(value: Format.integer(stats.lowBattery),
                                 label: "Piles faibles", symbol: "battery.25",
                                 tint: Palette.warn)
                    }
                    if stats.updates > 0 {
                        StatTile(value: Format.integer(stats.updates),
                                 label: "Mises à jour", symbol: "arrow.down.circle",
                                 tint: Palette.warn)
                    }
                    if stats.automationsOff > 0 {
                        StatTile(value: Format.integer(stats.automationsOff),
                                 label: "Automatisations coupées",
                                 symbol: "arrow.triangle.branch", tint: Palette.idle)
                    }
                }

                Picker("Filtre", selection: $filter) {
                    ForEach(HomeFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        } footer: {
            if let version = hub.version {
                Text("Home Assistant \(version)\(hub.location.map { " · \($0)" } ?? "")")
            }
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Entités

    @ViewBuilder
    private func entitySections(hub: HomeHub, labels: [String: String]) -> some View {
        let visible = hub.entities
            .filter { filter.accepts($0) }
            .filter { $0.matches(normalizedSearch) }

        if visible.isEmpty {
            Section {
                EmptyState(title: "Aucune entité",
                           message: filter == .all
                               ? "Aucune entité ne correspond à « \(search) »."
                               : "Rien ne correspond à ce filtre. C'est la bonne nouvelle du jour.",
                           symbol: "house")
                    .listRowBackground(Color.clear)
            }
        } else {
            let grouped = Dictionary(grouping: visible, by: \.domain)
            // On garde l'ordre du hub — domaines les plus fournis d'abord —
            // pour que la liste ne se réorganise pas à chaque filtre.
            ForEach(hub.domains(labels: labels).filter { grouped[$0] != nil }, id: \.self) { domain in
                let entities = (grouped[domain] ?? []).sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                Section("\(HomeEntity.label(for: domain, labels: labels)) · \(entities.count)") {
                    ForEach(entities) { entity in
                        NavigationLink(value: entity) {
                            EntityRow(entity: entity)
                        }
                        .swipeActions(edge: .leading) {
                            // Le geste principal du domaine, à portée de pouce.
                            if let command = entity.commands.first, !command.isSensitive {
                                Button(command.label, systemImage: command.symbol) {
                                    call(command, on: entity, hub: hub)
                                }
                                .tint(.accentColor)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func call(_ command: HomeCommand, on entity: HomeEntity, hub: HomeHub) {
        let body = HomeServiceCall(entityID: entity.entityID, service: command.service)
        let operation: @Sendable () async throws -> String? = { [client = session.client] in
            guard let client else { return nil }
            let _: JSONValue = try await client.post("/home/\(hub.id)/call", body: body)
            return "\(command.label) — \(entity.name). Home Assistant met une seconde ou deux à refléter le nouvel état."
        }

        if command.isSensitive {
            runner.confirm(
                "\(command.label) — \(entity.name) ?",
                message: "L'appel \(entity.domain).\(command.service) sera envoyé à Home Assistant, qui l'exécutera dans la maison.",
                confirmLabel: command.label,
                isDestructive: false,
                operation: operation)
        } else {
            Task { await runner.run(command.label, operation: operation) }
        }
        Task { await reloadSoon() }
    }

    // MARK: - Données

    private func activeHub(_ overview: HomeOverview) -> HomeHub? {
        guard let selectedHubID,
              let hub = overview.hubs.first(where: { $0.id == selectedHubID })
        else { return overview.hubs.first }
        return hub
    }

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/home"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    private func reloadSoon() async {
        // Le collecteur est réveillé par l'appel de service ; on lui laisse le
        // temps d'un cycle avant de redemander l'état.
        try? await Task.sleep(for: .seconds(2))
        await load()
    }
}

/// Les vues qui valent la peine d'être isolées d'un parc de plusieurs centaines
/// d'entités.
enum HomeFilter: String, CaseIterable, Identifiable {
    case all, on, problems

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "Tout"
        case .on: "Actifs"
        case .problems: "À voir"
        }
    }

    func accepts(_ entity: HomeEntity) -> Bool {
        switch self {
        case .all: true
        case .on: entity.isOn
        case .problems: !entity.available || entity.isLowBattery || entity.announcesUpdate
        }
    }
}

// MARK: - Ligne

private struct EntityRow: View {
    let entity: HomeEntity

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entity.symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(entity.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if let area = entity.area, !area.isEmpty {
                    Text(area)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if !entity.available {
                        StatusBadge(text: "indisponible", color: Palette.danger,
                                    symbol: "exclamationmark.triangle.fill")
                    }
                    if entity.isLowBattery {
                        StatusBadge(text: Format.percent(entity.battery, digits: 0),
                                    color: Palette.warn, symbol: "battery.25")
                    }
                    if entity.announcesUpdate {
                        StatusBadge(text: "mise à jour", color: Palette.warn,
                                    symbol: "arrow.down.circle")
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entity.displayState)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if let changed = entity.changed {
                    Text(Format.ago(changed))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(entity.available ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        if !entity.available { return Palette.idle }
        return entity.isOn ? Palette.warn : .secondary
    }
}

// MARK: - Fiche

private struct EntityDetailView: View {
    let hub: HomeHub
    let entity: HomeEntity
    let labels: [String: String]
    let onCall: (HomeCommand) -> Void

    @Environment(SessionStore.self) private var session

    @State private var history: Loadable<[HomeHistoryPoint]> = .idle

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                SectionBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: entity.symbol)
                                .font(.title2)
                                .foregroundStyle(entity.isOn ? Palette.warn : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entity.displayState)
                                    .font(.title3.weight(.semibold))
                                Text(HomeEntity.label(for: entity.domain, labels: labels))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            if !entity.available {
                                StatusBadge(text: "indisponible", color: Palette.danger,
                                            symbol: "exclamationmark.triangle.fill")
                            }
                        }
                        if let changed = entity.changed {
                            Text("Dernier changement \(Format.ago(changed)) · \(Format.fullDate(changed))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !entity.commands.isEmpty {
                    SectionBox("Commandes", symbol: "hand.tap") {
                        VStack(spacing: 10) {
                            ForEach(entity.commands) { command in
                                Button {
                                    onCall(command)
                                } label: {
                                    Label(command.label, systemImage: command.symbol)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                SectionBox("Détails", symbol: "info.circle") {
                    VStack(spacing: 10) {
                        LabeledValue(label: "Identifiant", value: entity.entityID, monospaced: true)
                        LabeledValue(label: "Pièce", value: entity.area)
                        LabeledValue(label: "Classe", value: entity.deviceClass)
                        if let battery = entity.battery {
                            LabeledValue(label: "Batterie",
                                         value: Format.percent(battery, digits: 0))
                        }
                        LabeledValue(label: "Instance", value: hub.name)
                    }
                }

                if entity.hasHistory {
                    historySection
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(entity.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadHistory() }
    }

    @ViewBuilder
    private var historySection: some View {
        SectionBox("24 dernières heures", symbol: "chart.xyaxis.line") {
            switch history {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 90)
            case .failed(let error):
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let points):
                let series = points.metricPoints
                if series.count < 2 {
                    Text("Pas assez de relevés pour tracer une courbe.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Sparkline(points: series, tint: .accentColor)
                            .frame(height: 90)
                        HStack {
                            Text("min \(Format.number(series.map(\.value).min(), digits: 1))")
                            Spacer()
                            Text("max \(Format.number(series.map(\.value).max(), digits: 1))")
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func loadHistory() async {
        guard let client = session.client, entity.hasHistory else { return }
        history.begin()
        // L'identifiant contient un point ; il voyage dans le chemin, il faut
        // donc l'échapper comme un segment d'URL.
        let segment = entity.entityID
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entity.entityID
        do {
            history = .loaded(try await client.get("/home/\(hub.id)/history/\(segment)",
                                                   query: ["hours": "24"]))
        } catch let error as APIError {
            if !error.isCancellation { history = .failed(error) }
        } catch {
            history = .failed(APIError.transport(error))
        }
    }
}
