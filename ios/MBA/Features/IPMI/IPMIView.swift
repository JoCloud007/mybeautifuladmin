import SwiftUI

/// Gestion hors-bande : les contrôleurs BMC du parc.
///
/// C'est la seule section qui agit sur le matériel lui-même, machine éteinte
/// comprise. Un BMC répond quand plus rien ne répond — d'où l'intérêt de
/// l'avoir sur un téléphone — mais ses gestes ne passent par aucun système
/// d'exploitation : l'écran les entoure donc d'avertissements que les autres
/// sections n'ont pas.
struct IPMIView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var state: Loadable<BMCList> = .idle
    @State private var search = ""
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let list = state.value {
                let visible = merged(list.bmcs).filter { $0.matches(normalizedSearch) }
                if visible.isEmpty {
                    Section {
                        emptyState(total: list.bmcs.count)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    summarySection(visible)
                    Section {
                        ForEach(visible) { bmc in
                            NavigationLink(value: bmc) {
                                BMCRow(bmc: bmc)
                            }
                        }
                    } footer: {
                        Text("Un contrôleur hors-bande reste joignable même machine éteinte : c'est par lui qu'on rallume un serveur qui ne répond plus.")
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
        .navigationTitle("Hors-bande")
        .searchable(text: $search, prompt: "Contrôleur, adresse, modèle")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: BMC.self) { bmc in
            BMCDetailView(bmc: bmc, onChange: { await load() })
        }
        .actionResult(runner)
    }

    // MARK: - Synthèse

    private func summarySection(_ bmcs: [BMC]) -> some View {
        let poweredOn = bmcs.filter(\.info.isPoweredOn)
        let ailing = bmcs.filter { $0.info.healthWarning != nil }
        let watts = bmcs.compactMap(\.info.powerWatts).reduce(0, +)
        let hottest = bmcs.compactMap(\.hottest).max { $0.value < $1.value }

        return Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(poweredOn.count)", label: "Machines allumées",
                             symbol: "power",
                             tint: poweredOn.isEmpty ? Palette.idle : Palette.ok,
                             trailing: "/ \(bmcs.count)")
                    StatTile(value: watts > 0 ? Format.watts(watts) : Format.placeholder,
                             label: "Consommation", symbol: "bolt.fill",
                             tint: watts > 0 ? .primary : Palette.idle)
                    if let hottest {
                        StatTile(value: Format.temperature(hottest.value),
                                 label: "Point le plus chaud", symbol: "thermometer.medium",
                                 tint: Palette.severity(hottest.value, warn: 65, critical: 80))
                    }
                    if !ailing.isEmpty {
                        StatTile(value: "\(ailing.count)", label: "Santé dégradée",
                                 symbol: "exclamationmark.triangle.fill", tint: Palette.danger)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    private func emptyState(total: Int) -> some View {
        EmptyState(
            title: total == 0 ? "Aucun contrôleur" : "Aucun résultat",
            message: total == 0
                ? "Un contrôleur hors-bande (iDRAC, iLO, ASMB, Supermicro) permet d'allumer, d'éteindre et de surveiller un serveur sans passer par son système.\n\nL'ajout demande des identifiants et un diagnostic de connexion : il se fait depuis la console web."
                : "Aucun contrôleur ne correspond à « \(search) ».",
            symbol: "cpu")
    }

    // MARK: - Données

    /// Les valeurs du flux temps réel priment sur celles du dernier chargement.
    private func merged(_ bmcs: [BMC]) -> [BMC] {
        bmcs.map { $0.applying(live.sample(for: $0.id)) }
    }

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/ipmi"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

// MARK: - Ligne

private struct BMCRow: View {
    let bmc: BMC

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: bmc.info.isPoweredOn ? "power" : "poweroff")
                .foregroundStyle(bmc.info.isPoweredOn ? Palette.ok : Palette.idle)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(bmc.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text([bmc.address, bmc.info.displayModel]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    StatusBadge(text: bmc.info.powerLabel,
                                color: bmc.info.isPoweredOn ? Palette.ok : Palette.idle,
                                symbol: bmc.info.isPoweredOn ? "power" : "poweroff")
                    if let health = bmc.info.healthWarning {
                        StatusBadge(text: health, color: Palette.danger,
                                    symbol: "exclamationmark.triangle.fill")
                    }
                    if bmc.info.isIdentifying {
                        StatusBadge(text: "LED allumée", color: Palette.warn,
                                    symbol: "lightbulb.fill")
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                if let hottest = bmc.hottest {
                    Text(Format.temperature(hottest.value))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Palette.severity(hottest.value, warn: 65, critical: 80))
                }
                if let watts = bmc.info.powerWatts {
                    Text(Format.watts(watts))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fiche

private struct BMCDetailView: View {
    let bmc: BMC
    let onChange: () async -> Void

    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var runner = ActionRunner()
    @State private var log: Loadable<[BMCLogEntry]> = .idle
    @State private var isShowingLog = false

    /// La fiche est poussée avec la valeur du moment ; le flux la rafraîchit
    /// ensuite sans qu'on ait à recharger l'écran.
    private var current: BMC { bmc.applying(live.sample(for: bmc.id)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                overview
                powerSection
                toolsSection
                identitySection
                if !current.temps.isEmpty { temperaturesSection }
                if !current.fans.isEmpty { fansSection }
                if !current.info.psus.isEmpty { suppliesSection }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(bmc.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingLog) {
            BMCLogSheet(name: bmc.name, state: log, reload: { await loadLog(force: true) })
        }
        .actionResult(runner)
    }

    // MARK: Synthèse

    private var overview: some View {
        let info = current.info
        return SectionBox {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: info.powerLabel, label: "Alimentation",
                             symbol: info.isPoweredOn ? "power" : "poweroff",
                             tint: info.isPoweredOn ? Palette.ok : Palette.idle)
                    StatTile(value: info.powerWatts.map(Format.watts) ?? Format.placeholder,
                             label: "Consommation", symbol: "bolt.fill")
                    StatTile(value: current.hottest.map { Format.temperature($0.value) }
                                ?? Format.placeholder,
                             label: current.hottest?.name ?? "Plus chaud",
                             symbol: "thermometer.medium",
                             tint: Palette.severity(current.hottest?.value, warn: 65, critical: 80))
                    StatTile(value: current.fans.isEmpty ? Format.placeholder : "\(current.fans.count)",
                             label: "Ventilateurs", symbol: "fan",
                             trailing: current.fastestFan.map { "max \(Format.rpm($0))" })
                }

                if let health = info.healthWarning {
                    Label("Santé du système signalée « \(health) » par le contrôleur.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let server = current.server {
                    Label("Système supervisé : \(server.name) (\(server.status))",
                          systemImage: "server.rack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Alimentation

    private var powerSection: some View {
        let info = current.info
        let actions = BMCPowerAction.allCases.filter { action in
            // Le BMC annonce ce qu'il accepte ; quand il ne dit rien, on
            // propose tout et on le laisse refuser.
            (info.supportedActions.isEmpty || info.supportedActions.contains(action.rawValue))
                && action.isRelevant(poweredOn: info.isPoweredOn)
        }

        return SectionBox("Alimentation", symbol: "power") {
            VStack(spacing: 10) {
                ForEach(actions) { action in
                    Button {
                        confirmPower(action)
                    } label: {
                        Label(action.label, systemImage: action.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .tint(action.isDestructive ? Palette.danger : Palette.ok)
                }

                if actions.isEmpty {
                    Text("Le contrôleur n'expose aucune action pour l'état courant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Ces commandes s'appliquent au matériel, immédiatement, sans que le système en soit averti.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Outils

    private var toolsSection: some View {
        SectionBox("Diagnostic", symbol: "stethoscope") {
            VStack(spacing: 10) {
                Button {
                    Task { await test() }
                } label: {
                    Label("Tester la connexion", systemImage: "wifi")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button {
                    isShowingLog = true
                    Task { await loadLog() }
                } label: {
                    Label("Journal matériel", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await identify() }
                } label: {
                    Label("Allumer la LED de localisation", systemImage: "lightbulb")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Text("La LED clignote sur la façade : c'est ainsi qu'on retrouve la bonne machine dans une baie.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Identité

    private var identitySection: some View {
        let info = current.info
        return SectionBox("Matériel", symbol: "cpu") {
            VStack(spacing: 10) {
                LabeledValue(label: "Adresse", value: current.address, monospaced: true)
                LabeledValue(label: "Transport", value: current.modeLabel)
                LabeledValue(label: "Constructeur", value: info.displayManufacturer)
                LabeledValue(label: "Modèle", value: info.displayModel)
                LabeledValue(label: "Numéro de série", value: info.displaySerial, monospaced: true)
                LabeledValue(label: "BIOS", value: info.bios)
                LabeledValue(label: "Firmware BMC",
                             value: [info.bmcModel, info.bmcFirmware]
                                .compactMap { $0 }.joined(separator: " · "))
                if let cpu = info.cpuModel {
                    LabeledValue(label: "Processeur",
                                 value: info.cpuCount.map { "\($0) × \(cpu)" } ?? cpu)
                }
                if let memory = info.memTotal {
                    LabeledValue(label: "Mémoire", value: Format.bytes(memory))
                }
                if let name = info.hostName {
                    LabeledValue(label: "Nom déclaré", value: name)
                }
            }
        }
    }

    // MARK: Capteurs

    private var temperaturesSection: some View {
        SectionBox("Températures", symbol: "thermometer.medium") {
            VStack(spacing: 8) {
                ForEach(current.temps.sorted { $0.value > $1.value }, id: \.key) { sensor in
                    ReadingRow(name: sensor.key,
                               value: Format.temperature(sensor.value),
                               tint: Palette.severity(sensor.value, warn: 65, critical: 80))
                }
            }
        }
    }

    private var fansSection: some View {
        SectionBox("Ventilateurs", symbol: "fan") {
            VStack(spacing: 8) {
                ForEach(current.fans.sorted { $0.value > $1.value }, id: \.key) { fan in
                    // Un ventilateur à l'arrêt est soit absent, soit en panne :
                    // dans les deux cas cela mérite d'être vu.
                    ReadingRow(name: fan.key,
                               value: Format.rpm(fan.value),
                               tint: fan.value <= 0 ? Palette.danger : .secondary)
                }
            }
        }
    }

    private var suppliesSection: some View {
        SectionBox("Alimentations", symbol: "bolt.fill") {
            VStack(spacing: 8) {
                ForEach(current.info.psus) { psu in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(psu.name ?? "Alimentation")
                                .font(.callout)
                            if let model = psu.model, !model.isEmpty {
                                Text(model)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        if psu.isAbsent {
                            StatusBadge(text: "emplacement vide", color: Palette.idle)
                        } else {
                            VStack(alignment: .trailing, spacing: 2) {
                                StatusBadge(text: psu.status ?? "inconnu",
                                            color: psu.isHealthy ? Palette.ok : Palette.danger)
                                if let input = psu.input {
                                    Text(Format.watts(input) + (psu.capacity.map { " / \(Format.watts($0))" } ?? ""))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func confirmPower(_ action: BMCPowerAction) {
        let message = [
            action.hint,
            "La commande passe par le contrôleur hors-bande et s'applique immédiatement, quel que soit l'état du système.",
            action.warning,
        ].compactMap { $0 }.joined(separator: "\n\n")

        runner.confirm(
            "\(action.label) — \(bmc.name) ?",
            message: message,
            confirmLabel: action.label,
            isDestructive: action.isDestructive
        ) { [client = session.client, id = bmc.id] in
            guard let client else { return nil }
            try await client.perform("/ipmi/\(id)/power/\(action.rawValue)")
            return "\(action.label) envoyé à \(bmc.name). Le contrôleur met quelques secondes à refléter le nouvel état."
        }
        Task {
            // Le BMC ne change pas d'état instantanément : on laisse passer le
            // temps du cycle avant de redemander la liste.
            try? await Task.sleep(for: .seconds(3))
            await onChange()
        }
    }

    private func identify() async {
        guard let client = session.client else { return }
        await runner.run("LED de localisation") { [id = bmc.id] in
            try await client.perform("/ipmi/\(id)/identify", body: Optional<Empty>.none)
            return "La LED de la façade est allumée."
        }
    }

    private func test() async {
        guard let client = session.client else { return }
        await runner.run("Test de connexion") { [id = bmc.id] in
            let result: BMCTestResult = try await client.post("/ipmi/\(id)/test")
            // Un test qui échoue n'est pas une erreur de l'application : le
            // compte rendu du serveur dit où la chaîne casse, on le rend tel quel.
            return (result.ok ? "✅ " : "⚠️ ") + result.report
        }
    }

    private func loadLog(force: Bool = false) async {
        guard let client = session.client else { return }
        if !force, log.value != nil { return }
        log.begin()
        do {
            log = .loaded(try await client.get("/ipmi/\(bmc.id)/sel", query: ["limit": "80"]))
        } catch let error as APIError {
            if !error.isCancellation { log = .failed(error) }
        } catch {
            log = .failed(APIError.transport(error))
        }
    }
}

// MARK: - Lignes de capteur

private struct ReadingRow: View {
    let name: String
    let value: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Journal matériel

/// Le SEL (System Event Log) du contrôleur : ce que le matériel a consigné
/// lui-même, y compris pendant que le système était éteint.
private struct BMCLogSheet: View {
    let name: String
    let state: Loadable<[BMCLogEntry]>
    let reload: () async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .idle, .loading:
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let error):
                    ErrorState(error: error) { Task { await reload() } }
                case .loaded(let entries):
                    if entries.isEmpty {
                        EmptyState(
                            title: "Journal vide",
                            message: "Le contrôleur n'a rien consigné. Sur du matériel sain, c'est le cas le plus fréquent.",
                            symbol: "list.bullet.rectangle")
                    } else {
                        List(entries) { entry in
                            BMCLogRow(entry: entry)
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("Journal · \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}

private struct BMCLogRow: View {
    let entry: BMCLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LeadingAccent(color: tint)
                .frame(height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message ?? "—")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text([entry.displayTime, entry.sensor].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        if entry.isCritical { return Palette.danger }
        if entry.isWarning { return Palette.warn }
        return Palette.idle
    }
}
