import Foundation

struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var avatarPath: String?
    enum CodingKeys: String, CodingKey { case id, username; case displayName = "display_name", avatarPath = "avatar_path" }
}

struct AuthUser: Codable, Equatable { let id: UUID; let email: String? }
struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    var expiresAt: Double?
    let expiresIn: Double?
    let user: AuthUser
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresAt = "expires_at", expiresIn = "expires_in", user
    }
    func dated() -> Self {
        var value = self
        if value.expiresAt == nil { value.expiresAt = Date().timeIntervalSince1970 + (expiresIn ?? 3600) }
        return value
    }
}

struct ConversationSummary: Codable, Identifiable, Hashable {
    let id: UUID
    let peerID: UUID
    let username: String
    let displayName: String
    let avatarPath: String?
    let lastMessage: String?
    let lastKind: String?
    let lastMessageAt: String?
    enum CodingKeys: String, CodingKey {
        case id, username
        case peerID = "peer_id", displayName = "display_name", avatarPath = "avatar_path"
        case lastMessage = "last_message", lastKind = "last_kind", lastMessageAt = "last_message_at"
    }
}

struct ChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let conversationID: UUID
    let senderID: UUID
    let kind: String
    let body: String?
    let attachmentPath: String?
    let durationSeconds: Double?
    let createdAt: String
    enum CodingKeys: String, CodingKey {
        case id, kind, body
        case conversationID = "conversation_id", senderID = "sender_id", attachmentPath = "attachment_path"
        case durationSeconds = "duration_seconds", createdAt = "created_at"
    }
}

struct CallRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let conversationID: UUID
    let callerID: UUID
    let calleeID: UUID
    let status: String
    let createdAt: String
    let endedAt: String?
    var isLive: Bool { status == "ringing" || status == "accepted" }
    enum CodingKeys: String, CodingKey {
        case id, status
        case conversationID = "conversation_id", callerID = "caller_id", calleeID = "callee_id"
        case createdAt = "created_at", endedAt = "ended_at"
    }
}

struct ServerConfiguration: Codable {
    let supabaseURL: URL
    let publishableKey: String
    let livekitURL: URL

    init(supabaseURL: String, publishableKey: String, livekitURL: String) throws {
        func endpoint(_ string: String, scheme: String) throws -> URL {
            guard let url = URL(string: string), url.scheme == scheme,
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
                throw VoiceError.message("Нужен корректный адрес \(scheme):// без пути, пароля и параметров.")
            }
            return url
        }
        self.supabaseURL = try endpoint(supabaseURL, scheme: "https")
        self.livekitURL = try endpoint(livekitURL, scheme: "wss")
        var isPublicKey = publishableKey.hasPrefix("sb_publishable_")
        let pieces = publishableKey.split(separator: ".")
        if pieces.count == 3 {
            var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                isPublicKey = json["role"] as? String == "anon"
            }
        }
        guard isPublicKey else { throw VoiceError.message("Используйте публичный publishable или anon key. Серверные секреты сюда вводить нельзя.") }
        self.publishableKey = publishableKey
    }
}

enum VoiceError: LocalizedError {
    case message(String)
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .http(_, let value): return value
        }
    }
    var unauthorized: Bool { if case .http(let status, _) = self { return status == 401 }; return false }
}
