import SwiftUI

/// Les hyperviseurs Proxmox déclarés dans MBA.
///
/// Un seul cluster dans la plupart des installations : la liste reste malgré
/// tout, parce qu'elle porte la synthèse (nœuds, invités, stockages) qu'on veut
/// voir avant d'entrer.
struct ProxmoxView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<[PVECluster]> = .idle

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let clusters = state.value {
                if clusters.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucun hyperviseur",
                            message: "Enregistre un hôte de type Proxmox depuis la console web — avec un jeton d'API sur le port 8006 — pour piloter ses VM et ses conteneurs.",
                            symbol: "square.stack.3d.up")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(clusters) { cluster in
                            NavigationLink(value: cluster) {
                                ClusterRow(cluster: cluster)
                            }
                        }
                    } footer: {
                        Text("L'inventaire vient du flux temps réel ; il se remplit quelques secondes après la connexion au serveur.")
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
        .navigationTitle("Proxmox")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: PVECluster.self) { cluster in
            PVEClusterView(cluster: cluster)
        }
        .navigationDestination(for: PVEGuestRoute.self) { route in
            PVEGuestView(route: route)
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/proxmox/hosts"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

/// Cible d'une fiche d'invité — le triplet qui identifie une VM ou un LXC.
struct PVEGuestRoute: Hashable, Sendable {
    let hostID: Int
    let node: String
    let kind: GuestKind
    let vmid: Int
    let name: String
}

private struct ClusterRow: View {
    let cluster: PVECluster

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(cluster.status.color)
                    .frame(width: 8, height: 8)
                Text(cluster.name)
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 6)
                if let version = cluster.nodes.first?.shortVersion {
                    TagChip(text: "PVE \(version)")
                }
            }
            Text(cluster.address)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if cluster.hasLiveSample {
                HStack(spacing: 14) {
                    Label("\(cluster.runningGuests)/\(cluster.guests.count)",
                          systemImage: "desktopcomputer")
                    Label("\(cluster.nodes.count)", systemImage: "server.rack")
                    Label("\(cluster.storages.count)", systemImage: "externaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Inventaire en attente du flux.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cluster

/// Un hyperviseur en quatre vues : ses invités, ses nœuds, ses stockages et ce
/// qu'il est en train de faire.
struct PVEClusterView: View {
    let cluster: PVECluster

    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<PVEInventory> = .idle
    @State private var tasks: [PVETask] = []
    @State private var tab: PVETab = .guests
    @State private var search = ""
    @State private var runner = ActionRunner()

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let inventory = state.value {
                summarySection(inventory)

                switch tab {
                case .guests: guestsTab(inventory)
                case .nodes: nodesTab(inventory)
                case .storages: storagesTab(inventory)
                case .tasks: tasksTab
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
        .navigationTitle(cluster.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Nom, VMID, étiquette")
        .refreshable { await load() }
        .task { await load() }
        .task(id: tab) { if tab == .tasks { await loadTasks() } }
        .actionResult(runner)
    }

    private func summarySection(_ inventory: PVEInventory) -> some View {
        Section {
            VStack(spacing: Metrics.spacing) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(value: "\(inventory.summary.running)", label: "En marche",
                             symbol: "play.circle", tint: Palette.ok,
                             trailing: "/ \(inventory.summary.total)")
                    StatTile(value: "\(inventory.summary.qemu)", label: "VM",
                             symbol: "desktopcomputer",
                             trailing: "\(inventory.summary.lxc) LXC")
                }

                Picker("Vue", selection: $tab) {
                    ForEach(PVETab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    // MARK: - Invités

    @ViewBuilder
    private func guestsTab(_ inventory: PVEInventory) -> some View {
        let visible = inventory.guests.filter { $0.matches(normalizedSearch) }
        if visible.isEmpty {
            Section {
                EmptyState(title: inventory.guests.isEmpty ? "Aucun invité" : "Aucun résultat",
                           message: inventory.guests.isEmpty
                               ? "Cet hyperviseur n'héberge aucune VM ni conteneur, ou le flux n'a pas encore remonté son inventaire."
                               : "Aucun invité ne correspond à « \(search) ».",
                           symbol: "desktopcomputer")
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(grouped(visible), id: \.node) { group in
                Section(inventory.nodes.count > 1 ? "Nœud \(group.node)" : "Invités") {
                    ForEach(group.guests) { guest in
                        NavigationLink(value: PVEGuestRoute(hostID: cluster.id, node: guest.node,
                                                            kind: guest.type, vmid: guest.vmid,
                                                            name: guest.name)) {
                            GuestRow(guest: guest)
                        }
                        .swipeActions(edge: .trailing) {
                            if guest.isRunning {
                                Button("Arrêter", systemImage: "stop.fill") {
                                    confirmPower(guest, "stop")
                                }
                                .tint(Palette.danger)
                                Button("Éteindre", systemImage: "power") {
                                    confirmPower(guest, "shutdown")
                                }
                                .tint(Palette.warn)
                            } else {
                                Button("Démarrer", systemImage: "play.fill") {
                                    confirmPower(guest, "start")
                                }
                                .tint(Palette.ok)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Nœuds

    @ViewBuilder
    private func nodesTab(_ inventory: PVEInventory) -> some View {
        if inventory.nodes.isEmpty {
            Section {
                EmptyState(title: "Aucun nœud remonté",
                           message: "Le flux temps réel n'a pas encore livré l'état des nœuds.",
                           symbol: "server.rack")
                    .listRowBackground(Color.clear)
            }
        } else {
            ForEach(inventory.nodes) { node in
                Section {
                    NodeCard(node: node)
                } header: {
                    HStack {
                        Text(node.node)
                        Spacer()
                        Menu {
                            Button("Redémarrer le nœud", systemImage: "arrow.clockwise") {
                                confirmNode(node, "reboot")
                            }
                            Button("Éteindre le nœud", systemImage: "power", role: .destructive) {
                                confirmNode(node, "shutdown")
                            }
                        } label: {
                            Label("Actions", systemImage: "ellipsis.circle")
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Stockages

    @ViewBuilder
    private func storagesTab(_ inventory: PVEInventory) -> some View {
        if inventory.storages.isEmpty {
            Section {
                EmptyState(title: "Aucun stockage",
                           message: "Le flux temps réel n'a pas encore livré les stockages du cluster.",
                           symbol: "externaldrive")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(inventory.storages) { storage in
                    StorageRow(storage: storage)
                }
            } footer: {
                Text("Un stockage déclaré mais non monté remonte une taille nulle — il apparaît « indisponible » plutôt qu'à 0 %.")
            }
        }
    }

    // MARK: - Tâches

    @ViewBuilder
    private var tasksTab: some View {
        if tasks.isEmpty {
            Section {
                EmptyState(title: "Aucune tâche",
                           message: "L'hyperviseur n'a rien exécuté récemment, ou son journal n'est pas lisible avec ce jeton.",
                           symbol: "clock.arrow.circlepath")
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                ForEach(tasks) { task in
                    PVETaskRow(task: task)
                }
            } footer: {
                Text("Soixante dernières tâches du journal Proxmox.")
            }
        }
    }

    // MARK: - Actions

    private func confirmPower(_ guest: PVEGuest, _ action: String) {
        let labels = ["start": "Démarrer", "stop": "Arrêter", "shutdown": "Éteindre",
                      "reboot": "Redémarrer", "reset": "Réinitialiser",
                      "suspend": "Suspendre", "resume": "Reprendre"]
        let title = labels[action] ?? action
        // `stop` coupe l'alimentation virtuelle sans prévenir le système : c'est
        // la seule action de cette liste qui peut corrompre un système de fichiers.
        let warning = action == "stop"
            ? "\n\nÉquivalent d'une coupure de courant : le système n'est pas prévenu."
            : ""
        runner.confirm(
            "\(title) \(guest.name) ?",
            message: "\(guest.type.label) \(guest.vmid) sur le nœud \(guest.node).\(warning)",
            confirmLabel: title,
            isDestructive: action != "start" && action != "resume"
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.perform(
                "/proxmox/\(cluster.id)/guests/\(guest.type.rawValue)/\(guest.vmid)/power/\(action)")
            return "\(title.lowercased()) demandé sur \(guest.name)."
        }
    }

    private func confirmNode(_ node: PVENode, _ action: String) {
        let title = action == "reboot" ? "Redémarrer" : "Éteindre"
        runner.confirm(
            "\(title) le nœud \(node.node) ?",
            message: "Tous les invités hébergés par ce nœud seront interrompus. C'est l'hyperviseur entier qui est concerné, pas une VM.",
            confirmLabel: title
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.perform("/proxmox/\(cluster.id)/nodes/\(node.node)/\(action)")
            return "\(title) du nœud \(node.node) demandé."
        }
    }

    // MARK: - Réseau

    private var normalizedSearch: String {
        search.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func grouped(_ guests: [PVEGuest]) -> [(node: String, guests: [PVEGuest])] {
        Dictionary(grouping: guests, by: \.node)
            .map { (node: $0.key, guests: $0.value.sorted { $0.vmid < $1.vmid }) }
            .sorted { $0.node.localizedStandardCompare($1.node) == .orderedAscending }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/proxmox/\(cluster.id)/guests"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
        if tab == .tasks { await loadTasks() }
    }

    private func loadTasks() async {
        guard let client = session.client else { return }
        tasks = (try? await client.get("/proxmox/\(cluster.id)/tasks")) ?? tasks
    }
}

enum PVETab: String, CaseIterable, Identifiable {
    case guests, nodes, storages, tasks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .guests: "Invités"
        case .nodes: "Nœuds"
        case .storages: "Stockages"
        case .tasks: "Tâches"
        }
    }
}

// MARK: - Lignes

struct GuestRow: View {
    let guest: PVEGuest

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(guest.isRunning ? Palette.ok : Palette.idle)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(guest.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    TagChip(text: guest.type.label, symbol: guest.type.symbol)
                }
                Text(guest.isRunning
                     ? "\(guest.vmid) · actif depuis \(Format.duration(guest.uptime))"
                     : "\(guest.vmid) · arrêté")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if guest.isRunning {
                HStack(spacing: 10) {
                    MiniGauge(value: guest.cpu, label: "CPU")
                    MiniGauge(value: guest.memPercent, label: "MEM")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Deux chiffres et deux barres : de quoi repérer l'invité qui sature sans
/// alourdir une ligne de liste.
private struct MiniGauge: View {
    let value: Double
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text("\(Int(value.rounded()))")
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(Palette.severity(value))
            Capsule()
                .fill(.quaternary)
                .frame(width: 26, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Palette.severity(value))
                        .frame(width: 26 * min(max(value / 100, 0), 1))
                }
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct NodeCard: View {
    let node: PVENode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StatusBadge(text: node.isOnline ? "en ligne" : node.status,
                            color: node.isOnline ? Palette.ok : Palette.danger,
                            symbol: node.isOnline ? "checkmark.circle.fill" : "xmark.octagon.fill")
                Spacer(minLength: 6)
                if let version = node.shortVersion {
                    TagChip(text: "PVE \(version)")
                }
            }

            if let model = node.cpuModel {
                Text(model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            MetricBar(title: "Processeur", value: node.cpu,
                      detail: "\(Format.percent(node.cpu, digits: 0)) · \(node.cpuCount) cœurs")
            MetricBar(title: "Mémoire", value: node.memPercent,
                      detail: "\(Format.bytes(node.memUsed)) / \(Format.bytes(node.memTotal))")
            MetricBar(title: "Disque système", value: node.diskPercent,
                      detail: "\(Format.bytes(node.diskUsed)) / \(Format.bytes(node.diskTotal))")

            HStack {
                Label(Format.duration(node.uptime), systemImage: "clock")
                Spacer(minLength: 6)
                if let load = node.loadPerCore {
                    // Rapportée au nombre de cœurs : au-delà de 1, des tâches
                    // attendent leur tour.
                    Label(Format.number(load, digits: 2) + " /cœur",
                          systemImage: "gauge.with.dots.needle.50percent")
                        .foregroundStyle(load > 1 ? Palette.warn : .secondary)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct StorageRow: View {
    let storage: PVEStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(storage.name, systemImage: "externaldrive.fill")
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if !storage.isAvailable {
                    TagChip(text: storage.total == 0 ? "non monté" : storage.status,
                            symbol: "exclamationmark.triangle")
                }
            }
            if storage.isAvailable {
                MetricBar(title: "\(Format.bytes(storage.used)) / \(Format.bytes(storage.total))",
                          value: storage.percent,
                          detail: Format.percent(storage.percent, digits: 1))
            }
        }
        .padding(.vertical, 3)
    }
}

struct PVETaskRow: View {
    let task: PVETask

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(task.isRunning ? Color.accentColor
                      : task.succeeded ? Palette.ok : Palette.danger)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(task.label)
                        .font(.subheadline)
                        .lineLimit(1)
                    if let vmid = task.vmid, !vmid.isEmpty {
                        TagChip(text: vmid)
                    }
                }
                Text([task.user, Format.dateTime(task.started)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                if task.isRunning {
                    ProgressView().controlSize(.mini)
                } else if !task.succeeded, let status = task.status {
                    Text(status)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Palette.danger)
                        .lineLimit(1)
                }
                if let duration = task.duration {
                    Text(Format.duration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
