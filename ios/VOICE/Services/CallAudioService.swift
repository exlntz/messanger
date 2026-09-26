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
                return "Microphone access is required for calls."
            case .notConnected:
                return "The call is not connected."
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

    init() {
        delegateProxy.onConnectionStateChange = { [weak self] room, state in
            Task { @MainActor [weak self] in
                self?.handleConnectionStateChange(for: room, state: state)
            }
        }
        delegateProxy.onDidConnect = { [weak self] room in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = "Connected"
            }
        }
        delegateProxy.onReconnecting = { [weak self] room in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = "Reconnecting…"
            }
        }
        delegateProxy.onDidReconnect = { [weak self] room in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = "Connected"
            }
        }
        delegateProxy.onDidFailToConnect = { [weak self] room, error in
            Task { @MainActor [weak self] in
                guard self?.room === room else { return }
                self?.connectionLabel = error?.localizedDescription ?? "Connection failed"
            }
        }
        delegateProxy.onDidDisconnect = { [weak self] room, error in
            Task { @MainActor [weak self] in
                guard let self, self.room === room else { return }
                self.connectionLabel = error?.localizedDescription ?? "Disconnected"
                self.isMuted = false
                self.room = nil
                await self.deactivateCallSessionIfPossible()
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

        let hasPermission = try await requestMicrophonePermission()
        guard hasPermission else {
            throw CallAudioError.microphonePermissionDenied
        }

        let room = Room(delegate: delegateProxy)
        self.room = room
        desiredMuted = false
        isMuted = false
        connectionLabel = "Connecting…"

        let task = Task { [weak self, room] in
            guard let self else { return }

            try self.configureCallSession()
            try Task.checkCancellation()

            try await room.connect(url: url, token: token)
            try Task.checkCancellation()

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

            if self.room === room {
                isMuted = false
                connectionLabel = displayLabel(for: room.connectionState)
            }
        } catch {
            connectTask = nil
            task.cancel()
            await cleanupAfterFailedConnect(for: room)
            throw error
        }
    }

    func disconnect() async {
        connectTask?.cancel()

        if let connectTask {
            _ = try? await connectTask.value
        }
        self.connectTask = nil

        let room = self.room
        self.room = nil
        desiredMuted = false
        isMuted = false
        connectionLabel = ""

        if let room {
            await room.disconnect()
        }

        await deactivateCallSessionIfPossible()
    }

    func setMuted(_ muted: Bool) async throws {
        guard let room else {
            throw CallAudioError.notConnected
        }
        guard room.connectionState == .connected else {
            throw CallAudioError.notConnected
        }

        if !muted {
            let hasPermission = try await requestMicrophonePermission()
            guard hasPermission else {
                throw CallAudioError.microphonePermissionDenied
            }
            try configureCallSession()
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
            return "Connecting…"
        case .reconnecting:
            return "Reconnecting…"
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting…"
        case .disconnected:
            return "Disconnected"
        @unknown default:
            return "Connection changed"
        }
    }

    private func cleanupAfterFailedConnect(for room: Room) async {
        if self.room === room {
            self.room = nil
            isMuted = false
            connectionLabel = ""
        }
        await room.disconnect()
        await deactivateCallSessionIfPossible()
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

    private func configureCallSession() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
    }

    private func deactivateCallSessionIfPossible() async {
        do {
            try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Leave the shared session as-is if another owner still needs it.
        }
    }
}
