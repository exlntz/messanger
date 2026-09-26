import Foundation
import Darwin

struct ContractFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ContractFailure(message: message) }
}

func expectThrows(_ message: String, _ action: () throws -> Void) throws {
    do {
        try action()
        throw ContractFailure(message: message)
    } catch is ContractFailure {
        throw ContractFailure(message: message)
    } catch {
        return
    }
}

func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

func base64URL(_ value: String) -> String {
    Data(value.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func jwt(role: String) -> String {
    let header = base64URL(#"{"alg":"none","typ":"JWT"}"#)
    let payload = base64URL(#"{"role":"\#(role)"}"#)
    return "\(header).\(payload).signature"
}

let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let profileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
let conversationID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
let peerID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
let messageID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
let senderID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
let callID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
let callerID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
let calleeID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

func testAuthSessionDatedExpiries() throws {
    let user = AuthUser(id: userID, email: "user@example.test")
    let before = Date().timeIntervalSince1970
    let dated = AuthSession(accessToken: "access", refreshToken: "refresh", expiresAt: nil, expiresIn: 120, user: user).dated()
    let after = Date().timeIntervalSince1970
    try check(dated.expiresAt != nil, "auth-session-dated-sets-missing-expires-at")
    try check(dated.expiresAt! >= before + 120 && dated.expiresAt! <= after + 120, "auth-session-dated-uses-expires-in-window")

    let preserved = AuthSession(accessToken: "access", refreshToken: "refresh", expiresAt: 42, expiresIn: 999, user: user).dated()
    try check(preserved.expiresAt == 42, "auth-session-dated-preserves-existing-expires-at")

    let defaulted = AuthSession(accessToken: "access", refreshToken: "refresh", expiresAt: nil, expiresIn: nil, user: user).dated()
    try check(defaulted.expiresAt! >= before + 3600 && defaulted.expiresAt! <= Date().timeIntervalSince1970 + 3600, "auth-session-dated-defaults-to-one-hour")

    try expectThrows("auth-session-decode-rejects-missing-refresh-token") {
        _ = try decode(AuthSession.self, #"{"access_token":"access","expires_in":120,"user":{"id":"11111111-1111-1111-1111-111111111111","email":"user@example.test"}}"#)
    }
}

func testProfileMapping() throws {
    let profile = try decode(Profile.self, #"{"id":"22222222-2222-2222-2222-222222222222","username":"voice_user","display_name":"Voice User","avatar_path":"avatars/voice.png"}"#)
    try check(profile.id == profileID, "profile-maps-id-uuid")
    try check(profile.username == "voice_user", "profile-maps-username")
    try check(profile.displayName == "Voice User", "profile-maps-display-name")
    try check(profile.avatarPath == "avatars/voice.png", "profile-maps-avatar-path")

    try expectThrows("profile-decode-rejects-missing-display-name") {
        _ = try decode(Profile.self, #"{"id":"22222222-2222-2222-2222-222222222222","username":"voice_user"}"#)
    }
}

func testChatMessageJSONFieldsAndUUIDs() throws {
    let image = try decode(ChatMessage.self, #"{"id":"55555555-5555-5555-5555-555555555555","conversation_id":"33333333-3333-3333-3333-333333333333","sender_id":"66666666-6666-6666-6666-666666666666","kind":"image","body":null,"attachment_path":"images/one.jpg","duration_seconds":null,"created_at":"2026-09-26T10:00:00Z"}"#)
    try check(image.id == messageID, "chat-message-image-maps-id-uuid")
    try check(image.conversationID == conversationID, "chat-message-image-maps-conversation-uuid")
    try check(image.senderID == senderID, "chat-message-image-maps-sender-uuid")
    try check(image.kind == "image", "chat-message-image-maps-kind")
    try check(image.attachmentPath == "images/one.jpg", "chat-message-image-maps-attachment-path")
    try check(image.durationSeconds == nil, "chat-message-image-keeps-duration-nil")

    let voice = try decode(ChatMessage.self, #"{"id":"55555555-5555-5555-5555-555555555555","conversation_id":"33333333-3333-3333-3333-333333333333","sender_id":"66666666-6666-6666-6666-666666666666","kind":"voice","body":null,"attachment_path":"voice/one.m4a","duration_seconds":3.5,"created_at":"2026-09-26T10:00:01Z"}"#)
    try check(voice.kind == "voice", "chat-message-voice-maps-kind")
    try check(voice.attachmentPath == "voice/one.m4a", "chat-message-voice-maps-attachment-path")
    try check(voice.durationSeconds == 3.5, "chat-message-voice-maps-duration-seconds")

    try expectThrows("chat-message-decode-rejects-invalid-id-uuid") {
        _ = try decode(ChatMessage.self, #"{"id":"not-a-uuid","conversation_id":"33333333-3333-3333-3333-333333333333","sender_id":"66666666-6666-6666-6666-666666666666","kind":"image","created_at":"2026-09-26T10:00:00Z"}"#)
    }
}

func testCallRecordStatusIsLive() throws {
    let ringing = CallRecord(id: callID, conversationID: conversationID, callerID: callerID, calleeID: calleeID, status: "ringing", createdAt: "2026-09-26T10:00:00Z", endedAt: nil)
    try check(ringing.isLive == true, "call-record-ringing-is-live")

    let accepted = CallRecord(id: callID, conversationID: conversationID, callerID: callerID, calleeID: calleeID, status: "accepted", createdAt: "2026-09-26T10:00:00Z", endedAt: nil)
    try check(accepted.isLive == true, "call-record-accepted-is-live")

    let ended = CallRecord(id: callID, conversationID: conversationID, callerID: callerID, calleeID: calleeID, status: "ended", createdAt: "2026-09-26T10:00:00Z", endedAt: "2026-09-26T10:05:00Z")
    try check(ended.isLive == false, "call-record-ended-is-not-live")

    let rejected = CallRecord(id: callID, conversationID: conversationID, callerID: callerID, calleeID: calleeID, status: "rejected", createdAt: "2026-09-26T10:00:00Z", endedAt: nil)
    try check(rejected.isLive == false, "call-record-rejected-is-not-live")
}

func testConversationDecode() throws {
    let conversation = try decode(ConversationSummary.self, #"{"id":"33333333-3333-3333-3333-333333333333","peer_id":"44444444-4444-4444-4444-444444444444","username":"peer_user","display_name":"Peer User","avatar_path":"avatars/peer.png","last_message":"hello","last_kind":"text","last_message_at":"2026-09-26T10:00:00Z"}"#)
    try check(conversation.id == conversationID, "conversation-decode-maps-id-uuid")
    try check(conversation.peerID == peerID, "conversation-decode-maps-peer-uuid")
    try check(conversation.displayName == "Peer User", "conversation-decode-maps-display-name")
    try check(conversation.lastKind == "text", "conversation-decode-maps-last-kind")
    try check(conversation.lastMessageAt == "2026-09-26T10:00:00Z", "conversation-decode-maps-last-message-at")

    try expectThrows("conversation-decode-rejects-invalid-peer-uuid") {
        _ = try decode(ConversationSummary.self, #"{"id":"33333333-3333-3333-3333-333333333333","peer_id":"bad-peer","username":"peer_user","display_name":"Peer User"}"#)
    }
}

func testServerConfigurationValidation() throws {
    let publicPrefix = "sb_publishable_contract_key"
    let anonJWT = jwt(role: "anon")
    let serviceRoleJWT = jwt(role: "service_role")
    let secretKey = "sb_secret_contract_key"

    let prefixConfig = try ServerConfiguration(supabaseURL: "https://api.example.test", publishableKey: publicPrefix, livekitURL: "wss://live.example.test")
    try check(prefixConfig.supabaseURL.absoluteString == "https://api.example.test", "server-config-accepts-https-supabase-url")
    try check(prefixConfig.livekitURL.absoluteString == "wss://live.example.test", "server-config-accepts-wss-livekit-url")
    try check(prefixConfig.publishableKey == publicPrefix, "server-config-accepts-public-prefix-key")

    let jwtConfig = try ServerConfiguration(supabaseURL: "https://api.example.test/", publishableKey: anonJWT, livekitURL: "wss://live.example.test/")
    try check(jwtConfig.publishableKey == anonJWT, "server-config-accepts-anon-jwt")

    try expectThrows("server-config-rejects-http-supabase-url") {
        _ = try ServerConfiguration(supabaseURL: "http://api.example.test", publishableKey: publicPrefix, livekitURL: "wss://live.example.test")
    }
    try expectThrows("server-config-rejects-ws-livekit-url") {
        _ = try ServerConfiguration(supabaseURL: "https://api.example.test", publishableKey: publicPrefix, livekitURL: "ws://live.example.test")
    }
    try expectThrows("server-config-rejects-url-username") {
        _ = try ServerConfiguration(supabaseURL: "https://user@api.example.test", publishableKey: publicPrefix, livekitURL: "wss://live.example.test")
    }
    try expectThrows("server-config-rejects-url-password") {
        _ = try ServerConfiguration(supabaseURL: "https://user:pass@api.example.test", publishableKey: publicPrefix, livekitURL: "wss://live.example.test")
    }
    try expectThrows("server-config-rejects-url-query") {
        _ = try ServerConfiguration(supabaseURL: "https://api.example.test?token=1", publishableKey: publicPrefix, livekitURL: "wss://live.example.test")
    }
    try expectThrows("server-config-rejects-url-path") {
        _ = try ServerConfiguration(supabaseURL: "https://api.example.test/rest/v1", publishableKey: publicPrefix, livekitURL: "wss://live.example.test")
    }
    try expectThrows("server-config-rejects-livekit-url-query") {
        _ = try ServerConfiguration(supabaseURL: "https://api.example.test", publishableKey: publicPrefix, livekitURL: "wss://live.example.test?room=1")
    }
    try expectThrows("server-config-rejects-secret-key") {
        _ = try ServerConfiguration(supabaseURL: "https://api.example.test", publishableKey: secretKey, livekitURL: "wss://live.example.test")
    }
    try expectThrows("server-config-rejects-service-role-jwt") {
        _ = try ServerConfiguration(supabaseURL: "https://api.example.test", publishableKey: serviceRoleJWT, livekitURL: "wss://live.example.test")
    }
    try expectThrows("server-config-rejects-malformed-key") {
        _ = try ServerConfiguration(supabaseURL: "https://api.example.test", publishableKey: "not-public-or-jwt", livekitURL: "wss://live.example.test")
    }
}

let tests: [(String, () throws -> Void)] = [
    ("auth-session-dated-expiries", testAuthSessionDatedExpiries),
    ("profile-mapping", testProfileMapping),
    ("chat-message-json-fields-and-uuids", testChatMessageJSONFieldsAndUUIDs),
    ("call-record-status-is-live", testCallRecordStatusIsLive),
    ("conversation-decode", testConversationDecode),
    ("server-configuration-validation", testServerConfigurationValidation),
]

do {
    for (name, test) in tests {
        try test()
        print("PASS \(name)")
    }
    print("PASS contract tests")
} catch {
    print("FAIL \(error)")
    exit(1)
}
