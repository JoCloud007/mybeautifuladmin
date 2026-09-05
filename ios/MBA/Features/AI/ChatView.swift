import SwiftUI

/// Dialogue avec un modèle hébergé.
///
/// La réponse arrive fragment par fragment : on l'affiche au fur et à mesure
/// plutôt que d'attendre la fin, parce qu'un modèle local sur une carte
/// modeste met parfois une minute à terminer sa phrase — et parce que le débit
/// observé est précisément ce qu'on vient mesurer.
struct ChatView: View {
    let endpoint: AIEndpoint
    let model: String

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var task: Task<Void, Never>?
    @State private var failure: APIError?

    private var isStreaming: Bool { task != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                composer
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(model)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Effacer", systemImage: "trash") {
                        task?.cancel()
                        task = nil
                        messages = []
                        failure = nil
                    }
                    .disabled(messages.isEmpty)
                }
            }
        }
    }

    // MARK: - Transcription

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty {
                        EmptyState(
                            title: "Dialogue avec \(model)",
                            message: "La conversation part de zéro et vit le temps de cet écran : rien n'est conservé côté serveur.\n\nLe débit en jetons par seconde s'affiche sous chaque réponse.",
                            symbol: "bubble.left.and.bubble.right")
                            .padding(.top, 40)
                    }

                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if let failure {
                        InlineErrorBanner(error: failure)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
            }
            .onChange(of: messages.last?.content) {
                guard let last = messages.last else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Saisie

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
                .disabled(isStreaming)

            Button {
                if isStreaming {
                    task?.cancel()
                    task = nil
                } else {
                    send()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(isStreaming ? Palette.danger : Color.accentColor)
            }
            .disabled(!isStreaming && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(isStreaming ? "Interrompre" : "Envoyer")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Envoi

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let client = session.client else { return }

        messages.append(ChatMessage(role: .user, content: text))
        draft = ""
        failure = nil

        // Le corps porte tout l'historique : le serveur d'inférence ne garde
        // aucun état entre deux requêtes.
        let request = ChatRequest(model: model, history: messages)
        let reply = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(reply)

        task = Task {
            defer { task = nil }
            do {
                for try await chunk in client.stream("/ai/endpoints/\(endpoint.id)/chat",
                                                     body: request) {
                    if let error = chunk["error"]?.stringValue, !error.isEmpty {
                        failure = .http(status: 502, message: error)
                        break
                    }
                    if let fragment = chunk["message"]?["content"]?.stringValue, !fragment.isEmpty {
                        append(fragment, to: reply.id)
                    }
                    if let stats = ChatStats(chunk: chunk) {
                        attach(stats, to: reply.id)
                    }
                    if chunk["done"]?.boolValue == true { break }
                }
            } catch let error as APIError {
                if !error.isCancellation { failure = error }
            } catch {
                failure = APIError.transport(error)
            }
            finish(reply.id)
        }
    }

    // MARK: - Mise à jour du message en cours

    private func append(_ fragment: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += fragment
    }

    private func attach(_ stats: ChatStats, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].stats = stats
    }

    private func finish(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].isStreaming = false
        // Une réponse restée vide n'apprend rien : le bandeau d'erreur, lui,
        // dit ce qui s'est passé.
        if messages[index].content.isEmpty {
            messages.remove(at: index)
        }
    }
}

// MARK: - Bulle

private struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            Text(message.content)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(isUser ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                                   : AnyShapeStyle(.background.secondary),
                            in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if message.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("génération…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let summary = message.stats?.summary {
                Text(summary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
