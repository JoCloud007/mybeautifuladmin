import Charts
import SwiftUI

struct ServicesView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var state: Loadable<[WebService]> = .idle
    @State private var search = ""
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let services = state.value {
                if !services.isEmpty { summarySection(services) }

                let visible = filtered(services)
                if visible.isEmpty {
                    Section {
                        EmptyState(
                            title: services.isEmpty ? "Aucun service" : "Aucun résultat",
                            message: services.isEmpty
                                ? "Ajoute une sonde HTTP depuis la console web pour surveiller la disponibilité d'un service."
                                : "Aucun service ne correspond à « \(search) ».",
                            symbol: "globe")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(grouped(visible), id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.services) { service in
                                NavigationLink(value: service) {
                                    ServiceRow(service: service, liveStatus: liveStatus(service))
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Vérifier", systemImage: "arrow.clockwise") {
                                        Task { await check(service) }
                                    }
                                    .tint(.accentColor)
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
        .navigationTitle("Services web")
        .searchable(text: $search, prompt: "Nom, adresse, groupe")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: WebService.self) { service in
            ServiceDetailView(service: service)
        }
        .actionResult(runner)
    }

    /// Le flux pousse `{"topic":"service", …}` à chaque contrôle : un service qui
    /// tombe change de couleur sans attendre le rafraîchissement de la liste.
    private func liveStatus(_ service: WebService) -> String? {
        live.services[service.id]?["status"]?.stringValue
    }

    private func summarySection(_ services: [WebService]) -> some View {
        let down = services.filter { (liveStatus($0) ?? $0.status) == "down" }
        let expiring = services.filter(\.certificateNeedsAttention)
        return Section {
            HStack(spacing: 10) {
                StatTile(value: "\(services.count - down.count)",
                         label: "Disponibles", symbol: "checkmark.circle",
                         tint: down.isEmpty ? Palette.ok : Palette.warn,
                         trailing: "/ \(services.count)")
                if !down.isEmpty {
                    StatTile(value: "\(down.count)", label: "En panne",
                             symbol: "xmark.octagon", tint: Palette.danger)
                }
                if !expiring.isEmpty {
                    StatTile(value: "\(expiring.count)", label: "Certificats",
                             symbol: "lock.trianglebadge.exclamationmark", tint: Palette.warn)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    private func filtered(_ services: [WebService]) -> [WebService] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return services }
        return services.filter {
            $0.name.lowercased().contains(query)
                || $0.url.lowercased().contains(query)
                || ($0.groupName?.lowercased().contains(query) ?? false)
        }
    }

    private func grouped(_ services: [WebService]) -> [(key: String, services: [WebService])] {
        Dictionary(grouping: services, by: { $0.groupName ?? "Sans groupe" })
            .map { (key: $0.key, services: $0.value.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { first, second in
                if (first.key == "Sans groupe") != (second.key == "Sans groupe") {
                    return second.key == "Sans groupe"
                }
                return first.key.localizedStandardCompare(second.key) == .orderedAscending
            }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let services: [WebService] = try await client.get("/services")
            state = .loaded(services)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    private func check(_ service: WebService) async {
        guard let client = session.client else { return }
        await runner.run("Contrôle de \(service.name)") {
            let response = try await client.perform("/services/\(service.id)/check")
            let status = response["status"]?.stringValue ?? "?"
            let latency = response["last_latency_ms"]?.doubleValue
            return status == "up"
                ? "Disponible en \(Format.milliseconds(latency))."
                : "Indisponible (\(status))."
        }
        await load()
    }
}

struct ServiceRow: View {
    let service: WebService
    var liveStatus: String?

    private var status: String { liveStatus ?? service.status }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Palette.serviceStatus(status))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name)
                    .lineLimit(1)
                Text(service.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.milliseconds(service.lastLatencyMilliseconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(status == "up" ? .primary : Palette.danger)
                if service.uptime24h > 0 {
                    Text("\(Format.number(service.uptime24h, digits: 1)) % / 24 h")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(service.uptime24h >= 99.5 ? .secondary : Palette.warn)
                }
            }

            if service.certificateNeedsAttention {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(Palette.warn)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Détail

struct ServiceDetailView: View {
    let service: WebService

    @Environment(SessionStore.self) private var session

    @State private var history: ServiceHistory?
    @State private var range: ServiceRange = .day
    @State private var isLoading = false
    @State private var runner = ActionRunner()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                summary
                chartSection
                if let certificate = certificateSection { certificate }
                configuration
                if let incidents = history?.incidents, !incidents.isEmpty {
                    incidentsSection(incidents)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Vérifier", systemImage: "arrow.clockwise") {
                    Task { await check() }
                }
            }
        }
        .task(id: range) { await loadHistory() }
        .actionResult(runner)
    }

    private var summary: some View {
        SectionBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusBadge(text: service.isUp ? "Disponible" : "En panne",
                                color: Palette.serviceStatus(service.status),
                                symbol: service.isUp ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    Spacer()
                    Text(Format.ago(service.lastChecked))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Link(destination: URL(string: service.url) ?? URL(string: "https://example.invalid")!) {
                    HStack(spacing: 4) {
                        Text(service.url)
                            .font(.footnote)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                }
                HStack(spacing: 16) {
                    LabeledValue(label: "Latence",
                                 value: Format.milliseconds(service.lastLatencyMilliseconds))
                    LabeledValue(label: "24 h",
                                 value: "\(Format.number(service.uptime24h, digits: 2)) %")
                }
            }
        }
    }

    private var chartSection: some View {
        SectionBox("Historique", symbol: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Fenêtre", selection: $range) {
                    ForEach(ServiceRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if isLoading, history == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 140)
                } else if let history, !history.points.isEmpty {
                    MetricChart(title: "Latence", unit: "ms",
                                formatter: { Format.milliseconds($0) },
                                series: [("Latence", history.latencyPoints, .accentColor)])
                    MetricChart(title: "Disponibilité", unit: "%",
                                series: [("Disponibilité", history.uptimePoints, Palette.ok)])
                } else {
                    Text("Aucun contrôle sur cette période.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 70)
                }
            }
        }
    }

    private var certificateSection: AnyView? {
        guard let expires = service.sslExpiresAt else { return nil }
        let days = service.certificateDaysRemaining ?? 0
        return AnyView(
            SectionBox("Certificat TLS", symbol: "lock.shield") {
                VStack(spacing: 10) {
                    LabeledValue(label: "Expire le", value: Format.fullDate(expires))
                    LabeledValue(label: "Reste",
                                 value: days < 0 ? "expiré" : Format.plural(days, "jour"))
                    if let issuer = service.sslIssuer {
                        LabeledValue(label: "Émetteur", value: issuer)
                    }
                    if service.certificateNeedsAttention {
                        Label(days < 0
                              ? "Le certificat est expiré."
                              : "Renouvellement à surveiller — un échec silencieux de Let's Encrypt se voit d'abord ici.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            })
    }

    private var configuration: some View {
        SectionBox("Sonde", symbol: "slider.horizontal.3") {
            VStack(spacing: 10) {
                LabeledValue(label: "Méthode", value: service.method)
                LabeledValue(label: "Code attendu", value: String(service.expectStatus))
                if let body = service.expectBody, !body.isEmpty {
                    LabeledValue(label: "Contenu attendu", value: body, monospaced: true)
                }
                LabeledValue(label: "Intervalle",
                             value: Format.duration(Double(service.intervalSeconds)))
                if let host = service.hostName {
                    LabeledValue(label: "Machine", value: host)
                }
                LabeledValue(label: "Sonde", value: service.enabled ? "Active" : "Suspendue")
            }
        }
    }

    private func incidentsSection(_ incidents: [ServiceHistory.Incident]) -> some View {
        SectionBox("Incidents", symbol: "exclamationmark.bubble") {
            VStack(spacing: 0) {
                ForEach(incidents.prefix(20)) { incident in
                    HStack(alignment: .top, spacing: 10) {
                        Text(Format.dateTime(incident.time))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            if let code = incident.statusCode, code > 0 {
                                Text("HTTP \(code)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Palette.danger)
                            }
                            if let error = incident.error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    if incident.id != incidents.prefix(20).last?.id { Divider() }
                }
            }
        }
    }

    private func loadHistory() async {
        guard let client = session.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            history = try await client.get("/services/\(service.id)/history",
                                           query: ["range": range.rawValue])
        } catch {
            history = nil
        }
    }

    private func check() async {
        guard let client = session.client else { return }
        await runner.run("Contrôle immédiat") {
            let response = try await client.perform("/services/\(service.id)/check")
            let status = response["status"]?.stringValue ?? "?"
            let latency = response["last_latency_ms"]?.doubleValue
            return status == "up"
                ? "Disponible en \(Format.milliseconds(latency))."
                : "Indisponible (\(status))."
        }
        await loadHistory()
    }
}
