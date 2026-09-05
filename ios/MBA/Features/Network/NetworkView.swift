import SwiftUI

/// Cartographie du réseau : ce que MBA supervise, et ce qu'il a seulement
/// aperçu.
///
/// L'intérêt de l'écran tient dans l'écart entre les deux — une adresse qui
/// répond sur le port 5432 sans être déclarée mérite qu'on s'y arrête.
struct NetworkView: View {
    @Environment(SessionStore.self) private var session

    @State private var state: Loadable<NetworkOverview> = .idle
    @State private var grouping: NetworkGrouping = .subnet
    @State private var search = ""
    @State private var showsUnmanagedOnly = false

    var body: some View {
        List {
            if let error = state.error, state.value != nil {
                InlineErrorBanner(error: error) { Task { await load() } }
                    .listRowBackground(Color.clear)
            }

            if let overview = state.value {
                summarySection(overview.summary)

                let groups = filteredGroups(overview)
                if groups.isEmpty {
                    Section {
                        EmptyState(
                            title: overview.assets.isEmpty ? "Réseau vide" : "Aucun résultat",
                            message: overview.assets.isEmpty
                                ? "Aucune machine déclarée ni adresse découverte."
                                : showsUnmanagedOnly
                                    ? "Tout ce qui répond sur le réseau est déjà supervisé."
                                    : "Rien ne correspond à « \(search) ».",
                            symbol: showsUnmanagedOnly ? "checkmark.shield" : "network")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.assets) { asset in
                                if let hostID = asset.hostID, !asset.isDiscovered {
                                    NavigationLink(value: hostID) { AssetRow(asset: asset) }
                                } else {
                                    AssetRow(asset: asset)
                                }
                            }
                        } header: {
                            GroupHeader(group: group)
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
        .navigationTitle("Réseau")
        .searchable(text: $search, prompt: "Nom, adresse, port, rôle")
        .refreshable { await load() }
        .task(id: grouping) { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Regrouper par", selection: $grouping) {
                        ForEach(NetworkGrouping.allCases) { Text($0.label).tag($0) }
                    }
                    Divider()
                    Toggle("Non supervisés seulement", isOn: $showsUnmanagedOnly)
                } label: {
                    Label("Affichage", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .navigationDestination(for: Int.self) { hostID in
            HostDetailView(hostID: hostID,
                           fallbackName: state.value?.assets
                               .first { $0.hostID == hostID }?.name ?? "Machine")
        }
    }

    private func summarySection(_ summary: NetworkOverview.Summary) -> some View {
        Section {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                StatTile(value: "\(summary.supervised)", label: "Supervisés",
                         symbol: "checkmark.shield", tint: Palette.ok,
                         trailing: "/ \(summary.total)")
                StatTile(value: "\(summary.unmanaged)", label: "Non supervisés",
                         symbol: "questionmark.circle",
                         tint: summary.unmanaged > 0 ? Palette.warn : Palette.ok)
                StatTile(value: "\(summary.online)", label: "En ligne",
                         symbol: "bolt.horizontal.circle", tint: Palette.ok)
                StatTile(value: "\(summary.tailscale)", label: "Via Tailscale",
                         symbol: "point.3.filled.connected.trianglepath.dotted")
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } footer: {
            Text(showsUnmanagedOnly
                 ? "Seuls les équipements repérés sur le réseau mais absents du parc sont listés."
                 : "Regroupé par \(grouping.label.lowercased()). Les équipements non supervisés viennent de la découverte réseau.")
        }
        .listRowBackground(Color.clear)
    }

    private func filteredGroups(_ overview: NetworkOverview) -> [NetworkGroup] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return overview.groups.compactMap { group in
            let assets = group.assets.filter {
                $0.matches(query) && (!showsUnmanagedOnly || !$0.supervised)
            }
            guard !assets.isEmpty else { return nil }
            var copy = group
            copy.assets = assets.sorted { first, second in
                if first.supervised != second.supervised { return second.supervised }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
            return copy
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            state = .loaded(try await client.get("/network",
                                                 query: ["group_by": grouping.rawValue]))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

private struct GroupHeader: View {
    let group: NetworkGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(group.key)
            Text("· \(group.count)")
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            if group.unmanaged > 0 {
                Text("\(group.unmanaged) hors parc")
                    .font(.caption2)
                    .foregroundStyle(Palette.warn)
                    .textCase(nil)
            }
        }
    }
}

private struct AssetRow: View {
    let asset: NetworkAsset

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: asset.isDiscovered ? "questionmark.circle" : asset.kindIcon.symbol)
                .foregroundStyle(asset.isDiscovered ? Palette.warn : asset.hostStatus.color)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(asset.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    if asset.tailscale {
                        Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Joint via Tailscale")
                    }
                }
                // L'adresse garde sa ligne : tronquée en son milieu au sein
                // d'une chaîne composée, elle avalait le séparateur et les deux
                // valeurs se retrouvaient collées.
                Text(asset.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !asset.roles.isEmpty || asset.isDiscovered || asset.os != nil || asset.model != nil {
                    HStack(spacing: 4) {
                        if asset.isDiscovered {
                            StatusBadge(text: "hors parc", color: Palette.warn,
                                        symbol: "exclamationmark.circle.fill")
                        }
                        if let system = asset.os ?? asset.model {
                            TagChip(text: system)
                        }
                        // Les rôles disent ce qui tourne derrière l'adresse : sur
                        // une machine inconnue, c'est le seul indice disponible.
                        ForEach(asset.roles.prefix(2), id: \.self) { role in
                            TagChip(text: role)
                        }
                    }
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if !asset.ports.isEmpty {
                Text(Format.plural(asset.ports.count, "port"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
