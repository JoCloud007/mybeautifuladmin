import SwiftUI

/// Planificateur : les tâches récurrentes que MBA exécute sur le parc.
///
/// L'écran répond à trois questions — qu'est-ce qui va se déclencher, qu'est-ce
/// qui a échoué la dernière fois, et qu'est-ce qui ne vise plus rien.
struct SchedulerView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<ScheduleList> = .idle
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
                let visible = list.schedules.filter { $0.matches(normalizedSearch) }

                if !list.schedules.isEmpty {
                    summarySection(list)
                }

                if visible.isEmpty {
                    Section {
                        EmptyState(
                            title: list.schedules.isEmpty ? "Aucune planification" : "Aucun résultat",
                            message: list.schedules.isEmpty
                                ? "Programme une mise à jour nocturne, un redémarrage hebdomadaire ou une purge Docker — MBA s'en charge et journalise chaque exécution."
                                : "Aucune planification ne correspond à « \(search) ».",
                            symbol: "calendar.badge.clock",
                            actionTitle: list.schedules.isEmpty ? "Créer une planification" : nil,
                            action: list.schedules.isEmpty ? { isCreating = true } : nil)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    let active = visible.filter(\.enabled)
                    let paused = visible.filter { !$0.enabled }

                    if !active.isEmpty {
                        Section("Actives · \(active.count)") {
                            ForEach(active) { schedule in
                                row(schedule, timezone: list.timezone)
                            }
                        }
                    }
                    if !paused.isEmpty {
                        Section("Suspendues · \(paused.count)") {
                            ForEach(paused) { schedule in
                                row(schedule, timezone: list.timezone)
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
        .navigationTitle("Planificateur")
        .searchable(text: $search, prompt: "Nom, cible, expression")
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Nouvelle planification", systemImage: "plus") { isCreating = true }
            }
        }
        .sheet(isPresented: $isCreating) {
            ScheduleEditor { payload in
                try await create(payload)
            }
        }
        .navigationDestination(for: Schedule.self) { schedule in
            ScheduleDetailView(
                schedule: schedule,
                timezone: state.value?.timezone ?? "UTC",
                onRun: { await run(schedule) },
                onToggle: { await toggle(schedule) },
                onDelete: { await delete(schedule) })
        }
        .actionResult(runner)
    }

    private func row(_ schedule: Schedule, timezone: String) -> some View {
        NavigationLink(value: schedule) {
            ScheduleRow(schedule: schedule)
        }
        .swipeActions(edge: .trailing) {
            Button("Supprimer", systemImage: "trash", role: .destructive) {
                confirmDelete(schedule)
            }
            Button(schedule.enabled ? "Suspendre" : "Activer",
                   systemImage: schedule.enabled ? "pause" : "play") {
                Task { await toggle(schedule) }
            }
            .tint(schedule.enabled ? Palette.warn : Palette.ok)
        }
        .swipeActions(edge: .leading) {
            Button("Exécuter", systemImage: "play.fill") {
                confirmRun(schedule)
            }
            .tint(.accentColor)
        }
    }

    // MARK: - Synthèse

    private func summarySection(_ list: ScheduleList) -> some View {
        let active = list.schedules.filter(\.enabled)
        let failing = list.schedules.filter(\.lastFailed)
        let orphans = list.schedules.filter(\.hasNoTarget)
        let next = active.compactMap(\.nextRun).min()

        return Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(active.count)", label: "Actives",
                             symbol: "calendar.badge.clock", tint: Palette.ok,
                             trailing: "/ \(list.schedules.count)")
                    StatTile(value: "\(failing.count)", label: "En échec",
                             symbol: "xmark.octagon",
                             tint: failing.isEmpty ? Palette.ok : Palette.danger)
                }

                if let next {
                    Label("Prochaine exécution \(Format.dateTime(next)) · \(Format.ago(next).replacingOccurrences(of: "il y a", with: "dans"))",
                          systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !orphans.isEmpty {
                    // Une planification active qui ne vise plus rien ne lèvera
                    // aucune erreur : elle se contentera de ne jamais rien faire.
                    Label("\(Format.plural(orphans.count, "planification")) active\(orphans.count > 1 ? "s" : "") ne vise aucune machine.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } footer: {
            Text("Les expressions cron sont interprétées dans le fuseau \(list.timezone).")
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func confirmRun(_ schedule: Schedule) {
        runner.confirm(
            "Exécuter « \(schedule.name) » ?",
            message: "\(schedule.scheduleAction.label) sur \(schedule.targetSummary), tout de suite.\n\nLa prochaine échéance planifiée est recalculée après l'exécution.",
            confirmLabel: "Exécuter",
            isDestructive: schedule.scheduleAction.isDisruptive
        ) { [client = session.client] in
            guard let client else { return nil }
            let response = try await client.perform("/schedules/\(schedule.id)/run")
            let status = response["status"]?.stringValue ?? "?"
            let output = response["output"]?.stringValue
            let verdict = switch status {
            case "success": "Exécution réussie."
            case "partial": "Exécution partielle : certaines cibles ont échoué."
            default: "Exécution en échec."
            }
            guard let output, !output.isEmpty else { return verdict }
            return "\(verdict)\n\n\(output.prefix(600))"
        }
    }

    private func confirmDelete(_ schedule: Schedule) {
        runner.confirm(
            "Supprimer « \(schedule.name) » ?",
            message: "La planification est retirée définitivement. Les exécutions déjà journalisées sont conservées.",
            confirmLabel: "Supprimer"
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.delete("/schedules/\(schedule.id)")
            return "Planification supprimée."
        }
    }

    private func run(_ schedule: Schedule) async {
        confirmRun(schedule)
    }

    private func toggle(_ schedule: Schedule) async {
        guard let client = session.client else { return }
        let enabling = !schedule.enabled
        await runner.run(enabling ? "Planification activée" : "Planification suspendue") {
            let _: Schedule = try await client.patch("/schedules/\(schedule.id)",
                                                     body: SchedulePatch(enabled: enabling))
            return enabling
                ? "« \(schedule.name) » reprendra à la prochaine échéance."
                : "« \(schedule.name) » ne se déclenchera plus tant qu'elle est suspendue."
        }
        await load()
    }

    private func delete(_ schedule: Schedule) async {
        confirmDelete(schedule)
    }

    private func create(_ payload: SchedulePayload) async throws {
        guard let client = session.client else { return }
        let _: Schedule = try await client.post("/schedules", body: payload)
        await load()
    }

    // MARK: - Réseau

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/schedules"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

// MARK: - Ligne

private struct ScheduleRow: View {
    let schedule: Schedule

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: schedule.scheduleAction.symbol)
                .foregroundStyle(schedule.enabled ? Color.accentColor : Color.secondary)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(schedule.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if schedule.running {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(schedule.summary ?? "\(schedule.scheduleAction.label) sur \(schedule.targetSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    if schedule.hasNoTarget {
                        StatusBadge(text: "aucune cible", color: Palette.warn,
                                    symbol: "exclamationmark.triangle.fill")
                    } else if let status = schedule.lastStatus {
                        StatusBadge(text: statusLabel(status),
                                    color: Palette.serviceStatus(status),
                                    symbol: schedule.lastSucceeded
                                        ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    }
                    if schedule.enabled, let next = schedule.nextRun {
                        Text("le \(Format.dateTime(next))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .opacity(schedule.enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "success": "réussie"
        case "partial": "partielle"
        case "failed": "en échec"
        default: status
        }
    }
}

// MARK: - Détail

private struct ScheduleDetailView: View {
    let schedule: Schedule
    let timezone: String
    let onRun: () async -> Void
    let onToggle: () async -> Void
    let onDelete: () async -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                SectionBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(schedule.scheduleAction.label,
                                  systemImage: schedule.scheduleAction.symbol)
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 6)
                            StatusBadge(text: schedule.enabled ? "active" : "suspendue",
                                        color: schedule.enabled ? Palette.ok : Palette.idle,
                                        symbol: schedule.enabled ? "play.fill" : "pause.fill")
                        }
                        if let summary = schedule.summary {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SectionBox("Déclenchement", symbol: "calendar.badge.clock") {
                    VStack(spacing: 10) {
                        LabeledValue(label: "Expression", value: schedule.cron, monospaced: true)
                        if let preset = CronPreset.label(for: schedule.cron) {
                            LabeledValue(label: "Soit", value: preset)
                        }
                        LabeledValue(label: "Fuseau", value: timezone)
                        LabeledValue(label: "Prochaine",
                                     value: schedule.enabled
                                         ? Format.fullDate(schedule.nextRun)
                                         : "suspendue")
                        LabeledValue(label: "Dernière", value: schedule.lastRun == nil
                                     ? "jamais exécutée"
                                     : "\(Format.fullDate(schedule.lastRun)) (\(Format.ago(schedule.lastRun)))")
                    }
                }

                SectionBox("Cibles · \(schedule.targets)", symbol: schedule.targetKind.symbol) {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledValue(label: "Portée", value: schedule.targetKind.label)
                        if schedule.targetNames.isEmpty {
                            Label(schedule.targetKind == .all
                                  ? "Tout le parc, aucune machine éligible pour l'instant."
                                  : "Aucune machine ne correspond — la planification ne fera rien.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(Palette.warn)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(schedule.targetNames, id: \.self) { name in
                                        TagChip(text: name, symbol: "server.rack")
                                    }
                                }
                            }
                            .scrollClipDisabled()
                        }
                    }
                }

                if let output = schedule.lastOutput, !output.isEmpty {
                    SectionBox("Dernière sortie", symbol: "text.alignleft") {
                        Text(output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                actions
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(schedule.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actions: some View {
        SectionBox {
            VStack(spacing: 10) {
                Button {
                    Task { await onRun() }
                } label: {
                    Label("Exécuter maintenant", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await onToggle() }
                } label: {
                    Label(schedule.enabled ? "Suspendre" : "Activer",
                          systemImage: schedule.enabled ? "pause" : "play")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    Task { await onDelete() }
                } label: {
                    Label("Supprimer", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Palette.danger)
            }
        }
    }
}

// MARK: - Création

/// Formulaire de création, avec aperçu du serveur avant enregistrement.
///
/// L'aperçu n'est pas un ornement : une expression cron et une cible se jugent
/// mal de tête, et se corrigent très mal une fois la tâche partie en production.
private struct ScheduleEditor: View {
    let onSave: (SchedulePayload) async throws -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var action: ScheduleAction = .upgrade
    @State private var targetKind: TargetKind = .host
    @State private var selectedHosts: Set<Int> = []
    @State private var selectedTags: Set<String> = []
    @State private var selectedKinds: Set<String> = []
    @State private var cron = CronPreset.all[1].expression
    @State private var usesCustomCron = false
    @State private var parameter = ""

    @State private var hosts: [Host] = []
    @State private var preview: SchedulePreview?
    @State private var previewError: APIError?
    @State private var isSaving = false
    @State private var saveError: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom", text: $name)
                        .textInputAutocapitalization(.sentences)
                    Picker("Action", selection: $action) {
                        ForEach(ScheduleAction.allCases) { action in
                            Label(action.label, systemImage: action.symbol).tag(action)
                        }
                    }
                    if let requirement = action.requiredParameter {
                        TextField(requirement.placeholder, text: $parameter)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(action == .command ? .callout.monospaced() : .callout)
                    }
                } header: {
                    Text("Tâche")
                } footer: {
                    if let requirement = action.requiredParameter {
                        Text("\(requirement.label) — obligatoire pour cette action.")
                    } else if action.isDisruptive {
                        Text("Les services hébergés seront interrompus à chaque exécution.")
                    }
                }

                Section("Cibles") {
                    Picker("Portée", selection: $targetKind) {
                        ForEach(TargetKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch targetKind {
                    case .host:
                        ForEach(hosts) { host in
                            SelectableRow(label: host.name, detail: host.address,
                                          symbol: host.kind.symbol,
                                          isOn: selectedHosts.contains(host.id)) {
                                toggle(&selectedHosts, host.id)
                            }
                        }
                    case .tag:
                        ForEach(availableTags, id: \.self) { tag in
                            SelectableRow(label: tag, detail: nil, symbol: "tag",
                                          isOn: selectedTags.contains(tag)) {
                                toggle(&selectedTags, tag)
                            }
                        }
                    case .kind:
                        ForEach(availableKinds, id: \.self) { kind in
                            SelectableRow(label: HostKind(rawValue: kind)?.label ?? kind,
                                          detail: nil,
                                          symbol: HostKind(rawValue: kind)?.symbol ?? "square",
                                          isOn: selectedKinds.contains(kind)) {
                                toggle(&selectedKinds, kind)
                            }
                        }
                    case .all:
                        Label("Toutes les machines activées.", systemImage: "globe")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("Fréquence", selection: $cron) {
                        ForEach(CronPreset.all) { Text($0.label).tag($0.expression) }
                        if usesCustomCron {
                            Text("Personnalisée").tag(cron)
                        }
                    }
                    Toggle("Expression personnalisée", isOn: $usesCustomCron)
                    if usesCustomCron {
                        TextField("0 3 * * *", text: $cron)
                            .font(.callout.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("Fréquence")
                } footer: {
                    Text("Format cron à cinq champs : minute, heure, jour du mois, mois, jour de la semaine.")
                }

                previewSection

                if let saveError {
                    Section {
                        Text(saveError.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Planification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") { Task { await save() } }
                        .disabled(!isValid || isSaving)
                }
            }
            .task { await loadHosts() }
            .task(id: previewKey) { await loadPreview() }
        }
    }

    // MARK: - Aperçu

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if let previewError {
                Label(previewError.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.warn)
            } else if let preview {
                LabeledValue(label: "Machines visées",
                             value: preview.targets.isEmpty
                                 ? "aucune"
                                 : preview.targets.map(\.name).joined(separator: ", "))
                ForEach(Array(preview.nextRuns.prefix(3).enumerated()), id: \.offset) { index, date in
                    LabeledValue(label: index == 0 ? "Prochaine" : "Puis",
                                 value: Format.fullDate(date))
                }
            } else if isValid {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Calcul de l'aperçu…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Complète le nom, la cible et la fréquence pour voir l'aperçu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Aperçu")
        } footer: {
            if preview?.targets.isEmpty == true {
                Text("Aucune machine ne correspond : la planification ne ferait rien.")
                    .foregroundStyle(Palette.warn)
            }
        }
    }

    // MARK: - État

    private var availableTags: [String] {
        Array(Set(hosts.flatMap(\.tags))).sorted()
    }

    private var availableKinds: [String] {
        Array(Set(hosts.map(\.kind.rawValue))).sorted()
    }

    private var targetValue: String? {
        switch targetKind {
        case .all: nil
        case .host: selectedHosts.isEmpty ? nil : selectedHosts.sorted().map(String.init).joined(separator: ",")
        case .tag: selectedTags.isEmpty ? nil : selectedTags.sorted().joined(separator: ",")
        case .kind: selectedKinds.isEmpty ? nil : selectedKinds.sorted().joined(separator: ",")
        }
    }

    private var params: [String: String] {
        guard let requirement = action.requiredParameter else { return [:] }
        let value = parameter.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? [:] : [requirement.key: value]
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard cron.split(separator: " ").count == 5 else { return false }
        guard targetKind == .all || targetValue != nil else { return false }
        if action.requiredParameter != nil, params.isEmpty { return false }
        return true
    }

    private var payload: SchedulePayload {
        SchedulePayload(name: name.trimmingCharacters(in: .whitespaces),
                        action: action.rawValue,
                        targetKind: targetKind.rawValue,
                        targetValue: targetValue,
                        params: params,
                        cron: cron,
                        enabled: true)
    }

    private var previewKey: String {
        "\(action.rawValue)|\(targetKind.rawValue)|\(targetValue ?? "")|\(cron)|\(isValid)"
    }

    private func toggle<T: Hashable>(_ set: inout Set<T>, _ value: T) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    // MARK: - Réseau

    private func loadHosts() async {
        guard let client = session.client else { return }
        hosts = (try? await client.get("/hosts")) ?? []
    }

    private func loadPreview() async {
        guard isValid, let client = session.client else {
            preview = nil
            previewError = nil
            return
        }
        do {
            preview = try await client.post("/schedules/preview", body: payload)
            previewError = nil
        } catch let error as APIError {
            guard !error.isCancellation else { return }
            preview = nil
            previewError = error
        } catch {
            preview = nil
            previewError = APIError.transport(error)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(payload)
            dismiss()
        } catch let error as APIError {
            saveError = error
        } catch {
            saveError = APIError.transport(error)
        }
    }
}

/// Ligne à cocher d'un formulaire — `List(selection:)` impose le mode édition,
/// trop lourd pour un choix qu'on fait en même temps que le reste du formulaire.
private struct SelectableRow: View {
    let label: String
    let detail: String?
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
