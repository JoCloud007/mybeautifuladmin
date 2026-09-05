import SwiftUI

/// Agents IA : des modèles à qui l'on confie un périmètre et un mandat.
///
/// L'écran s'ouvre sur les propositions en attente, parce que c'est la seule
/// chose qui réclame vraiment une personne : un agent analyse tout seul, mais
/// il ne touche à rien sans qu'on ait tranché — sauf mandat automatique, que
/// l'écran signale partout où il s'applique.
struct AgentsView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<AgentList> = .idle
    @State private var catalog: AgentCatalog?
    @State private var tab: AgentTab = .pending
    @State private var search = ""
    @State private var runner = ActionRunner()
    @State private var isCreating = false

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let list = state.value {
                summarySection(list)

                switch tab {
                case .pending: pendingTab(list)
                case .agents: agentsTab(list)
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
        .navigationTitle("Agents IA")
        .searchable(text: $search, prompt: "Agent, modèle, machine")
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Nouvel agent", systemImage: "plus") { isCreating = true }
                    .disabled(catalog == nil)
            }
        }
        .sheet(isPresented: $isCreating) {
            if let catalog {
                AgentEditor(catalog: catalog) { payload in
                    guard let client = session.client else { return }
                    let _: JSONValue = try await client.post("/agents", body: payload)
                    await load()
                }
            }
        }
        .navigationDestination(for: Agent.self) { agent in
            AgentDetailView(agent: agent,
                            onRun: { confirmRun(agent) },
                            onToggle: { await toggle(agent) },
                            onDelete: { confirmDelete(agent) },
                            onDecide: { proposal, approve in decide(proposal, approve: approve) })
        }
        .actionResult(runner)
    }

    // MARK: - Synthèse

    private func summarySection(_ list: AgentList) -> some View {
        let active = list.agents.filter(\.enabled)
        let autonomous = active.filter { $0.mode.actsAlone }
        let running = list.agents.filter(\.running)

        return Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(active.count)", label: "Agents actifs",
                             symbol: "person.2.badge.gearshape",
                             tint: active.isEmpty ? Palette.idle : Palette.ok,
                             trailing: "/ \(list.agents.count)")
                    StatTile(value: "\(list.pending.count)", label: "À trancher",
                             symbol: "hand.raised.fill",
                             tint: list.pending.isEmpty ? Palette.idle : Palette.warn)
                }

                if !autonomous.isEmpty {
                    // Un agent qui agit seul est le seul cas où MBA modifie
                    // l'infrastructure sans qu'on ait rien demandé.
                    Label("\(Format.plural(autonomous.count, "agent")) agi\(autonomous.count > 1 ? "ssent" : "t") sans validation.",
                          systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !running.isEmpty {
                    Label("\(Format.plural(running.count, "agent")) en cours d'analyse.",
                          systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Picker("Vue", selection: $tab) {
                    ForEach(AgentTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Propositions

    @ViewBuilder
    private func pendingTab(_ list: AgentList) -> some View {
        let visible = list.pending.filter {
            normalizedSearch.isEmpty
                || $0.summary.lowercased().contains(normalizedSearch)
                || ($0.agentName?.lowercased().contains(normalizedSearch) ?? false)
        }
        if visible.isEmpty {
            Section {
                EmptyState(
                    title: list.pending.isEmpty ? "Rien à trancher" : "Aucun résultat",
                    message: list.pending.isEmpty
                        ? "Aucun agent n'attend de décision. Une proposition apparaît ici dès qu'un agent estime qu'un geste s'impose — à toi de l'accorder ou non."
                        : "Aucune proposition ne correspond à « \(search) ».",
                    symbol: "checkmark.seal")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(visible.sorted { $0.severity.rank < $1.severity.rank }) { proposal in
                    ProposalRow(proposal: proposal,
                                onApprove: { decide(proposal, approve: true) },
                                onReject: { decide(proposal, approve: false) })
                }
            } footer: {
                Text("Approuver exécute l'action immédiatement, sur la machine visée. Refuser la classe sans rien faire.")
            }
        }
    }

    // MARK: - Agents

    @ViewBuilder
    private func agentsTab(_ list: AgentList) -> some View {
        let visible = list.agents.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(
                    title: list.agents.isEmpty ? "Aucun agent" : "Aucun résultat",
                    message: list.agents.isEmpty
                        ? "Un agent lit l'état du parc, le donne à un modèle local, et rapporte ce qu'il en conclut. En observation il ne fait qu'analyser ; il faut le lui dire explicitement pour qu'il propose ou qu'il agisse."
                        : "Aucun agent ne correspond à « \(search) ».",
                    symbol: "person.2.badge.gearshape",
                    actionTitle: list.agents.isEmpty && catalog != nil ? "Créer un agent" : nil,
                    action: list.agents.isEmpty ? { isCreating = true } : nil)
                    .listRowBackground(Color.clear)
            }
        } else {
            let active = visible.filter(\.enabled)
            let paused = visible.filter { !$0.enabled }
            if !active.isEmpty {
                Section("Actifs · \(active.count)") {
                    ForEach(active) { agent in agentRow(agent) }
                }
            }
            if !paused.isEmpty {
                Section("Suspendus · \(paused.count)") {
                    ForEach(paused) { agent in agentRow(agent) }
                }
            }
        }
    }

    private func agentRow(_ agent: Agent) -> some View {
        NavigationLink(value: agent) {
            AgentRow(agent: agent)
        }
        .swipeActions(edge: .trailing) {
            Button("Supprimer", systemImage: "trash", role: .destructive) {
                confirmDelete(agent)
            }
            Button(agent.enabled ? "Suspendre" : "Activer",
                   systemImage: agent.enabled ? "pause" : "play") {
                Task { await toggle(agent) }
            }
            .tint(agent.enabled ? Palette.warn : Palette.ok)
        }
        .swipeActions(edge: .leading) {
            Button("Exécuter", systemImage: "play.fill") { confirmRun(agent) }
                .tint(.accentColor)
                .disabled(agent.running)
        }
    }

    // MARK: - Actions

    private func decide(_ proposal: AgentProposal, approve: Bool) {
        guard approve else {
            Task {
                await runner.run("Proposition refusée") { [client = session.client] in
                    guard let client else { return nil }
                    let _: JSONValue = try await client.post(
                        "/agents/proposals/\(proposal.id)/decide",
                        body: AgentDecision(approve: false))
                    return "« \(proposal.summary) » a été écartée."
                }
                await load()
            }
            return
        }

        runner.confirm(
            "Approuver « \(proposal.displayLabel) » ?",
            message: "\(proposal.summary).\n\nL'action est exécutée tout de suite sur la machine visée.\n\nMotif avancé par l'agent : \(proposal.reason ?? "aucun")",
            confirmLabel: "Approuver",
            isDestructive: proposal.severity.rank <= FindingSeverity.high.rank
        ) { [client = session.client] in
            guard let client else { return nil }
            let response = try await client.perform(
                "/agents/proposals/\(proposal.id)/decide",
                body: AgentDecision(approve: true))
            let detail = response["result"]?.stringValue ?? response["output"]?.stringValue
            guard let detail, !detail.isEmpty else { return "Action exécutée." }
            return "Action exécutée.\n\n\(detail.prefix(600))"
        }
        Task { await reloadSoon() }
    }

    private func confirmRun(_ agent: Agent) {
        runner.confirm(
            "Exécuter « \(agent.name) » ?",
            message: agent.mode.actsAlone
                ? "L'agent analyse \(agent.scopeSummary) et exécutera lui-même les actions réversibles qu'il juge nécessaires, dans la limite de \(agent.maxActions)."
                : "L'agent analyse \(agent.scopeSummary) et déposera ses propositions ici. Rien ne sera exécuté sans ta décision.",
            confirmLabel: "Exécuter",
            isDestructive: agent.mode.actsAlone
        ) { [client = session.client] in
            guard let client else { return nil }
            let response = try await client.perform("/agents/\(agent.id)/run")
            let summary = response["summary"]?.stringValue
            let count = response["proposals"]?.arrayValue?.count
            return [summary, count.map { "\(Format.plural($0, "proposition")) déposée\($0 > 1 ? "s" : "")." }]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }
        Task { await reloadSoon() }
    }

    private func confirmDelete(_ agent: Agent) {
        runner.confirm(
            "Supprimer « \(agent.name) » ?",
            message: "L'agent est retiré définitivement, avec son historique d'exécutions et ses propositions.",
            confirmLabel: "Supprimer"
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.delete("/agents/\(agent.id)")
            return "Agent supprimé."
        }
        Task { await reloadSoon() }
    }

    private func toggle(_ agent: Agent) async {
        guard let client = session.client else { return }
        let enabling = !agent.enabled
        await runner.run(enabling ? "Agent activé" : "Agent suspendu") {
            let _: JSONValue = try await client.patch("/agents/\(agent.id)",
                                                      body: AgentUpdate(enabled: enabling))
            return enabling
                ? "« \(agent.name) » repartira à sa prochaine échéance."
                : "« \(agent.name) » n'analysera plus rien tant qu'il est suspendu."
        }
        await load()
    }

    // MARK: - Données

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/agents"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
        if catalog == nil {
            catalog = try? await client.get("/agents/catalog")
        }
    }

    private func reloadSoon() async {
        try? await Task.sleep(for: .seconds(2))
        await load()
    }
}

enum AgentTab: String, CaseIterable, Identifiable {
    case pending, agents

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pending: "À trancher"
        case .agents: "Agents"
        }
    }
}

