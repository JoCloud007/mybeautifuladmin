import SwiftUI

/// Mur de capteurs du parc : températures, ventilateurs, puissances.
struct SensorsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var state: Loadable<SensorsResponse> = .idle
    @State private var kindFilter: SensorReading.Kind?

    var body: some View {
        List {
            if let response = state.value {
                summarySection(response.summary)

                let readings = filtered(response.readings)
                if readings.isEmpty {
                    Section {
                        EmptyState(title: "Aucun capteur",
                                   message: "Aucune machine ne remonte de capteur pour ce filtre.",
                                   symbol: "thermometer.medium.slash")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(grouped(readings), id: \.key) { group in
                        Section(group.key) {
                            ForEach(group.readings) { reading in
                                SensorRow(reading: reading, liveValue: liveValue(for: reading))
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
        .navigationTitle("Capteurs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Type", selection: $kindFilter) {
                    Text("Tous").tag(SensorReading.Kind?.none)
                    Text("Températures").tag(SensorReading.Kind?.some(.temperature))
                    Text("Ventilateurs").tag(SensorReading.Kind?.some(.fan))
                    Text("Puissances").tag(SensorReading.Kind?.some(.power))
                }
                .pickerStyle(.menu)
            }
        }
    }

    /// Le relevé REST est un instantané ; le flux, lui, continue d'arriver.
    private func liveValue(for reading: SensorReading) -> Double? {
        live.metric(reading.metric, for: reading.hostID)
    }

    private func summarySection(_ summary: SensorsResponse.Summary) -> some View {
        Section {
            HStack(spacing: 10) {
                if let hottest = summary.hottest {
                    StatTile(value: Format.temperature(hottest.value),
                             label: hottest.hostName ?? "Plus chaud",
                             symbol: "thermometer.high",
                             tint: Palette.severity(hottest.value, warn: 70, critical: 85))
                }
                if summary.powerTotal > 0 {
                    StatTile(value: Format.watts(summary.powerTotal),
                             label: "Consommation", symbol: "bolt.fill", tint: .accentColor)
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            if summary.critical > 0 || summary.warning > 0 {
                HStack(spacing: 10) {
                    if summary.critical > 0 {
                        StatTile(value: "\(summary.critical)", label: "Critiques",
                                 symbol: "exclamationmark.octagon", tint: Palette.danger)
                    }
                    if summary.warning > 0 {
                        StatTile(value: "\(summary.warning)", label: "À surveiller",
                                 symbol: "exclamationmark.triangle", tint: Palette.warn)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }
        }
        .listRowBackground(Color.clear)
    }

    private func filtered(_ readings: [SensorReading]) -> [SensorReading] {
        guard let kindFilter else { return readings }
        return readings.filter { $0.sensorKind == kindFilter }
    }

    private func grouped(_ readings: [SensorReading]) -> [(key: String, readings: [SensorReading])] {
        Dictionary(grouping: readings, by: { $0.hostName ?? "Machine \($0.hostID)" })
            .map { (key: $0.key, readings: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let response: SensorsResponse = try await client.get("/monitoring/sensors")
            state = .loaded(response)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

private struct SensorRow: View {
    let reading: SensorReading
    let liveValue: Double?

    private var value: Double { liveValue ?? reading.value }

    private var tint: Color {
        switch reading.sensorKind {
        case .temperature: Palette.severity(value, warn: 70, critical: 85)
        case .fan: value == 0 ? .secondary : .primary
        case .power: .accentColor
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reading.symbol)
                .foregroundStyle(reading.sensorKind == .temperature ? tint : .secondary)
                .frame(width: 20)
            Text(reading.label)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(formatted)
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reading.label)
        .accessibilityValue(formatted)
    }

    private var formatted: String {
        switch reading.sensorKind {
        case .temperature: Format.temperature(value)
        case .fan: Format.rpm(value)
        case .power: Format.watts(value)
        }
    }
}
