import SwiftUI

/// Fiche d'une VM ou d'un conteneur : état, historique, configuration,
/// snapshots et sauvegardes — avec les actions qui vont avec.
struct PVEGuestView: View {
    let route: PVEGuestRoute

    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<PVEGuestDetail> = .idle
    @State private var runner = ActionRunner()
    @State private var isSnapshotting = false
    @State private var isBackingUp = false
    @State private var isEditing = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                if let detail = state.value {
                    header(detail)
                    if !detail.history.isEmpty { chartSection(detail) }
                    configurationSection(detail)
                    snapshotsSection(detail)
                    backupsSection(detail)
                } else if let error = state.error {
                    ErrorState(error: error) { Task { await load() } }
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ProgressView().controlSize(.large)
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let detail = state.value { powerMenu(detail) }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $isSnapshotting) {
            SnapshotEditor(kind: route.kind, isRunning: state.value?.isRunning ?? false) { payload in
                try await createSnapshot(payload)
            }
        }
        .sheet(isPresented: $isBackingUp) {
            if let detail = state.value {
                BackupEditor(storages: detail.backupStorages, guestName: route.name) { payload in
                    try await createBackup(payload)
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            if let detail = state.value {
                ConfigEditor(config: detail.config, kind: route.kind,
                             isRunning: detail.isRunning) { payload in
                    try await updateConfig(payload)
                }
            }
        }
        .actionResult(runner)
    }

    // MARK: - En-tête

    private func header(_ detail: PVEGuestDetail) -> some View {
        SectionBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    StatusBadge(text: detail.isRunning ? "en marche" : (detail.status ?? "arrêté"),
                                color: detail.isRunning ? Palette.ok : Palette.idle,
                                symbol: detail.isRunning ? "play.circle.fill" : "stop.circle.fill")
                    Spacer(minLength: 6)
                    TagChip(text: route.kind.label, symbol: route.kind.symbol)
                    TagChip(text: "\(route.vmid)")
                }

                if detail.isRunning {
                    HStack(spacing: 18) {
                        MetricRing(value: detail.live.cpu, label: "CPU",
                                   caption: detail.config.totalCores.map { "\($0) cœurs" })
                        MetricRing(value: detail.live.memPercent, label: "Mémoire",
                                   caption: Format.bytes(detail.live.mem))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Actif depuis")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(Format.duration(detail.live.uptime))
                                .font(.callout.weight(.medium))
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Text("L'invité est arrêté : ni métrique ni historique récent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                LabeledValue(label: "Nœud", value: detail.node)
            }
        }
    }

    private func powerMenu(_ detail: PVEGuestDetail) -> some View {
        Menu {
            if detail.isRunning {
                Button("Éteindre", systemImage: "power") { confirmPower(detail, "shutdown") }
                Button("Redémarrer", systemImage: "arrow.clockwise") { confirmPower(detail, "reboot") }
                if route.kind.supportsSuspend {
                    Button("Suspendre", systemImage: "pause.circle") { confirmPower(detail, "suspend") }
                }
                Divider()
                Button("Arrêter brutalement", systemImage: "bolt.slash", role: .destructive) {
                    confirmPower(detail, "stop")
                }
            } else {
                Button("Démarrer", systemImage: "play.fill") { confirmPower(detail, "start") }
                if route.kind.supportsSuspend {
                    Button("Reprendre", systemImage: "playpause") { confirmPower(detail, "resume") }
                }
            }
            Divider()
            Button("Modifier les ressources", systemImage: "slider.horizontal.3") { isEditing = true }
            Button("Créer un snapshot", systemImage: "camera") { isSnapshotting = true }
            Button("Sauvegarder", systemImage: "externaldrive.badge.plus") { isBackingUp = true }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - Historique

    private func chartSection(_ detail: PVEGuestDetail) -> some View {
        SectionBox("Dernière heure", symbol: "chart.xyaxis.line") {
            VStack(alignment: .leading, spacing: 12) {
                // L'historique vient du RRD de Proxmox, pas de la rétention de
                // MBA : il reste lisible même si le serveur vient de redémarrer.
                MetricChart(title: "Processeur", unit: "%",
                            series: [("CPU", detail.cpuPoints, .accentColor)])
                MetricChart(title: "Mémoire", unit: "%",
                            series: [("Mémoire", detail.memoryPoints, Palette.warn)])
            }
        }
    }

    // MARK: - Configuration

    private func configurationSection(_ detail: PVEGuestDetail) -> some View {
        let config = detail.config
        return SectionBox("Configuration", symbol: "slider.horizontal.3",
                          accessory: AnyView(
                            Button("Modifier") { isEditing = true }
                                .font(.caption.weight(.semibold)))) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledValue(label: "Processeurs",
                             value: config.totalCores.map { "\($0) cœurs" } ?? Format.placeholder)
                LabeledValue(label: "Mémoire", value: Format.bytes(config.memoryBytes))
                if let balloon = config.balloon, balloon > 0 {
                    LabeledValue(label: "Ballon minimum",
                                 value: Format.bytes(balloon * 1024 * 1024))
                }
                LabeledValue(label: "Démarrage auto", value: config.onboot ? "oui" : "non")
                if let ostype = config.ostype {
                    LabeledValue(label: "Système", value: ostype)
                }
                if !config.description.isEmpty {
                    Text(config.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let disks = config.disks.filter(\.isPresent)
                if !disks.isEmpty {
                    Divider()
                    ForEach(disks) { disk in
                        LabeledValue(label: disk.slot,
                                     value: [disk.size, disk.spec].compactMap { $0 }
                                        .joined(separator: " · "),
                                     symbol: "internaldrive", monospaced: true)
                    }
                }
                if !config.networks.isEmpty {
                    Divider()
                    ForEach(config.networks) { network in
                        LabeledValue(label: network.slot,
                                     value: [network.bridge, network.mac].compactMap { $0 }
                                        .joined(separator: " · "),
                                     symbol: "network", monospaced: true)
                    }
                }
            }
        }
    }

    // MARK: - Snapshots

    private func snapshotsSection(_ detail: PVEGuestDetail) -> some View {
        SectionBox("Snapshots · \(detail.snapshots.count)", symbol: "camera",
                   accessory: AnyView(
                    Button("Créer") { isSnapshotting = true }
                        .font(.caption.weight(.semibold)))) {
            if detail.snapshots.isEmpty {
                Text("Aucun snapshot. Un snapshot n'est pas une sauvegarde : il vit sur le même stockage que le disque.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(detail.snapshots) { snapshot in
                        SnapshotRow(snapshot: snapshot,
                                    onRollback: { confirmRollback(detail, snapshot) },
                                    onDelete: { confirmDeleteSnapshot(detail, snapshot) })
                        if snapshot.id != detail.snapshots.last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Sauvegardes

    private func backupsSection(_ detail: PVEGuestDetail) -> some View {
        SectionBox("Sauvegardes · \(detail.backups.count)",
                   symbol: "externaldrive.badge.timemachine",
                   accessory: AnyView(
                    Button("Lancer") { isBackingUp = true }
                        .font(.caption.weight(.semibold)))) {
            if detail.backups.isEmpty {
                Text("Aucune sauvegarde vzdump pour cet invité.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    let shown = detail.backups.prefix(12)
                    ForEach(shown) { backup in
                        HStack(spacing: 10) {
                            Image(systemName: backup.isProtected ? "lock.fill" : "archivebox")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(Format.dateTime(backup.created))
                                    .font(.footnote.monospacedDigit())
                                Text(backup.storage)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(Format.bytes(backup.size))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                        if backup.id != shown.last?.id { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var basePath: String {
        "/proxmox/\(route.hostID)/guests/\(route.kind.rawValue)/\(route.vmid)"
    }

    private func confirmPower(_ detail: PVEGuestDetail, _ action: String) {
        let labels = ["start": "Démarrer", "stop": "Arrêter brutalement",
                      "shutdown": "Éteindre", "reboot": "Redémarrer",
                      "suspend": "Suspendre", "resume": "Reprendre"]
        let title = labels[action] ?? action
        let warning = action == "stop"
            ? "\n\nÉquivalent d'une coupure de courant : le système n'est pas prévenu, les écritures en cours sont perdues."
            : ""
        runner.confirm(
            "\(title) \(route.name) ?",
            message: "\(route.kind.label) \(route.vmid) sur le nœud \(detail.node).\(warning)",
            confirmLabel: title,
            isDestructive: action != "start" && action != "resume"
        ) { [client = session.client, basePath] in
            guard let client else { return nil }
            try await client.perform("\(basePath)/power/\(action)")
            return "\(title) demandé."
        }
        Task { await reloadSoon() }
    }

    private func createSnapshot(_ payload: PVESnapshotPayload) async throws {
        guard let client = session.client else { return }
        try await client.perform("\(basePath)/snapshots", body: payload)
        await load()
    }

    private func confirmRollback(_ detail: PVEGuestDetail, _ snapshot: PVESnapshot) {
        runner.confirm(
            "Restaurer « \(snapshot.name) » ?",
            message: "Tout ce qui a changé depuis le \(Format.fullDate(snapshot.created)) sera perdu. L'invité est arrêté puis remis dans l'état du snapshot.",
            confirmLabel: "Restaurer"
        ) { [client = session.client, basePath] in
            guard let client else { return nil }
            try await client.perform("\(basePath)/snapshots/\(snapshot.name)/rollback")
            return "Restauration lancée sur \(route.name)."
        }
        Task { await reloadSoon() }
    }

    private func confirmDeleteSnapshot(_ detail: PVEGuestDetail, _ snapshot: PVESnapshot) {
        runner.confirm(
            "Supprimer « \(snapshot.name) » ?",
            message: "Le snapshot est effacé définitivement. L'invité n'est pas touché.",
            confirmLabel: "Supprimer"
        ) { [client = session.client, basePath] in
            guard let client else { return nil }
            try await client.perform("\(basePath)/snapshots/\(snapshot.name)", method: "DELETE")
            return "Snapshot supprimé."
        }
        Task { await reloadSoon() }
    }

    private func createBackup(_ payload: PVEBackupPayload) async throws {
        guard let client = session.client else { return }
        try await client.perform("\(basePath)/backup", body: payload)
        await load()
    }

    private func updateConfig(_ payload: PVEConfigPayload) async throws {
        guard let client = session.client else { return }
        let _: JSONValue = try await client.patch("\(basePath)/config", body: payload)
        await load()
    }

    // MARK: - Réseau

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get(basePath))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }

    /// Proxmox répond avant que la tâche soit finie : on laisse passer quelques
    /// secondes, sinon la fiche se recharge sur l'état d'avant.
    private func reloadSoon() async {
        try? await Task.sleep(for: .seconds(3))
        await load()
    }
}

// MARK: - Ligne de snapshot

private struct SnapshotRow: View {
    let snapshot: PVESnapshot
    let onRollback: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(snapshot.name)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    if snapshot.vmstate {
                        TagChip(text: "RAM incluse", symbol: "memorychip")
                    }
                }
                Text(snapshot.description.isEmpty
                     ? Format.dateTime(snapshot.created)
                     : "\(Format.dateTime(snapshot.created)) · \(snapshot.description)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Menu {
                Button("Restaurer", systemImage: "arrow.uturn.backward", action: onRollback)
                Button("Supprimer", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Création de snapshot

private struct SnapshotEditor: View {
    let kind: GuestKind
    let isRunning: Bool
    let onSave: (PVESnapshotPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var includeMemory = false
    @State private var isSaving = false
    @State private var error: APIError?

    /// Le serveur refuse tout ce qui sort de `[A-Za-z0-9_-]{1,40}` : autant le
    /// dire avant l'aller-retour.
    private var isValid: Bool {
        !name.isEmpty && name.count <= 40
            && name.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("nom-du-snapshot", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    TextField("Description (facultative)", text: $description)
                } footer: {
                    if !name.isEmpty && !isValid {
                        Text("Lettres non accentuées, chiffres, tiret et souligné uniquement, 40 caractères au plus.")
                            .foregroundStyle(Palette.danger)
                    } else {
                        Text("Un snapshot vit sur le même stockage que le disque : il protège d'une fausse manœuvre, pas d'une panne de disque.")
                    }
                }

                if kind.supportsSuspend && isRunning {
                    Section {
                        Toggle("Inclure la mémoire vive", isOn: $includeMemory)
                    } footer: {
                        Text("Permet de reprendre la VM exactement où elle en était, au prix d'un snapshot plus lourd et plus long à prendre.")
                    }
                }

                if let error {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Snapshot")
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
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(PVESnapshotPayload(name: name, description: description,
                                                vmstate: includeMemory))
            dismiss()
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}

// MARK: - Sauvegarde

private struct BackupEditor: View {
    let storages: [PVEBackupStorage]
    let guestName: String
    let onSave: (PVEBackupPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var storage = ""
    @State private var mode = "snapshot"
    @State private var compress = "zstd"
    @State private var notes = ""
    @State private var isSaving = false
    @State private var error: APIError?

    private let modes = [("snapshot", "Snapshot — sans interruption"),
                         ("suspend", "Suspend — brève pause"),
                         ("stop", "Stop — arrêt le temps de la copie")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Stockage", selection: $storage) {
                        ForEach(storages) { store in
                            Text("\(store.name) · \(Format.bytes(store.available)) libres")
                                .tag(store.name)
                        }
                    }
                } footer: {
                    if let chosen = storages.first(where: { $0.name == storage }) {
                        Text("\(chosen.type.uppercased()) — occupé à \(Format.percent(chosen.usedPercent, digits: 0)).")
                    }
                }

                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(modes, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Picker("Compression", selection: $compress) {
                        Text("zstd").tag("zstd")
                        Text("gzip").tag("gzip")
                        Text("lzo").tag("lzo")
                        Text("aucune").tag("0")
                    }
                    TextField("Notes (facultatif)", text: $notes)
                } footer: {
                    Text("Le mode snapshot n'interrompt pas l'invité : c'est celui qu'on veut par défaut.")
                }

                if let error {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Sauvegarder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lancer") { Task { await save() } }
                        .disabled(storage.isEmpty || isSaving)
                }
            }
            .onAppear {
                if storage.isEmpty { storage = storages.first?.name ?? "" }
                if notes.isEmpty { notes = guestName }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(PVEBackupPayload(storage: storage, mode: mode,
                                              compress: compress, notes: notes))
            dismiss()
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}

// MARK: - Ressources

private struct ConfigEditor: View {
    let config: PVEGuestConfig
    let kind: GuestKind
    let isRunning: Bool
    let onSave: (PVEConfigPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cores = 1
    @State private var memoryMiB = 1024
    @State private var onboot = false
    @State private var isSaving = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section("Identité") {
                    TextField("Nom", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Stepper("Cœurs : \(cores)", value: $cores, in: 1...256)
                    Stepper("Mémoire : \(Format.bytes(Double(memoryMiB) * 1024 * 1024))",
                            value: $memoryMiB, in: 64...1_048_576, step: memoryStep)
                } header: {
                    Text("Ressources")
                } footer: {
                    if isRunning {
                        Text("L'invité tourne : la plupart des changements ne prendront effet qu'après un redémarrage.")
                    }
                }

                Section {
                    Toggle("Démarrer avec l'hôte", isOn: $onboot)
                }

                if let error {
                    Section {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }
            .navigationTitle("Ressources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .onAppear {
                name = config.name ?? ""
                cores = config.cores ?? 1
                memoryMiB = Int(config.memory ?? 1024)
                onboot = config.onboot
            }
        }
    }

    /// Un pas de 1 Gio au-delà de 4 Gio : ajuster 40 Gio de 256 Mio en 256 Mio
    /// demanderait cent cinquante appuis.
    private var memoryStep: Int { memoryMiB >= 4096 ? 1024 : 256 }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        // Seuls les champs réellement modifiés partent : le serveur applique
        // tout ce qu'il reçoit, et réécrire un nom inchangé n'est pas anodin.
        let payload = PVEConfigPayload(
            cores: cores == config.cores ? nil : cores,
            memory: Double(memoryMiB) == config.memory ? nil : memoryMiB,
            name: name == (config.name ?? "") ? nil : name,
            onboot: onboot == config.onboot ? nil : onboot)
        do {
            try await onSave(payload)
            dismiss()
        } catch let apiError as APIError {
            error = apiError
        } catch {
            self.error = APIError.transport(error)
        }
    }
}
