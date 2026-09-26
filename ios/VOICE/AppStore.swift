import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var config: ServerConfiguration?
    @Published private(set) var session: AuthSession?
    @Published private(set) var profile: Profile?
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var searchResults: [Profile] = []
    @Published private(set) var callHistory: [CallRecord] = []
    @Published private(set) var activeCall: CallRecord?
    @Published private(set) var isLoading = false
    @Published private(set) var isMuted = false
    @Published private(set) var callConnectionLabel = ""
    @Published var error: String?
    @Published var notice: String?

    private var backend: BackendClient?
    private let audio = CallAudioService()
    private let realtime = RealtimeObserver()
    private var subscriptions = Set<AnyCancellable>()
    private var pollTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var connectingCallID: UUID?
    private var openConversationID: UUID?
    private var epoch = UUID()
    private var searchGeneration = UUID()
    private var refreshing = false
    private var callAction = false
    private var sceneActive = true
    private var bootstrapped = false
    private var locallySuppressedCallIDs: [UUID: Date] = [:]
    private let callSuppressionDuration: TimeInterval = 30
    private let configurationKey = "voice.server.configuration.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: configurationKey),
           let saved = try? JSONDecoder().decode(ServerConfiguration.self, from: data),
           let checked = try? ServerConfiguration(
               supabaseURL: saved.supabaseURL.absoluteString,
               publishableKey: saved.publishableKey,
               livekitURL: saved.livekitURL.absoluteString) {
            config = checked
            backend = BackendClient(config: checked)
        }
        audio.$isMuted.sink { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self, self.activeCall != nil else { return }
                self.isMuted = value
            }
        }.store(in: &subscriptions)
        audio.$connectionLabel.sink { [weak self] value in
            Task { @MainActor [weak self] in
                self?.handleAudioConnectionLabel(value)
            }
        }.store(in: &subscriptions)
    }

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        guard let backend else { return }
        let ticket = epoch
        let storedSession = await backend.currentSession()
        guard ticket == epoch else { return }
        session = storedSession
        guard session != nil else { return }
        do {
            let restored = try await backend.authorizedSession()
            guard ticket == epoch else { return }
            session = restored
            try await fetchProfile(backend, ticket: ticket)
            guard ticket == epoch else { return }
            startPolling()
        } catch {
            await handle(error, ticket: ticket)
            if ticket == epoch, session != nil { startPolling() }
        }
    }

    func saveConfiguration(supabaseURL: String, publishableKey: String, livekitURL: String) throws {
        let value = try ServerConfiguration(
            supabaseURL: supabaseURL,
            publishableKey: publishableKey,
            livekitURL: livekitURL)
        let data = try JSONEncoder().encode(value)
        clearLocalState()
        config = value
        backend = BackendClient(config: value)
        UserDefaults.standard.set(data, forKey: configurationKey)
        bootstrapped = false
        Task { await bootstrap() }
    }

    func resetConfiguration() async {
        await signOut()
        config = nil
        backend = nil
        UserDefaults.standard.removeObject(forKey: configurationKey)
    }

    func signIn(email: String, password: String) async {
        guard let backend else { return }
        let ticket = epoch
        error = nil
        do {
            let result = try await backend.signIn(email: email, password: password)
            guard ticket == epoch else { return }
            session = result
            try await fetchProfile(backend, ticket: ticket)
            guard ticket == epoch else { return }
            startPolling()
        } catch { await handle(error, ticket: ticket) }
    }

    func signUp(email: String, password: String, username: String, displayName: String) async {
        guard let backend else { return }
        let ticket = epoch
        error = nil
        do {
            let normalized = try validUsername(username)
            guard password.count >= 8,
                  !displayName.isEmpty,
                  displayName.count <= 80 else {
                throw VoiceError.message("Пароль должен содержать минимум 8 символов, имя от 1 до 80.")
            }
            let result = try await backend.signUp(
                email: email,
                password: password,
                username: normalized,
                displayName: displayName)
            guard ticket == epoch else { return }
            if let result {
                session = result
                try await fetchProfile(backend, ticket: ticket)
                guard ticket == epoch else { return }
                startPolling()
            }
        } catch { await handle(error, ticket: ticket) }
    }

    func signOut() async {
        let currentBackend = backend
        let currentCallID = activeCall?.id
        if let currentCallID { suppressCall(currentCallID) }
        clearLocalState()
        let token = await currentBackend?.invalidateLocalSessionForSignOut()
        let cleanupTask = Task {
            await currentBackend?.finishSignOut(token: token, endingCallID: currentCallID)
        }
        await audio.disconnect()
        await cleanupTask.value
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if active { startPolling() }
        else if activeCall == nil { stopPolling() }
        // Established audio calls retain their network state in the background.
        // Incoming calls when suspended require APNs/PushKit, not a polling loop.
    }

    func refreshConversations() async { await refresh(reportErrors: true) }
    func refreshCallHistory() async { await refresh(reportErrors: true) }

    private func refresh(reportErrors: Bool) async {
        guard !refreshing,
              let backend,
              session != nil else { return }
        let ticket = epoch
        refreshing = true
        isLoading = conversations.isEmpty
        defer { if ticket == epoch { refreshing = false; isLoading = false } }
        do {
            let current = try await backend.authorizedSession()
            guard ticket == epoch else { return }
            session = current
            if profile == nil { try await fetchProfile(backend, ticket: ticket) }
            guard ticket == epoch else { return }
            let rows = try await backend.request(
                [ConversationSummary].self,
                path: "rest/v1/rpc/conversation_list",
                method: "POST",
                body: [:])
            guard ticket == epoch else { return }
            conversations = rows
            let calls = try await backend.request(
                [CallRecord].self,
                path: "rest/v1/calls",
                query: [
                    .init(name: "select", value: "*"),
                    .init(name: "order", value: "created_at.desc"),
                    .init(name: "limit", value: "100")
                ])
            guard ticket == epoch else { return }
            callHistory = calls
            await reconcileCalls(calls, backend: backend, ticket: ticket)
            guard ticket == epoch else { return }
            if let conversationID = openConversationID {
                try await fetchMessages(conversationID, backend: backend, ticket: ticket)
            }
            guard ticket == epoch else { return }
            if let config, sceneActive || activeCall != nil {
                realtime.start(
                    config: config,
                    token: current.accessToken,
                    userID: current.user.id) { [weak self] in
                    Task { await self?.refresh(reportErrors: false) }
                }
            }
        } catch { await handle(error, ticket: ticket, report: reportErrors) }
    }

    func loadMessages(conversationID: UUID) async {
        openConversationID = conversationID
        guard let backend, session != nil else { return }
        let ticket = epoch
        do { try await fetchMessages(conversationID, backend: backend, ticket: ticket) }
        catch { await handle(error, ticket: ticket) }
    }

    func closeConversation(_ conversationID: UUID) {
        if openConversationID == conversationID { openConversationID = nil }
    }

    private func fetchMessages(_ conversationID: UUID,
                               backend: BackendClient,
                               ticket: UUID) async throws {
        let rows = try await backend.request(
            [ChatMessage].self,
            path: "rest/v1/messages",
            query: [
                .init(name: "conversation_id", value: "eq.\(conversationID.uuidString)"),
                .init(name: "order", value: "created_at.desc"),
                .init(name: "limit", value: "500")
            ])
        guard ticket == epoch,
              openConversationID == conversationID else { return }
        // Merge with recently submitted records so a slower refresh cannot erase a successful send.
        var byID = Dictionary(uniqueKeysWithValues:
            messages.filter { $0.conversationID == conversationID }.map { ($0.id, $0) })
        rows.forEach { byID[$0.id] = $0 }
        messages = byID.values.sorted { $0.createdAt < $1.createdAt }
    }

    func searchPeople(_ text: String) async {
        let generation = UUID()
        searchGeneration = generation
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2,
              let backend,
              let userID = session?.user.id else {
            searchResults = []
            return
        }
        // PostgREST boolean grammar must not be composed from arbitrary punctuation.
        let safe = String(query.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == " "
        }.prefix(64))
        guard !safe.isEmpty else { searchResults = []; return }
        let ticket = epoch
        do {
            let results = try await backend.request(
                [Profile].self,
                path: "rest/v1/profiles",
                query: [
                    .init(name: "id", value: "neq.\(userID.uuidString)"),
                    .init(name: "or", value: "(username.ilike.*\(safe)*,display_name.ilike.*\(safe)*)"),
                    .init(name: "limit", value: "30")
                ])
            guard !Task.isCancelled,
                  generation == searchGeneration,
                  ticket == epoch else { return }
            searchResults = results
        } catch {
            if generation == searchGeneration { await handle(error, ticket: ticket) }
        }
    }

    func openConversation(with person: Profile) async -> ConversationSummary? {
        guard let backend else { return nil }
        let ticket = epoch
        do {
            let id = try await backend.request(
                UUID.self,
                path: "rest/v1/rpc/start_direct_chat",
                method: "POST",
                body: ["other_user_id": person.id.uuidString])
            guard ticket == epoch else { return nil }
            await refresh(reportErrors: false)
            guard ticket == epoch else { return nil }
            return conversations.first { $0.id == id } ?? ConversationSummary(
                id: id,
                peerID: person.id,
                username: person.username,
                displayName: person.displayName,
                avatarPath: person.avatarPath,
                lastMessage: nil,
                lastKind: nil,
                lastMessageAt: nil)
        } catch {
            await handle(error, ticket: ticket)
            return nil
        }
    }

    func sendText(_ text: String, conversationID: UUID) async -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty,
              body.count <= 4000 else {
            error = "Сообщение должно содержать от 1 до 4000 символов."
            return false
        }
        return await send(conversationID: conversationID, kind: "text", body: body)
    }

    func sendPhoto(_ data: Data, conversationID: UUID) async -> Bool {
        await send(
            conversationID: conversationID,
            kind: "image",
            data: data,
            extensionName: "jpg",
            contentType: "image/jpeg")
    }

    func sendVoice(fileURL: URL, duration: Double, conversationID: UUID) async -> Bool {
        guard duration > 0, duration <= 301 else {
            error = "Длительность голосового сообщения должна быть до 5 минут."
            return false
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return await send(
                conversationID: conversationID,
                kind: "voice",
                data: data,
                extensionName: "m4a",
                contentType: "audio/mp4",
                duration: duration)
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func send(conversationID: UUID,
                      kind: String,
                      body: String? = nil,
                      data: Data? = nil,
                      extensionName: String = "",
                      contentType: String = "",
                      duration: Double? = nil) async -> Bool {
        guard let backend,
              let userID = session?.user.id else { return false }
        let ticket = epoch
        let messageID = UUID()
        var uploadedPath: String?
        var insertionStarted = false
        do {
            var payload: [String: Any] = [
                "id": messageID.uuidString,
                "conversation_id": conversationID.uuidString,
                "sender_id": userID.uuidString,
                "kind": kind
            ]
            if let body { payload["body"] = body }
            if let data {
                let path = "\(conversationID.uuidString.lowercased())/\(userID.uuidString.lowercased())/\(messageID.uuidString.lowercased()).\(extensionName)"
                try await backend.upload(bucket: "media", path: path, data: data, contentType: contentType)
                guard ticket == epoch else { throw CancellationError() }
                uploadedPath = path
                payload["attachment_path"] = path
            }
            if let duration { payload["duration_seconds"] = duration }
            guard ticket == epoch else { throw CancellationError() }
            insertionStarted = true
            let result = try await backend.request(
                [ChatMessage].self,
                path: "rest/v1/messages",
                method: "POST",
                body: payload,
                prefer: "return=representation")
            guard ticket == epoch,
                  let message = result.first else { return false }
            messages.removeAll { $0.id == message.id }
            messages.append(message)
            Task { await self.refresh(reportErrors: false) }
            return true
        } catch {
            // On an ambiguous network result, read the client-generated id before deciding it failed.
            if insertionStarted, ticket == epoch {
                if let rows = try? await backend.request(
                    [ChatMessage].self,
                    path: "rest/v1/messages",
                    query: [.init(name: "id", value: "eq.\(messageID.uuidString)")]),
                   let message = rows.first,
                   ticket == epoch {
                    messages.removeAll { $0.id == message.id }
                    messages.append(message)
                    return true
                }
            }
            // Do not delete an attachment after an ambiguous INSERT: it may already be referenced.
            if !insertionStarted, let uploadedPath {
                await backend.removeUpload(bucket: "media", path: uploadedPath)
            }
            await handle(error, ticket: ticket)
            return false
        }
    }

    func signedURL(bucket: String, path: String) async -> URL? {
        guard let backend,
              session != nil,
              isAllowedStoragePath(bucket: bucket, path: path) else { return nil }
        let ticket = epoch
        do {
            let url = try await backend.signedURL(bucket: bucket, path: path)
            return ticket == epoch ? url : nil
        } catch {
            await handle(error, ticket: ticket, report: false)
            return nil
        }
    }

    func updateProfile(displayName: String, username: String, avatarData: Data?) async -> Bool {
        guard let backend,
              let current = profile else { return false }
        let ticket = epoch
        do {
            guard !displayName.isEmpty,
                  displayName.count <= 80 else {
                throw VoiceError.message("Имя должно содержать от 1 до 80 символов.")
            }
            var body: [String: Any] = [
                "username": try validUsername(username),
                "display_name": displayName
            ]
            if let avatarData {
                let path = "\(current.id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
                try await backend.upload(bucket: "avatars", path: path, data: avatarData, contentType: "image/jpeg")
                guard ticket == epoch else { throw CancellationError() }
                body["avatar_path"] = path
            }
            let rows = try await backend.request(
                [Profile].self,
                path: "rest/v1/profiles",
                method: "PATCH",
                query: [.init(name: "id", value: "eq.\(current.id.uuidString)")],
                body: body,
                prefer: "return=representation")
            guard ticket == epoch,
                  let updated = rows.first else { return false }
            profile = updated
            return true
        } catch {
            await handle(error, ticket: ticket)
            return false
        }
    }

    private func fetchProfile(_ backend: BackendClient, ticket: UUID) async throws {
        guard let userID = session?.user.id else { return }
        let rows = try await backend.request(
            [Profile].self,
            path: "rest/v1/profiles",
            query: [.init(name: "id", value: "eq.\(userID.uuidString)")])
        guard ticket == epoch else { return }
        guard let value = rows.first else {
            throw VoiceError.message("Профиль не найден. Проверьте миграции сервера.")
        }
        profile = value
    }

    func startCall(conversationID: UUID) async {
        guard activeCall == nil,
              !callAction,
              let backend else { return }
        callAction = true
        let ticket = epoch
        defer { if ticket == epoch { callAction = false } }
        do {
            let response = try await backend.request(
                RPCRow<CallRecord>.self,
                path: "rest/v1/rpc/start_call",
                method: "POST",
                body: ["p_conversation_id": conversationID.uuidString])
            guard ticket == epoch else { return }
            activeCall = response.value
            callConnectionLabel = "Вызов"
            startPolling()
        } catch { await handle(error, ticket: ticket) }
    }

    func acceptCall() async { await changeCallStatus("accepted") }
    func declineCall() async { await changeCallStatus("declined") }
    func endCall() async { await changeCallStatus("ended") }

    private func changeCallStatus(_ status: String) async {
        guard let call = activeCall,
              let backend,
              !callAction else { return }
        callAction = true
        let ticket = epoch
        defer { if ticket == epoch { callAction = false } }
        if status != "accepted" {
            clearActiveCallLocally(call.id)
            await audio.disconnect()
            guard ticket == epoch else { return }
        }
        do {
            let response = try await backend.request(
                RPCRow<CallRecord>.self,
                path: "rest/v1/rpc/update_call_status",
                method: "POST",
                body: ["p_call_id": call.id.uuidString, "p_status": status])
            guard ticket == epoch else { return }
            let updated = response.value
            if updated.isLive, !isCallSuppressed(updated.id) {
                activeCall = updated
                if updated.status == "accepted" { connectAudio(updated) }
            } else {
                clearActiveCallLocally(updated.id)
            }
            Task { await self.refresh(reportErrors: false) }
        } catch {
            if status != "accepted", ticket == epoch {
                clearActiveCallLocally(call.id)
            }
            await handle(error, ticket: ticket)
        }
    }

    func toggleMute() async {
        let ticket = epoch
        do {
            try await audio.setMuted(!audio.isMuted)
            guard ticket == epoch else { return }
        } catch { await handle(error, ticket: ticket) }
    }

    private func reconcileCalls(_ calls: [CallRecord], backend: BackendClient, ticket: UUID) async {
        guard ticket == epoch else { return }
        pruneSuppressedCalls()
        if let current = activeCall {
            if let updated = calls.first(where: { $0.id == current.id }) {
                await applyCallUpdate(updated, ticket: ticket)
                return
            }

            let rows = try? await backend.request(
                [CallRecord].self,
                path: "rest/v1/calls",
                query: [
                    .init(name: "select", value: "*"),
                    .init(name: "id", value: "eq.\(current.id.uuidString)"),
                    .init(name: "limit", value: "1")
                ])
            guard ticket == epoch,
                  activeCall?.id == current.id else { return }
            if let updated = rows?.first {
                await applyCallUpdate(updated, ticket: ticket)
            } else {
                clearActiveCallLocally(current.id)
                await audio.disconnect()
            }
        } else if sceneActive,
                  let incoming = calls.first(where: {
                      locallySuppressedCallIDs[$0.id] == nil
                          && $0.status == "ringing"
                          && $0.calleeID == session?.user.id
                  }) {
            activeCall = incoming
            callConnectionLabel = "Входящий звонок"
        }
    }

    private func applyCallUpdate(_ updated: CallRecord, ticket: UUID) async {
        guard ticket == epoch,
              activeCall?.id == updated.id else { return }
        if !updated.isLive || isCallSuppressed(updated.id) {
            clearActiveCallLocally(updated.id)
            await audio.disconnect()
        } else {
            activeCall = updated
            if updated.status == "accepted" { connectAudio(updated) }
        }
    }

    private func connectAudio(_ call: CallRecord) {
        guard connectingCallID != call.id,
              let backend,
              let config else { return }
        connectTask?.cancel()
        connectingCallID = call.id
        let ticket = epoch
        callConnectionLabel = "Подключение"
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                struct Token: Decodable { let token: String; let url: String }
                let response = try await backend.request(
                    Token.self,
                    path: "functions/v1/livekit-token",
                    method: "POST",
                    body: ["call_id": call.id.uuidString])
                try Task.checkCancellation()
                guard self.epoch == ticket,
                      self.activeCall?.id == call.id,
                      self.activeCall?.status == "accepted" else { return }
                guard let endpoint = URL(string: response.url),
                      endpoint.scheme == "wss",
                      endpoint.host == config.livekitURL.host,
                      endpoint.port == config.livekitURL.port else {
                    throw VoiceError.message("Адрес звонков не совпадает с настройками LiveKit.")
                }
                try await self.audio.connect(url: response.url, token: response.token)
                if Task.isCancelled || self.epoch != ticket || self.activeCall?.id != call.id {
                    await self.audio.disconnect()
                    if self.epoch == ticket { self.connectingCallID = nil }
                }
            } catch {
                guard !Task.isCancelled, self.epoch == ticket else { return }
                self.error = error.localizedDescription
                self.connectingCallID = nil
                await self.endCall()
            }
        }
    }

    private func startPolling() {
        guard session != nil,
              sceneActive || activeCall != nil,
              pollTask == nil else { return }
        let ticket = epoch
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.epoch == ticket else { return }
                await self.refresh(reportErrors: false)
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        realtime.stop()
    }

    private func clearLocalState() {
        epoch = UUID()
        stopPolling()
        connectTask?.cancel()
        connectTask = nil
        connectingCallID = nil
        session = nil
        profile = nil
        conversations = []
        messages = []
        searchResults = []
        callHistory = []
        activeCall = nil
        openConversationID = nil
        refreshing = false
        callAction = false
        isLoading = false
        isMuted = false
        error = nil
        notice = nil
        callConnectionLabel = ""
    }

    private func handle(_ failure: Error, ticket: UUID, report: Bool = true) async {
        guard ticket == epoch,
              !(failure is CancellationError),
              (failure as? URLError)?.code != .cancelled else { return }
        if let value = failure as? VoiceError, value.unauthorized {
            let current = backend
            let currentCallID = activeCall?.id
            if let currentCallID { suppressCall(currentCallID) }
            clearLocalState()
            let clearedEpoch = epoch
            let token = await current?.invalidateLocalSessionForSignOut()
            let cleanupTask = Task {
                await current?.finishSignOut(token: token, endingCallID: currentCallID)
            }
            await audio.disconnect()
            await cleanupTask.value
            if epoch == clearedEpoch {
                error = "Сеанс истёк. Войдите снова."
            }
        } else if report {
            error = failure.localizedDescription
        }
    }

    private func handleAudioConnectionLabel(_ label: String) {
        guard let call = activeCall else {
            if label.isEmpty { callConnectionLabel = "" }
            return
        }
        guard !label.isEmpty else { return }
        callConnectionLabel = label
        if label == "Disconnected",
           call.status == "accepted",
           !callAction {
            Task { await self.endCall() }
        }
    }

    private func clearActiveCallLocally(_ callID: UUID?) {
        if let callID { suppressCall(callID) }
        connectTask?.cancel()
        connectTask = nil
        connectingCallID = nil
        if callID == nil || activeCall?.id == callID { activeCall = nil }
        isMuted = false
        callConnectionLabel = ""
        if activeCall == nil, !sceneActive { stopPolling() }
    }

    private func suppressCall(_ callID: UUID) {
        pruneSuppressedCalls()
        locallySuppressedCallIDs[callID] = Date().addingTimeInterval(callSuppressionDuration)
    }

    private func isCallSuppressed(_ callID: UUID) -> Bool {
        pruneSuppressedCalls()
        return locallySuppressedCallIDs[callID] != nil
    }

    private func pruneSuppressedCalls() {
        let now = Date()
        locallySuppressedCallIDs = locallySuppressedCallIDs.filter { $0.value > now }
    }

    private func isAllowedStoragePath(bucket: String, path: String) -> Bool {
        guard bucket == "media" || bucket == "avatars",
              !path.isEmpty,
              path == path.lowercased(),
              !path.hasPrefix("/"),
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains(".."),
              !path.contains("%"),
              path.range(of: "[\\x00-\\x1F\\x7F]", options: .regularExpression) == nil else {
            return false
        }
        let uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        let pattern = bucket == "media"
            ? "^\(uuid)/\(uuid)/\(uuid)\\.(jpg|m4a)$"
            : "^\(uuid)/\(uuid)\\.jpg$"
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    private func validUsername(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard normalized.range(of: "^[a-z0-9_]{3,32}$", options: .regularExpression) != nil else {
            throw VoiceError.message("Username: от 3 до 32 латинских букв, цифр или знаков подчёркивания.")
        }
        return normalized
    }
}

private struct RPCRow<T: Decodable>: Decodable {
    let value: T
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(T.self) {
            value = single
        } else {
            let rows = try container.decode([T].self)
            guard let first = rows.first else {
                throw VoiceError.message("Сервер вернул пустой ответ.")
            }
            value = first
        }
    }
}
