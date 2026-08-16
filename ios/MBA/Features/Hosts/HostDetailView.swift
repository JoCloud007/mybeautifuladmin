import Charts
import SwiftUI

struct HostDetailView: View {
    let hostID: Int
    let fallbackName: String

    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var state: Loadable<Host> = .idle
    @State private var history: MetricHistory?
    @State private var range: MetricRange = .oneHour
    @State private var isLoadingHistory = false
    @State private var action = ActionRunner()

    private var sample: [String: JSONValue] {
        // Le flux prime : il est plus frais que la réponse REST du chargement.
        let liveSample = live.sample(for: hostID)
        return liveSample.isEmpty ? (state.value?.sample ?? [:]) : liveSample
    }

    private var status: HostStatus {
        live.statuses[hostID] ?? state.value?.status ?? .unknown
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let host = state.value {
                    header(host)
                    if host.kind.hasSystemMetrics && status == .online {
                        gauges
                        chartSection(host)
                        if !sample.cpuCores.isEmpty { coresSection }
                        if !sample.filesystems.isEmpty { filesystemsSection }
                        if !sample.networkInterfaces.isEmpty { networkSection }
                        if !sample.gpus.isEmpty { gpuSection }
                        if !sample.temperatures.isEmpty || !sample.fans.isEmpty { sensorsSection }
                        if !sample.processes.isEmpty { processesSection }
                    } else if status != .online {
                        unreachableSection(host)
                    }
                    detailsSection(host)
                } else if state.isFailed, let error = state.error {
                    ErrorState(error: error) { Task { await load() } }
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(state.value?.name ?? fallbackName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let host = state.value {
                    HostActionsMenu(host: host, runner: action) { await load() }
                }
            }
        }
        .refreshable {
            await load()
            await loadHistory()
        }
        .task { await load() }
        .task(id: range) { await loadHistory() }
        .actionResult(action)
    }

    // MARK: - En-tête

