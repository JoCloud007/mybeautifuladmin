import Foundation
import SwiftUI

/// État d'un chargement asynchrone.
///
/// `.refreshing` porte la donnée précédente : un rafraîchissement ne doit pas
/// vider l'écran, sinon la liste clignote à chaque tirage vers le bas.
enum Loadable<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(APIError)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var error: APIError? {
        if case .failed(let error) = self { return error }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Vrai tant qu'aucune donnée n'a jamais été obtenue.
    var isEmptyLoading: Bool { value == nil && !isFailed }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
extension Loadable {
    /// Exécute un chargement en conservant la donnée déjà affichée.
    mutating func begin() {
        if value == nil { self = .loading }
    }
}

/// Enveloppe standard : squelette au premier chargement, erreur pleine page si
/// rien n'a jamais été chargé, bandeau discret si une donnée reste affichable.
struct LoadableContent<Value: Sendable, Content: View>: View {
    let state: Loadable<Value>
    var retry: (() async -> Void)?
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .controlSize(.large)
        case .failed(let error):
            ErrorState(error: error, retry: retry.map { action in { Task { await action() } } })
        case .loaded(let value):
            content(value)
        }
    }
}
