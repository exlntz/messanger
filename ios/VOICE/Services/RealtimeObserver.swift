import Foundation

@MainActor
final class RealtimeObserver {
    private struct ConnectionKey: Equatable {
        let supabaseURL: String
        let publishableKey: String
        let livekitURL: String
        let token: String
        let userID: UUID
    }

    private struct Envelope<Payload: Encodable>: Encodable {
        let topic: String
        let event: String
        let payload: Payload
        let ref: String
        let joinRef: String?

        enum CodingKeys: String, CodingKey {
            case topic
            case event
            case payload
            case ref
            case joinRef = "join_ref"
        }
    }

    private struct EmptyPayload: Encodable {}

    private struct JoinPayload: Encodable {
        let config: JoinConfiguration
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case config
            case accessToken = "access_token"
        }
    }

    private struct JoinConfiguration: Encodable {
        let broadcast: BroadcastConfiguration
        let presence: PresenceConfiguration
        let postgresChanges: [PostgresChangeSubscription]
        let isPrivate: Bool

        enum CodingKeys: String, CodingKey {
            case broadcast
            case presence
            case postgresChanges = "postgres_changes"
            case isPrivate = "private"
        }
    }

    private struct BroadcastConfiguration: Encodable {
        let ack: Bool
        let receiveSelf: Bool

        enum CodingKeys: String, CodingKey {
            case ack
            case receiveSelf = "self"
        }
    }

    private struct PresenceConfiguration: Encodable {
        let enabled: Bool
    }

    private struct PostgresChangeSubscription: Encodable {
        let event: String
        let schema: String
        let table: String
    }

    private static let topic = "realtime:public"
    private static let expectedTables: Set<String> = ["messages", "calls"]
    private static let heartbeatIntervalNanoseconds: UInt64 = 20_000_000_000
    private static let joinTimeoutNanoseconds: UInt64 = 10_000_000_000
    private static let maxReconnectDelaySeconds = 20.0

    private let encoder = JSONEncoder()
    private let session: URLSession

    private var currentConfig: ServerConfiguration?
    private var currentKey: ConnectionKey?
    private var onChange: (@MainActor () -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var connectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var joinTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var generation = 0
    private var nextRef = 0
    private var reconnectAttempt = 0
    private var activeJoinRef: String?
    private var subscriptionIDs = Set<Int64>()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func start(
        config: ServerConfiguration,
        token: String,
        userID: UUID,
        onChange: @escaping @MainActor () -> Void
    ) {
        let key = ConnectionKey(
            supabaseURL: config.supabaseURL.absoluteString,
            publishableKey: config.publishableKey,
            livekitURL: config.livekitURL.absoluteString,
            token: token,
            userID: userID
        )

        guard key != currentKey else { return }

        generation += 1
        reconnectAttempt = 0
        currentConfig = config
        currentKey = key
        self.onChange = onChange
        tearDownConnection(closeSocket: true, cancelReconnect: true)
        scheduleConnect(for: generation)
    }

    func stop() {
        generation += 1
        reconnectAttempt = 0
        currentConfig = nil
        currentKey = nil
        onChange = nil
        tearDownConnection(closeSocket: true, cancelReconnect: true)
    }

    private func scheduleConnect(for generation: Int) {
        connectTask?.cancel()
        connectTask = Task { @MainActor [weak self] in
            await self?.openConnection(for: generation)
        }
    }

    private func openConnection(for generation: Int) async {
        defer {
            if generation == self.generation {
                connectTask = nil
            }
        }

        guard generation == self.generation,
              let config = currentConfig,
              let key = currentKey else { return }

        tearDownConnection(closeSocket: true, cancelReconnect: false)

        let socket = session.webSocketTask(with: websocketURL(for: config))
        self.socket = socket
        subscriptionIDs.removeAll()

        let joinRef = makeRef()
        activeJoinRef = joinRef

        socket.resume()

        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop(for: generation, socket: socket)
        }
        heartbeatTask = Task { @MainActor [weak self] in
            await self?.heartbeatLoop(for: generation, socket: socket)
        }
        joinTimeoutTask = Task { @MainActor [weak self] in
            await self?.joinTimeoutLoop(for: generation, joinRef: joinRef)
        }

        do {
            try await sendJoin(on: socket, joinRef: joinRef, token: key.token)
        } catch {
            await handleConnectionFailure(for: generation)
        }
    }

    private func receiveLoop(for generation: Int, socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                try Task.checkCancellation()
                await handleIncoming(message, for: generation, socket: socket)
            }
        } catch {
            await handleConnectionFailure(for: generation)
        }
    }

    private func heartbeatLoop(for generation: Int, socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: Self.heartbeatIntervalNanoseconds)
                try Task.checkCancellation()
                guard generation == self.generation, self.socket === socket else { return }
                try await sendHeartbeat(on: socket)
            }
        } catch {
            await handleConnectionFailure(for: generation)
        }
    }

    private func joinTimeoutLoop(for generation: Int, joinRef: String) async {
        do {
            try await Task.sleep(nanoseconds: Self.joinTimeoutNanoseconds)
            try Task.checkCancellation()
            guard generation == self.generation,
                  activeJoinRef == joinRef,
                  subscriptionIDs.isEmpty else { return }
            await handleConnectionFailure(for: generation)
        } catch {
            return
        }
    }

    private func handleIncoming(
        _ message: URLSessionWebSocketTask.Message,
        for generation: Int,
        socket: URLSessionWebSocketTask
    ) async {
        guard generation == self.generation, self.socket === socket else { return }

        let data: Data
        switch message {
        case .string(let text):
            guard let encoded = text.data(using: .utf8) else { return }
            data = encoded
        case .data(let binary):
            data = binary
        @unknown default:
            return
        }

        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = raw["event"] as? String,
              let topic = raw["topic"] as? String,
              let payload = raw["payload"] as? [String: Any] else { return }

        switch event {
        case "phx_reply":
            await handleReply(topic: topic, payload: payload, raw: raw, for: generation)
        case "postgres_changes":
            handlePostgresChange(topic: topic, payload: payload)
        case "phx_error", "phx_close":
            await handleConnectionFailure(for: generation)
        default:
            break
        }
    }

    private func handleReply(
        topic: String,
        payload: [String: Any],
        raw: [String: Any],
        for generation: Int
    ) async {
        guard topic == Self.topic,
              payload["status"] as? String == "ok" else { return }

        let replyJoinRef = (raw["join_ref"] as? String) ?? (raw["ref"] as? String)
        guard let joinRef = replyJoinRef,
              joinRef == activeJoinRef,
              subscriptionIDs.isEmpty,
              let response = payload["response"] as? [String: Any],
              let items = response["postgres_changes"] as? [[String: Any]] else { return }

        var ids = Set<Int64>()
        var tables = Set<String>()

        for item in items {
            guard let schema = item["schema"] as? String,
                  schema == "public",
                  let table = item["table"] as? String,
                  Self.expectedTables.contains(table),
                  let number = item["id"] as? NSNumber else { continue }
            tables.insert(table)
            ids.insert(number.int64Value)
        }

        guard tables.isSuperset(of: Self.expectedTables),
              ids.count >= Self.expectedTables.count else {
            await handleConnectionFailure(for: generation)
            return
        }

        reconnectAttempt = 0
        subscriptionIDs = ids
        joinTimeoutTask?.cancel()
        joinTimeoutTask = nil
        onChange?()
    }

    private func handlePostgresChange(topic: String, payload: [String: Any]) {
        guard topic == Self.topic,
              !subscriptionIDs.isEmpty,
              let idValues = payload["ids"] as? [Any],
              let data = payload["data"] as? [String: Any],
              let schema = data["schema"] as? String,
              schema == "public",
              let table = data["table"] as? String,
              Self.expectedTables.contains(table),
              let type = data["type"] as? String,
              !type.isEmpty else { return }

        let ids = Set(idValues.compactMap { ($0 as? NSNumber)?.int64Value })
        guard !ids.isDisjoint(with: subscriptionIDs) else { return }

        onChange?()
    }

    private func handleConnectionFailure(for generation: Int) async {
        guard generation == self.generation, currentKey != nil else { return }
        tearDownConnection(closeSocket: true, cancelReconnect: false)
        scheduleReconnect(for: generation)
    }

    private func scheduleReconnect(for generation: Int) {
        guard reconnectTask == nil, currentKey != nil else { return }

        let attempt = reconnectAttempt
        reconnectAttempt += 1
        let delaySeconds = min(pow(2.0, Double(attempt)), Self.maxReconnectDelaySeconds)

        reconnectTask = Task { @MainActor [weak self] in
            defer {
                if generation == self?.generation {
                    self?.reconnectTask = nil
                }
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                try Task.checkCancellation()
                guard let self,
                      generation == self.generation,
                      self.currentKey != nil else { return }
                self.scheduleConnect(for: generation)
            } catch {
                return
            }
        }
    }

    private func tearDownConnection(closeSocket: Bool, cancelReconnect: Bool) {
        connectTask?.cancel()
        connectTask = nil

        receiveTask?.cancel()
        receiveTask = nil

        heartbeatTask?.cancel()
        heartbeatTask = nil

        joinTimeoutTask?.cancel()
        joinTimeoutTask = nil

        if cancelReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }

        activeJoinRef = nil
        subscriptionIDs.removeAll()

        if closeSocket, let socket {
            socket.cancel(with: .goingAway, reason: nil)
        }
        socket = nil
    }

    private func sendJoin(on socket: URLSessionWebSocketTask, joinRef: String, token: String) async throws {
        let payload = JoinPayload(
            config: JoinConfiguration(
                broadcast: BroadcastConfiguration(ack: false, receiveSelf: false),
                presence: PresenceConfiguration(enabled: false),
                postgresChanges: [
                    PostgresChangeSubscription(event: "*", schema: "public", table: "messages"),
                    PostgresChangeSubscription(event: "*", schema: "public", table: "calls")
                ],
                isPrivate: false
            ),
            accessToken: token
        )

        try await send(
            Envelope(
                topic: Self.topic,
                event: "phx_join",
                payload: payload,
                ref: joinRef,
                joinRef: joinRef
            ),
            on: socket
        )
    }

    private func sendHeartbeat(on socket: URLSessionWebSocketTask) async throws {
        try await send(
            Envelope(
                topic: "phoenix",
                event: "heartbeat",
                payload: EmptyPayload(),
                ref: makeRef(),
                joinRef: nil
            ),
            on: socket
        )
    }

    private func send<Payload: Encodable>(
        _ envelope: Envelope<Payload>,
        on socket: URLSessionWebSocketTask
    ) async throws {
        let data = try encoder.encode(envelope)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceError.message("Не удалось подготовить realtime-запрос.")
        }
        try await socket.send(.string(text))
    }

    private func makeRef() -> String {
        nextRef += 1
        return String(nextRef)
    }

    private func websocketURL(for config: ServerConfiguration) -> URL {
        var components = URLComponents(url: config.supabaseURL, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [
            URLQueryItem(name: "apikey", value: config.publishableKey),
            URLQueryItem(name: "vsn", value: "1.0.0")
        ]
        return components.url!
    }
}
