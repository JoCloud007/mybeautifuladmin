import SwiftUI

/// Point d'entrée du terminal : sessions en cours, puis choix d'une machine.
struct TerminalView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<TerminalSessionsResponse> = .idle
    @State private var hosts: [Host] = []
    @State private var runner = ActionRunner()
    @State private var target: TerminalTarget?

    /// Destination d'ouverture, qu'il s'agisse d'une reprise ou d'un nouveau shell.
    private struct TerminalTarget: Hashable, Identifiable {
        let hostID: Int
        let hostName: String
        var container: String?
        var resuming: TerminalSession?
        var id: String { "\(hostID)-\(container ?? "")-\(resuming?.id ?? "new")" }
    }

    /// Seuls les hôtes Linux et Docker acceptent un shell : sur un DSM ou un BMC,
    /// l'API refuserait la session.
    private var connectableHosts: [Host] {
        hosts.filter { $0.kind.supportsTerminal }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if let response = state.value, !response.sessions.isEmpty {
                Section {
                    ForEach(response.sessions) { item in
                        Button {
                            target = TerminalTarget(hostID: item.hostID,
                                                    hostName: item.hostName ?? item.label,
                                                    container: item.container,
                                                    resuming: item)
                        } label: {
                            SessionRow(session: item)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Fermer", systemImage: "xmark", role: .destructive) {
                                Task { await close(item) }
                            }
                        }
                    }
                } header: {
                    Text("Sessions ouvertes")
                } footer: {
                    Text("Un shell continue de tourner sur le serveur après la fermeture de l'app. Reprendre une session rejoue les dernières lignes.")
                }
            }

            Section("Ouvrir un shell") {
                if connectableHosts.isEmpty {
                    Text("Aucune machine Linux ou Docker enregistrée.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                } else {
                    ForEach(connectableHosts) { host in
                        Button {
                            target = TerminalTarget(hostID: host.id, hostName: host.name)
                        } label: {
                            HStack {
                                HostRow(host: host)
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        // Sans style explicite, une ligne de liste bâtie sur un
                        // bouton se colore entièrement à la teinte de l'app.
                        .buttonStyle(.plain)
                        .disabled(host.status == .offline)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if state.isEmptyLoading, !state.isFailed, hosts.isEmpty {
                ProgressView().controlSize(.large)
            } else if let error = state.error, state.value == nil {
                ErrorState(error: error) { Task { await load() } }
            }
        }
        .navigationTitle("Terminal")
        .refreshable { await load() }
        .task {
            await load()
            #if DEBUG
            if let hostID = DebugLaunch.terminalHostID,
               let host = hosts.first(where: { $0.id == hostID }) {
                target = TerminalTarget(hostID: host.id, hostName: host.name)
            }
            #endif
        }
        .navigationDestination(item: $target) { target in
            TerminalScreen(hostID: target.hostID, hostName: target.hostName,
                           container: target.container, resuming: target.resuming)
        }
        .actionResult(runner)
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            async let sessions: TerminalSessionsResponse = client.get("/terminal/sessions")
            async let hostList: [Host] = client.get("/hosts")
            let (response, loadedHosts) = try await (sessions, hostList)
            hosts = loadedHosts
            state = .loaded(response)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    private func close(_ item: TerminalSession) async {
        guard let client = session.client else { return }
        await runner.run("Fermeture de la session") {
            try await client.delete("/terminal/sessions/\(item.id)")
            return "Le shell a été terminé."
        }
        await load()
    }
}

private struct SessionRow: View {
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.container == nil ? "terminal" : "shippingbox")
                .foregroundStyle(session.isAttached ? Palette.ok : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if session.isAttached {
                        Text("attachée")
                    } else if let remaining = session.expiresIn {
                        Text("expire dans \(Format.duration(remaining))")
                    } else {
                        Text("détachée · \(session.ttlLabel)")
                    }
                    if session.buffered > 0 {
                        Text("·")
                        Text("\(Format.bytes(Double(session.buffered), digits: 0)) en attente")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}
