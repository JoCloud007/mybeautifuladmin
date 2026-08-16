import SwiftUI

struct DashboardView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var state: Loadable<Overview> = .idle
    @State private var selectedHost: Host?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let error = state.error, state.value != nil {
                    InlineErrorBanner(error: error) { Task { await load() } }
                }
                if let overview = state.value {
                    summary(overview.summary)
                    if !overview.alerts.isEmpty { alerts(overview.alerts) }
                    hosts(overview.hosts)
                    if !overview.events.isEmpty { events(overview.events) }
                } else if state.isFailed, let error = state.error {
                    ErrorState(error: error) { Task { await load() } }
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Tableau de bord")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionIndicator() } }
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(item: $selectedHost) { host in
            HostDetailView(hostID: host.id, fallbackName: host.name)
        }
        // Déclaré une fois pour l'écran entier : accroché à une sous-vue
        // conditionnelle, le lien « Tout voir » cesserait de fonctionner dès que
        // la section qui le porte disparaît.
        .navigationDestination(for: Destination.self) { destination in
            DestinationView(destination: destination)
        }
    }

    // MARK: - Sections

    private func summary(_ summary: Overview.Summary) -> some View {
        VStack(spacing: Metrics.spacing) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2),
                      spacing: 10) {
                StatTile(value: "\(summary.hostsOnline)",
                         label: "Machines en ligne",
                         symbol: "server.rack",
                         tint: Palette.ok,
                         trailing: "/ \(summary.hostsTotal)")
                StatTile(value: "\(summary.containersRunning)",
                         label: "Conteneurs actifs",
                         symbol: "shippingbox",
                         tint: .accentColor,
                         trailing: "/ \(summary.containersTotal)")
                StatTile(value: Format.percent(summary.cpuAverage, digits: 0),
                         label: "CPU moyen",
                         symbol: "cpu",
                         tint: Palette.severity(summary.cpuAverage))
                StatTile(value: Format.percent(summary.memoryAverage, digits: 0),
                         label: "Mémoire moyenne",
                         symbol: "memorychip",
                         tint: Palette.severity(summary.memoryAverage))
            }

            HStack(spacing: 10) {
                if summary.hostsOffline > 0 {
                    StatTile(value: "\(summary.hostsOffline)", label: "Hors ligne",
                             symbol: "exclamationmark.triangle", tint: Palette.danger)
                }
                if summary.servicesTotal > 0 {
                    StatTile(value: "\(summary.servicesUp)", label: "Services OK",
                             symbol: "globe",
                             tint: summary.servicesDown > 0 ? Palette.warn : Palette.ok,
                             trailing: "/ \(summary.servicesTotal)")
                }
                if summary.updatesPending > 0 {
                    StatTile(value: "\(summary.updatesPending)", label: "Mises à jour",
                             symbol: "arrow.down.circle", tint: Palette.warn)
                }
            }
        }
    }

    private func alerts(_ alerts: [Alert]) -> some View {
        SectionBox("Alertes en cours", symbol: "bell.badge",
                   accessory: AnyView(
                    NavigationLink(value: Destination.alerts) {
                        Text("Tout voir").font(.caption)
                    })) {
            VStack(spacing: 10) {
                ForEach(alerts.prefix(4)) { alert in
                    AlertRow(alert: alert)
                }
            }
        }
    }

    private func hosts(_ hosts: [Host]) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text("Machines")
                    .font(.headline)
                Spacer()
                NavigationLink(value: Destination.hosts) {
                    Text("Tout voir").font(.caption)
                }
            }

            if hosts.isEmpty {
                SectionBox {
                    EmptyState(title: "Aucune machine",
                               message: "Ajoute un premier équipement depuis la console web, ou lance une découverte réseau.",
                               symbol: "server.rack")
                }
            } else {
                ForEach(sorted(hosts)) { host in
                    Button {
                        selectedHost = host
                    } label: {
                        HostCard(host: host)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Ce qui ne va pas remonte en tête : hors ligne, puis dégradé, puis le reste.
    private func sorted(_ hosts: [Host]) -> [Host] {
        hosts.sorted { first, second in
            let firstStatus = live.statuses[first.id] ?? first.status
            let secondStatus = live.statuses[second.id] ?? second.status
            if firstStatus != secondStatus {
                return rank(firstStatus) > rank(secondStatus)
            }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    private func rank(_ status: HostStatus) -> Int {
        switch status {
        case .offline: 3
        case .warning: 2
        case .unknown: 1
        case .online: 0
        }
    }

    private func events(_ events: [EventItem]) -> some View {
        SectionBox("Derniers évènements", symbol: "list.bullet.rectangle",
                   accessory: AnyView(
                    NavigationLink(value: Destination.events) {
                        Text("Journal").font(.caption)
                    })) {
            VStack(spacing: 0) {
                ForEach(events.prefix(6)) { event in
                    EventRow(event: event)
                    if event.id != events.prefix(6).last?.id {
                        Divider().padding(.vertical, 6)
                    }
                }
            }
        }
    }

    // MARK: - Chargement

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let overview: Overview = try await client.get("/overview")
            state = .loaded(overview)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

/// Témoin de connexion au flux temps réel, dans la barre de navigation.
struct ConnectionIndicator: View {
    @Environment(LiveStore.self) private var live

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(live.isConnected ? Palette.ok : Palette.warn)
                .frame(width: 7, height: 7)
            Text(live.isConnected ? "Direct" : "Reconnexion…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .animation(.smooth, value: live.isConnected)
        .accessibilityLabel(live.isConnected ? "Flux temps réel connecté" : "Flux temps réel interrompu")
    }
}

struct AlertRow: View {
    let alert: Alert

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: alert.severity.symbol)
                .foregroundStyle(alert.severity.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.message)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let host = alert.hostName {
                        Text(host)
                    }
                    if let started = alert.startedAt {
                        Text("·")
                        Text(Format.ago(started))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let value = alert.value {
                Text(Format.number(value, digits: 1))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(alert.severity.color)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct EventRow: View {
    let event: EventItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.level.symbol)
                .font(.caption)
                .foregroundStyle(event.level.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .font(.footnote)
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Text(event.source)
                    if let host = event.hostName {
                        Text("·")
                        Text(host)
                    }
                    Spacer(minLength: 4)
                    Text(Format.ago(event.time))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
