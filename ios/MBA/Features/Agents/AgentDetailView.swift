import SwiftUI

/// La fiche d'un agent : son mandat, ses garde-fous, et ce qu'il a conclu.
struct AgentDetailView: View {
    let agent: Agent
    let onRun: () -> Void
    let onToggle: () async -> Void
    let onDelete: () -> Void
    let onDecide: (AgentProposal, Bool) -> Void

    @Environment(SessionStore.self) private var session

    @State private var runs: Loadable<[AgentRun]> = .idle

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                mandate
                guardrails
                history
                actions
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(agent.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadRuns() }
        .task { await loadRuns() }
    }

    // MARK: - Mandat

    private var mandate: some View {
        SectionBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StatusBadge(text: agent.enabled ? "actif" : "suspendu",
                                color: agent.enabled ? Palette.ok : Palette.idle,
                                symbol: agent.enabled ? "play.fill" : "pause.fill")
                    Spacer(minLength: 6)
                    StatusBadge(text: agent.mode.label,
                                color: agent.mode.actsAlone ? Palette.warn : Palette.ok,
                                symbol: agent.mode.symbol)
                }

                if let description = agent.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if agent.mode.actsAlone {
                    Label("Cet agent exécute lui-même les actions réversibles qu'il juge nécessaires, sans validation.",
                          systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !agent.endpointReachable {
                    Label("Le serveur d'inférence ne répond pas : l'agent échouera tant qu'il reste muet.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Garde-fous

    private var guardrails: some View {
        SectionBox("Cadre", symbol: "shield.lefthalf.filled") {
            VStack(spacing: 10) {
                LabeledValue(label: "Modèle", value: agent.model)
                LabeledValue(label: "Serveur", value: agent.endpointName)
                LabeledValue(label: "Périmètre",
                             value: "\(agent.scopeSummary) · \(Format.plural(agent.scopeCount, "machine"))")
                LabeledValue(label: "Plafond", value: "\(agent.maxActions) actions par exécution")
                LabeledValue(label: "Planification",
                             value: agent.isScheduled ? agent.cron : "sur commande uniquement",
                             monospaced: agent.isScheduled)
                if let next = agent.nextRun {
                    LabeledValue(label: "Prochaine", value: Format.fullDate(next))
                }
                LabeledValue(label: "Dernière",
                             value: agent.lastRun == nil
                                 ? "jamais"
                                 : "\(Format.fullDate(agent.lastRun)) (\(agent.lastStatus ?? "?"))")

                if !agent.allowedActions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Actions autorisées")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Ce que l'agent a le droit de proposer borne tout le
                        // reste : le mode ne fait qu'en régler l'usage.
                        ForEach(agent.allowedActions, id: \.self) { action in
                            Label(action, systemImage: "checkmark.circle")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Historique

    @ViewBuilder
    private var history: some View {
        SectionBox("Exécutions", symbol: "clock.arrow.circlepath") {
            switch runs {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            case .failed(let error):
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loaded(let history):
                if history.isEmpty {
                    Text("Cet agent n'a jamais tourné.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(history) { run in
                            RunBlock(run: run, onDecide: onDecide)
                            if run.id != history.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Commandes

    private var actions: some View {
        SectionBox {
            VStack(spacing: 10) {
                Button(action: onRun) {
                    Label(agent.running ? "Analyse en cours…" : "Exécuter maintenant",
                          systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(agent.running)

                Button {
                    Task { await onToggle() }
                } label: {
                    Label(agent.enabled ? "Suspendre" : "Activer",
                          systemImage: agent.enabled ? "pause" : "play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: onDelete) {
                    Label("Supprimer", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Palette.danger)
            }
        }
    }

    // MARK: - Données

    private func loadRuns() async {
        guard let client = session.client else { return }
        runs.begin()
        do {
            runs = .loaded(try await client.get("/agents/\(agent.id)/runs",
                                                query: ["limit": "20"]))
        } catch let error as APIError {
            if !error.isCancellation { runs = .failed(error) }
        } catch {
            runs = .failed(APIError.transport(error))
        }
    }
}

// MARK: - Une exécution

private struct RunBlock: View {
    let run: AgentRun
    let onDecide: (AgentProposal, Bool) -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(Format.dateTime(run.startedAt))
                    .font(.caption.monospacedDigit())
                Text("· \(run.statusLabel) · \(run.triggerLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let duration = run.duration {
                    Text(Format.duration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            if let summary = run.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = run.error, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(run.proposals) { proposal in
                RunProposalRow(proposal: proposal, onDecide: onDecide)
            }

            // Le raisonnement complet est long : il se déplie à la demande.
            if let analysis = run.analysis, !analysis.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    Text(analysis)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } label: {
                    Text("Analyse du modèle")
                        .font(.caption.weight(.medium))
                }
            }
        }
    }

    private var tint: Color {
        if run.isRunning { return .accentColor }
        return run.succeeded ? Palette.ok : Palette.danger
    }
}

private struct RunProposalRow: View {
    let proposal: AgentProposal
    let onDecide: (AgentProposal, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: proposal.severity.symbol)
                    .foregroundStyle(proposal.severity.color)
                    .imageScale(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.summary)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = proposal.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let result = proposal.result, !result.isEmpty {
                        Text(result)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(4)
                    }
                }
                Spacer(minLength: 4)
                StatusBadge(text: proposal.stateLabel, color: stateColor)
            }

            if proposal.isPending {
                HStack(spacing: 10) {
                    Button("Approuver") { onDecide(proposal, true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    Button("Refuser") { onDecide(proposal, false) }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
        .padding(.leading, 4)
    }

    private var stateColor: Color {
        switch proposal.state {
        case "executed": Palette.ok
        case "pending": Palette.warn
        case "failed": Palette.danger
        default: Palette.idle
        }
    }
}
