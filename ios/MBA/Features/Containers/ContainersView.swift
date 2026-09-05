import SwiftUI

struct ContainersView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<[Container]> = .idle
    @State private var projects: ProjectsResponse?
    @State private var search = ""
    @State private var grouping: Grouping = .project
    @State private var onlyStopped = false
    @State private var runner = ActionRunner()
    @State private var maintenanceHost: Host?
    @State private var hosts: [Host] = []

    private enum Grouping: String, CaseIterable, Identifiable {
        case project, host, flat
        var id: String { rawValue }
        var label: String {
            switch self {
            case .project: "Pile"
            case .host: "Machine"
            case .flat: "À plat"
            }
        }
    }

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if state.value != nil {
                if let summary = projects?.summary, grouping == .project {
                    Section {
                        HStack(spacing: 10) {
                            StatTile(value: "\(summary.projects)", label: "Piles compose",
                                     symbol: "square.stack.3d.up", tint: .accentColor)
                            StatTile(value: "\(summary.orphans)", label: "Hors pile",
                                     symbol: "shippingbox",
                                     tint: summary.orphans > 0 ? Palette.warn : .secondary)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listRowBackground(Color.clear)
                }

                let visible = filtered
                if visible.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucun conteneur",
                            message: search.isEmpty
                                ? "Aucun conteneur ne correspond à ce filtre."
                                : "Aucun conteneur ne correspond à « \(search) ».",
                            symbol: "shippingbox")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(groups(of: visible), id: \.key) { group in
                        Section {
                            ForEach(group.items) { container in
                                NavigationLink(value: container) {
                                    ContainerRow(container: container,
                                                 showsHost: grouping != .host)
                                }
                            }
                        } header: {
                            groupHeader(group)
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
        .navigationTitle("Conteneurs")
        .searchable(text: $search, prompt: "Nom, image, pile")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: Container.self) { container in
            ContainerDetailView(container: container) { await load() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Regrouper par", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Seulement les arrêtés", isOn: $onlyStopped)
                    if !dockerHosts.isEmpty {
                        Divider()
                        Menu("Ménage Docker") {
                            ForEach(dockerHosts) { host in
                                Button(host.name) { maintenanceHost = host }
                            }
                        }
                    }
                } label: {
                    Label("Options", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .sheet(item: $maintenanceHost) { host in
            DockerMaintenanceView(host: host)
        }
        .actionResult(runner)
    }

    // MARK: - Regroupement

    private struct Group {
        let key: String
        let title: String
        let subtitle: String?
        let items: [Container]
        let project: ContainerProject?
    }

    private func groups(of containers: [Container]) -> [Group] {
        switch grouping {
        case .flat:
            return [Group(key: "all", title: Format.plural(containers.count, "conteneur"),
                          subtitle: nil, items: containers, project: nil)]
        case .host:
            return Dictionary(grouping: containers, by: \.hostID)
                .map { hostID, items in
                    Group(key: "h\(hostID)",
                          title: items.first?.hostName ?? "Machine \(hostID)",
                          subtitle: "\(items.filter(\.isRunning).count)/\(items.count) actifs",
                          items: sorted(items), project: nil)
                }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .project:
            return Dictionary(grouping: containers, by: { "\($0.hostID):\($0.project ?? "~")" })
                .map { key, items in
                    let project = projects?.projects.first { $0.id == key.replacingOccurrences(
                        of: ":~", with: ":~orphans") }
                    let name = items.first?.project ?? "Hors pile"
                    return Group(key: key, title: name,
                                 subtitle: items.first?.hostName,
                                 items: sorted(items), project: project)
                }
                .sorted { first, second in
                    // Les conteneurs hors pile en dernier : ce sont les restes.
                    if (first.title == "Hors pile") != (second.title == "Hors pile") {
                        return second.title == "Hors pile"
                    }
                    return first.title.localizedStandardCompare(second.title) == .orderedAscending
                }
        }
    }

    private func sorted(_ items: [Container]) -> [Container] {
        items.sorted { first, second in
            if first.isRunning != second.isRunning { return first.isRunning }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: Group) -> some View {
        HStack(spacing: 6) {
            Text(group.title)
            if let subtitle = group.subtitle {
                Text("·")
                Text(subtitle)
            }
            Spacer()
            let running = group.items.filter(\.isRunning).count
            if running < group.items.count {
                Text("\(running)/\(group.items.count)")
                    .foregroundStyle(Palette.warn)
            }
            if grouping == .project, group.title != "Hors pile",
               let hostID = group.items.first?.hostID {
                Menu {
                    Button("Démarrer la pile", systemImage: "play") {
                        confirmProject(group.title, host: hostID, action: "start")
                    }
                    Button("Redémarrer la pile", systemImage: "arrow.clockwise") {
                        confirmProject(group.title, host: hostID, action: "restart")
                    }
                    Button("Arrêter la pile", systemImage: "stop", role: .destructive) {
                        confirmProject(group.title, host: hostID, action: "stop")
                    }
                    Divider()
                    Button("Mettre à jour (pull + up)", systemImage: "arrow.down.circle") {
                        confirmProjectUpdate(group.title, host: hostID)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.small)
                }
            }
        }
        .textCase(nil)
    }

    // MARK: - Filtres

    private var dockerHosts: [Host] {
        hosts.filter { $0.kind == .docker || $0.kind == .linux }
    }

    private var filtered: [Container] {
        var containers = state.value ?? []
        if onlyStopped { containers = containers.filter { !$0.isRunning } }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            containers = containers.filter { container in
                container.name.lowercased().contains(query)
                    || (container.image?.lowercased().contains(query) ?? false)
                    || (container.project?.lowercased().contains(query) ?? false)
                    || (container.hostName?.lowercased().contains(query) ?? false)
            }
        }
        return containers
    }

    // MARK: - Actions de pile

    private func confirmProject(_ project: String, host: Int, action: String) {
        guard let client = session.client else { return }
        let labels = ["start": "Démarrer", "stop": "Arrêter", "restart": "Redémarrer"]
        runner.confirm(
            "\(labels[action] ?? action) « \(project) »",
            message: action == "start"
                ? "Tous les conteneurs de la pile seront démarrés."
                : "Tous les conteneurs de la pile sont concernés : les services qu'ils rendent seront interrompus.",
            confirmLabel: labels[action] ?? action,
            isDestructive: action != "start"
        ) {
            let response = try await client.perform("/hosts/\(host)/projects/\(project)/\(action)")
            let done = response["done"]?.arrayValue?.count ?? 0
            let errors = response["errors"]?.arrayValue ?? []
            if errors.isEmpty { return "\(done) conteneur(s) traité(s)." }
            let details = errors.compactMap { $0["error"]?.stringValue }.joined(separator: "\n")
            return "\(done) traité(s), \(errors.count) en échec :\n\(details)"
        }
        Task { await load() }
    }

    private func confirmProjectUpdate(_ project: String, host: Int) {
        guard let client = session.client else { return }
        runner.confirm(
            "Mettre à jour « \(project) »",
            message: "Exécute « compose pull » puis « up -d ». Les conteneurs sont recréés et le service est interrompu le temps du redéploiement.",
            confirmLabel: "Mettre à jour"
        ) {
            let response = try await client.perform("/hosts/\(host)/projects/\(project)/update")
            let output = response["output"]?.stringValue ?? ""
            return output.isEmpty ? "Pile mise à jour." : String(output.suffix(800))
        }
        Task { await load() }
    }

    // MARK: - Chargement

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            async let containerList: [Container] = client.get("/containers")
            async let projectList: ProjectsResponse = client.get("/containers/projects")
            async let hostList: [Host] = client.get("/hosts")
            let (containers, projectResponse, loadedHosts) =
                try await (containerList, projectList, hostList)
            projects = projectResponse
            hosts = loadedHosts
            state = .loaded(containers)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

struct ContainerRow: View {
    let container: Container
    var showsHost = true

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Palette.serviceStatus(container.state ?? ""))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let image = container.shortImage {
                        Text(image).lineLimit(1)
                    }
                    if showsHost, let host = container.hostName {
                        Text("·")
                        Text(host)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if container.isRunning {
                VStack(alignment: .trailing, spacing: 1) {
                    if let cpu = container.cpu {
                        Text(Format.percent(cpu, digits: 1))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.severity(cpu))
                    }
                    if let memory = container.memory {
                        Text(Format.bytes(memory, digits: 0))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(container.status ?? "arrêté")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(container.name), \(container.isRunning ? "actif" : "arrêté")")
    }
}
