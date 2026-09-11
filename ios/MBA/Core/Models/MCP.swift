import Foundation

/// Policy MCP : définit les capabilities du serveur MCP.
struct MCPPolicy: Decodable, Identifiable, Hashable, Sendable {
    let id: Int
    var name: String
    var description: String?
    var readOnly: Bool
    var restrictions: [String: [String: Bool]]
    var enabled: Bool
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, description, restrictions, enabled
        case readOnly = "read_only"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "—"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        readOnly = (try? c.decode(Bool.self, forKey: .readOnly)) ?? false
        restrictions = (try? c.decode([String: [String: Bool]].self, forKey: .restrictions)) ?? [:]
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

/// Configuration du serveur MCP (port, transport, host).
struct MCPServerConfig: Decodable, Sendable {
    let id: Int
    var port: Int
    var transport: String
    var host: String
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, port, transport, host
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 3000
        transport = (try? c.decode(String.self, forKey: .transport)) ?? "stdio"
        host = (try? c.decode(String.self, forKey: .host)) ?? "0.0.0.0"
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var isHTTP: Bool { transport == "http" }
    var displayTransport: String { isHTTP ? "HTTP/SSE" : "stdio" }
}

// MARK: - Écritures

/// Corps de `POST /mcp/policies`.
struct MCPPolicyPayload: Encodable, Sendable {
    var name: String
    var description: String?
    var readOnly: Bool
    var restrictions: [String: [String: Bool]]
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case name, description, restrictions, enabled
        case readOnly = "read_only"
    }
}

/// Corps de `PATCH /mcp/policies/{id}`.
struct MCPPolicyPatch: Encodable, Sendable {
    var name: String?
    var description: String?
    var readOnly: Bool?
    var restrictions: [String: [String: Bool]]?
    var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case name, description, restrictions, enabled
        case readOnly = "read_only"
    }
}

/// Corps de `PUT /mcp/config`.
struct MCPServerConfigPayload: Encodable, Sendable {
    var port: Int
    var transport: String
    var host: String
}
