import SwiftUI

@main
struct MBAApp: App {
    @State private var session = SessionStore()
    @State private var live = LiveStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(live)
                .tint(.accentColor)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Le flux est rouvert au retour d'arrière-plan : iOS coupe les
                // WebSockets en veille, et rien ne le signale à l'application.
                if let profile = session.activeProfile, session.isAuthenticated {
                    live.connect(profile: profile)
                }
            case .background:
                live.disconnect()
            default:
                break
            }
        }
    }
}
