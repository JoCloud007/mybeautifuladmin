import SwiftUI

struct ContainerDetailView: View {
    let container: Container
    let onChange: () async -> Void

    @Environment(SessionStore.self) private var session

    @State private var runner = ActionRunner()
    @State private var logs: String?
    @State private var isLoadingLogs = false
    @State private var logLines = 200
    @State private var showsTerminal = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                summary
                if container.isRunning { resources }
                actions
                identity
                logSection
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLogs() }
        .actionResult(runner)
        .navigationDestination(isPresented: $showsTerminal) {
            TerminalScreen(hostID: container.hostID,
                           hostName: container.hostName ?? "Machine",
                           container: container.extID)
        }
    }

    // MARK: - Sections

    private var summary: some View {
        SectionBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    StatusBadge(text: container.isRunning ? "Actif" : (container.state ?? "arrêté"),
                                color: Palette.serviceStatus(container.state ?? ""),
                                symbol: container.isRunning ? "play.circle.fill" : "stop.circle.fill")
                    Spacer()
                    if let updated = container.updatedAt {
                        Text(Format.ago(updated))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let status = container.status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !container.publishedPorts.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(container.publishedPorts, id: \.self) { port in
                                TagChip(text: port, symbol: "arrow.left.arrow.right")
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
            }
        }
    }

    private var resources: some View {
        SectionBox("Consommation", symbol: "gauge.with.needle") {
            HStack(spacing: 18) {
                if let cpu = container.cpu {
                    MetricRing(value: cpu, label: "CPU")
                }
                if let percent = container.memoryPercent {
                    MetricRing(value: percent, label: "RAM",
                               caption: container.memory.map { Format.bytes($0, digits: 0) })
                } else if let memory = container.memory {
                    VStack(spacing: 4) {
                        Text(Format.bytes(memory, digits: 0))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        Text("Mémoire")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var actions: some View {
        SectionBox("Actions", symbol: "bolt") {
            VStack(spacing: 8) {
                ForEach(container.availableActions) { action in
                    Button {
                        run(action)
                    } label: {
                        HStack {
                            Label(action.label, systemImage: action.symbol)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(action == .remove ? Palette.danger : .primary)
                    if action != container.availableActions.last { Divider() }
                }

                if container.isDocker {
                    Divider()
                    Button {
                        confirmPull()
                    } label: {
                        HStack {
                            Label("Récupérer la dernière image", systemImage: "arrow.down.circle")
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)

                    if container.isRunning {
                        Divider()
                        Button {
                            showsTerminal = true
                        } label: {
                            HStack {
                                Label("Ouvrir un shell", systemImage: "terminal")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var identity: some View {
        SectionBox("Fiche", symbol: "info.circle") {
            VStack(spacing: 10) {
                LabeledValue(label: "Machine", value: container.hostName)
                if let project = container.project {
                    LabeledValue(label: "Pile", value: project)
                }
                if let service = container.service {
                    LabeledValue(label: "Service", value: service)
                }
                LabeledValue(label: "Type", value: container.kind)
                LabeledValue(label: "Image", value: container.image, monospaced: true)
                LabeledValue(label: "Identifiant", value: String(container.extID.prefix(12)),
                             monospaced: true)
            }
        }
    }

    private var logSection: some View {
        SectionBox("Journal", symbol: "text.alignleft",
                   accessory: AnyView(
                    Menu {
                        Picker("Lignes", selection: $logLines) {
                            Text("100 lignes").tag(100)
                            Text("200 lignes").tag(200)
                            Text("500 lignes").tag(500)
                            Text("2000 lignes").tag(2000)
                        }
                        Button("Rafraîchir", systemImage: "arrow.clockwise") {
                            Task { await loadLogs() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").imageScale(.small)
                    })) {
            if isLoadingLogs {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if let logs, !logs.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(logs)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 340)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Aucune sortie disponible.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: logLines) { await loadLogs() }
    }

    // MARK: - Actions

    private func run(_ action: ContainerAction) {
        guard let client = session.client else { return }
        let operation: @Sendable () async throws -> String? = {
            let response = try await client.perform(
                "/hosts/\(container.hostID)/containers/\(container.extID)/\(action.rawValue)")
            return response["detail"]?.stringValue ?? "\(action.label) effectué."
        }

        if action.isDestructive {
            runner.confirm("\(action.label) « \(container.name) »",
                           message: action.confirmationMessage,
                           confirmLabel: action.label,
                           operation: operation)
        } else {
            Task {
                await runner.run(action.label, operation: operation)
                await onChange()
            }
        }
    }

    private func confirmPull() {
        guard let client = session.client else { return }
        runner.confirm(
            "Récupérer l'image",
            message: "Télécharge la dernière version de l'image. Le conteneur continue de tourner sur l'ancienne jusqu'à sa recréation.",
            confirmLabel: "Récupérer",
            isDestructive: false
        ) {
            let response = try await client.perform(
                "/hosts/\(container.hostID)/containers/\(container.extID)/pull")
            let detail = response["detail"]?.stringValue ?? "Image à jour."
            guard response["needs_recreate"]?.boolValue == true else { return detail }
            return detail + "\n\nL'image a changé : recrée la pile pour l'activer (« Mettre à jour » sur la pile)."
        }
    }

    private func loadLogs() async {
        guard let client = session.client, container.isDocker else { return }
        isLoadingLogs = true
        defer { isLoadingLogs = false }
        do {
            let response: JSONValue = try await client.get(
                "/hosts/\(container.hostID)/containers/\(container.extID)/logs",
                query: ["lines": String(logLines)])
            logs = response["logs"]?.stringValue
        } catch let error as APIError {
            logs = "— Journal indisponible : \(error.message)"
        } catch {
            logs = nil
        }
    }
}
