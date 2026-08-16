import SwiftUI

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(LiveStore.self) private var live

    var body: some View {
        Group {
            switch session.phase {
            case .launching:
                LaunchView()
            case .onboarding:
                OnboardingView()
            case .locked(let profile):
                LoginView(profile: profile)
            case .authenticated:
                MainShell()
            }
        }
        .animation(.smooth(duration: 0.25), value: session.isAuthenticated)
        .task {
            guard case .launching = session.phase else { return }
            #if DEBUG
            if await session.autoLoginIfRequested() { return }
            #endif
            await session.restore()
        }
        .onChange(of: session.isAuthenticated) { _, authenticated in
            if authenticated, let profile = session.activeProfile {
                live.connect(profile: profile)
            } else {
                live.reset()
            }
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// Coquille principale.
///
/// iPhone et iPad ne partagent pas la même grammaire de navigation : barre
/// d'onglets d'un côté, barre latérale de l'autre. Les deux affichent les mêmes
/// écrans, construits par `DestinationView`.
struct MainShell: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                PhoneTabs()
            } else {
                PadSidebar()
            }
        }
        .overlay(alignment: .top) { AlertBanner() }
    }
}

private struct PhoneTabs: View {
    @State private var selection: Destination = {
        #if DEBUG
        if let screen = DebugLaunch.startScreen, Destination.primary.contains(screen) { return screen }
        #endif
        return .dashboard
    }()

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Destination.primary) { destination in
                Tab(destination.title, systemImage: destination.symbol, value: destination) {
                    NavigationStack {
                        DestinationView(destination: destination)
                    }
                }
            }
            Tab("Plus", systemImage: "ellipsis.circle", value: Destination.settings) {
                MoreView()
            }
        }
    }
}

/// Toutes les sections secondaires, groupées — l'onglet « Plus » de l'iPhone.
private struct MoreView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: Destination.settings) {
                        ServerRow(profile: session.activeProfile, user: session.currentUser)
                    }
                }
                ForEach(Destination.groups, id: \.title) { group in
                    // Les réglages ont déjà leur place en tête d'écran.
                    let items = group.items.filter { $0 != .settings }
                    if !items.isEmpty {
                        Section(group.title) {
                            ForEach(items) { destination in
                                NavigationLink(value: destination) {
                                    Label(destination.title, systemImage: destination.symbol)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Plus")
            .navigationDestination(for: Destination.self) { destination in
                DestinationView(destination: destination)
            }
        }
    }
}

private struct ServerRow: View {
    let profile: ServerProfile?
    let user: CurrentUser?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.person.crop")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.name ?? "Serveur")
                    .font(.body.weight(.medium))
                Text([user?.username, profile?.displayHost].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PadSidebar: View {
    @State private var selection: Destination? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(Destination.primary) { destination in
                        Label(destination.title, systemImage: destination.symbol)
                            .tag(destination)
                    }
                }
                ForEach(Destination.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { destination in
                            Label(destination.title, systemImage: destination.symbol)
                                .tag(destination)
                        }
                    }
                }
            }
            .navigationTitle("MyBeautifulAdmin")
        } detail: {
            NavigationStack {
                DestinationView(destination: selection ?? .dashboard)
            }
        }
    }
}

/// Aiguillage unique vers l'écran d'une section.
struct DestinationView: View {
    let destination: Destination

    var body: some View {
        switch destination {
        case .dashboard: DashboardView()
        case .hosts: HostsView()
        case .alerts: AlertsView()
        case .events: EventsView()
        case .settings: SettingsView()
        default:
            ComingSoonView(destination: destination)
        }
    }
}

/// Marque-place explicite : une section annoncée mais pas encore portée vaut
/// mieux qu'un onglet qui disparaît d'une version à l'autre.
struct ComingSoonView: View {
    let destination: Destination

    var body: some View {
        ContentUnavailableView {
            Label(destination.title, systemImage: destination.symbol)
        } description: {
            Text("Cette section arrive dans une prochaine version de l'application.\nElle est déjà disponible dans la console web.")
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Bandeau d'alerte éphémère, poussé par le flux temps réel.
private struct AlertBanner: View {
    @Environment(LiveStore.self) private var live

    var body: some View {
        if let alert = live.latestAlert {
            HStack(spacing: 10) {
                Image(systemName: alert.severity.symbol)
                    .foregroundStyle(alert.severity.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.message)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                    if let host = alert.hostName {
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    live.dismissAlertBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .leading) {
                LeadingAccent(color: alert.severity.color)
                    .padding(.vertical, 8)
                    .padding(.leading, 2)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.snappy, value: alert.id)
            .task(id: alert.id) {
                // Une alerte reste 6 s : assez pour être lue, assez peu pour ne
                // pas masquer l'écran si l'infra part en cascade.
                try? await Task.sleep(for: .seconds(6))
                live.dismissAlertBanner()
            }
        }
    }
}
