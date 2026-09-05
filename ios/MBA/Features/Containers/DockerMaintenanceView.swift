import SwiftUI

/// Ménage Docker : ce qui occupe l'espace, ce qui est récupérable, et la purge.
///
/// L'écran montre le coût avant de proposer l'action — purger sans savoir ce
/// qu'on récupère, ni ce qu'on risque de perdre, est le meilleur moyen d'effacer
/// un volume qui portait des données.
struct DockerMaintenanceView: View {
    let host: Host

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var state: Loadable<DockerUsage> = .idle
    @State private var selection: Set<PruneTarget> = []
    @State private var runner = ActionRunner()

    private var risky: [PruneTarget] { selection.filter(\.isRisky) }

    var body: some View {
        NavigationStack {
            List {
                if let usage = state.value {
                    Section {
                        HStack(spacing: 10) {
                            StatTile(value: Format.bytes(usage.sizeTotal),
                                     label: "Occupé", symbol: "internaldrive")
                            StatTile(value: Format.bytes(usage.reclaimableTotal),
                                     label: "Récupérable", symbol: "arrow.3.trianglepath",
                                     tint: usage.reclaimableTotal > 0 ? Palette.warn : .secondary)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listRowBackground(Color.clear)

                    Section("Détail") {
                        ForEach(DockerUsage.order.filter { usage.usage[$0] != nil }, id: \.self) { key in
                            if let category = usage.usage[key] {
                                categoryRow(key, category)
                            }
                        }
                    }

                    Section {
                        ForEach(PruneTarget.allCases) { target in
                            Toggle(isOn: binding(for: target)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.label)
                                    if let caution = target.caution, selection.contains(target) {
                                        Text(caution)
                                            .font(.caption)
                                            .foregroundStyle(Palette.warn)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Que purger")
                    } footer: {
                        Text("La purge est immédiate et sans retour. Elle ne touche jamais un conteneur en cours d'exécution ni un volume encore rattaché.")
                    }

                    Section {
                        Button {
                            confirmPrune()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Purger la sélection").fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(risky.isEmpty ? .accentColor : Palette.danger)
                        .controlSize(.large)
                        .disabled(selection.isEmpty || runner.isRunning)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
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
            .navigationTitle("Ménage Docker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Ménage Docker").font(.headline)
                        Text(host.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .actionResult(runner)
        }
    }

    private func categoryRow(_ key: String, _ category: DockerUsage.Category) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(DockerUsage.label(key))
                Spacer()
                Text(Format.bytes(category.size))
                    .font(.callout.monospacedDigit())
            }
            HStack(spacing: 6) {
                Text(Format.plural(category.count, "élément"))
                if category.reclaimable > 0 {
                    Text("·")
                    Text("\(Format.bytes(category.reclaimable)) récupérables")
                        .foregroundStyle(Palette.warn)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func binding(for target: PruneTarget) -> Binding<Bool> {
        Binding(
            get: { selection.contains(target) },
            set: { isOn in
                if isOn {
                    selection.insert(target)
                    // « Toutes les images » englobe « images sans conteneur » :
                    // les envoyer ensemble ferait deux passes pour rien.
                    if target == .imagesAll { selection.remove(.images) }
                    if target == .images { selection.remove(.imagesAll) }
                } else {
                    selection.remove(target)
                }
            })
    }

    private func confirmPrune() {
        guard let client = session.client else { return }
        let targets = Array(selection)
        let names = targets.map(\.label).joined(separator: ", ")
        let warning = risky.compactMap(\.caution).joined(separator: "\n\n")

        struct Payload: Encodable, Sendable {
            let targets: [String]
        }

        runner.confirm(
            "Purger sur \(host.name)",
            message: warning.isEmpty ? names : "\(names)\n\n\(warning)",
            confirmLabel: "Purger"
        ) {
            let response = try await client.perform(
                "/hosts/\(host.id)/docker/prune",
                body: Payload(targets: targets.map(\.rawValue)))
            let reclaimed = response["reclaimed"]?.doubleValue ?? 0
            let errors = response["errors"]?.arrayValue ?? []
            var lines = ["\(Format.bytes(reclaimed)) récupérés."]
            if !errors.isEmpty {
                lines.append(contentsOf: errors.compactMap {
                    guard let target = $0["target"]?.stringValue,
                          let message = $0["error"]?.stringValue else { return nil }
                    return "\(target) : \(message)"
                })
            }
            return lines.joined(separator: "\n")
        }
        Task {
            // Le compte rendu s'affiche pendant que les chiffres se rafraîchissent.
            try? await Task.sleep(for: .seconds(1))
            await load()
            selection.removeAll()
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let usage: DockerUsage = try await client.get("/hosts/\(host.id)/docker/usage")
            state = .loaded(usage)
        } catch let error as APIError {
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}
