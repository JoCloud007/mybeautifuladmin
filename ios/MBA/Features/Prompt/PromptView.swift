import SwiftUI

/// Prompt Agent : dialogue avec un assistant IA qui peut interroger
/// l'infrastructure via des outils (list_hosts, get_host_metrics, run_action…).
///
/// L'écran est organisé en deux panneaux sur iPad (liste + chat) et en
/// navigation empilée sur iPhone. Les conversations sont persistantes côté
/// serveur et streamées en SSE.
struct PromptView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var sessionsState: Loadable<[PromptSession]> = .idle
    @State private var selectedSession: PromptSession?
    @State private var detailState: Loadable<PromptSessionDetail> = .idle
    @State private var runner = ActionRunner()
    @State private var isCreating = false
    @State private var editingSession: PromptSession?

    var body: some View {
        Group {
            if sizeClass == .compact {
                PhonePromptView(
                    sessionsState: $sessionsState,
                    selectedSession: $selectedSession,
                    detailState: $detailState,
                    runner: $runner,
                    isCreating: $isCreating,
                    editingSession: $editingSession
                )
            } else {
                PadPromptView(
                    sessionsState: $sessionsState,
                    selectedSession: $selectedSession,
                    detailState: $detailState,
                    runner: $runner,
                    isCreating: $isCreating,
                    editingSession: $editingSession
                )
            }
        }
        .navigationTitle("Prompt Agent")
        .sheet(isPresented: $isCreating) {
            NewSessionSheet(onCreate: { payload in
                guard let client = session.client else { return }
                let created: PromptSession = try await client.post("/prompt/sessions", body: payload)
                await loadSessions()
                selectedSession = created
                await loadDetail(created.id)
            })
        }
        .sheet(item: $editingSession) { sessionItem in
            RenameSessionSheet(title: sessionItem.title, onRename: { newTitle in
                guard let client = session.client else { return }
                let _: JSONValue = try await client.patch("/prompt/sessions/\(sessionItem.id)",
                                                           body: PromptSessionPatch(title: newTitle))
                await loadSessions()
                if selectedSession?.id == sessionItem.id {
                    await loadDetail(sessionItem.id)
                }
            })
        }
        .actionResult(runner)
        .task { await loadSessions() }
    }

    func loadSessions() async {
        guard let client = session.client else { return }
        sessionsState.begin()
        do {
            sessionsState = .loaded(try await client.get("/prompt/sessions"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { sessionsState = .failed(error) }
        } catch {
            sessionsState = .failed(APIError.transport(error))
        }
    }

    func loadDetail(_ sessionId: Int) async {
        guard let client = session.client else { return }
        detailState.begin()
        do {
            detailState = .loaded(try await client.get("/prompt/sessions/\(sessionId)"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { detailState = .failed(error) }
        } catch {
            detailState = .failed(APIError.transport(error))
        }
    }

    func deleteSession(_ sess: PromptSession) {
        runner.confirm(
            "Supprimer la conversation ?",
            message: "« \(sess.title) » sera définitivement effacée.",
            confirmLabel: "Supprimer"
        ) { [client = session.client] in
            guard let client else { return nil }
            try await client.delete("/prompt/sessions/\(sess.id)")
            return "Conversation supprimée."
        }
    }
}

// MARK: - iPhone

private struct PhonePromptView: View {
    @Binding var sessionsState: Loadable<[PromptSession]>
    @Binding var selectedSession: PromptSession?
    @Binding var detailState: Loadable<PromptSessionDetail>
    @Binding var runner: ActionRunner
    @Binding var isCreating: Bool
    @Binding var editingSession: PromptSession?

    var body: some View {
        NavigationStack {
            SessionListView(
                sessionsState: $sessionsState,
                selectedSession: $selectedSession,
                isCreating: $isCreating,
                editingSession: $editingSession
            )
            .navigationDestination(for: PromptSession.self) { session in
                ChatScreen(
                    session: session,
                    detailState: $detailState,
                    runner: $runner,
                    editingSession: $editingSession
                )
            }
        }
    }
}

// MARK: - iPad

private struct PadPromptView: View {
    @Binding var sessionsState: Loadable<[PromptSession]>
    @Binding var selectedSession: PromptSession?
    @Binding var detailState: Loadable<PromptSessionDetail>
    @Binding var runner: ActionRunner
    @Binding var isCreating: Bool
    @Binding var editingSession: PromptSession?

    var body: some View {
        NavigationSplitView {
            SessionListView(
                sessionsState: $sessionsState,
                selectedSession: $selectedSession,
                isCreating: $isCreating,
                editingSession: $editingSession
            )
            .navigationTitle("Conversations")
        } detail: {
            if let session = selectedSession {
                ChatScreen(
                    session: session,
                    detailState: $detailState,
                    runner: $runner,
                    editingSession: $editingSession
                )
            } else {
                ContentUnavailableView("Sélectionne une conversation",
                                       systemImage: "bubble.left.and.sparkles",
                                       description: Text("Crée ou choisis une conversation pour discuter avec l'assistant de ton infrastructure."))
            }
        }
    }
}

// MARK: - Liste des sessions

private struct SessionListView: View {
    @Environment(SessionStore.self) private var session
    @Binding var sessionsState: Loadable<[PromptSession]>
    @Binding var selectedSession: PromptSession?
    @Binding var isCreating: Bool
    @Binding var editingSession: PromptSession?

    var body: some View {
        List(selection: $selectedSession) {
            Button {
                isCreating = true
            } label: {
                Label("Nouvelle conversation", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if let sessions = sessionsState.value {
                if sessions.isEmpty {
                    Section {
                        EmptyState(
                            title: "Aucune conversation",
                            message: "Crée une conversation pour discuter avec l'assistant de ton infrastructure.",
                            symbol: "bubble.left.and.sparkles")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(sessions) { sess in
                            NavigationLink(value: sess) {
                                SessionRow(session: sess, isSelected: selectedSession?.id == sess.id)
                            }
                            .tag(sess)
                            .swipeActions(edge: .trailing) {
                                Button("Supprimer", systemImage: "trash", role: .destructive) {
                                    Task { await delete(sess) }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Renommer", systemImage: "pencil") {
                                    editingSession = sess
                                }
                                .tint(.accentColor)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if sessionsState.isEmptyLoading {
                ProgressView().controlSize(.large)
            } else if let error = sessionsState.error, sessionsState.value == nil {
                ErrorState(error: error) { Task { await load() } }
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        sessionsState.begin()
        do {
            sessionsState = .loaded(try await client.get("/prompt/sessions"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
            if !error.isCancellation { sessionsState = .failed(error) }
        } catch {
            sessionsState = .failed(APIError.transport(error))
        }
    }

    private func delete(_ sess: PromptSession) async {
        guard let client = session.client else { return }
        do {
            try await client.delete("/prompt/sessions/\(sess.id)")
            if selectedSession?.id == sess.id {
                selectedSession = nil
            }
            sessionsState.begin()
            sessionsState = .loaded(try await client.get("/prompt/sessions"))
        } catch let error as APIError {
            if error.kind == .unauthorized { session.handleUnauthorized() }
        } catch { }
    }
}

private struct SessionRow: View {
    let session: PromptSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "message")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .imageScale(.small)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if let endpoint = session.endpointName {
                    Text("\(endpoint) · \(session.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Écran de chat

private struct ChatScreen: View {
    let session: PromptSession
    @Binding var detailState: Loadable<PromptSessionDetail>
    @Binding var runner: ActionRunner
    @Binding var editingSession: PromptSession?

    @Environment(SessionStore.self) private var sessionStore
    @State private var messages: [PromptMessage] = []
    @State private var draft = ""
    @State private var isStreaming = false
    @State private var streamTask: Task<Void, Never>?
    @State private var streamError: APIError?
    @State private var availableModels: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            transcript
            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        editingSession = session
                    } label: {
                        Label("Renommer", systemImage: "pencil")
                    }
                    if availableModels.count > 1 {
                        Menu("Changer de modèle") {
                            ForEach(availableModels, id: \.self) { model in
                                Button(model) {
                                    Task { await changeModel(model) }
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadDetail()
            await loadModels()
        }
        .onChange(of: session.id) { _, _ in
            streamTask?.cancel()
            streamTask = nil
            isStreaming = false
            messages = []
            Task { await loadDetail() }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Text("\(session.endpointName ?? "—") · \(session.model)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Transcription

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty && !isStreaming {
                        EmptyState(
                            title: "Prompt Agent",
                            message: "Discute avec l'assistant intelligent de ton infrastructure. Il peut consulter l'état de tes hôtes, tes conteneurs, tes services et exécuter des actions.",
                            symbol: "sparkles")
                            .padding(.top, 40)
                    }

                    ForEach(messages) { message in
                        PromptMessageBubble(message: message)
                            .id(message.id)
                    }

                    if isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("L'agent réfléchit…")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }

                    if let error = streamError {
                        InlineErrorBanner(error: error) {
                            streamError = nil
                        }
                        .padding(.horizontal)
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

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Pose une question…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
                .disabled(isStreaming)

            Button {
                if isStreaming {
                    streamTask?.cancel()
                    streamTask = nil
                    isStreaming = false
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
        guard !text.isEmpty, let client = sessionStore.client else { return }

        messages.append(PromptMessage(id: Int.random(in: -999999 ..< -1),
                                       role: .user, content: text))
        draft = ""
        streamError = nil
        isStreaming = true

        let assistantMsg = PromptMessage(id: Int.random(in: -999999 ..< -1),
                                          role: .assistant, content: "")
        messages.append(assistantMsg)

        streamTask = Task {
            defer {
                isStreaming = false
                streamTask = nil
            }
            do {
                let payload = PromptChatPayload(content: text)
                for try await chunk in client.stream("/prompt/sessions/\(session.id)/chat", body: payload) {
                    let event = PromptStreamEvent(json: chunk)
                    if event.isError, let err = event.error {
                        streamError = .http(status: 502, message: err)
                        break
                    }
                    if event.isContent, let content = event.content {
                        append(content, to: assistantMsg.id)
                    }
                    if event.isToolCall, let name = event.name {
                        let toolMsg = PromptMessage(id: Int.random(in: -999999 ..< -1),
                                                     role: .tool,
                                                     content: "🔧 \(name)…")
                        messages.append(toolMsg)
                    }
                    if event.isToolResult, let name = event.name {
                        let resultMsg = PromptMessage(id: Int.random(in: -999999 ..< -1),
                                                       role: .tool,
                                                       content: "✓ \(name)")
                        messages.append(resultMsg)
                    }
                    if event.isDone || event.isFinished {
                        break
                    }
                }
                // Nettoyer un message assistant vide
                if let idx = messages.firstIndex(where: { $0.id == assistantMsg.id }),
                   messages[idx].content.isEmpty {
                    messages.remove(at: idx)
                }
            } catch let error as APIError {
                if !error.isCancellation { streamError = error }
            } catch {
                streamError = APIError.transport(error)
            }
        }
    }

    private func append(_ fragment: String, to id: Int) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content += fragment
    }

    // MARK: - Données

    private func loadDetail() async {
        guard let client = sessionStore.client else { return }
        detailState.begin()
        do {
            let detail: PromptSessionDetail = try await client.get("/prompt/sessions/\(session.id)")
            detailState = .loaded(detail)
            messages = detail.messages
        } catch let error as APIError {
            if error.kind == .unauthorized { sessionStore.handleUnauthorized() }
            if !error.isCancellation { detailState = .failed(error) }
        } catch {
            detailState = .failed(APIError.transport(error))
        }
    }

    private func loadModels() async {
        guard let client = sessionStore.client else { return }
        do {
            let overview: AIOverview = try await client.get("/ai/overview")
            if let endpoint = overview.endpoints.first(where: { $0.id == session.endpointID }) {
                availableModels = endpoint.models.map(\.name)
            }
        } catch { }
    }

    private func changeModel(_ model: String) async {
        guard let client = sessionStore.client else { return }
        await runner.run("Modèle changé") {
            let _: JSONValue = try await client.patch("/prompt/sessions/\(session.id)",
                                                       body: PromptSessionPatch(model: model))
            return "Le modèle est maintenant \(model)."
        }
        await loadDetail()
    }
}

// MARK: - Bulle de message

private struct PromptMessageBubble: View {
    let message: PromptMessage

    var body: some View {
        if message.isTool {
            HStack(spacing: 6) {
                Image(systemName: "wrench")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        message.isUser
                            ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                            : AnyShapeStyle(.background.secondary),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
            }
            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        }
    }
}

// MARK: - Sheets

private struct NewSessionSheet: View {
    let onCreate: (PromptSessionPayload) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    @State private var title = "Nouvelle conversation"
    @State private var endpoints: [AIEndpoint] = []
    @State private var selectedEndpointID: Int?
    @State private var selectedModel = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Palette.danger)
                    }
                    .listRowBackground(Palette.danger.opacity(0.08))
                }

                Section {
                    TextField("Titre", text: $title)
                }

                Section("Endpoint") {
                    if endpoints.isEmpty {
                        Text("Chargement…")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Endpoint", selection: $selectedEndpointID) {
                            ForEach(endpoints) { ep in
                                Text("\(ep.name) (\(ep.kindLabel ?? ep.kind))").tag(ep.id as Int?)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }

                Section("Modèle") {
                    if currentModels.isEmpty {
                        Text("Aucun modèle disponible")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Modèle", selection: $selectedModel) {
                            ForEach(currentModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
            }
            .navigationTitle("Nouvelle conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer") {
                        Task { await create() }
                    }
                    .disabled(selectedEndpointID == nil || selectedModel.isEmpty || busy)
                }
            }
            .task { await loadEndpoints() }
            .onChange(of: selectedEndpointID) { _, _ in
                if let first = currentModels.first, !currentModels.contains(selectedModel) {
                    selectedModel = first
                }
            }
        }
    }

    private var currentModels: [String] {
        guard let epID = selectedEndpointID,
              let ep = endpoints.first(where: { $0.id == epID }) else { return [] }
        return ep.models.map(\.name)
    }

    private func loadEndpoints() async {
        guard let client = session.client else { return }
        do {
            let overview: AIOverview = try await client.get("/ai/overview")
            endpoints = overview.endpoints.filter(\.isOnline)
            if let first = endpoints.first {
                selectedEndpointID = first.id
                selectedModel = first.models.first?.name ?? ""
            }
        } catch { }
    }

    private func create() async {
        guard let endpointID = selectedEndpointID else { return }
        busy = true
        errorMessage = nil
        let payload = PromptSessionPayload(
            title: title.trimmingCharacters(in: .whitespaces),
            endpointID: endpointID,
            model: selectedModel
        )
        do {
            try await onCreate(payload)
            busy = false
            dismiss()
        } catch let error as APIError {
            busy = false
            errorMessage = error.message
        } catch {
            busy = false
            errorMessage = error.localizedDescription
        }
    }
}

private struct RenameSessionSheet: View {
    let title: String
    let onRename: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""
    @State private var busy = false
    @State private var errorMessage: String?

    init(title: String, onRename: @escaping (String) async throws -> Void) {
        self.title = title
        self.onRename = onRename
        _newTitle = State(initialValue: title)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Palette.danger)
                    }
                    .listRowBackground(Palette.danger.opacity(0.08))
                }

                Section {
                    TextField("Titre", text: $newTitle)
                }
            }
            .navigationTitle("Renommer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        Task {
                            busy = true
                            errorMessage = nil
                            do {
                                try await onRename(newTitle.trimmingCharacters(in: .whitespaces))
                                busy = false
                                dismiss()
                            } catch let error as APIError {
                                busy = false
                                errorMessage = error.message
                            } catch {
                                busy = false
                                errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }
        }
    }
}
