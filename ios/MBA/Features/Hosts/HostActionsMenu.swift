import SwiftUI

/// Menu d'actions d'une machine.
///
/// Seules les actions que le type d'hôte sait réellement exécuter sont
/// proposées : ni `apt` ni terminal sur un BMC, et « reset matériel » y remplace
/// « redémarrer » puisque l'ordre court-circuite le système d'exploitation.
struct HostActionsMenu: View {
    let host: Host
    let runner: ActionRunner
    let onFinished: () async -> Void

    @Environment(SessionStore.self) private var session

    var body: some View {
        Menu {
            Button("Tester la connexion", systemImage: "bolt.horizontal") {
                Task { await test() }
            }

            if host.kind.supportsPackageUpgrade {
                Button("Mettre à jour les paquets", systemImage: "arrow.down.circle") {
                    confirmUpgrade()
                }
            }

            Divider()

            if host.kind == .ipmi {
                Button("Reset matériel", systemImage: "bolt.trianglebadge.exclamationmark",
                       role: .destructive) {
                    confirmPower("reset", title: "Reset matériel",
                                 message: "Le serveur redémarre sans prévenir le système d'exploitation. Les écritures en cours seront perdues.")
                }
                Button("Extinction", systemImage: "power", role: .destructive) {
                    confirmPower("off", title: "Éteindre",
                                 message: "Coupe l'alimentation du serveur via le contrôleur.")
                }
            } else {
                Button("Redémarrer", systemImage: "arrow.clockwise", role: .destructive) {
                    confirmPower("reboot", title: "Redémarrer \(host.name)",
                                 message: "La machine sera indisponible le temps du redémarrage.")
                }
                Button("Éteindre", systemImage: "power", role: .destructive) {
                    confirmPower("shutdown", title: "Éteindre \(host.name)",
                                 message: "La machine s'éteint. Il faudra la rallumer physiquement ou via son contrôleur.")
                }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .disabled(runner.isRunning)
    }

    // MARK: - Actions

    private func test() async {
        guard let client = session.client else { return }
        await runner.run("Test de connexion") {
            let response = try await client.perform("/hosts/\(host.id)/test")
            let detail = response["detail"]?.stringValue ?? "—"
            guard response["ok"]?.boolValue == true else { throw APIError(kind: .transport, message: detail) }
            return detail
        }
        await onFinished()
    }

    private func confirmUpgrade() {
        guard let client = session.client else { return }
        runner.confirm(
            "Mettre à jour \(host.name)",
            message: "Installe les paquets en attente. Certains services peuvent redémarrer.",
            confirmLabel: "Mettre à jour",
            isDestructive: false
        ) {
            let response = try await client.perform("/hosts/\(host.id)/upgrade")
            return response["detail"]?.stringValue
                ?? response["output"]?.stringValue.map { String($0.suffix(600)) }
                ?? "Mise à jour lancée."
        }
    }

    private func confirmPower(_ action: String, title: String, message: String) {
        guard let client = session.client else { return }
        runner.confirm(title, message: message, confirmLabel: title) {
            let response = try await client.perform("/hosts/\(host.id)/power/\(action)")
            return response["detail"]?.stringValue ?? "Ordre transmis."
        }
    }
}
