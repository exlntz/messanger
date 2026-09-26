import AVFoundation
import Combine
import Foundation
import LiveKit

@MainActor
final class CallAudioService: ObservableObject {
    @Published private(set) var connectionLabel = ""
    @Published private(set) var isMuted = false

    private enum CallAudioError: LocalizedError {
        case microphonePermissionDenied
        case notConnected

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Нужен доступ к микрофону для звонков."
            case .notConnected:
                return "Звонок не подключен."
            }
        }
    }

    private final class DelegateProxy: NSObject, RoomDelegate {
        var onConnectionStateChange: ((Room, ConnectionState) -> Void)?
        var onDidConnect: ((Room) -> Void)?
        var onReconnecting: ((Room) -> Void)?
        var onDidReconnect: ((Room) -> Void)?
        var onDidFailToConnect: ((Room, LiveKitError?) -> Void)?
        var onDidDisconnect: ((Room, LiveKitError?) -> Void)?
        var onLocalMuteChanged: ((Room, Bool) -> Void)?

        func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
            onConnectionStateChange?(room, connectionState)
        }

        func roomDidConnect(_ room: Room) {
            onDidConnect?(room)
        }

        func roomIsReconnecting(_ room: Room) {
            onReconnecting?(room)
        }

        func roomDidReconnect(_ room: Room) {
            onDidReconnect?(room)
        }

        func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
            onDidFailToConnect?(room, error)
        }

        func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
            onDidDisconnect?(room, error)
        }

        func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
            guard participant is LocalParticipant else { return }
            onLocalMuteChanged?(room, isMuted)
        }
    }

    private let audioSession = AVAudioSession.sharedInstance()
    private let delegateProxy = DelegateProxy()

    private var room: Room?
    private var connectTask: Task<Void, Error>?
    private var desiredMuted = false
    private var generation = 0
    private var sessionOwnerGeneration: Int?

    init() {
        delegateProxy.onConnectionStateChange = { [weak self] room, state in
            Task { @MainActor [weak self] in
                self?.handleConnectionStateChange(for: room, state: state)
            }
        }
        delegateProxy.onDidConnect = { [weak self] room in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = "На связи"
            }
        }
        delegateProxy.onReconnecting = { [weak self] room in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = "Переподключение..."
            }
        }
        delegateProxy.onDidReconnect = { [weak self] room in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = "На связи"
            }
        }
        delegateProxy.onDidFailToConnect = { [weak self] room, _ in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = "Ошибка подключения"
            }
        }
        delegateProxy.onDidDisconnect = { [weak self] room, _ in
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                let endedGeneration = self.generation
                self.connectionLabel = "Отключено"
                self.isMuted = false
                self.room = nil
                self.connectTask = nil
                self.desiredMuted = false
                await self.deactivateCallSessionIfOwned(by: endedGeneration)
            }
        }
        delegateProxy.onLocalMuteChanged = { [weak self] room, muted in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.isMuted = muted
            }
        }
    }

    func connect(url: String, token: String) async throws {
        await disconnect()

        let connectGeneration = nextGeneration()

        let hasPermission = try await requestMicrophonePermission()
        try Task.checkCancellation()
        guard generation == connectGeneration else { throw CancellationError() }
        guard hasPermission else {
            throw CallAudioError.microphonePermissionDenied
        }

        let room = Room(delegate: delegateProxy)
        self.room = room
        desiredMuted = false
        isMuted = false
        connectionLabel = "Подключение..."

        let task = Task { [weak self, room, connectGeneration] in
            guard let self else { return }
            guard await self.isCurrent(room: room, generation: connectGeneration) else {
                throw CancellationError()
            }

            try await self.configureCallSession(for: connectGeneration)
            try Task.checkCancellation()
            guard await self.isCurrent(room: room, generation: connectGeneration) else {
                throw CancellationError()
            }

            try await room.connect(url: url, token: token)
            try Task.checkCancellation()
            guard await self.isCurrent(room: room, generation: connectGeneration) else {
                throw CancellationError()
            }

            try await room.localParticipant.setMicrophone(enabled: true)
        }

        connectTask = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }

            connectTask = nil

            if self.room === room, generation == connectGeneration {
                isMuted = false
                connectionLabel = displayLabel(for: room.connectionState)
            }
        } catch {
            connectTask = nil
            task.cancel()
            await cleanupAfterFailedConnect(for: room, generation: connectGeneration)
            throw error
        }
    }

    func disconnect() async {
        let ownerGeneration = sessionOwnerGeneration
        _ = nextGeneration()
        let taskToCancel = connectTask
        let roomToDisconnect = room

        taskToCancel?.cancel()
        connectTask = nil
        room = nil
        desiredMuted = false
        isMuted = false
        connectionLabel = ""

        if let roomToDisconnect {
            await roomToDisconnect.disconnect()
        }

        await deactivateCallSessionIfOwned(by: ownerGeneration)
    }

    func setMuted(_ muted: Bool) async throws {
        guard let room else {
            throw CallAudioError.notConnected
        }
        let muteGeneration = generation
        guard room.connectionState == .connected else {
            throw CallAudioError.notConnected
        }

        if !muted {
            let hasPermission = try await requestMicrophonePermission()
            try Task.checkCancellation()
            guard self.room === room, generation == muteGeneration else {
                throw CancellationError()
            }
            guard hasPermission else {
                throw CallAudioError.microphonePermissionDenied
            }
            try await configureCallSession(for: muteGeneration)
        }

        try Task.checkCancellation()
        guard self.room === room, generation == muteGeneration else {
            throw CancellationError()
        }

        desiredMuted = muted
        try await room.localParticipant.setMicrophone(enabled: !muted)
        isMuted = muted
    }

    private func handleConnectionStateChange(for room: Room, state: ConnectionState) {
        guard self.room === room else { return }
        connectionLabel = displayLabel(for: state)
    }

    private func displayLabel(for state: ConnectionState) -> String {
        switch state {
        case .connecting:
            return "Подключение..."
        case .reconnecting:
            return "Переподключение..."
        case .connected:
            return "На связи"
        case .disconnecting:
            return "Отключение..."
        case .disconnected:
            return "Отключено"
        @unknown default:
            return "Состояние звонка изменилось"
        }
    }

    private func cleanupAfterFailedConnect(for room: Room, generation connectGeneration: Int) async {
        if self.room === room, generation == connectGeneration {
            self.room = nil
            isMuted = false
            connectionLabel = ""
            desiredMuted = false
        }

        await room.disconnect()
        await deactivateCallSessionIfOwned(by: connectGeneration)
    }

    private func requestMicrophonePermission() async throws -> Bool {
        switch audioSession.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                audioSession.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func configureCallSession(for ownerGeneration: Int) async throws {
        guard generation == ownerGeneration else { throw CancellationError() }
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
        sessionOwnerGeneration = ownerGeneration
    }

    private func deactivateCallSessionIfOwned(by ownerGeneration: Int?) async {
        guard let ownerGeneration, sessionOwnerGeneration == ownerGeneration else { return }
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
            sessionOwnerGeneration = nil
        } catch {
            sessionOwnerGeneration = nil
        }
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    private func isCurrent(room: Room, generation expectedGeneration: Int) -> Bool {
        self.room === room && generation == expectedGeneration
    }
}