    private func header(_ host: Host) -> some View {
        SectionBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: host.kind.symbol)
                        .font(.title)
                        .foregroundStyle(status.color)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.kind.label)
                            .font(.subheadline.weight(.medium))
                        Text(host.displayAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 6)
                    StatusBadge(text: status.label, color: status.color)
                }

                if !host.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(host.tags, id: \.self) { TagChip(text: $0, symbol: "tag") }
                        }
                    }
                    .scrollClipDisabled()
                }

                HStack(spacing: 16) {
                    if let uptime = sample.double("uptime") {
                        LabeledValue(label: "Actif depuis", value: Format.duration(uptime),
                                     symbol: "clock")
                    }
                }
                if let updates = host.pendingUpdates, updates > 0 {
                    Label(Format.plural(updates, "mise à jour en attente", "mises à jour en attente"),
                          systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                }
            }
        }
    }

    // MARK: - Jauges

    private var gauges: some View {
        SectionBox("Charge", symbol: "speedometer") {
            VStack(spacing: 14) {
                HStack(spacing: 16) {
                    MetricRing(value: sample.double("cpu.usage"), label: "CPU",
                               caption: sample.double("cpu.count").map { "\(Int($0)) cœurs" })
                    MetricRing(value: sample.double("mem.percent"), label: "RAM",
                               caption: memoryCaption)
                    if let swap = sample.double("swap.percent"), (sample.double("swap.total") ?? 0) > 0 {
                        MetricRing(value: swap, label: "Swap", warnAt: 40, criticalAt: 70)
                    }
                    if let disk = sample.double("disk.percent") {
                        MetricRing(value: disk, label: "Disque", warnAt: 80, criticalAt: 92)
                    }
                    Spacer(minLength: 0)
                }

                Divider()

                HStack(spacing: 0) {
                    ForEach(loadValues, id: \.0) { item in
                        VStack(spacing: 2) {
                            Text(Format.number(item.1, digits: 2))
                                .font(.subheadline.monospacedDigit())
                            Text(item.0)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if let temperature = sample.double("temp.cpu") {
                        VStack(spacing: 2) {
                            Text(Format.temperature(temperature))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(Palette.severity(temperature, warn: 75, critical: 88))
                            Text("Température")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var loadValues: [(String, Double)] {
        [("Charge 1 min", sample.double("load.1")),
         ("5 min", sample.double("load.5")),
         ("15 min", sample.double("load.15"))]
            .compactMap { label, value in value.map { (label, $0) } }
    }

    private var memoryCaption: String? {
        guard let used = sample.double("mem.used"), let total = sample.double("mem.total"), total > 0
        else { return nil }
        return "\(Format.bytes(used, digits: 0)) / \(Format.bytes(total, digits: 0))"
    }

    // MARK: - Historique

    private func chartSection(_ host: Host) -> some View {
        SectionBox("Historique", symbol: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Fenêtre", selection: $range) {
                    ForEach(MetricRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                if isLoadingHistory && history == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 150)
                } else if let history, !history.isEmpty {
                    MetricChart(title: "Processeur",
                                unit: "%",
                                series: [("CPU", history.points("cpu.usage"), Color.accentColor)])
                    MetricChart(title: "Mémoire",
                                unit: "%",
                                series: [("RAM", history.points("mem.percent"), Color.purple),
                                         ("Swap", history.points("swap.percent"), Color.orange)])
                    MetricChart(title: "Réseau",
                                unit: "o/s",
                                formatter: { Format.bytes($0, digits: 0) },
                                series: [("Reçu", history.points("net.rx"), Color.teal),
                                         ("Émis", history.points("net.tx"), Color.pink)])
                } else {
                    Text("Aucun point sur cette période.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
        }
    }

    // MARK: - Cœurs

    private var coresSection: some View {
        SectionBox("Cœurs", symbol: "cpu") {
            let cores = sample.cpuCores
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                     count: cores.count > 16 ? 8 : 4),
                      spacing: 8) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 26)
                            .overlay(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Palette.severity(value))
                                    .frame(height: max(2, 26 * min(value / 100, 1)))
                            }
                        Text("\(index)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Cœur \(index)")
                    .accessibilityValue(Format.percent(value, digits: 0))
                }
            }
        }
    }

    // MARK: - Stockage

    private var filesystemsSection: some View {
        SectionBox("Systèmes de fichiers", symbol: "internaldrive") {
            VStack(spacing: 14) {
                ForEach(sample.filesystems) { filesystem in
                    MetricBar(title: filesystem.mount,
                              value: filesystem.percent,
                              detail: "\(Format.bytes(filesystem.used, digits: 0)) / \(Format.bytes(filesystem.total, digits: 0))",
                              warnAt: 80, criticalAt: 92)
                }
            }
        }
    }

    // MARK: - Réseau

    private var networkSection: some View {
        SectionBox("Réseau", symbol: "network") {
            VStack(spacing: 10) {
                ForEach(sample.networkInterfaces, id: \.name) { interface in
                    HStack {
                        Text(interface.name)
                            .font(.subheadline)
                        Spacer()
                        Label(Format.bitrate(interface.rx), systemImage: "arrow.down")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.teal)
                        Label(Format.bitrate(interface.tx), systemImage: "arrow.up")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.pink)
                    }
                }
            }
        }
    }

    // MARK: - GPU

    private var gpuSection: some View {
        SectionBox("Accélérateurs", symbol: "cpu.fill") {
            VStack(spacing: 16) {
                ForEach(sample.gpus) { gpu in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(gpu.name)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            if let temperature = gpu.temperature {
                                Text(Format.temperature(temperature))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Palette.severity(temperature, warn: 80, critical: 92))
                            }
                            if let power = gpu.power {
                                Text(Format.watts(power))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let busy = gpu.busy {
                            MetricBar(title: "Occupation", value: busy)
                        }
                        if let vram = gpu.vramPercent {
                            MetricBar(title: gpu.hasUnifiedMemory ? "VRAM dédiée" : "VRAM",
                                      value: vram,
                                      detail: vramDetail(gpu))
                        }
                        if gpu.hasUnifiedMemory, let used = gpu.gttUsed, let total = gpu.gttTotal, total > 0 {
                            MetricBar(title: "GTT partagée",
                                      value: used / total * 100,
                                      detail: "\(Format.bytes(used, digits: 0)) / \(Format.bytes(total, digits: 0))")
                        }
                    }
                }
            }
        }
    }

    private func vramDetail(_ gpu: GPUEntry) -> String? {
        guard let used = gpu.vramUsed, let total = gpu.vramTotal, total > 0 else { return nil }
        return "\(Format.bytes(used, digits: 0)) / \(Format.bytes(total, digits: 0))"
    }

    // MARK: - Capteurs

    private var sensorsSection: some View {
        SectionBox("Capteurs", symbol: "thermometer.medium") {
            VStack(spacing: 8) {
                ForEach(sample.temperatures, id: \.name) { sensor in
                    HStack {
                        Text(sensor.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(Format.temperature(sensor.value))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.severity(sensor.value, warn: 75, critical: 88))
                    }
                }
                if !sample.fans.isEmpty {
                    Divider()
                    ForEach(sample.fans, id: \.name) { fan in
                        HStack {
                            Label(fan.name, systemImage: "fan")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(Format.rpm(fan.value))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(fan.value == 0 ? .secondary : .primary)
                        }
                    }
                }
                if !sample.powerSensors.isEmpty {
                    Divider()
                    ForEach(sample.powerSensors, id: \.name) { sensor in
                        HStack {
                            Label(sensor.name, systemImage: "bolt")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Format.watts(sensor.value))
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
        }
    }

    // MARK: - Processus

    private var processesSection: some View {
        SectionBox("Processus les plus gourmands", symbol: "list.number") {
            VStack(spacing: 8) {
                ForEach(sample.processes.prefix(8)) { process in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(process.name)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(process.user) · \(process.pid)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 6)
                        Text(Format.percent(process.cpu, digits: 1))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.severity(process.cpu))
                            .frame(width: 54, alignment: .trailing)
                        Text(Format.bytes(process.rss, digits: 0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - Hors ligne / détails

    private func unreachableSection(_ host: Host) -> some View {
        SectionBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(status == .offline ? "Machine injoignable" : "Aucune donnée",
                      systemImage: "bolt.horizontal.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(status.color)
                if let error = host.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let lastSeen = host.lastSeen {
                    Text("Dernier contact \(Format.ago(lastSeen))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func detailsSection(_ host: Host) -> some View {
        SectionBox("Fiche", symbol: "info.circle") {
            VStack(spacing: 10) {
                LabeledValue(label: "Adresse", value: host.address, monospaced: true)
                LabeledValue(label: "Port", value: host.port.map(String.init))
                LabeledValue(label: "Type", value: host.kind.label)
                if let category = host.category {
                    LabeledValue(label: "Catégorie", value: category)
                }
                if let location = host.location {
                    LabeledValue(label: "Emplacement", value: location)
                }
                LabeledValue(label: "Dernier contact", value: Format.dateTime(host.lastSeen))
                LabeledValue(label: "Collecte", value: host.enabled ? "Active" : "Suspendue")
                if let notes = host.notes, !notes.isEmpty {
                    Divider()
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Chargement

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let host: Host = try await client.get("/hosts/\(hostID)")
            state = .loaded(host)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    private func loadHistory() async {
        guard let client = session.client else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            history = try await client.get(
                "/hosts/\(hostID)/metrics",
                query: ["metrics": "cpu.usage,mem.percent,swap.percent,net.rx,net.tx",
                        "range": range.rawValue,
                        "points": "180"])
        } catch {
            // L'historique est un complément : son absence ne doit pas masquer
            // les valeurs temps réel déjà affichées.
            history = nil
        }
    }
}

// MARK: - Graphique

/// Graphique multi-séries avec axes, échelle et légende.
struct MetricChart: View {
    let title: String
    var unit: String = ""
    var formatter: ((Double) -> String)?
    let series: [(name: String, points: [MetricPoint], color: Color)]

    private var plotted: [(name: String, points: [MetricPoint], color: Color)] {
        series.filter { $0.points.count > 1 }
    }

    var body: some View {
        if plotted.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(plotted, id: \.name) { entry in
                        HStack(spacing: 3) {
                            Circle().fill(entry.color).frame(width: 6, height: 6)
                            Text(entry.name).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                Chart {
                    ForEach(plotted, id: \.name) { entry in
                        ForEach(entry.points) { point in
                            LineMark(x: .value("Instant", point.date),
                                     y: .value(unit, point.value))
                                .foregroundStyle(entry.color)
                                .interpolationMethod(.monotone)
                        }
                        .foregroundStyle(by: .value("Série", entry.name))
                    }
                }
                .chartForegroundStyleScale(domain: plotted.map(\.name),
                                           range: plotted.map(\.color))
                .chartLegend(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(formatter?(number) ?? "\(Int(number))\(unit)")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(preset: .aligned) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 130)
            }
        }
    }
}
