import SwiftUI

/// Exécution d'une action d'administration, avec confirmation et compte rendu.
///
/// Toute action qui touche une machine passe par là : elle est confirmée quand
/// elle est destructrice, elle affiche sa sortie, et elle ne peut pas être
/// lancée deux fois pendant qu'elle tourne.
@MainActor
@Observable
final class ActionRunner {
    struct Outcome: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let succeeded: Bool
        let detail: String?
    }

    struct Pending: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let isDestructive: Bool
        let operation: @Sendable () async throws -> String?
    }

    private(set) var runningTitle: String?
    var outcome: Outcome?
    var pending: Pending?

    var isRunning: Bool { runningTitle != nil }

    /// Action immédiate — lecture, test, rafraîchissement.
    func run(_ title: String, operation: @escaping @Sendable () async throws -> String?) async {
        guard !isRunning else { return }
        runningTitle = title
        defer { runningTitle = nil }
        do {
            let detail = try await operation()
            outcome = Outcome(title: title, succeeded: true, detail: detail)
        } catch let error as APIError {
            outcome = Outcome(title: title, succeeded: false,
                              detail: [error.message, error.hint].compactMap { $0 }.joined(separator: "\n\n"))
        } catch {
            outcome = Outcome(title: title, succeeded: false, detail: error.localizedDescription)
        }
    }

    /// Action qui coupe un service ou une machine : on demande d'abord.
    func confirm(_ title: String, message: String, confirmLabel: String = "Confirmer",
                 isDestructive: Bool = true,
                 operation: @escaping @Sendable () async throws -> String?) {
        pending = Pending(title: title, message: message, confirmLabel: confirmLabel,
                          isDestructive: isDestructive, operation: operation)
    }

    fileprivate func execute(_ pending: Pending) async {
        await run(pending.title, operation: pending.operation)
    }
}

private struct ActionResultModifier: ViewModifier {
    @Bindable var runner: ActionRunner

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                runner.pending?.title ?? "",
                isPresented: Binding(get: { runner.pending != nil },
                                     set: { if !$0 { runner.pending = nil } }),
                titleVisibility: .visible,
                presenting: runner.pending
            ) { pending in
                Button(pending.confirmLabel, role: pending.isDestructive ? .destructive : nil) {
                    runner.pending = nil
                    Task { await runner.execute(pending) }
                }
                Button("Annuler", role: .cancel) { runner.pending = nil }
            } message: { pending in
                Text(pending.message)
            }
            .alert(runner.outcome?.title ?? "",
                   isPresented: Binding(get: { runner.outcome != nil },
                                        set: { if !$0 { runner.outcome = nil } }),
                   presenting: runner.outcome) { _ in
                Button("OK", role: .cancel) { runner.outcome = nil }
            } message: { outcome in
                Text(outcome.detail ?? (outcome.succeeded ? "Action effectuée." : "Action en échec."))
            }
            .overlay {
                if let title = runner.runningTitle {
                    RunningOverlay(title: title)
                }
            }
    }
}

private struct RunningOverlay: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(radius: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.12))
        .ignoresSafeArea()
        .transition(.opacity)
    }
}

extension View {
    /// Branche confirmations, compte rendu et voile d'attente d'un `ActionRunner`.
    func actionResult(_ runner: ActionRunner) -> some View {
        modifier(ActionResultModifier(runner: runner))
    }
}
