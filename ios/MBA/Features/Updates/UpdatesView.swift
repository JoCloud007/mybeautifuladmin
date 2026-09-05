import SwiftUI

/// Mises à jour du parc : paquets système, piles Docker et NAS Synology.
///
/// Les trois familles n'ont ni le même rythme ni la même façon d'être
/// appliquées, mais elles répondent à la même question — qu'est-ce qui est en
/// retard, et qu'est-ce que je peux lancer depuis mon téléphone ?
struct UpdatesView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<UpdateOverview> = .idle
    @State private var activity: UpdateActivity?
    @State private var tab: UpdateTab = .hosts
    @State private var search = ""
    @State private var runner = ActionRunner()
    @State private var inspected: UpdateActivity.Entry?

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let overview = state.value {
                summarySection(overview.summary)

                switch tab {
                case .hosts: hostsTab(overview)
                case .stacks: stacksTab(overview)
                case .synology: synologyTab(overview)
                case .activity: activityTab
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
        .navigationTitle("Mises à jour")
        .searchable(text: $search, prompt: "Machine, pile, étiquette")
        .refreshable { await load() }
        .task { await load() }
        .task(id: tab) { if tab == .activity { await loadActivity() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Le relevé des NAS est mis en cache cinq minutes côté serveur :
                // ce bouton force la relecture, ce que le tirage vers le bas ne
                // fait pas — inutile de réveiller tous les NAS à chaque coup d'œil.
                Button("Interroger les NAS", systemImage: "arrow.clockwise") {
                    Task { await load(refresh: true) }
                }
            }
        }
        .sheet(item: $inspected) { entry in
            ActivityDetailSheet(entry: entry)
        }
        .actionResult(runner)
    }

    // MARK: - Synthèse

    private func summarySection(_ summary: UpdateOverview.Summary) -> some View {
        Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(summary.packages)", label: "Paquets en attente",
                             symbol: "shippingbox",
                             tint: summary.packages > 0 ? Palette.warn : Palette.ok,
                             trailing: summary.hostsPending > 0
                                 ? "sur \(Format.plural(summary.hostsPending, "machine"))" : nil)
                    StatTile(value: "\(summary.security)", label: "Sécurité",
                             symbol: "shield.lefthalf.filled",
                             tint: summary.security > 0 ? Palette.danger : Palette.ok)
                    StatTile(value: "\(summary.rebootRequired)", label: "Redémarrages",
                             symbol: "arrow.clockwise.circle",
                             tint: summary.rebootRequired > 0 ? Palette.warn : Palette.ok)
                    StatTile(value: "\(summary.synoPackages + summary.dsmPending)",
                             label: "Paquets NAS",
                             symbol: "externaldrive.connected.to.line.below",
                             tint: summary.synoPackages + summary.dsmPending > 0
                                 ? Palette.warn : Palette.ok,
                             trailing: summary.dsmPending > 0 ? "dont DSM" : nil)
                }

                if let running = activity?.running, running > 0 {
                    Button {
                        tab = .activity
                    } label: {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(Format.plural(running, "opération")) en cours")
                                .font(.footnote.weight(.medium))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color.accentColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                Picker("Vue", selection: $tab) {
                    ForEach(UpdateTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Machines

    @ViewBuilder
    private func hostsTab(_ overview: UpdateOverview) -> some View {
        let visible = overview.hosts.filter { $0.matches(normalizedSearch) }
        let pending = visible.filter { !$0.isUpToDate }
        let current = visible.filter(\.isUpToDate)

        if visible.isEmpty {
            Section {
                EmptyState(title: overview.hosts.isEmpty ? "Aucune machine à suivre" : "Aucun résultat",
                           message: overview.hosts.isEmpty
                               ? "Seules les machines que MBA sait mettre à jour, ou qui ont du retard, apparaissent ici."
                               : "Aucune machine ne correspond à « \(search) ».",
                           symbol: "checkmark.circle")
                    .listRowBackground(Color.clear)
            }
        } else {
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { host in
                        UpdateHostRow(host: host)
                            .swipeActions(edge: .trailing) {
                                if host.canRebootNow {
                                    Button("Redémarrer", systemImage: "arrow.clockwise") {
                                        confirmReboot([host])
                                    }
                                    .tint(Palette.danger)
                                }
                                if host.canUpgradeNow {
                                    Button("Mettre à jour", systemImage: "arrow.down.circle") {
                                        confirmUpgrade([host])
                                    }
                                    .tint(.accentColor)
                                }
                            }
                    }
                } header: {
                    let eligible = pending.filter(\.canUpgradeNow)
                    HStack {
                        Text("En retard · \(pending.count)")
                        Spacer()
                        if !eligible.isEmpty {
                            Button("Tout mettre à jour") { confirmUpgrade(eligible) }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                } footer: {
                    Text("Balaie une machine pour la mettre à jour ou la redémarrer. MBA applique les correctifs deux machines à la fois.")
                }
            }

            if !current.isEmpty {
                Section("À jour · \(current.count)") {
                    ForEach(current) { host in
                        UpdateHostRow(host: host)
                            .swipeActions(edge: .trailing) {
                                if host.canRebootNow {
                                    Button("Redémarrer", systemImage: "arrow.clockwise") {
                                        confirmReboot([host])
                                    }
                                    .tint(Palette.danger)
                                }
                            }
                    }
                }
            }
        }
    }

    // MARK: - Piles Docker

    @ViewBuilder
    private func stacksTab(_ overview: UpdateOverview) -> some View {
        let visible = overview.stacks.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(title: overview.stacks.isEmpty ? "Aucune pile Compose" : "Aucun résultat",
                           message: overview.stacks.isEmpty
                               ? "Les piles apparaissent dès qu'un hôte Docker expose des conteneurs portant un projet Compose."
                               : "Aucune pile ne correspond à « \(search) ».",
                           symbol: "shippingbox")
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(groupedStacks(visible), id: \.host) { group in
                Section {
                    ForEach(group.stacks) { stack in
                        StackRow(stack: stack)
                            .swipeActions(edge: .trailing) {
                                Button("Mettre à jour", systemImage: "arrow.down.circle") {
                                    confirmStacks([stack])
                                }
                                .tint(.accentColor)
                            }
                    }
                } header: {
                    HStack {
                        Text("\(group.host) · \(group.stacks.count)")
                        Spacer()
                        Button("Tout mettre à jour") { confirmStacks(group.stacks) }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                    }
                }
            }
        }
    }

    // MARK: - NAS Synology

    @ViewBuilder
    private func synologyTab(_ overview: UpdateOverview) -> some View {
        if overview.synology.isEmpty {
            Section {
                EmptyState(title: "Aucun NAS Synology",
                           message: "Enregistre un NAS avec un compte DSM pour suivre ses paquets et ses mises à jour système.",
                           symbol: "externaldrive.connected.to.line.below")
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(overview.synology) { entry in
                Section {
                    if let error = entry.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.warn)
                    } else if entry.packages.isEmpty && !(entry.dsm?.available ?? false) {
                        Label(entry.reason ?? "Tout est à jour.",
                              systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(entry.reason == nil ? Palette.ok : .secondary)
                    }

                    ForEach(entry.packages) { package in
                        SynologyPackageRow(package: package)
                    }

                    if let dsm = entry.dsm {
                        DSMRow(dsm: dsm) { step in
                            confirmDSM(entry, step: step, dsm: dsm)
                        }
                    }
                } header: {
                    HStack {
                        Text(entry.name)
                        Spacer()
                        if !entry.packages.isEmpty {
                            Button("Tout mettre à jour") { confirmSynologyPackages(entry) }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Journal

    @ViewBuilder
    private var activityTab: some View {
        let entries = activity?.entries ?? []
        if entries.isEmpty {
            Section {
                EmptyState(title: "Rien à signaler",
                           message: "Aucune mise à jour ni redémarrage lancé depuis MBA au cours des 12 dernières heures.",
                           symbol: "clock.arrow.circlepath")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(entries) { entry in
                    Button {
                        inspected = entry
                    } label: {
                        ActivityRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Douze dernières heures. Touche une ligne pour lire la sortie de la commande.")
            }
        }
    }

    // MARK: - Actions

    private func confirmUpgrade(_ hosts: [UpdateHost]) {
        let names = hosts.map(\.name).joined(separator: ", ")
        let packages = hosts.reduce(0) { $0 + $1.updates }
        runner.confirm(
            hosts.count == 1 ? "Mettre à jour \(names) ?" : "Mettre à jour \(hosts.count) machines ?",
            message: "\(Format.plural(packages, "paquet")) sur \(names).\n\nMBA applique les correctifs deux machines à la fois et journalise chaque sortie.",
            confirmLabel: "Mettre à jour",
            isDestructive: false
        ) { [client = session.client] in
            guard let client else { return nil }
            let result: BatchResult = try await client.post(
                "/updates/hosts",
                body: HostBatchPayload(hostIDs: hosts.map(\.id), action: "upgrade"))
            return result.report
        }
    }

    private func confirmReboot(_ hosts: [UpdateHost]) {
        let names = hosts.map(\.name).joined(separator: ", ")
        runner.confirm(
            "Redémarrer \(names) ?",
            message: "Les services hébergés seront interrompus le temps du redémarrage.",
            confirmLabel: "Redémarrer"
        ) { [client = session.client] in
            guard let client else { return nil }
            let result: BatchResult = try await client.post(
                "/updates/hosts",
                body: HostBatchPayload(hostIDs: hosts.map(\.id), action: "reboot"))
            return result.report
        }
    }

    private func confirmStacks(_ stacks: [ComposeStack]) {
        let names = stacks.map(\.project).joined(separator: ", ")
        runner.confirm(
            stacks.count == 1 ? "Mettre à jour \(names) ?" : "Mettre à jour \(stacks.count) piles ?",
            message: "compose pull puis up -d sur \(names).\n\nLes conteneurs sont recréés : une courte interruption est attendue sur chaque pile.",
            confirmLabel: "Mettre à jour"
        ) { [client = session.client] in
            guard let client else { return nil }
            let targets = stacks.map { StackBatchPayload.Target(hostID: $0.hostID, project: $0.project) }
            let result: BatchResult = try await client.post("/updates/stacks",
                                                            body: StackBatchPayload(targets: targets))
            return result.report
        }
    }

    private func confirmSynologyPackages(_ entry: SynologyUpdateState) {
        let names = entry.packages.map(\.name).joined(separator: ", ")
        runner.confirm(
            "Mettre à jour \(Format.plural(entry.packages.count, "paquet")) ?",
            message: "Sur \(entry.name) : \(names).\n\nChaque paquet est traité séparément — un refus sur l'un n'empêche pas les autres.",
            confirmLabel: "Mettre à jour",
            isDestructive: false
        ) { [client = session.client] in
            guard let client else { return nil }
            let response = try await client.perform("/synology/\(entry.hostID)/packages/upgrade-all",
                                                    body: Empty())
            if let detail = response["detail"]?.stringValue { return detail }
            let done = response["done"]?.arrayValue?.count ?? 0
            let errors = response["errors"]?.arrayValue ?? []
            guard errors.isEmpty else {
                let details = errors.compactMap { $0["error"]?.stringValue }.joined(separator: "\n")
                return "\(Format.plural(done, "paquet")) mis à jour, \(errors.count) en échec.\n\n\(details)"
            }
            return "\(Format.plural(done, "paquet")) mis à jour."
        }
    }

    private func confirmDSM(_ entry: SynologyUpdateState, step: String, dsm: DSMUpdate) {
        let isInstall = step == "install"
        runner.confirm(
            isInstall ? "Installer DSM \(dsm.version ?? "") ?" : "Télécharger la mise à jour DSM ?",
            message: isInstall
                ? "\(entry.name) redémarrera pour appliquer la mise à jour. Tous ses services seront interrompus."
                : "La mise à jour est préparée sur \(entry.name), sans rien installer ni redémarrer.",
            confirmLabel: isInstall ? "Installer et redémarrer" : "Télécharger",
            isDestructive: isInstall
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.perform("/synology/\(entry.hostID)/dsm-update/\(step)")
            return isInstall
                ? "Installation lancée. Le NAS redémarrera de lui-même."
                : "Téléchargement lancé sur le NAS."
        }
    }

    // MARK: - Réseau

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func groupedStacks(
        _ stacks: [ComposeStack]
    ) -> [(host: String, stacks: [ComposeStack])] {
        Dictionary(grouping: stacks, by: \.hostName)
            .map { (host: $0.key, stacks: $0.value.sorted {
                $0.project.localizedStandardCompare($1.project) == .orderedAscending }) }
            .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    private func load(refresh: Bool = false) async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/updates",
                                                 query: refresh ? ["refresh": "1"] : [:]))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
        await loadActivity()
    }

    private func loadActivity() async {
        guard let client = session.client else { return }
        activity = (try? await client.get("/updates/activity")) ?? activity
    }
}

enum UpdateTab: String, CaseIterable, Identifiable {
    case hosts, stacks, synology, activity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hosts: "Machines"
        case .stacks: "Piles"
        case .synology: "NAS"
        case .activity: "Journal"
        }
    }
}

// MARK: - Lignes

private struct UpdateHostRow: View {
    let host: UpdateHost

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: host.hostKind.symbol)
                .foregroundStyle(host.isOffline ? Palette.danger : .secondary)
                .imageScale(.small)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(host.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if host.autoUpdates {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Mises à jour automatiques activées")
                    }
                }
                Text(host.os ?? host.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    if host.isOffline {
                        TagChip(text: "injoignable", symbol: "wifi.slash")
                    }
                    if host.rebootRequired {
                        StatusBadge(text: host.kernelStale ? "noyau en attente" : "redémarrage requis",
                                    color: Palette.warn, symbol: "arrow.clockwise")
                    }
                    if !host.upgradable && !host.isOffline {
                        TagChip(text: "hors gestion", symbol: "hand.raised")
                    }
                }
            }

            Spacer(minLength: 6)

            if host.updates > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(host.updates)")
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(host.securityUpdates > 0 ? Palette.danger : .primary)
                    Text(host.securityUpdates > 0
                         ? "dont \(host.securityUpdates) séc."
                         : "paquets")
                        .font(.caption2)
                        .foregroundStyle(host.securityUpdates > 0 ? Palette.danger : .secondary)
                }
            } else if !host.rebootRequired {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.ok)
                    .imageScale(.small)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct StackRow: View {
    let stack: ComposeStack

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(stack.isFullyRunning ? Palette.ok : Palette.warn)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(stack.project)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(stack.running)/\(stack.total) en marche · vu \(Format.ago(stack.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if stack.floating > 0 {
                // Une image `:latest` ne dit pas si elle est à jour : seul un
                // `pull` tranche, d'où le rappel plutôt qu'un compteur.
                StatusBadge(text: "\(stack.floating) × latest", color: Palette.warn,
                            symbol: "questionmark.circle")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SynologyPackageRow: View {
    let package: SynologyPackage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: package.security ? "shield.lefthalf.filled" : "shippingbox")
                .foregroundStyle(package.security ? Palette.danger : .secondary)
                .imageScale(.small)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name)
                    .font(.subheadline)
                    .lineLimit(1)
                if let installed = package.installedVersion {
                    Text("\(installed) → \(package.version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(package.version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if package.security {
                TagChip(text: "sécurité")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct DSMRow: View {
    let dsm: DSMUpdate
    let action: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("DSM", systemImage: "gearshape.2")
                    .font(.subheadline)
                Spacer(minLength: 6)
                if dsm.available {
                    StatusBadge(text: dsm.version ?? "disponible", color: Palette.warn,
                                symbol: "arrow.down.circle.fill")
                } else {
                    StatusBadge(text: "à jour", color: Palette.ok, symbol: "checkmark.circle.fill")
                }
            }

            if let current = dsm.current {
                Text(current)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = dsm.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if dsm.available {
                let downloaded = dsm.download?.finished ?? false
                HStack(spacing: 10) {
                    if !downloaded, dsm.canDownload {
                        Button("Télécharger", systemImage: "arrow.down.circle") {
                            action("download")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    if dsm.canInstall {
                        // Installer redémarre le NAS : le bouton ne s'impose
                        // qu'une fois la mise à jour déjà téléchargée.
                        let install = Button("Installer", systemImage: "square.and.arrow.down") {
                            action("install")
                        }
                        .controlSize(.small)
                        .tint(Palette.danger)

                        if downloaded {
                            install.buttonStyle(.borderedProminent)
                        } else {
                            install.buttonStyle(.bordered)
                        }
                    }
                    Spacer(minLength: 0)
                    if let percent = dsm.download?.percent, !(dsm.download?.isIdle ?? true) {
                        Text(Format.percent(percent, digits: 0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ActivityRow: View {
    let entry: UpdateActivity.Entry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbol)
                .foregroundStyle(tint)
                .imageScale(.small)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.subheadline)
                    .lineLimit(1)
                Text([entry.hostName, entry.target, Format.ago(entry.startedAt)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if entry.isRunning {
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(entry.succeeded ? Palette.ok : Palette.danger)
                        .imageScale(.small)
                    if let duration = entry.duration {
                        Text(Format.duration(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        if entry.isRunning { return .accentColor }
        return entry.succeeded ? .secondary : Palette.danger
    }
}

/// Sortie brute d'une opération — c'est là qu'on lit pourquoi `apt` a refusé.
private struct ActivityDetailSheet: View {
    let entry: UpdateActivity.Entry

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    SectionBox("Opération", symbol: entry.symbol) {
                        VStack(spacing: 10) {
                            LabeledValue(label: "Action", value: entry.label)
                            if let host = entry.hostName {
                                LabeledValue(label: "Machine", value: host)
                            }
                            if let target = entry.target, !target.isEmpty {
                                LabeledValue(label: "Cible", value: target)
                            }
                            LabeledValue(label: "État",
                                         value: entry.isRunning ? "en cours"
                                             : entry.succeeded ? "réussie" : "en échec")
                            LabeledValue(label: "Lancée", value: Format.fullDate(entry.startedAt))
                            if let duration = entry.duration {
                                LabeledValue(label: "Durée", value: Format.duration(duration))
                            }
                        }
                    }

                    if let excerpt = entry.excerpt, !excerpt.isEmpty {
                        SectionBox("Sortie", symbol: "text.alignleft") {
                            Text(excerpt)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        SectionBox {
                            Text(entry.isRunning
                                 ? "L'opération n'a pas encore produit de sortie."
                                 : "Aucune sortie enregistrée.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, Metrics.sectionSpacing)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(entry.hostName ?? entry.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
