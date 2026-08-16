import SwiftUI

struct AlertsView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<[Alert]> = .idle
    @State private var scope: Scope = .firing
    @State private var runner = ActionRunner()

    private enum Scope: String, CaseIterable, Identifiable {
        case firing, acked, resolved
        var id: String { rawValue }
        var label: String {
            switch self {
            case .firing: "En cours"
            case .acked: "Acquittées"
            case .resolved: "Résolues"
            }
        }
    }

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            if let alerts = state.value {
                if alerts.isEmpty {
                    Section {
                        EmptyState(
                            title: scope == .firing ? "Rien à signaler" : "Aucune alerte",
                            message: scope == .firing
                                ? "Aucune alerte n'est déclenchée sur ton infrastructure."
                                : "Aucune alerte dans cet état.",
                            symbol: scope == .firing ? "checkmark.seal" : "bell.slash")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(grouped(alerts), id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.value) { alert in
                                AlertDetailRow(alert: alert)
                                    .swipeActions(edge: .trailing) {
                                        if alert.isFiring {
                                            Button("Acquitter", systemImage: "checkmark") {
                                                Task { await acknowledge(alert) }
                                            }
                                            .tint(Palette.ok)
                                        }
                                    }
                            }
                        }
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
        .navigationTitle("Alertes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("État", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
            }
        }
        .refreshable { await load() }
        .task(id: scope) { await load() }
        .actionResult(runner)
    }

    /// Le critique d'abord : c'est ce qui décide s'il faut se lever la nuit.
    private func grouped(_ alerts: [Alert]) -> [(key: String, value: [Alert])] {
        Dictionary(grouping: alerts, by: \.severity)
            .sorted { $0.key > $1.key }
            .map { (key: $0.key.label, value: $0.value.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }) }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let alerts: [Alert] = try await client.get("/alerts", query: ["state": scope.rawValue])
            state = .loaded(alerts)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    private func acknowledge(_ alert: Alert) async {
        guard let client = session.client else { return }
        await runner.run("Acquittement") {
            try await client.perform("/alerts/\(alert.id)/ack")
            return "Alerte acquittée."
        }
        await load()
    }
}

struct AlertDetailRow: View {
    let alert: Alert

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LeadingAccent(color: alert.severity.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.message)
                    .font(.subheadline)
                HStack(spacing: 6) {
                    if let rule = alert.ruleName {
                        Text(rule)
                    }
                    if let host = alert.hostName {
                        Text("·")
                        Text(host)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(Format.ago(alert.startedAt))
                    if let value = alert.value {
                        Text("·")
                        Text("valeur \(Format.number(value, digits: 1))")
                    }
                    if alert.state == "acked" {
                        Text("·")
                        Text("acquittée")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
