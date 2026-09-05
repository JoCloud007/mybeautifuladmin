import SwiftUI

/// Cloud public : ce qui est stocké au dehors, et ce que ça coûte.
///
/// Deux choses comptent ici et ne se voient nulle part ailleurs : la dépense du
/// mois, qui ne prévient pas quand elle dérive, et la volumétrie du stockage
/// objet, dont la pente dit dans combien de temps un seuil sera franchi.
struct CloudView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<CloudOverview> = .idle
    @State private var tab: CloudTab = .resources
    @State private var search = ""
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let overview = state.value {
                if overview.accounts.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucun compte",
                            message: "Rattache un projet de cloud public pour suivre sa dépense et la volumétrie de son stockage objet depuis MBA.\n\nL'ajout demande des clés d'API : il se fait depuis la console web.",
                            symbol: "cloud")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    summarySection(overview)
                    switch tab {
                    case .resources: resourcesTab(overview)
                    case .accounts: accountsTab(overview)
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
        .navigationTitle("Cloud public")
        .searchable(text: $search, prompt: "Ressource, région, compte")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: CloudResource.self) { resource in
            ResourceDetailView(resource: resource)
        }
        .actionResult(runner)
    }

    // MARK: - Synthèse

    private func summarySection(_ overview: CloudOverview) -> some View {
        let summary = overview.summary
        let overrun = summary.costForecast > 0 && summary.costForecast > summary.costCurrent * 1.5
        let watched = overview.resources.filter { $0.daysToQuota != nil }
            .min { ($0.daysToQuota ?? .infinity) < ($1.daysToQuota ?? .infinity) }

        return Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: Format.money(summary.costCurrent, currency: summary.currency),
                             label: "Dépense du mois", symbol: "eurosign.circle",
                             tint: summary.costCurrent > 0 ? .primary : Palette.idle)
                    StatTile(value: Format.money(summary.costForecast, currency: summary.currency),
                             label: "Projection", symbol: "chart.line.uptrend.xyaxis",
                             tint: overrun ? Palette.warn : .primary)
                    StatTile(value: Format.bytes(summary.storedBytes), label: "Stocké",
                             symbol: "externaldrive.badge.icloud",
                             trailing: "\(summary.buckets) buckets")
                    StatTile(value: "\(summary.accountsOnline)", label: "Comptes joignables",
                             symbol: "cloud",
                             tint: summary.accountsOnline == summary.accounts
                                 ? Palette.ok : Palette.warn,
                             trailing: "/ \(summary.accounts)")
                }

                if let watched, let days = watched.daysToQuota {
                    // Une pente sur un stockage objet est la seule alerte qui
                    // arrive avec des semaines d'avance : autant la montrer.
                    Label("« \(watched.name) » atteint son seuil dans \(Format.number(days, digits: 0)) jours au rythme actuel.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(days < 30 ? Palette.danger : Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if summary.linkedPBS > 0 {
                    Label("\(Format.plural(summary.linkedPBS, "bucket")) sert\(summary.linkedPBS > 1 ? "vent" : "") de dépôt à un PBS.",
                          systemImage: "externaldrive.badge.timemachine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Picker("Vue", selection: $tab) {
                    ForEach(CloudTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Ressources

    @ViewBuilder
    private func resourcesTab(_ overview: CloudOverview) -> some View {
        let visible = overview.resources.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(
                    title: overview.resources.isEmpty ? "Aucune ressource" : "Aucun résultat",
                    message: overview.resources.isEmpty
                        ? "Synchronise un compte pour relever ses buckets, ses instances et ses volumes."
                        : "Aucune ressource ne correspond à « \(search) ».",
                    symbol: "cube")
                    .listRowBackground(Color.clear)
            }
        } else {
            // On regroupe par libellé, pas par `kind` : « bucket » et
            // « container » désignent le même stockage objet selon le
            // fournisseur, et deux sections du même nom n'auraient aucun sens.
            let grouped = Dictionary(grouping: visible.filter { !$0.isGone }, by: \.kindLabel)
            ForEach(grouped.keys.sorted(), id: \.self) { label in
                let resources = (grouped[label] ?? []).sorted {
                    ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0)
                }
                Section("\(label) · \(resources.count)") {
                    ForEach(resources) { resource in
                        NavigationLink(value: resource) {
                            ResourceRow(resource: resource)
                        }
                    }
                }
            }

            let gone = visible.filter(\.isGone)
            if !gone.isEmpty {
                Section {
                    ForEach(gone) { resource in
                        NavigationLink(value: resource) {
                            ResourceRow(resource: resource)
                        }
                    }
                } header: {
                    Text("Disparues · \(gone.count)")
                } footer: {
                    Text("Ces ressources n'existent plus chez le fournisseur. Leur historique est conservé ici.")
                }
            }
        }
    }

    // MARK: - Comptes

    @ViewBuilder
    private func accountsTab(_ overview: CloudOverview) -> some View {
        Section {
            ForEach(overview.accounts) { account in
                AccountRow(account: account,
                           resources: overview.resources.filter { $0.accountID == account.id }.count)
                    .swipeActions(edge: .leading) {
                        Button("Synchroniser", systemImage: "arrow.triangle.2.circlepath") {
                            sync(account)
                        }
                        .tint(.accentColor)
                    }
            }
        } footer: {
            Text("Une synchronisation interroge l'API du fournisseur : elle relève la volumétrie, la dépense du mois et l'inventaire des ressources.")
        }
    }

    // MARK: - Actions

    private func sync(_ account: CloudAccount) {
        guard !account.needsProject else {
            runner.confirm(
                "Aucun projet sélectionné",
                message: "Le compte « \(account.name) » n'a pas de projet Public Cloud associé. Choisis-en un depuis la console web avant de synchroniser.",
                confirmLabel: "Compris",
                isDestructive: false
            ) { nil }
            return
        }
        Task {
            await runner.run("Synchronisation de « \(account.name) »") { [client = session.client] in
                guard let client else { return nil }
                let result: CloudSyncResult = try await client.post("/cloud/accounts/\(account.id)/sync")
                return result.report
            }
            await load()
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
            state = .loaded(try await client.get("/cloud"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

enum CloudTab: String, CaseIterable, Identifiable {
    case resources, accounts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .resources: "Ressources"
        case .accounts: "Comptes"
        }
    }
}

// MARK: - Lignes

private struct ResourceRow: View {
    let resource: CloudResource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: resource.symbol)
                .foregroundStyle(resource.isGone ? Palette.idle : .secondary)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(resource.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text([resource.region, resource.accountName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if resource.isBackupStore {
                        StatusBadge(text: "dépôt PBS", color: Palette.ok,
                                    symbol: "externaldrive.badge.timemachine")
                    }
                    if let days = resource.daysToQuota {
                        StatusBadge(text: "seuil dans \(Format.number(days, digits: 0)) j",
                                    color: days < 30 ? Palette.danger : Palette.warn,
                                    symbol: "gauge.with.dots.needle.67percent")
                    } else if let label = resource.trend.label {
                        TagChip(text: label,
                                symbol: resource.trend.isGrowing
                                    ? "arrow.up.right" : "arrow.down.right")
                    }
                    if resource.isGone {
                        StatusBadge(text: "disparue", color: Palette.idle)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.bytes(resource.sizeBytes))
                    .font(.caption.monospacedDigit())
                if let objects = resource.objects, objects > 0 {
                    Text("\(Format.integer(Int(objects))) objets")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(resource.isGone ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRow: View {
    let account: CloudAccount
    let resources: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cloud")
                .foregroundStyle(account.isOnline ? Palette.ok : Palette.danger)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text([account.provider.uppercased(), account.endpoint, account.credentialName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    StatusBadge(text: account.isOnline ? "joignable" : "muet",
                                color: account.isOnline ? Palette.ok : Palette.danger)
                    if account.needsProject {
                        StatusBadge(text: "aucun projet", color: Palette.warn,
                                    symbol: "exclamationmark.triangle.fill")
                    }
                    TagChip(text: "\(resources) ressources")
                }

                if let error = account.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(Palette.danger)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                if let cost = account.costCurrent {
                    Text(Format.money(cost, currency: account.currency))
                        .font(.caption.monospacedDigit())
                }
                Text(Format.ago(account.lastSync))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .opacity(account.enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fiche

private struct ResourceDetailView: View {
    let resource: CloudResource

    @Environment(SessionStore.self) private var session

    @State private var detail: Loadable<CloudResourceDetail> = .idle

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                overview
                if detail.value?.storagePoints.isEmpty == false { historySection }
                identitySection
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(resource.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private var current: CloudResource { detail.value?.resource ?? resource }

    private var overview: some View {
        SectionBox {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: Format.bytes(current.sizeBytes), label: "Volumétrie",
                             symbol: "externaldrive")
                    StatTile(value: current.objects.map { Format.integer(Int($0)) }
                                ?? Format.placeholder,
                             label: "Objets", symbol: "doc.on.doc")
                    if let trend = detail.value?.trend7d, let label = trend.label {
                        StatTile(value: label, label: "Croissance (7 j)",
                                 symbol: trend.isGrowing ? "arrow.up.right" : "arrow.down.right",
                                 tint: trend.isGrowing ? Palette.warn : Palette.ok)
                    }
                    if let price = current.priceMonth, price > 0 {
                        StatTile(value: Format.money(price), label: "Coût mensuel",
                                 symbol: "eurosign.circle")
                    }
                }

                if let percent = current.quotaPercent {
                    MetricBar(title: "Seuil de surveillance", value: percent,
                              detail: "\(Format.bytes(current.sizeBytes)) / \(Format.bytes(current.quotaBytes))")
                }
                if let days = current.daysToQuota {
                    Label("Au rythme actuel, le seuil est atteint dans \(Format.number(days, digits: 0)) jours.",
                          systemImage: "calendar.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(days < 30 ? Palette.danger : Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if current.isBackupStore {
                    Label("Ce bucket sert de dépôt au datastore « \(current.linkRef ?? "?") »\(current.pbsName.map { " sur \($0)" } ?? "").",
                          systemImage: "externaldrive.badge.timemachine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let points = detail.value?.storagePoints, points.count > 1 {
            SectionBox("Volumétrie sur 30 jours", symbol: "chart.xyaxis.line") {
                VStack(alignment: .leading, spacing: 8) {
                    Sparkline(points: points, tint: .accentColor)
                        .frame(height: 110)
                    HStack {
                        Text(Format.bytes(points.map(\.value).min()))
                        Spacer()
                        if let trend = detail.value?.trend30d, let label = trend.label {
                            Text("30 j : \(label)")
                        }
                        Spacer()
                        Text(Format.bytes(points.map(\.value).max()))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var identitySection: some View {
        SectionBox("Identité", symbol: "info.circle") {
            VStack(spacing: 10) {
                LabeledValue(label: "Type", value: current.kindLabel)
                LabeledValue(label: "Région", value: current.region)
                LabeledValue(label: "Compte", value: current.accountName)
                LabeledValue(label: "Identifiant", value: current.extID, monospaced: true)
                LabeledValue(label: "État", value: current.status)
                LabeledValue(label: "Vue pour la première fois",
                             value: Format.fullDate(current.firstSeen))
                LabeledValue(label: "Dernier relevé", value: Format.ago(current.lastSeen))
                if let notes = current.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        detail.begin()
        do {
            detail = .loaded(try await client.get("/cloud/resources/\(resource.id)",
                                                  query: ["days": "30"]))
        } catch let error as APIError {
            if !error.isCancellation { detail = .failed(error) }
        } catch {
            detail = .failed(APIError.transport(error))
        }
    }
}
