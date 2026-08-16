import SwiftUI

/// Journal filtrable — l'équivalent de « Journal → Évènements » de la console web.
struct EventsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    @State private var state: Loadable<EventsResponse> = .idle
    @State private var search = ""
    @State private var level: EventLevel?
    @State private var source: String?
    @State private var showsLiveFeed = true

    var body: some View {
        List {
            filterSection

            if showsLiveFeed && !live.events.isEmpty && search.isEmpty && level == nil && source == nil {
                Section("En direct") {
                    ForEach(live.events.prefix(15)) { event in
                        EventRow(event: event)
                    }
                }
            }

            if let response = state.value {
                Section(response.events.isEmpty ? "" : "Historique") {
                    if response.events.isEmpty {
                        EmptyState(title: "Aucun évènement",
                                   message: "Aucune ligne ne correspond à ces filtres.",
                                   symbol: "line.3.horizontal.decrease.circle")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(response.events) { event in
                            EventRow(event: event)
                                .listRowSeparator(.visible)
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
        .navigationTitle("Journal")
        .searchable(text: $search, prompt: "Rechercher dans les messages")
        .refreshable { await load() }
        .task(id: FilterKey(search: search, level: level, source: source)) {
            // Laisse la frappe se poser avant d'interroger le serveur.
            try? await Task.sleep(for: .milliseconds(search.isEmpty ? 0 : 350))
            guard !Task.isCancelled else { return }
            await load()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Flux en direct", isOn: $showsLiveFeed)
                    Divider()
                    Picker("Niveau", selection: $level) {
                        Text("Tous les niveaux").tag(EventLevel?.none)
                        Text("Information").tag(EventLevel?.some(.info))
                        Text("Avertissement").tag(EventLevel?.some(.warning))
                        Text("Critique").tag(EventLevel?.some(.critical))
                    }
                } label: {
                    Label("Filtres", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "Tout", isOn: source == nil && level == nil) {
                        source = nil
                        level = nil
                    }
                    ForEach(state.value?.sources.prefix(8) ?? []) { entry in
                        FilterChip(title: "\(entry.source) (\(entry.count))",
                                   isOn: source == entry.source) {
                            source = source == entry.source ? nil : entry.source
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
        .listRowBackground(Color.clear)
    }

    private struct FilterKey: Equatable {
        let search: String
        let level: EventLevel?
        let source: String?
    }

    private func load() async {
        guard let client = session.client else { return }
        state.begin()
        do {
            let response: EventsResponse = try await client.get("/events", query: [
                "limit": "200",
                "level": level?.rawValue,
                "source": source,
                "search": search.isEmpty ? nil : search,
            ])
            state = .loaded(response)
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { state = .failed(error) }
        } catch {
            state = .failed(APIError.transport(error))
        }
    }
}
