import SwiftUI

struct HostsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var state: Loadable<[Host]> = .idle
    @State private var search = ""
    @State private var kindFilter: HostKind?
    @State private var onlyProblems = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Metrics.spacing) {
                if let error = state.error, state.value != nil {
                    InlineErrorBanner(error: error) { Task { await load() } }
                }
                if state.value != nil {
                    filters
                    let hosts = filtered
                    if hosts.isEmpty {
                        EmptyState(
                            title: "Aucun résultat",
                            message: search.isEmpty
                                ? "Aucune machine ne correspond à ces filtres."
                                : "Aucune machine ne correspond à « \(search) ».",
                            symbol: "magnifyingglass")
                            .frame(minHeight: 260)
                    } else {
                        ForEach(hosts) { host in
                            NavigationLink(value: host.id) {
                                HostCard(host: host)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if state.isFailed, let error = state.error {
                    ErrorState(error: error) { Task { await load() } }
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    ProgressView().controlSize(.large).frame(minHeight: 320)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, Metrics.sectionSpacing)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Machines")
        .searchable(text: $search, prompt: "Nom, adresse, étiquette")
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(for: Int.self) { hostID in
            HostDetailView(hostID: hostID,
                           fallbackName: state.value?.first { $0.id == hostID }?.name ?? "Machine")
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionIndicator() } }
    }

    // MARK: - Filtres

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Tout", isOn: kindFilter == nil && !onlyProblems) {
                    kindFilter = nil
                    onlyProblems = false
                }
                FilterChip(title: "À surveiller", symbol: "exclamationmark.triangle",
                           isOn: onlyProblems) {
                    onlyProblems.toggle()
                }
                ForEach(availableKinds, id: \.self) { kind in
                    FilterChip(title: kind.label, symbol: kind.symbol,
                               isOn: kindFilter == kind) {
                        kindFilter = kindFilter == kind ? nil : kind
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    private var availableKinds: [HostKind] {
        let present = Set(state.value?.map(\.kind) ?? [])
        return HostKind.allCases.filter(present.contains)
    }

    private var filtered: [Host] {
        var hosts = state.value ?? []
        if let kindFilter { hosts = hosts.filter { $0.kind == kindFilter } }
        if onlyProblems {
            hosts = hosts.filter { (live.statuses[$0.id] ?? $0.status) != .online }
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            hosts = hosts.filter { host in
                host.name.lowercased().contains(query)
                    || host.address.lowercased().contains(query)
                    || host.tags.contains { $0.lowercased().contains(query) }
                    || (host.location?.lowercased().contains(query) ?? false)
            }
        }
        return hosts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Chargement

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let hosts: [Host] = try await client.get("/hosts")
            state = .loaded(hosts)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}

struct FilterChip: View {
    let title: String
    var symbol: String?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).imageScale(.small) }
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary),
                        in: Capsule())
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
