import SwiftUI

/// Les NAS Synology déclarés dans MBA.
///
/// Les paquets et les mises à jour DSM vivent dans l'écran « Mises à jour » —
/// ici, c'est le NAS lui-même qu'on regarde : ses disques, ses partages, ce qui
/// y tourne et qui y accède.
struct SynologyView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<[SynologyHost]> = .idle

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let hosts = state.value {
                if hosts.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucun NAS Synology",
                            message: "Enregistre un NAS depuis la console web, avec un compte DSM et le port 5001, pour suivre ses volumes, ses partages et ses tâches.",
                            symbol: "externaldrive.connected.to.line.below")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(hosts) { host in
                            NavigationLink(value: host) {
                                SynologyRow(host: host)
                            }
                        }
                    } footer: {
                        Text("Volumes, disques et température viennent du flux temps réel ; le reste est lu à la demande sur DSM.")
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
        .navigationTitle("Synology")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: SynologyHost.self) { host in
            SynologyDetailView(host: host)
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/synology/hosts"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

private struct SynologyRow: View {
    let host: SynologyHost

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(host.status.color)
                    .frame(width: 8, height: 8)
                Text(host.name)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 6)
                if let model = host.info.model {
                    TagChip(text: model)
                }
            }

            if let version = host.info.dsmVersion {
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let volume = host.fullestVolume {
                MetricBar(title: volume.name, value: volume.percent,
                          detail: "\(Format.bytes(volume.free)) libres")
            }

            HStack(spacing: 14) {
                Label("\(host.disks.count) disques", systemImage: "internaldrive")
                if let temperature = host.info.temperature {
                    Label(Format.temperature(temperature), systemImage: "thermometer.medium")
                        .foregroundStyle(host.info.tempWarn ? Palette.warn : .secondary)
                }
                if !host.failingDisks.isEmpty {
                    Label("\(host.failingDisks.count) en défaut",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.danger)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fiche

struct SynologyDetailView: View {
    let host: SynologyHost

    @Environment(SessionStore.self) private var session

    @State private var tab: SynoTab = .storage
    @State private var shares: Loadable<[SynoShare]> = .idle
    @State private var services: Loadable<SynoServicesResponse> = .idle
    @State private var tasks: Loadable<SynoTasksResponse> = .idle
    @State private var access: Loadable<SynoAccess> = .idle
    @State private var search = ""
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            summarySection

            switch tab {
            case .storage: storageTab
            case .shares: sharesTab
            case .system: systemTab
            case .access: accessTab
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: searchPrompt)
        .refreshable { await loadTab(force: true) }
        .task(id: tab) { await loadTab() }
        .actionResult(runner)
    }

    private var searchPrompt: String {
        switch tab {
        case .shares: "Nom de partage"
        case .system: "Tâche, service"
        case .access: "Compte, adresse"
        case .storage: "Disque"
        }
    }

    // MARK: - Synthèse

    private var summarySection: some View {
        Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: Format.percent(host.cpuUsage, digits: 0), label: "Processeur",
                             symbol: "cpu",
                             tint: Palette.severity(host.cpuUsage))
                    StatTile(value: Format.percent(host.memoryPercent, digits: 0), label: "Mémoire",
                             symbol: "memorychip",
                             tint: Palette.severity(host.memoryPercent))
                    StatTile(value: Format.temperature(host.info.temperature), label: "Température",
                             symbol: "thermometer.medium",
                             tint: host.info.tempWarn ? Palette.danger : Palette.ok)
                    StatTile(value: Format.duration(host.uptime), label: "Actif depuis",
                             symbol: "clock")
                }

                Picker("Vue", selection: $tab) {
                    ForEach(SynoTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Stockage

    @ViewBuilder
    private var storageTab: some View {
        if !host.volumes.isEmpty {
            Section("Volumes") {
                ForEach(host.volumes) { volume in
                    VolumeRow(volume: volume)
                }
            }
        }

        if !host.pools.isEmpty {
            Section("Groupes de stockage") {
                ForEach(host.pools) { pool in
                    HStack {
                        Label(pool.raid?.uppercased() ?? "RAID", systemImage: "square.stack.3d.down.right")
                            .font(.subheadline)
                        Spacer(minLength: 6)
                        Text(Format.bytes(pool.size))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        StatusBadge(text: pool.status,
                                    color: pool.isHealthy ? Palette.ok : Palette.danger)
                    }
                }
            }
        }

        let visibleDisks = host.disks.filter {
            normalizedSearch.isEmpty
                || $0.name.lowercased().contains(normalizedSearch)
                || $0.label.lowercased().contains(normalizedSearch)
        }
        if visibleDisks.isEmpty {
            Section {
                EmptyState(title: host.disks.isEmpty ? "Aucun disque remonté" : "Aucun résultat",
                           message: host.disks.isEmpty
                               ? "Le flux temps réel n'a pas encore livré l'état des disques."
                               : "Aucun disque ne correspond à « \(search) ».",
                           symbol: "internaldrive")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(visibleDisks) { disk in
                    DiskRow(disk: disk)
                }
            } header: {
                Text("Disques · \(visibleDisks.count)")
            } footer: {
                Text("DSM juge séparément l'état du disque et son verdict SMART : les deux doivent être « normal ».")
            }
        }
    }

    // MARK: - Partages

    @ViewBuilder
    private var sharesTab: some View {
        LoadableSection(state: shares, retry: { await loadShares(force: true) }) { list in
            let visible = list.filter { $0.matches(normalizedSearch) }
            if visible.isEmpty {
                Section {
                    EmptyState(title: list.isEmpty ? "Aucun partage" : "Aucun résultat",
                               message: list.isEmpty
                                   ? "Ce NAS n'expose aucun dossier partagé."
                                   : "Aucun partage ne correspond à « \(search) ».",
                               symbol: "folder")
                        .listRowBackground(Color.clear)
                }
            } else {
                Section("Dossiers partagés · \(visible.count)") {
                    ForEach(visible) { share in
                        HStack(spacing: 10) {
                            Image(systemName: share.isUSBShare ? "externaldrive.badge.plus" : "folder.fill")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(share.name)
                                    .font(.subheadline)
                                if let desc = share.desc, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 6)
                            if let path = share.volPath {
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    // MARK: - Système

    @ViewBuilder
    private var systemTab: some View {
        LoadableSection(state: services, retry: { await loadServices(force: true) }) { response in
            if let reason = response.reason {
                Section {
                    // DSM refuse parfois la liste selon sa version : mieux vaut
                    // dire pourquoi que d'afficher une section vide.
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Services DSM")
                }
            } else {
                let visible = response.services.filter {
                    normalizedSearch.isEmpty || $0.label.lowercased().contains(normalizedSearch)
                }
                if !visible.isEmpty {
                    Section("Services DSM · \(visible.count)") {
                        ForEach(visible) { service in
                            HStack {
                                Circle()
                                    .fill(service.enabled ? Palette.ok : Palette.idle)
                                    .frame(width: 8, height: 8)
                                Text(service.label)
                                    .font(.subheadline)
                                Spacer(minLength: 6)
                                Text(service.enabled ? "actif" : "inactif")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }

        LoadableSection(state: tasks, retry: { await loadTasks(force: true) }) { response in
            let visible = response.tasks.filter { $0.matches(normalizedSearch) }
            if visible.isEmpty {
                Section {
                    EmptyState(title: response.tasks.isEmpty ? "Aucune tâche planifiée" : "Aucun résultat",
                               message: response.reason
                                   ?? (response.tasks.isEmpty
                                       ? "Le planificateur de DSM ne contient aucune tâche."
                                       : "Aucune tâche ne correspond à « \(search) »."),
                               symbol: "calendar.badge.clock")
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(visible) { task in
                        SynoTaskRow(task: task)
                            .swipeActions(edge: .trailing) {
                                Button(task.enabled ? "Suspendre" : "Activer",
                                       systemImage: task.enabled ? "pause" : "play") {
                                    confirmTask(task, task.enabled ? "disable" : "enable")
                                }
                                .tint(task.enabled ? Palette.warn : Palette.ok)
                                if task.canRun {
                                    Button("Exécuter", systemImage: "play.fill") {
                                        confirmTask(task, "run")
                                    }
                                    .tint(.accentColor)
                                }
                            }
                    }
                } header: {
                    Text("Planificateur DSM · \(visible.count)")
                } footer: {
                    Text("Ces tâches vivent dans DSM, pas dans le planificateur de MBA.")
                }
            }
        }
    }

    // MARK: - Accès

    @ViewBuilder
    private var accessTab: some View {
        LoadableSection(state: access, retry: { await loadAccess(force: true) }) { response in
            let connections = response.connections.filter {
                normalizedSearch.isEmpty
                    || $0.user.lowercased().contains(normalizedSearch)
                    || $0.from.lowercased().contains(normalizedSearch)
            }
            if connections.isEmpty, let reason = response.connectionsReason {
                Section("Sessions ouvertes") {
                    Label(reason, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !connections.isEmpty {
                Section("Sessions ouvertes · \(connections.count)") {
                    ForEach(connections) { connection in
                        HStack(spacing: 10) {
                            Image(systemName: "person.wave.2")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.user)
                                    .font(.subheadline)
                                Text([connection.from, connection.detail]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 2) {
                                TagChip(text: connection.type)
                                if let time = connection.time {
                                    Text(time)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            let users = response.users.filter {
                normalizedSearch.isEmpty || $0.name.lowercased().contains(normalizedSearch)
            }
            if !users.isEmpty {
                Section {
                    ForEach(users) { user in
                        HStack(spacing: 10) {
                            Image(systemName: user.admin ? "person.badge.key.fill" : "person")
                                .foregroundStyle(user.admin ? Palette.warn : .secondary)
                                .imageScale(.small)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name)
                                    .font(.subheadline)
                                if let description = user.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 6)
                            if user.isDisabled {
                                TagChip(text: "désactivé", symbol: "nosign")
                            } else if user.admin {
                                StatusBadge(text: "administrateur", color: Palette.warn)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Comptes DSM · \(users.count)")
                } footer: {
                    Text("\(Format.plural(response.admins.count, "compte")) avec les droits d'administration.")
                }
            }
        }
    }

    // MARK: - Actions

    private func confirmTask(_ task: SynoTask, _ action: String) {
        let titles = ["run": "Exécuter", "enable": "Activer", "disable": "Suspendre"]
        let title = titles[action] ?? action
        runner.confirm(
            "\(title) « \(task.name) » ?",
            message: action == "run"
                ? "La tâche part tout de suite sur \(host.name), en plus de sa planification habituelle."
                : "La planification DSM de cette tâche est modifiée sur \(host.name).",
            confirmLabel: title,
            isDestructive: action == "disable"
        ) { [client = session.client, hostID = host.id] in
            guard let client else { return nil }
            try await client.perform("/synology/\(hostID)/tasks",
                                     body: SynoTaskPayload(taskID: task.id, action: action))
            return "\(title) demandé sur « \(task.name) »."
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            await loadTasks(force: true)
        }
    }

    // MARK: - Réseau

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Chaque onglet a sa requête : ouvrir la fiche ne doit pas réveiller DSM
    /// quatre fois pour des données qu'on ne regardera peut-être pas.
    private func loadTab(force: Bool = false) async {
        switch tab {
        case .storage: break
        case .shares: await loadShares(force: force)
        case .system:
            await loadServices(force: force)
            await loadTasks(force: force)
        case .access: await loadAccess(force: force)
        }
    }

    private func loadShares(force: Bool) async {
        guard force || shares.value == nil, let client = session.client else { return }
        shares.begin()
        do {
            shares = .loaded(try await client.get("/synology/\(host.id)/shares"))
        } catch let error as APIError {
            if !error.isCancellation { shares = .failed(error) }
        } catch {
            shares = .failed(APIError.transport(error))
        }
    }

    private func loadServices(force: Bool) async {
        guard force || services.value == nil, let client = session.client else { return }
        services.begin()
        do {
            services = .loaded(try await client.get("/synology/\(host.id)/services"))
        } catch let error as APIError {
            if !error.isCancellation { services = .failed(error) }
        } catch {
            services = .failed(APIError.transport(error))
        }
    }

    private func loadTasks(force: Bool) async {
        guard force || tasks.value == nil, let client = session.client else { return }
        tasks.begin()
        do {
            tasks = .loaded(try await client.get("/synology/\(host.id)/tasks"))
        } catch let error as APIError {
            if !error.isCancellation { tasks = .failed(error) }
        } catch {
            tasks = .failed(APIError.transport(error))
        }
    }

    private func loadAccess(force: Bool) async {
        guard force || access.value == nil, let client = session.client else { return }
        access.begin()
        do {
            access = .loaded(try await client.get("/synology/\(host.id)/access"))
        } catch let error as APIError {
            if !error.isCancellation { access = .failed(error) }
        } catch {
            access = .failed(APIError.transport(error))
        }
    }
}

enum SynoTab: String, CaseIterable, Identifiable {
    case storage, shares, system, access

    var id: String { rawValue }

    var label: String {
        switch self {
        case .storage: "Stockage"
        case .shares: "Partages"
        case .system: "Système"
        case .access: "Accès"
        }
    }
}

/// Section de liste qui porte elle-même son chargement et son erreur — les
/// onglets d'un NAS interrogent DSM séparément, chacun peut échouer seul.
private struct LoadableSection<Value: Sendable, Content: View>: View {
    let state: Loadable<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            }
        case .failed(let error):
            Section {
                InlineErrorBanner(error: error) { Task { await retry() } }
                    .listRowBackground(Color.clear)
            }
        case .loaded(let value):
            content(value)
        }
    }
}

// MARK: - Lignes

private struct VolumeRow: View {
    let volume: SynoVolume

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(volume.name, systemImage: "externaldrive.fill")
                    .font(.subheadline)
                Spacer(minLength: 6)
                if let fs = volume.fs {
                    TagChip(text: fs)
                }
                if !volume.isHealthy {
                    StatusBadge(text: volume.status, color: Palette.danger,
                                symbol: "exclamationmark.triangle.fill")
                }
            }
            MetricBar(title: "\(Format.bytes(volume.used)) / \(Format.bytes(volume.total))",
                      value: volume.percent,
                      detail: Format.percent(volume.percent, digits: 1))
            Text("\(Format.bytes(volume.free)) libres")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

private struct DiskRow: View {
    let disk: SynoDisk

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: disk.isHealthy ? "internaldrive" : "internaldrive.badge.xmark")
                .foregroundStyle(disk.isHealthy ? .secondary : Palette.danger)
                .imageScale(.small)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(disk.name)
                    .font(.subheadline)
                Text(disk.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.bytes(disk.size))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if let temperature = disk.temp {
                        // 45 °C est le seuil au-delà duquel l'espérance de vie
                        // d'un disque mécanique commence à se dégrader.
                        Text(Format.temperature(temperature))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(temperature >= 45 ? Palette.warn : Color.secondary)
                    }
                    if !disk.isHealthy {
                        StatusBadge(text: disk.smart ?? disk.status, color: Palette.danger)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct SynoTaskRow: View {
    let task: SynoTask

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(task.enabled ? Palette.ok : Palette.idle)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text([task.typeLabel, task.owner].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if let succeeded = task.lastSucceeded {
                    Image(systemName: succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(succeeded ? Palette.ok : Palette.danger)
                        .imageScale(.small)
                }
                if let next = task.nextRun, task.enabled {
                    Text(next)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(task.enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }
}
