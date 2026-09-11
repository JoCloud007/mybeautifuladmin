import Foundation

/// Session de conversation Prompt Agent.
struct PromptSession: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var title: String
    var endpointID: Int
    var model: String
    var endpointName: String?
    var endpointKind: String?
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, model
        case endpointID = "endpoint_id"
        case endpointName = "endpoint_name"
        case endpointKind = "endpoint_kind"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Nouvelle conversation"
        endpointID = try c.decode(Int.self, forKey: .endpointID)
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        endpointName = try c.decodeIfPresent(String.self, forKey: .endpointName)
        endpointKind = try c.decodeIfPresent(String.self, forKey: .endpointKind)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

/// Rôle d'un message dans une conversation Prompt.
enum PromptMessageRole: String, Codable, Sendable {
    case user, assistant, tool
}

/// Message d'une conversation Prompt Agent.
struct PromptMessage: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var role: PromptMessageRole
    var content: String
    var toolCalls: [JSONValue]?
    var toolResults: [JSONValue]?
    var stats: JSONValue?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, role, content, stats
        case toolCalls = "tool_calls"
        case toolResults = "tool_results"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        role = (try? c.decode(PromptMessageRole.self, forKey: .role)) ?? .assistant
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        toolCalls = try c.decodeIfPresent([JSONValue].self, forKey: .toolCalls)
        toolResults = try c.decodeIfPresent([JSONValue].self, forKey: .toolResults)
        stats = try c.decodeIfPresent(JSONValue.self, forKey: .stats)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    init(id: Int, role: PromptMessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    var isUser: Bool { role == .user }
    var isTool: Bool { role == .tool }
}

/// Détail d'une session avec ses messages.
struct PromptSessionDetail: Decodable, Sendable {
    var id: Int
    var title: String
    var endpointID: Int
    var model: String
    var endpointName: String?
    var endpointKind: String?
    var messages: [PromptMessage]
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, model, messages
        case endpointID = "endpoint_id"
        case endpointName = "endpoint_name"
        case endpointKind = "endpoint_kind"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Nouvelle conversation"
        endpointID = try c.decode(Int.self, forKey: .endpointID)
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        endpointName = try c.decodeIfPresent(String.self, forKey: .endpointName)
        endpointKind = try c.decodeIfPresent(String.self, forKey: .endpointKind)
        messages = (try? c.decode([PromptMessage].self, forKey: .messages)) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

// MARK: - Écritures

/// Corps de `POST /prompt/sessions`.
struct PromptSessionPayload: Encodable, Sendable {
    var title: String
    var endpointID: Int
    var model: String

    enum CodingKeys: String, CodingKey {
        case title, model
        case endpointID = "endpoint_id"
    }
}

/// Corps de `PATCH /prompt/sessions/{id}`.
struct PromptSessionPatch: Encodable, Sendable {
    var title: String?
    var model: String?
}

/// Corps de `POST /prompt/sessions/{id}/chat`.
struct PromptChatPayload: Encodable, Sendable {
    var content: String
}

// MARK: - Stream

/// Événement SSE reçu du endpoint chat.
struct PromptStreamEvent: Sendable {
    var type: String
    var content: String?
    var name: String?
    var arguments: JSONValue?
    var output: String?
    var error: String?

    init(json: JSONValue) {
        type = json["type"]?.stringValue ?? "unknown"
        content = json["content"]?.stringValue
        name = json["name"]?.stringValue
        arguments = json["arguments"]
        output = json["output"]?.stringValue
        error = json["error"]?.stringValue
    }

    var isContent: Bool { type == "content" }
    var isToolCall: Bool { type == "tool_call" }
    var isToolResult: Bool { type == "tool_result" }
    var isDone: Bool { type == "done" }
    var isError: Bool { type == "error" }
    var isFinished: Bool { type == "finished" }
}
