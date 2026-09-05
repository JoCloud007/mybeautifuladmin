import SwiftUI

/// Auto-remédiation : les règles qui laissent MBA agir seul.
///
/// C'est la section où l'on donne la main à la machine : l'écran insiste donc
/// sur les garde-fous — délai de confirmation, délai de garde, plafond
/// quotidien — autant que sur ce que la règle fait.
struct RemediationView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<RemediationList> = .idle
    @State private var catalog: RemediationCatalog?
    @State private var tab: RemediationTab = .rules
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
                summarySection(list)

                switch tab {
                case .rules: rulesTab(list)
                case .runs: runsTab(list)
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
        .navigationTitle("Auto-remédiation")
        .searchable(text: $search, prompt: "Règle, déclencheur, action")
        .refreshable { await load() }
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Nouvelle règle", systemImage: "plus") { isCreating = true }
                    .disabled(catalog == nil)
            }
        }
        .sheet(isPresented: $isCreating) {
            if let catalog {
                RuleEditor(catalog: catalog) { payload in
                    try await create(payload)
                }
            }
        }
        .navigationDestination(for: RemediationRule.self) { rule in
            RuleDetailView(rule: rule,
                           runs: state.value?.runs.filter { $0.ruleID == rule.id } ?? [],
                           onRun: { confirmRun(rule) },
                           onToggle: { await toggle(rule) },
                           onDelete: { confirmDelete(rule) })
        }
        .actionResult(runner)
    }

    // MARK: - Synthèse

    private func summarySection(_ list: RemediationList) -> some View {
        let active = list.rules.filter(\.enabled)
        let destructive = active.filter(\.allowDestructive)
        let capped = active.filter(\.isCapped)

        return Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(active.count)", label: "Règles actives",
                             symbol: "wand.and.sparkles",
                             tint: active.isEmpty ? Palette.idle : Palette.ok,
                             trailing: "/ \(list.rules.count)")
                    StatTile(value: "\(list.runs.filter { $0.startedAt != nil }.count)",
                             label: "Exécutions récentes", symbol: "clock.arrow.circlepath")
                }

                if !destructive.isEmpty {
                    // Une règle autorisée à couper un service mérite d'être vue
                    // en tête d'écran, pas au fond d'une fiche.
                    Label("\(Format.plural(destructive.count, "règle")) peu\(destructive.count > 1 ? "vent" : "t") interrompre un service.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.warn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !capped.isEmpty {
                    Label("\(Format.plural(capped.count, "règle")) a\(capped.count > 1 ? "ont" : "") atteint son plafond quotidien.",
                          systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Picker("Vue", selection: $tab) {
                    ForEach(RemediationTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Règles

    @ViewBuilder
    private func rulesTab(_ list: RemediationList) -> some View {
        let visible = list.rules.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(
                    title: list.rules.isEmpty ? "Aucune règle" : "Aucun résultat",
                    message: list.rules.isEmpty
                        ? "Une règle relie un symptôme à un geste : « service web en panne → redémarrer le service ». MBA attend le délai de confirmation avant d'agir, et ne recommence pas plus que le plafond fixé."
                        : "Aucune règle ne correspond à « \(search) ».",
                    symbol: "wand.and.sparkles",
                    actionTitle: list.rules.isEmpty && catalog != nil ? "Créer une règle" : nil,
                    action: list.rules.isEmpty ? { isCreating = true } : nil)
                    .listRowBackground(Color.clear)
            }
        } else {
            let active = visible.filter(\.enabled)
            let paused = visible.filter { !$0.enabled }
            if !active.isEmpty {
                Section("Actives · \(active.count)") {
                    ForEach(active) { rule in ruleRow(rule) }
                }
            }
            if !paused.isEmpty {
                Section("Suspendues · \(paused.count)") {
                    ForEach(paused) { rule in ruleRow(rule) }
                }
            }
        }
    }

    private func ruleRow(_ rule: RemediationRule) -> some View {
        NavigationLink(value: rule) {
            RuleRow(rule: rule)
        }
        .swipeActions(edge: .trailing) {
            Button("Supprimer", systemImage: "trash", role: .destructive) {
                confirmDelete(rule)
            }
            Button(rule.enabled ? "Suspendre" : "Activer",
                   systemImage: rule.enabled ? "pause" : "play") {
                Task { await toggle(rule) }
            }
            .tint(rule.enabled ? Palette.warn : Palette.ok)
        }
        .swipeActions(edge: .leading) {
            Button("Exécuter", systemImage: "play.fill") { confirmRun(rule) }
                .tint(.accentColor)
        }
    }

    // MARK: - Exécutions

    @ViewBuilder
    private func runsTab(_ list: RemediationList) -> some View {
        let visible = list.runs.filter {
            normalizedSearch.isEmpty
                || ($0.ruleName?.lowercased().contains(normalizedSearch) ?? false)
                || ($0.hostName?.lowercased().contains(normalizedSearch) ?? false)
        }
        if visible.isEmpty {
            Section {
                EmptyState(title: "Aucune exécution",
                           message: "Aucune règle ne s'est déclenchée. C'est plutôt bon signe.",
                           symbol: "clock.arrow.circlepath")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(visible) { run in
                    RunRow(run: run)
                }
            } footer: {
                Text("Une exécution « ignorée » signifie que la règle a vu le symptôme mais s'est abstenue : plafond atteint, délai de garde non écoulé, ou cible déjà traitée.")
            }
        }
    }

    // MARK: - Actions

    private func confirmRun(_ rule: RemediationRule) {
        runner.confirm(
            "Exécuter « \(rule.name) » ?",
            message: "\(rule.actionLabel) sur \(rule.scopeSummary), tout de suite — sans attendre le délai de confirmation ni vérifier le plafond quotidien.",
            confirmLabel: "Exécuter",
            isDestructive: rule.allowDestructive
        ) { [client = session.client] in
            guard let client else { return nil }
            let response = try await client.perform("/remediation/\(rule.id)/run")
            let status = response["status"]?.stringValue ?? "?"
            let detail = response["detail"]?.stringValue
            let verdict = switch status {
            case "success": "Règle appliquée."
            case "skipped": "Règle ignorée : aucune cible ne remplit la condition."
            default: "Règle en échec."
            }
            guard let detail, !detail.isEmpty else { return verdict }
            return "\(verdict)\n\n\(detail.prefix(600))"
        }
        Task { await reloadSoon() }
    }

    private func confirmDelete(_ rule: RemediationRule) {
        runner.confirm(
            "Supprimer « \(rule.name) » ?",
            message: "La règle est retirée définitivement. Son historique d'exécutions part avec elle.",
            confirmLabel: "Supprimer"
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.delete("/remediation/\(rule.id)")
            return "Règle supprimée."
        }
        Task { await reloadSoon() }
    }

    private func toggle(_ rule: RemediationRule) async {
        guard let client = session.client else { return }
        let enabling = !rule.enabled
        await runner.run(enabling ? "Règle activée" : "Règle suspendue") {
            let _: JSONValue = try await client.patch("/remediation/\(rule.id)",
                                                      body: RemediationPatch(enabled: enabling))
            return enabling
                ? "« \(rule.name) » agira de nouveau dès que la condition sera réunie."
                : "« \(rule.name) » n'agira plus tant qu'elle est suspendue."
        }
        await load()
    }

    private func create(_ payload: RemediationPayload) async throws {
        guard let client = session.client else { return }
        let _: JSONValue = try await client.post("/remediation", body: payload)
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
            state = .loaded(try await client.get("/remediation"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
        if catalog == nil {
            catalog = try? await client.get("/remediation/catalog")
        }
    }

    private func reloadSoon() async {
        try? await Task.sleep(for: .seconds(2))
        await load()
    }
}

enum RemediationTab: String, CaseIterable, Identifiable {
    case rules, runs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rules: "Règles"
        case .runs: "Exécutions"
        }
    }
}

// MARK: - Lignes

private struct RuleRow: View {
    let rule: RemediationRule

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: rule.allowDestructive ? "exclamationmark.triangle.fill" : "wand.and.sparkles")
                .foregroundStyle(rule.allowDestructive ? Palette.warn
                                 : rule.enabled ? Color.accentColor : Color.secondary)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name)
                    .font(.subheadline)
                    .lineLimit(1)
                // La phrase « symptôme → geste » dit tout de la règle en une ligne.
                Text("\(rule.triggerLabel) → \(rule.actionLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    TagChip(text: rule.scopeSummary)
                    if rule.isCapped {
                        StatusBadge(text: "plafond atteint", color: Palette.warn,
                                    symbol: "hand.raised.fill")
                    } else if let succeeded = rule.lastSucceeded {
                        StatusBadge(text: succeeded ? "dernière réussie" : "dernière en échec",
                                    color: succeeded ? Palette.ok : Palette.danger)
                    }
                }
            }

            Spacer(minLength: 4)

            if rule.stats.total > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(rule.stats.today)/\(rule.maxPerDay)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(rule.isCapped ? Palette.warn : .secondary)
                    Text("aujourd'hui")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(rule.enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}

