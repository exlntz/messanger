import Foundation
import Security

// Tokens stay in the device Keychain. Passwords are never persisted.
enum SessionVault {
    static func account(_ config: ServerConfiguration) -> String { config.supabaseURL.absoluteString }
    static func read(_ config: ServerConfiguration) -> AuthSession? {
        var query = base(config)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }
    static func save(_ session: AuthSession, config: ServerConfiguration) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(base(config) as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var query = base(config)
            attributes.forEach { query[$0.key] = $0.value }
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw VoiceError.message("Не удалось сохранить сеанс в Keychain.") }
        } else if result != errSecSuccess { throw VoiceError.message("Keychain недоступен.") }
    }
    static func clear(_ config: ServerConfiguration) { SecItemDelete(base(config) as CFDictionary) }
    private static func base(_ config: ServerConfiguration) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.exlntz.voice.session", kSecAttrAccount as String: account(config)]
    }
}

actor BackendClient {
    let config: ServerConfiguration
    private var session: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?
    private var sessionGeneration = 0
    private let transport: URLSession
    private let decoder = JSONDecoder()

    init(config: ServerConfiguration) {
        self.config = config
        self.session = SessionVault.read(config)
        let setup = URLSessionConfiguration.ephemeral
        setup.timeoutIntervalForRequest = 30
        setup.timeoutIntervalForResource = 120
        self.transport = URLSession(configuration: setup)
    }
    func currentSession() -> AuthSession? { session }
    func authorizedSession() async throws -> AuthSession {
        guard let current = session else { throw VoiceError.http(401, "Войдите в аккаунт.") }
        if (current.expiresAt ?? 0) > Date().timeIntervalSince1970 + 90 { return current }
        if let refreshTask { return try await refreshTask.value }
        let generation = sessionGeneration
        let task = Task<AuthSession, Error> {
            let data = try await self.raw(path: "auth/v1/token", method: "POST", query: [URLQueryItem(name: "grant_type", value: "refresh_token")], body: ["refresh_token": current.refreshToken], token: nil)
            return try self.decoder.decode(AuthSession.self, from: data).dated()
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let renewed = try await task.value
            guard generation == sessionGeneration else { throw CancellationError() }
            try SessionVault.save(renewed, config: config)
            session = renewed
            return renewed
        } catch {
            if let failure = error as? VoiceError, case .http(let code, _) = failure, code == 400 || code == 401 {
                if generation == sessionGeneration { session = nil; SessionVault.clear(config) }
                throw VoiceError.http(401, "Сеанс истёк. Войдите снова.")
            }
            throw error
        }
    }
    func signIn(email: String, password: String) async throws -> AuthSession {
        let data = try await raw(path: "auth/v1/token", method: "POST", query: [.init(name: "grant_type", value: "password")], body: ["email": email, "password": password], token: nil)
        let result = try decoder.decode(AuthSession.self, from: data).dated()
        try SessionVault.save(result, config: config)
        sessionGeneration += 1
        session = result
        return result
    }
    func signUp(email: String, password: String, username: String, displayName: String) async throws -> AuthSession? {
        let data = try await raw(path: "auth/v1/signup", method: "POST", body: ["email": email, "password": password, "data": ["username": username, "display_name": displayName]], token: nil)
        // With email confirmation enabled, GoTrue returns a user without tokens.
        guard let result = try? decoder.decode(AuthSession.self, from: data).dated() else { return nil }
        try SessionVault.save(result, config: config)
        sessionGeneration += 1
        session = result
        return result
    }
    func signOut() async {
        let token = session?.accessToken
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        session = nil
        SessionVault.clear(config)
        if let token { _ = try? await raw(path: "auth/v1/logout", method: "POST", token: token) }
    }
    func request<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil, prefer: String? = nil) async throws -> T {
        let auth = try await authorizedSession()
        let data = try await raw(path: path, method: method, query: query, body: body, token: auth.accessToken, prefer: prefer)
        return try decoder.decode(type, from: data)
    }
    func upload(bucket: String, path: String, data: Data, contentType: String) async throws {
        let auth = try await authorizedSession()
        let maxBytes = bucket == "avatars" ? 5 * 1024 * 1024 : 15 * 1024 * 1024
        guard !data.isEmpty, data.count <= maxBytes else { throw VoiceError.message("Файл слишком большой или пустой.") }
        var request = URLRequest(url: try url(path: "storage/v1/object/\(bucket)/\(path)"))
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        let (body, response) = try await transport.data(for: request)
        try validate(body, response)
    }
    func removeUpload(bucket: String, path: String) async {
        guard let auth = try? await authorizedSession() else { return }
        _ = try? await raw(path: "storage/v1/object/\(bucket)", method: "DELETE", body: ["prefixes": [path]], token: auth.accessToken)
    }
    func signedURL(bucket: String, path: String) async throws -> URL {
        struct Signed: Decodable { let signedURL: String }
        let result = try await request(Signed.self, path: "storage/v1/object/sign/\(bucket)/\(path)", method: "POST", body: ["expiresIn": 300])
        let rawURL = result.signedURL
        let url: URL?
        if rawURL.hasPrefix("https://") { url = URL(string: rawURL) }
        else if rawURL.hasPrefix("/storage/v1/") { url = URL(string: rawURL, relativeTo: config.supabaseURL)?.absoluteURL }
        else { url = URL(string: config.supabaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/storage/v1" + (rawURL.hasPrefix("/") ? "" : "/") + rawURL) }
        guard let url, url.scheme == "https", url.host == config.supabaseURL.host, url.port == config.supabaseURL.port else { throw VoiceError.message("Сервер вернул некорректный адрес файла.") }
        return url
    }
    private func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: config.supabaseURL, resolvingAgainstBaseURL: false)!
        components.path = "/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw VoiceError.message("Некорректный адрес запроса.") }
        return url
    }
    private func raw(path: String, method: String, query: [URLQueryItem] = [], body: [String: Any]? = nil, token: String?, prefer: String? = nil) async throws -> Data {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await transport.data(for: request)
        try validate(data, response)
        return data
    }
    private func validate(_ data: Data, _ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw VoiceError.message("Нет ответа от сервера.") }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let text = object?["msg"] as? String ?? object?["message"] as? String ?? object?["error_description"] as? String ?? object?["error"] as? String
            throw VoiceError.http(response.statusCode, text ?? "Ошибка сервера (\(response.statusCode)).")
        }
    }
}
