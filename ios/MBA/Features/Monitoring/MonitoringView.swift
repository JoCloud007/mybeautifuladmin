import Charts
import SwiftUI

/// Comparaison de métriques entre machines.
///
/// C'est l'écran qui répond à « lequel de mes serveurs sature ? » : une métrique,
/// plusieurs hôtes superposés sur la même échelle.
struct MonitoringView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var catalog: Loadable<MonitoringCatalog> = .idle
    @State private var series: MultiSeries?
    @State private var isLoadingSeries = false
    @State private var seriesError: APIError?

    @State private var selectedHosts: Set<Int> = []
    @State private var selectedMetrics: [String] = ["cpu.usage"]
    @State private var range: MetricRange = .oneHour
    @State private var showsPicker = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let catalog = catalog.value {
                    controls(catalog)
                    if selectedHosts.isEmpty {
                        EmptyState(title: "Aucune machine choisie",
                                   message: "Sélectionne au moins une machine pour tracer ses métriques.",
                                   symbol: "chart.xyaxis.line",
                                   actionTitle: "Choisir") { showsPicker = true }
                            .frame(minHeight: 240)
                    } else {
                        liveRow(catalog)
                        chartsSection(catalog)
                    }
                } else if catalog.isFailed, let error = catalog.error {
                    ErrorState(error: error) { Task { await loadCatalog() } }
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Monitoring")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SensorsView()
                } label: {
                    Label("Capteurs", systemImage: "thermometer.medium")
                }
            }
        }
        .refreshable {
            await loadCatalog()
            await loadSeries()
        }
        .task { await loadCatalog() }
        .task(id: seriesKey) { await loadSeries() }
        .sheet(isPresented: $showsPicker) {
            if let catalog = catalog.value {
                MonitoringPicker(catalog: catalog,
                                 selectedHosts: $selectedHosts,
                                 selectedMetrics: $selectedMetrics)
            }
        }
    }

    private var seriesKey: String {
        "\(selectedHosts.sorted().map(String.init).joined(separator: ","))|\(selectedMetrics.joined(separator: ","))|\(range.rawValue)"
    }

    // MARK: - Contrôles

    private func controls(_ catalog: MonitoringCatalog) -> some View {
        VStack(spacing: Metrics.spacing) {
            Picker("Fenêtre", selection: $range) {
                ForEach(MetricRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Button {
                showsPicker = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hostsSummary(catalog))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(metricsSummary(catalog))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.tint)
                }
                .padding(Metrics.cardPadding)
                .background(.background.secondary,
                            in: RoundedRectangle(cornerRadius: Metrics.cardRadius))
            }
            .buttonStyle(.plain)
        }
    }

    private func hostsSummary(_ catalog: MonitoringCatalog) -> String {
        let names = catalog.hosts.filter { selectedHosts.contains($0.id) }.map(\.name)
        if names.isEmpty { return "Aucune machine" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names[0]), \(names[1]) et \(names.count - 2) autre\(names.count - 2 > 1 ? "s" : "")"
    }

    private func metricsSummary(_ catalog: MonitoringCatalog) -> String {
        let labels = selectedMetrics.map {
            MonitoringCatalog.descriptor(for: $0, in: catalog.catalog).label
        }
        return labels.isEmpty ? "Aucune métrique" : labels.joined(separator: " · ")
    }

    // MARK: - Valeurs instantanées

    /// Ligne de valeurs temps réel, alimentée par le flux et non par l'historique :
    /// c'est ce qui permet de voir bouger un pic pendant qu'on regarde l'écran.
    private func liveRow(_ catalog: MonitoringCatalog) -> some View {
        SectionBox("En direct", symbol: "dot.radiowaves.left.and.right") {
            let descriptor = MonitoringCatalog.descriptor(
                for: selectedMetrics.first ?? "cpu.usage", in: catalog.catalog)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(orderedHosts(catalog)) { host in
                    let value = live.metric(descriptor.metric, for: host.id)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(descriptor.format(value))
                            .font(.system(.callout, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(descriptor.isPercentage
                                             ? Palette.severity(value) : .primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func orderedHosts(_ catalog: MonitoringCatalog) -> [MonitoringCatalog.CatalogHost] {
        catalog.hosts.filter { selectedHosts.contains($0.id) }
    }

    // MARK: - Graphiques

    private func chartsSection(_ catalog: MonitoringCatalog) -> some View {
        VStack(spacing: Metrics.spacing) {
            if isLoadingSeries, series == nil {
                SectionBox {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            } else if let error = seriesError {
                SectionBox { InlineErrorBanner(error: error) { Task { await loadSeries() } } }
            } else if let series, !series.isEmpty {
                ForEach(selectedMetrics, id: \.self) { metric in
                    let descriptor = MonitoringCatalog.descriptor(for: metric, in: catalog.catalog)
                    SectionBox(descriptor.label, symbol: "chart.xyaxis.line") {
                        ComparisonChart(descriptor: descriptor,
                                        hosts: orderedHosts(catalog),
                                        series: series)
                    }
                }
            } else {
                SectionBox {
                    Text("Aucun point sur cette période pour cette sélection.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
        }
    }

    // MARK: - Chargement

    private func loadCatalog() async {
        guard let client = session.client else { return }
        catalog.begin()
        do {
            let response: MonitoringCatalog = try await client.get("/monitoring/catalog")
            catalog = .loaded(response)
            if selectedHosts.isEmpty {
                // Première ouverture : on ne retient que les machines qui
                // remontent la métrique affichée par défaut. Les autres n'auraient
                // donné qu'une tuile « — » et aucune courbe.
                let metric = selectedMetrics.first ?? "cpu.usage"
                selectedHosts = Set(response.hosts
                    .filter { $0.hostStatus == .online && $0.metrics.contains(metric) }
                    .prefix(4)
                    .map(\.id))
            }
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { catalog = .failed(error) }
        } catch {
            catalog = .failed(APIError.transport(error))
        }
    }

    private func loadSeries() async {
        guard let client = session.client, !selectedHosts.isEmpty, !selectedMetrics.isEmpty else {
            series = nil
            return
        }
        isLoadingSeries = true
        seriesError = nil
        defer { isLoadingSeries = false }
        do {
            series = try await client.get("/monitoring/series", query: [
                "hosts": selectedHosts.sorted().map(String.init).joined(separator: ","),
                "metrics": selectedMetrics.joined(separator: ","),
                "range": range.rawValue,
                "points": "240",
            ])
        } catch let error as APIError {
            if !error.isCancellation { seriesError = error }
        } catch {
            seriesError = APIError.transport(error)
        }
    }
}

/// Une métrique, plusieurs machines superposées.
private struct ComparisonChart: View {
    let descriptor: MonitoringCatalog.MetricDescriptor
    let hosts: [MonitoringCatalog.CatalogHost]
    let series: MultiSeries

    private var plotted: [(host: MonitoringCatalog.CatalogHost, points: [MetricPoint], color: Color)] {
        hosts.enumerated().compactMap { index, host in
            let points = series.points(host: host.id, metric: descriptor.metric)
            guard points.count > 1 else { return nil }
            return (host, points, Self.palette[index % Self.palette.count])
        }
    }

    private static let palette: [Color] = [
        .accentColor, .blue, .orange, .purple, .pink, .teal, .indigo, .brown,
    ]

    var body: some View {
        if plotted.isEmpty {
            Text("Aucune machine sélectionnée ne remonte cette métrique.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Chart {
                    ForEach(plotted, id: \.host.id) { entry in
                        ForEach(entry.points) { point in
                            LineMark(x: .value("Instant", point.date),
                                     y: .value(descriptor.label, point.value))
                                .foregroundStyle(entry.color)
                                .interpolationMethod(.monotone)
                        }
                        .foregroundStyle(by: .value("Machine", entry.host.name))
                    }
                }
                .chartForegroundStyleScale(domain: plotted.map(\.host.name),
                                           range: plotted.map(\.color))
                .chartLegend(.hidden)
                .chartYScale(domain: descriptor.isPercentage ? .automatic(includesZero: true) : .automatic)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(compact(number)).font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 190)

                // Légende avec la dernière valeur : elle sert autant à identifier
                // les courbes qu'à les classer.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 6) {
                    ForEach(plotted.sorted { ($0.points.last?.value ?? 0) > ($1.points.last?.value ?? 0) },
                            id: \.host.id) { entry in
                        HStack(spacing: 5) {
                            Circle().fill(entry.color).frame(width: 7, height: 7)
                            Text(entry.host.name)
                                .font(.caption2)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(descriptor.format(entry.points.last?.value))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func compact(_ value: Double) -> String {
        switch descriptor.unit {
        case "%": "\(Int(value))%"
        case "B/s": Format.bytes(value, digits: 0)
        case "°C": "\(Int(value))°"
        case "W": "\(Int(value))W"
        default: Format.number(value, digits: value < 10 ? 1 : 0)
        }
    }
}

/// Feuille de sélection des machines et des métriques.
private struct MonitoringPicker: View {
    let catalog: MonitoringCatalog
    @Binding var selectedHosts: Set<Int>
    @Binding var selectedMetrics: [String]

    @Environment(\.dismiss) private var dismiss

    /// Métriques réellement disponibles sur au moins une machine choisie —
    /// proposer le reste ne mènerait qu'à des graphiques vides.
    private var availableMetrics: Set<String> {
        Set(catalog.hosts.filter { selectedHosts.contains($0.id) }.flatMap(\.metrics))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(catalog.hosts) { host in
                        Button {
                            if selectedHosts.contains(host.id) {
                                selectedHosts.remove(host.id)
                            } else {
                                selectedHosts.insert(host.id)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: host.hostKind.symbol)
                                    .foregroundStyle(host.hostStatus.color)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(host.name).foregroundStyle(.primary)
                                    Text(Format.plural(host.metrics.count, "métrique"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedHosts.contains(host.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(host.metrics.isEmpty)
                    }
                } header: {
                    Text("Machines")
                } footer: {
                    Text("Une machine sans métrique collectée dans les 30 dernières minutes n'est pas proposée.")
                }

                Section("Métriques") {
                    ForEach(catalog.catalog) { descriptor in
                        metricRow(descriptor.metric, label: descriptor.label,
                                  unit: descriptor.unit)
                    }
                }

                if !catalog.extraMetrics.isEmpty {
                    Section {
                        ForEach(catalog.extraMetrics.filter(availableMetrics.contains), id: \.self) { metric in
                            metricRow(metric, label: metric, unit: nil)
                        }
                    } header: {
                        Text("Autres métriques collectées")
                    }
                }
            }
            .navigationTitle("Sélection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { dismiss() }
                }
            }
        }
    }

    private func metricRow(_ metric: String, label: String, unit: String?) -> some View {
        let isAvailable = availableMetrics.contains(metric)
        let isSelected = selectedMetrics.contains(metric)
        return Button {
            if isSelected {
                selectedMetrics.removeAll { $0 == metric }
            } else {
                selectedMetrics.append(metric)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .foregroundStyle(isAvailable ? .primary : .secondary)
                    if let unit, !unit.isEmpty {
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                } else if !isAvailable {
                    Text("indisponible").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(!isAvailable && !isSelected)
    }
}