private struct RunRow: View {
    let run: RemediationRun

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.ruleName ?? "Règle supprimée")
                    .font(.subheadline)
                    .lineLimit(1)
                Text([run.hostName, run.detail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(run.statusLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
                Text(Format.ago(run.startedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        if run.isRunning { return .accentColor }
        if run.wasSkipped { return Palette.idle }
        return run.succeeded ? Palette.ok : Palette.danger
    }
}

// MARK: - Fiche

private struct RuleDetailView: View {
    let rule: RemediationRule
    let runs: [RemediationRun]
    let onRun: () -> Void
    let onToggle: () async -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                SectionBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StatusBadge(text: rule.enabled ? "active" : "suspendue",
                                        color: rule.enabled ? Palette.ok : Palette.idle,
                                        symbol: rule.enabled ? "play.fill" : "pause.fill")
                            Spacer(minLength: 6)
                            if rule.allowDestructive {
                                StatusBadge(text: "destructive", color: Palette.warn,
                                            symbol: "exclamationmark.triangle.fill")
                            }
                        }
                        Text("\(rule.triggerLabel) → \(rule.actionLabel)")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let description = rule.description, !description.isEmpty {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                SectionBox("Garde-fous", symbol: "shield.lefthalf.filled") {
                    VStack(spacing: 10) {
                        LabeledValue(label: "Confirmation",
                                     value: Format.duration(Double(rule.confirmSeconds)))
                        LabeledValue(label: "Délai de garde",
                                     value: Format.duration(Double(rule.cooldownSeconds)))
                        LabeledValue(label: "Plafond quotidien",
                                     value: "\(rule.stats.today) / \(rule.maxPerDay)")
                        LabeledValue(label: "Périmètre", value: rule.scopeSummary)
                        if rule.isCapped {
                            Label("Plafond atteint : la règle n'agira plus aujourd'hui.",
                                  systemImage: "hand.raised.fill")
                                .font(.caption)
                                .foregroundStyle(Palette.warn)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                SectionBox("Historique", symbol: "clock.arrow.circlepath") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledValue(label: "Exécutions", value: "\(rule.stats.total)")
                        LabeledValue(label: "Réussites", value: "\(rule.stats.ok)")
                        LabeledValue(label: "Dernière",
                                     value: rule.lastRun == nil
                                         ? "jamais"
                                         : "\(Format.fullDate(rule.lastRun)) (\(rule.lastStatus ?? "?"))")

                        if !runs.isEmpty {
                            Divider()
                            ForEach(runs.prefix(10)) { run in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(Format.dateTime(run.startedAt))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 92, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text([run.hostName, run.statusLabel]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption.weight(.medium))
                                        if let detail = run.detail, !detail.isEmpty {
                                            Text(detail)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }

                SectionBox {
                    VStack(spacing: 10) {
                        Button {
                            onRun()
                        } label: {
                            Label("Exécuter maintenant", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            Task { await onToggle() }
                        } label: {
                            Label(rule.enabled ? "Suspendre" : "Activer",
                                  systemImage: rule.enabled ? "pause" : "play")
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
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(rule.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Création

private struct RuleEditor: View {
    let catalog: RemediationCatalog
    let onSave: (RemediationPayload) async throws -> Void

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var trigger = ""
    @State private var action = ""
    @State private var parameter = ""
    @State private var agentID: Int?
    @State private var scopeKind: TargetKind = .all
    @State private var scopeValue = ""
    @State private var confirmMinutes = 5
    @State private var cooldownMinutes = 30
    @State private var maxPerDay = 3
    @State private var allowDestructive = false

    @State private var preview: RemediationPreview?
    @State private var previewError: APIError?
    @State private var isSaving = false
    @State private var saveError: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Règle") {
                    TextField("Nom", text: $name)
                    Picker("Quand", selection: $trigger) {
                        ForEach(catalog.sortedTriggers, id: \.key) { entry in
                            Text(entry.trigger.label).tag(entry.key)
                        }
                    }
                    Picker("Alors", selection: $action) {
                        ForEach(catalog.sortedActions, id: \.key) { entry in
                            Text(entry.action.label).tag(entry.key)
                        }
                    }
                }

                if let help = catalog.triggers[trigger]?.help {
                    Section {
                        Text(help)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let spec = catalog.actions[action], !spec.params.isEmpty {
                    Section {
                        if spec.params.contains("agent_id") {
                            Picker("Agent", selection: $agentID) {
                                Text("Choisir…").tag(Int?.none)
                                ForEach(catalog.agents) { agent in
                                    Text("\(agent.name) (\(agent.mode))").tag(Int?.some(agent.id))
                                }
                            }
                        } else {
                            TextField(spec.params.first ?? "Paramètre", text: $parameter)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    } header: {
                        Text("Paramètre requis")
                    }
                }

                if catalog.actions[action]?.destructive == true {
                    Section {
                        Toggle("Autoriser les actions destructives", isOn: $allowDestructive)
                    } footer: {
                        Text("« \(catalog.actions[action]?.label ?? "") » interrompt un service. Le serveur refuse la règle tant que cette case n'est pas cochée.")
                            .foregroundStyle(allowDestructive ? .secondary : Palette.warn)
                    }
                }

                Section("Périmètre") {
                    Picker("Portée", selection: $scopeKind) {
                        ForEach(TargetKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if scopeKind != .all {
                        TextField(scopeKind == .tag ? "prod, edge" : "linux, docker",
                                  text: $scopeValue)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Stepper("Confirmation : \(confirmMinutes) min",
                            value: $confirmMinutes, in: 1...240)
                    Stepper("Délai de garde : \(cooldownMinutes) min",
                            value: $cooldownMinutes, in: 1...1440)
                    Stepper("Au plus \(maxPerDay) fois par jour", value: $maxPerDay, in: 1...50)
                } header: {
                    Text("Garde-fous")
                } footer: {
                    Text("Le délai de confirmation évite d'agir sur une coupure passagère ; le délai de garde empêche la règle de s'acharner ; le plafond borne les dégâts d'un symptôme qui persiste.")
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
            .navigationTitle("Règle")
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
            .onAppear {
                if trigger.isEmpty { trigger = catalog.sortedTriggers.first?.key ?? "" }
                if action.isEmpty {
                    // On s'ouvre sur une action qui ne réclame ni paramètre ni
                    // autorisation : sinon le formulaire naît invalide, avec un
                    // bouton « Créer » grisé sans qu'on sache pourquoi.
                    action = catalog.sortedActions.first {
                        $0.action.params.isEmpty && !$0.action.destructive
                    }?.key ?? catalog.sortedActions.first?.key ?? ""
                }
            }
            .task(id: previewKey) { await loadPreview() }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section {
            if let previewError {
                Label(previewError.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.warn)
            } else if let preview {
                LabeledValue(label: "Cibles concernées",
                             value: preview.targets.isEmpty
                                 ? "aucune pour l'instant"
                                 : preview.targets.map(\.label).joined(separator: ", "))
            } else if isValid {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Calcul de l'aperçu…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Complète le nom et les paramètres pour voir l'aperçu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Aperçu")
        } footer: {
            Text("Ce que la règle traiterait si elle se déclenchait maintenant. Une liste vide est normale quand tout va bien.")
        }
    }

    // MARK: - État

    private var params: [String: String] {
        guard let spec = catalog.actions[action], let key = spec.params.first else { return [:] }
        if key == "agent_id" {
            return agentID.map { [key: String($0)] } ?? [:]
        }
        let value = parameter.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? [:] : [key: value]
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard !trigger.isEmpty, !action.isEmpty else { return false }
        guard let spec = catalog.actions[action] else { return false }
        if !spec.params.isEmpty && params.isEmpty { return false }
        if spec.destructive && !allowDestructive { return false }
        if scopeKind != .all && scopeValue.trimmingCharacters(in: .whitespaces).isEmpty {
            return false
        }
        return true
    }

    private var payload: RemediationPayload {
        RemediationPayload(
            name: name.trimmingCharacters(in: .whitespaces),
            description: nil,
            trigger: trigger,
            action: action,
            params: params,
            scopeKind: scopeKind.rawValue,
            scopeValue: scopeKind == .all
                ? nil : scopeValue.trimmingCharacters(in: .whitespaces),
            confirmSeconds: confirmMinutes * 60,
            cooldownSeconds: cooldownMinutes * 60,
            maxPerDay: maxPerDay,
            allowDestructive: allowDestructive,
            enabled: true)
    }

    private var previewKey: String {
        "\(trigger)|\(action)|\(scopeKind.rawValue)|\(scopeValue)|\(isValid)"
    }

    private func loadPreview() async {
        guard isValid, let client = session.client else {
            preview = nil
            previewError = nil
            return
        }
        do {
            preview = try await client.post("/remediation/preview", body: payload)
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