// MARK: - Lignes

private struct AgentRow: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.running ? "clock.arrow.circlepath" : agent.mode.symbol)
                .foregroundStyle(agent.mode.actsAlone ? Palette.warn
                                 : agent.enabled ? Color.accentColor : Color.secondary)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text([agent.model, agent.endpointName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    StatusBadge(text: agent.mode.label,
                                color: agent.mode.actsAlone ? Palette.warn : Palette.ok,
                                symbol: agent.mode.symbol)
                    TagChip(text: "\(agent.scopeCount) machines")
                    if agent.pending > 0 {
                        StatusBadge(text: "\(agent.pending) en attente", color: Palette.warn,
                                    symbol: "hand.raised.fill")
                    }
                    if !agent.endpointReachable {
                        StatusBadge(text: "serveur IA muet", color: Palette.danger,
                                    symbol: "exclamationmark.triangle.fill")
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                if let succeeded = agent.lastSucceeded {
                    Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(succeeded ? Palette.ok : Palette.danger)
                }
                Text(Format.ago(agent.lastRun))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .opacity(agent.enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}

private struct ProposalRow: View {
    let proposal: AgentProposal
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: proposal.severity.symbol)
                    .foregroundStyle(proposal.severity.color)
                    .imageScale(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.summary)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = proposal.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 5) {
                        if let agent = proposal.agentName {
                            TagChip(text: agent, symbol: "person.2.badge.gearshape")
                        }
                        if proposal.autoCapable {
                            TagChip(text: "réversible")
                        }
                        Text(Format.ago(proposal.createdAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    onApprove()
                } label: {
                    Label("Approuver", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    onReject()
                } label: {
                    Label("Refuser", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
