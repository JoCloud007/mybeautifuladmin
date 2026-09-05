import SwiftUI

/// Audit de sécurité du parc : correctifs manquants, obsolescence, durcissement.
///
/// L'analyse tourne côté serveur toutes les quinze minutes ; l'écran se contente
/// de la lire, avec un bouton pour la relancer quand on vient de corriger.
struct SecurityView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<SecurityOverview> = .idle
    @State private var muted: [SecurityFinding] = []
    @State private var resolved: [SecurityFinding] = []
    @State private var tab: SecurityTab = .findings
    @State private var search = ""
    @State private var severityFilter: Set<FindingSeverity> = []
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let overview = state.value {
                summarySection(overview.summary)

                switch tab {
                case .findings: findingsTab(overview)
                case .hosts: hostsTab(overview)
                case .muted: mutedTab
                case .resolved: resolvedTab
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
        .navigationTitle("Sécurité")
        .searchable(text: $search, prompt: "Constat, machine, code")
        .refreshable { await reloadAll() }
        .task { await load() }
        .task(id: tab) { await loadTabContents() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Relancer l'analyse", systemImage: "arrow.clockwise") {
                    Task { await rescan() }
                }
            }
        }
        .navigationDestination(for: SecurityFinding.self) { finding in
            FindingDetailView(finding: finding) { value in
                await mute(finding, value)
            }
        }
        .navigationDestination(for: Int.self) { hostID in
            HostDetailView(hostID: hostID, fallbackName: hostName(hostID) ?? "Machine")
        }
        .actionResult(runner)
    }

    // MARK: - Synthèse

    private func summarySection(_ summary: SecurityOverview.Summary) -> some View {
        Section {
            VStack(spacing: Metrics.spacing) {
                HStack(spacing: 14) {
                    ScoreRing(score: summary.score, size: 62, label: "Score de sécurité")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Score global")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(scoreLabel(summary.score))
                            .font(.headline)
                            .foregroundStyle(Palette.score(summary.score))
                        Text(summary.total == 0
                             ? "Aucun constat ouvert."
                             : "\(Format.plural(summary.total, "constat")) sur \(Format.plural(summary.hostsAffected, "machine")).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(summary.count(.critical))", label: "Critiques",
                             symbol: "exclamationmark.octagon",
                             tint: summary.count(.critical) > 0 ? Palette.danger : Palette.ok)
                    StatTile(value: "\(summary.count(.high))", label: "Élevés",
                             symbol: "exclamationmark.triangle",
                             tint: summary.count(.high) > 0 ? Palette.danger : Palette.ok)
                    StatTile(value: "\(summary.hostsClean)", label: "Machines saines",
                             symbol: "checkmark.shield", tint: Palette.ok,
                             trailing: "/ \(summary.hostsClean + summary.hostsAffected)")
                    StatTile(value: "\(summary.resolved7d)", label: "Résolus (7 j)",
                             symbol: "checkmark.circle", tint: Palette.ok)
                }

                // Le sélecteur vit dans la même carte que la synthèse : en
                // section séparée, l'espacement des listes groupées repoussait
                // le contenu sous la ligne de flottaison.
                Picker("Vue", selection: $tab) {
                    ForEach(SecurityTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    private func scoreLabel(_ score: Int) -> String {
        if score >= 85 { return "\(score)/100 · bon" }
        if score >= 60 { return "\(score)/100 · à surveiller" }
        return "\(score)/100 · à traiter"
    }

    // MARK: - Constats

    @ViewBuilder
    private func findingsTab(_ overview: SecurityOverview) -> some View {
        let visible = filtered(overview.findings)

        if !overview.summary.bySeverity.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(FindingSeverity.allCases) { severity in
                            let count = overview.summary.count(severity)
                            if count > 0 {
                                SeverityChip(severity: severity, count: count,
                                             isOn: severityFilter.contains(severity)) {
                                    toggle(severity)
                                }
                            }
                        }
                        if !severityFilter.isEmpty {
                            Button("Réinitialiser") { severityFilter = [] }
                                .font(.caption.weight(.medium))
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
            .listRowBackground(Color.clear)
            // Les puces prolongent le sélecteur : l'espacement standard des
            // sections creusait une bande vide entre les deux.
            .listSectionSpacing(.compact)
        }

        if visible.isEmpty {
            Section {
                EmptyState(
                    title: overview.findings.isEmpty
                        ? "Aucune vulnérabilité détectée"
                        : "Aucun constat pour ces filtres",
                    message: overview.findings.isEmpty
                        ? "Le parc est à jour et correctement durci. L'analyse tourne automatiquement toutes les 15 minutes."
                        : "Élargis les filtres pour voir le reste.",
                    symbol: "checkmark.shield")
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(grouped(visible), id: \.family) { group in
                Section {
                    ForEach(group.findings) { finding in
                        NavigationLink(value: finding) {
                            FindingRow(finding: finding)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Ignorer", systemImage: "bell.slash") {
                                Task { await mute(finding, true) }
                            }
                            .tint(Palette.idle)
                        }
                    }
                } header: {
                    Label("\(group.family.label) · \(group.findings.count)",
                          systemImage: group.family.symbol)
                }
            }
        }
    }

    // MARK: - Par machine

    @ViewBuilder
    private func hostsTab(_ overview: SecurityOverview) -> some View {
        let hosts = overview.byHost.filter {
            normalizedSearch.isEmpty || $0.name.lowercased().contains(normalizedSearch)
        }
        if hosts.isEmpty {
            Section {
                EmptyState(title: "Toutes les machines sont saines",
                           message: "Aucun constat ouvert n'est rattaché à une machine.",
                           symbol: "checkmark.shield")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(hosts) { host in
                    NavigationLink(value: host.hostID) {
                        HostScoreRow(host: host)
                    }
                }
            }
        }
    }

    // MARK: - Ignorés et résolus

    @ViewBuilder
    private var mutedTab: some View {
        let visible = muted.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(title: "Aucun constat ignoré",
                           message: "Les constats mis de côté depuis la liste principale se retrouvent ici.",
                           symbol: "bell.slash")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(visible) { finding in
                    FindingRow(finding: finding)
                        .swipeActions(edge: .trailing) {
                            Button("Réactiver", systemImage: "bell") {
                                Task { await mute(finding, false) }
                            }
                            .tint(.accentColor)
                        }
                }
            } footer: {
                Text("Balaie vers la gauche pour réactiver un constat.")
            }
        }
    }

    @ViewBuilder
    private var resolvedTab: some View {
        let visible = resolved.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(title: "Aucun constat résolu",
                           message: "Rien n'a été corrigé au cours des 30 derniers jours.",
                           symbol: "checkmark.circle")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(visible) { finding in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.ok)
                            .imageScale(.small)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title)
                                .font(.subheadline)
                                .strikethrough(color: .secondary)
                                .foregroundStyle(.secondary)
                            Text([finding.target, "corrigé \(Format.ago(finding.resolvedAt))"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } footer: {
                Text("Constats clos sur les 30 derniers jours.")
            }
        }
    }

    // MARK: - Filtres

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func toggle(_ severity: FindingSeverity) {
        if severityFilter.contains(severity) {
            severityFilter.remove(severity)
        } else {
            severityFilter.insert(severity)
        }
    }

    private func filtered(_ findings: [SecurityFinding]) -> [SecurityFinding] {
        findings.filter {
            (severityFilter.isEmpty || severityFilter.contains($0.severity))
                && $0.matches(normalizedSearch)
        }
    }

    /// Familles ordonnées par gravité du pire constat qu'elles contiennent : ce
    /// qui brûle arrive en tête, sans avoir à dérouler l'écran.
    private func grouped(
        _ findings: [SecurityFinding]
    ) -> [(family: FindingFamily, findings: [SecurityFinding])] {
        Dictionary(grouping: findings, by: \.family)
            .map { (family: $0.key, findings: $0.value.sorted { $0.severity > $1.severity }) }
            .sorted { first, second in
                let left = first.findings.first?.severity.rank ?? 9
                let right = second.findings.first?.severity.rank ?? 9
                if left != right { return left < right }
                return first.family.label.localizedStandardCompare(second.family.label) == .orderedAscending
            }
    }

    private func hostName(_ hostID: Int) -> String? {
        state.value?.byHost.first { $0.hostID == hostID }?.name
            ?? state.value?.findings.first { $0.hostID == hostID }?.hostName
    }

    // MARK: - Réseau

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/security"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    /// Les onglets « Ignorés » et « Résolus » ont leur propre requête : inutile
    /// de la lancer tant qu'on ne les ouvre pas.
    private func loadTabContents() async {
        guard let client = session.client else { return }
        switch tab {
        case .muted:
            muted = (try? await client.get("/security/muted")) ?? muted
        case .resolved:
            resolved = (try? await client.get("/security/history")) ?? resolved
        case .findings, .hosts:
            break
        }
    }

    private func reloadAll() async {
        await load()
        await loadTabContents()
    }

    private func rescan() async {
        guard let client = session.client else { return }
        await runner.run("Analyse de sécurité") {
            let response: JSONValue = try await client.perform("/security/scan")
            let total = response["summary"]?["total"]?.intValue
            let score = response["summary"]?["score"]?.intValue
            guard let total, let score else { return "Analyse terminée." }
            return total == 0
                ? "Aucun constat ouvert — score \(score)/100."
                : "\(Format.plural(total, "constat")) en attente — score \(score)/100."
        }
        await reloadAll()
    }

    private func mute(_ finding: SecurityFinding, _ value: Bool) async {
        guard let client = session.client else { return }
        await runner.run(value ? "Constat ignoré" : "Constat réactivé") {
            try await client.perform("/security/findings/\(finding.id)/mute",
                                     body: MutePayload(muted: value))
            return value
                ? "« \(finding.title) » n'apparaîtra plus dans les constats. Tu peux le réactiver depuis l'onglet « Ignorés »."
                : "« \(finding.title) » revient dans la liste des constats."
        }
        await reloadAll()
    }
}

enum SecurityTab: String, CaseIterable, Identifiable {
    case findings, hosts, muted, resolved

    var id: String { rawValue }

    var label: String {
        switch self {
        case .findings: "Constats"
        case .hosts: "Machines"
        case .muted: "Ignorés"
        case .resolved: "Résolus"
        }
    }
}

// MARK: - Lignes

private struct FindingRow: View {
    let finding: SecurityFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LeadingAccent(color: finding.severity.color)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let detail = finding.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(finding.severity.label)
                        .foregroundStyle(finding.severity.color)
                    if let target = finding.target {
                        Text("· \(target)")
                    }
                    Text("· vu \(Format.ago(finding.lastSeen))")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct HostScoreRow: View {
    let host: SecurityOverview.HostScore

    var body: some View {
        HStack(spacing: 12) {
            ScoreRing(score: host.score, size: 42, label: "Score de sécurité")
            VStack(alignment: .leading, spacing: 3) {
                Text(host.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Label(host.hostKind.label, systemImage: host.hostKind.symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(text: host.worst.label, color: host.worst.color)
                Text(Format.plural(host.count, "constat"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SeverityChip: View {
    let severity: FindingSeverity
    let count: Int
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(severity.label)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isOn ? .primary : .secondary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isOn ? Color.accentColor : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isOn ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12),
                        in: Capsule())
            .overlay {
                if isOn { Capsule().strokeBorder(Color.accentColor.opacity(0.4)) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(severity.label), \(count)")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Détail

/// Fiche d'un constat : sur un téléphone, la remédiation est un paragraphe qu'on
/// ne peut pas laisser tronqué dans une ligne de liste.
private struct FindingDetailView: View {
    let finding: SecurityFinding
    let onMute: (Bool) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                SectionBox {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusBadge(text: finding.severity.label,
                                    color: finding.severity.color,
                                    symbol: finding.severity.symbol)
                        Text(finding.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = finding.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let remediation = finding.remediation, !remediation.isEmpty {
                    SectionBox("Remédiation", symbol: "wrench.and.screwdriver") {
                        Text(remediation)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SectionBox("Origine", symbol: "info.circle") {
                    VStack(spacing: 10) {
                        if let target = finding.target {
                            LabeledValue(label: finding.hostName != nil ? "Machine" : "Service",
                                         value: target)
                        }
                        LabeledValue(label: "Contrôle", value: finding.code, monospaced: true)
                        LabeledValue(label: "Première détection",
                                     value: Format.dateTime(finding.firstSeen))
                        LabeledValue(label: "Dernière observation",
                                     value: Format.ago(finding.lastSeen))
                    }
                }

                if finding.hostID != nil || finding.isFixableOnHost {
                    actions
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(finding.severity.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(finding.muted ? "Réactiver" : "Ignorer",
                       systemImage: finding.muted ? "bell" : "bell.slash") {
                    Task {
                        await onMute(!finding.muted)
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let hostID = finding.hostID {
            SectionBox {
                NavigationLink(value: hostID) {
                    HStack {
                        Label(finding.isFixableOnHost
                              ? "Corriger depuis la machine"
                              : "Ouvrir la machine",
                              systemImage: finding.isFixableOnHost ? "arrow.down.circle" : "server.rack")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
