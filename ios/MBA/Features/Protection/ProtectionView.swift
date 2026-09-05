import SwiftUI

/// Protection des données : ce qui est sauvegardé, ce qui ne l'est pas, et ce
/// qui menace de ne plus l'être.
///
/// Le serveur agrège trois sources hétérogènes (PBS, vzdump, Hyper Backup) et
/// n'expose que le verdict : l'écran ne recalcule rien, il met en évidence.
struct ProtectionView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<ProtectionOverview> = .idle
    @State private var sources: ProtectionSources?
    @State private var tab: ProtectionTab = .items
    @State private var search = ""
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let overview = state.value {
                if hasNoSource {
                    noSourceSection
                } else {
                    noticesSection(overview)
                    summarySection(overview.summary)

                    switch tab {
                    case .items: itemsTab(overview)
                    case .gaps: gapsTab(overview)
                    case .risks: risksTab(overview)
                    case .stores: storesTab(overview)
                    case .tasks: tasksTab(overview)
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
        .navigationTitle("Sauvegardes")
        .searchable(text: $search, prompt: "Objet, dépôt, machine")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: SnapshotRoute.self) { route in
            PBSSnapshotsView(route: route)
        }
        .navigationDestination(for: Int.self) { hostID in
            HostDetailView(hostID: hostID, fallbackName: "Machine")
        }
        .actionResult(runner)
    }

    /// Sans source déclarée, tous les compteurs valent zéro : mieux vaut dire
    /// quoi brancher que d'afficher une couverture de 100 % sur un parc vide.
    private var hasNoSource: Bool {
        guard let sources else { return false }
        return sources.sources.isEmpty
    }

    private var noSourceSection: some View {
        Section {
            EmptyState(
                title: "Aucune source de sauvegarde",
                message: "Enregistre depuis la console web ton Proxmox Backup Server (port 8007, jeton d'API), ton hyperviseur PVE pour lire ses vzdump, ou ton NAS Synology pour ses tâches Hyper Backup.",
                symbol: "archivebox")
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Bandeaux

    @ViewBuilder
    private func noticesSection(_ overview: ProtectionOverview) -> some View {
        if !overview.errors.isEmpty || !overview.notices.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(overview.errors) { error in
                        NoticeLine(symbol: "exclamationmark.triangle.fill", tint: Palette.warn,
                                   title: "\(error.host) (\(error.kind))", message: error.error)
                    }
                    ForEach(overview.notices) { notice in
                        NoticeLine(symbol: notice.isWarning ? "exclamationmark.circle.fill" : "info.circle.fill",
                                   tint: notice.isWarning ? Palette.warn : Color.accentColor,
                                   title: notice.host, message: notice.message)
                    }
                }
                .padding(12)
                // Le fond suit le pire des avis : un simple « ce NAS est une
                // destination » ne doit pas s'afficher sur un carton orange.
                .background(noticeTint(overview).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .listRowBackground(Color.clear)
        }
    }

    private func noticeTint(_ overview: ProtectionOverview) -> Color {
        overview.errors.isEmpty && !overview.notices.contains(where: \.isWarning)
            ? Color.accentColor
            : Palette.warn
    }

    // MARK: - Synthèse

    private func summarySection(_ summary: ProtectionOverview.Summary) -> some View {
        Section {
            VStack(spacing: Metrics.spacing) {
                HStack(spacing: 14) {
                    ScoreRing(score: Int(summary.coverage.rounded()), size: 62, label: "Couverture des sauvegardes")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Couverture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Format.percent(summary.coverage, digits: 0))
                            .font(.headline)
                            .foregroundStyle(Palette.score(Int(summary.coverage.rounded())))
                        Text("\(Format.plural(summary.fresh, "objet")) à jour sur \(summary.protectedCount + summary.gaps) recensés.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(summary.protectedCount)", label: "Sauvegardés",
                             symbol: "archivebox", tint: Palette.ok,
                             // Le point sépare : sans lui, « 4 » et « 592 Go »
                             // se lisent comme le seul nombre « 4 592 Go ».
                             trailing: summary.totalSize > 0 ? "· \(Format.bytes(summary.totalSize))" : nil)
                    StatTile(value: "\(summary.stale + summary.critical)", label: "En retard",
                             symbol: "clock.badge.exclamationmark",
                             tint: summary.critical > 0 ? Palette.danger
                                 : summary.stale > 0 ? Palette.warn : Palette.ok,
                             trailing: summary.critical > 0
                                 ? "dont \(Format.plural(summary.critical, "périmée"))" : nil)
                    StatTile(value: "\(summary.gaps)", label: "Non protégés",
                             symbol: "shield.slash",
                             tint: summary.gaps > 0 ? Palette.danger : Palette.ok)
                    StatTile(value: "\(summary.offsite)", label: "Hors site",
                             symbol: "cloud",
                             tint: summary.offsite > 0 ? Palette.ok : Palette.warn)
                }

                // Le sélecteur vit dans la même carte que la synthèse : en
                // section séparée, l'espacement des listes groupées repoussait
                // le contenu sous la ligne de flottaison.
                Picker("Vue", selection: $tab) {
                    ForEach(ProtectionTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Objets sauvegardés

    @ViewBuilder
    private func itemsTab(_ overview: ProtectionOverview) -> some View {
        let visible = overview.protectedItems.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(
                    title: overview.protectedItems.isEmpty
                        ? "Aucune sauvegarde recensée"
                        : "Aucun résultat",
                    message: overview.protectedItems.isEmpty
                        ? "Vérifie que le jeton PBS a le droit de lecture sur les datastores, et que les tâches Hyper Backup sont visibles du compte DSM."
                        : "Aucun objet ne correspond à « \(search) ».",
                    symbol: "archivebox")
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(groupedBySource(visible), id: \.source) { group in
                Section(group.source.label) {
                    ForEach(group.items) { item in
                        if let route = snapshotRoute(for: item) {
                            NavigationLink(value: route) { ProtectedItemRow(item: item) }
                        } else {
                            ProtectedItemRow(item: item)
                        }
                    }
                }
            }
        }
    }

    /// Les instantanés ne sont lisibles que sur un PBS, et seulement si on sait
    /// de quel serveur et de quel datastore ils viennent.
    private func snapshotRoute(for item: ProtectedItem) -> SnapshotRoute? {
        guard item.source == .pbs, let hostID = item.sourceHostID,
              let store = item.store, !store.isEmpty else { return nil }
        return SnapshotRoute(hostID: hostID, store: store, hostName: item.sourceHost)
    }

    // MARK: - Écarts

    @ViewBuilder
    private func gapsTab(_ overview: ProtectionOverview) -> some View {
        if overview.gaps.isEmpty {
            Section {
                EmptyState(title: "Aucun écart détecté",
                           message: "Chaque VM, conteneur et machine connus apparaît dans au moins une sauvegarde.",
                           symbol: "checkmark.shield")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(overview.gaps) { gap in
                    if let hostID = gap.hostID {
                        NavigationLink(value: hostID) { GapRow(gap: gap) }
                    } else {
                        GapRow(gap: gap)
                    }
                }
            } footer: {
                Text("Objets connus de MBA qui n'apparaissent dans aucune sauvegarde.")
            }
        }
    }

    // MARK: - Risques

    @ViewBuilder
    private func risksTab(_ overview: ProtectionOverview) -> some View {
        if overview.risks.isEmpty {
            Section {
                EmptyState(title: "Aucun risque identifié",
                           message: "Sauvegardes fraîches, stockages sains, tâches réussies.",
                           symbol: "checkmark.shield")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(overview.risks) { risk in
                    RiskRow(risk: risk)
                }
            }
        }
    }

    // MARK: - Stockages

    @ViewBuilder
    private func storesTab(_ overview: ProtectionOverview) -> some View {
        if overview.datastores.isEmpty {
            Section {
                EmptyState(title: "Aucun datastore",
                           message: "Les datastores proviennent du Proxmox Backup Server. vzdump et Hyper Backup n'en exposent pas.",
                           symbol: "externaldrive")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(overview.datastores) { store in
                    if let host = sources?.pbsHost(named: store.sourceHost) {
                        NavigationLink(value: SnapshotRoute(hostID: host.id, store: store.name,
                                                            hostName: store.sourceHost)) {
                            DatastoreRow(store: store)
                        }
                    } else {
                        DatastoreRow(store: store)
                    }
                }
            } footer: {
                Text("Un datastore au-delà de 92 % fait échouer les sauvegardes suivantes.")
            }
        }
    }

    // MARK: - Tâches

    @ViewBuilder
    private func tasksTab(_ overview: ProtectionOverview) -> some View {
        let visible = overview.tasks.filter {
            normalizedSearch.isEmpty
                || $0.label.lowercased().contains(normalizedSearch)
                || $0.sourceHost.lowercased().contains(normalizedSearch)
        }
        if visible.isEmpty {
            Section {
                EmptyState(title: "Aucune tâche récente",
                           message: "Les exécutions remontées par PBS et Hyper Backup s'affichent ici.",
                           symbol: "clock.arrow.circlepath")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(visible) { task in
                    BackupTaskRow(task: task)
                }
            }
        }
    }

    // MARK: - Réseau

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func groupedBySource(
        _ items: [ProtectedItem]
    ) -> [(source: BackupSource, items: [ProtectedItem])] {
        Dictionary(grouping: items, by: \.source)
            .map { (source: $0.key, items: $0.value) }
            // Le pire d'abord : c'est la source dont une copie est périmée qu'on
            // veut voir en ouvrant l'écran.
            .sorted { first, second in
                let left = first.items.contains { $0.freshness != .fresh }
                let right = second.items.contains { $0.freshness != .fresh }
                if left != right { return left }
                return first.source.label.localizedStandardCompare(second.source.label) == .orderedAscending
            }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/protection"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
        // Les sources déclarées ne servent qu'à l'état vide et aux liens vers les
        // instantanés : leur échec ne doit pas emporter l'écran.
        sources = try? await client.get("/protection/sources")
    }
}

enum ProtectionTab: String, CaseIterable, Identifiable {
    case items, gaps, risks, stores, tasks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .items: "Objets"
        case .gaps: "Écarts"
        case .risks: "Risques"
        case .stores: "Dépôts"
        case .tasks: "Tâches"
        }
    }
}

/// Cible d'un détail d'instantanés PBS.
struct SnapshotRoute: Hashable, Sendable {
    let hostID: Int
    let store: String
    let hostName: String
}

// MARK: - Lignes

private struct NoticeLine: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.footnote.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ProtectedItemRow: View {
    let item: ProtectedItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.freshness.symbol)
                .foregroundStyle(item.freshness.color)
                .imageScale(.small)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if item.offsite {
                        Image(systemName: "cloud.fill")
                            .font(.caption2)
                            .foregroundStyle(Palette.ok)
                            .accessibilityLabel("Copie hors site")
                    }
                    if item.enabled == false {
                        TagChip(text: "désactivée", symbol: "pause.circle")
                    }
                }
                Text(item.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.ageHours.map { Format.duration($0 * 3600) } ?? Format.placeholder)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(item.freshness == .fresh ? .primary : item.freshness.color)
                Text([item.count.map { Format.plural($0, "version") },
                      item.size.map { Format.bytes($0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue("sauvegarde \(item.freshness.label)")
    }
}

private struct GapRow: View {
    let gap: ProtectionGap

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.slash.fill")
                .foregroundStyle(gap.severity.color)
                .imageScale(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(gap.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if let detail = gap.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            TagChip(text: gap.kindLabel)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct RiskRow: View {
    let risk: ProtectionRisk

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LeadingAccent(color: risk.severity.color)
                .padding(.vertical, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(risk.title)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = risk.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let remediation = risk.remediation, !remediation.isEmpty {
                    Label(remediation, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(risk.severity.label)
                        .foregroundStyle(risk.severity.color)
                    Text("· \(risk.source.shortLabel)")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

private struct DatastoreRow: View {
    let store: Datastore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(store.name, systemImage: "externaldrive.fill")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                TagChip(text: store.sourceHost)
            }
            // Un datastore de sauvegarde sature plus vite qu'un disque système :
            // les seuils du moteur (80 / 92 %) sont plus bas que ceux des jauges.
            MetricBar(title: "\(Format.bytes(store.used)) / \(Format.bytes(store.total))",
                      value: store.percent,
                      detail: Format.percent(store.percent, digits: 1),
                      warnAt: 80, criticalAt: 92)
            HStack {
                Text("\(Format.bytes(store.available)) libres")
                Spacer(minLength: 6)
                if let full = store.estimatedFull {
                    Text("saturation \(Format.dateTime(full))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct BackupTaskRow: View {
    let task: BackupTask

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(task.succeeded ? Palette.ok : Palette.danger)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.label)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([task.sourceHost, Format.dateTime(task.started),
                      task.next.map { "prochaine \(Format.dateTime($0))" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if let status = task.status, !status.isEmpty, status != "OK" {
                    Text(status)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(task.succeeded ? .secondary : Palette.danger)
                        .lineLimit(1)
                }
                if let duration = task.duration {
                    Text(Format.duration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Instantanés PBS

/// Les points de restauration réellement disponibles dans un datastore.
///
/// C'est la réponse à la seule question qui compte un jour d'incident : « de
/// quand date la copie que je peux remonter, et a-t-elle été vérifiée ? »
private struct PBSSnapshotsView: View {
    let route: SnapshotRoute

    @Environment(SessionStore.self) private var session
    @State private var state: Loadable<[PBSSnapshot]> = .idle
    @State private var search = ""

    var body: some View {
        List {
            if let snapshots = state.value {
                let visible = filtered(snapshots)
                if visible.isEmpty {
                    Section {
                        EmptyState(
                            title: snapshots.isEmpty ? "Datastore vide" : "Aucun résultat",
                            message: snapshots.isEmpty
                                ? "Ce datastore ne contient aucun instantané."
                                : "Aucun instantané ne correspond à « \(search) ».",
                            symbol: "clock.arrow.circlepath")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(grouped(visible), id: \.group) { group in
                        Section {
                            ForEach(group.snapshots) { snapshot in
                                SnapshotRow(snapshot: snapshot)
                            }
                        } header: {
                            Text("\(group.group) · \(Format.plural(group.snapshots.count, "version"))")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if state.isEmptyLoading, !state.isFailed {
                ProgressView().controlSize(.large)
            } else if let error = state.error {
                ErrorState(error: error) { Task { await load() } }
            }
        }
        .navigationTitle(route.store)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Groupe, commentaire")
        .refreshable { await load() }
        .task { await load() }
    }

    private func filtered(_ snapshots: [PBSSnapshot]) -> [PBSSnapshot] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return snapshots }
        return snapshots.filter {
            $0.group.lowercased().contains(query)
                || ($0.comment?.lowercased().contains(query) ?? false)
        }
    }

    private func grouped(
        _ snapshots: [PBSSnapshot]
    ) -> [(group: String, snapshots: [PBSSnapshot])] {
        Dictionary(grouping: snapshots, by: \.group)
            .map { (group: $0.key, snapshots: $0.value.sorted {
                ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }) }
            .sorted { $0.group.localizedStandardCompare($1.group) == .orderedAscending }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let encoded = route.store.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) ?? route.store
            state = .loaded(try await client.get("/protection/\(route.hostID)/snapshots/\(encoded)"))
        } catch let error as APIError {
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: PBSSnapshot

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(Format.dateTime(snapshot.time))
                        .font(.subheadline.monospacedDigit())
                    if snapshot.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Protégé de la purge")
                    }
                }
                Text([snapshot.comment, snapshot.owner]
                    .compactMap { $0 }.first ?? Format.ago(snapshot.time))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.bytes(snapshot.size))
                    .font(.caption.monospacedDigit())
                // Une sauvegarde jamais vérifiée peut être illisible le jour où
                // on en a besoin : l'état de vérification vaut la place qu'il prend.
                if let verified = snapshot.verified {
                    StatusBadge(text: snapshot.isVerified ? "vérifié" : verified,
                                color: snapshot.isVerified ? Palette.ok : Palette.warn,
                                symbol: snapshot.isVerified ? "checkmark.seal.fill" : "seal")
                } else {
                    TagChip(text: "non vérifié", symbol: "questionmark.circle")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
