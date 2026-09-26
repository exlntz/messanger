import AVFoundation
import Combine
import Foundation
import UIKit

@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0

    private static let maxDuration: Double = 5 * 60

    private enum RecorderError: LocalizedError {
        case alreadyRecording
        case notRecording
        case microphonePermissionDenied
        case recordingUnavailableDuringCall
        case failedToStartRecording
        case interrupted
        case failedRecording
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case .notRecording:
                return "There is no recording to stop."
            case .microphonePermissionDenied:
                return "Microphone access is required to record voice messages."
            case .recordingUnavailableDuringCall:
                return "Voice recording is unavailable while call audio is active."
            case .failedToStartRecording:
                return "Failed to start audio recording."
            case .interrupted:
                return "The recording was interrupted."
            case .failedRecording:
                return "The recording failed."
            case .encodingFailed(let message):
                return message
            }
        }
    }

    private final class DelegateProxy: NSObject, AVAudioRecorderDelegate {
        var onFinish: ((AVAudioRecorder, Bool) -> Void)?
        var onError: ((AVAudioRecorder, Error?) -> Void)?

        func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
            onFinish?(recorder, flag)
        }

        func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
            onError?(recorder, error)
        }
    }

    private let audioSession = AVAudioSession.sharedInstance()
    private let notificationCenter: NotificationCenter
    private let delegateProxy = DelegateProxy()

    private var notificationTokens: [NSObjectProtocol] = []
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var recordingStartedAt: Date?
    private var elapsedTask: Task<Void, Never>?
    private var finishedResult: (url: URL, duration: Double)?
    private var finishedError: Error?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter

        delegateProxy.onFinish = { [weak self] recorder, successfully in
            Task { @MainActor [weak self] in
                self?.handleRecorderFinish(recorder: recorder, successfully: successfully)
            }
        }
        delegateProxy.onError = { [weak self] recorder, error in
            Task { @MainActor [weak self] in
                self?.handleRecorderError(recorder: recorder, error: error)
            }
        }

        notificationTokens = [
            notificationCenter.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: nil
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(notification)
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshElapsedFromRecorder()
                }
            },
            notificationCenter.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshElapsedFromRecorder()
                }
            }
        ]
    }

    deinit {
        elapsedTask?.cancel()
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
    }

    func start() async throws {
        guard recorder == nil, !isRecording else {
            throw RecorderError.alreadyRecording
        }

        clearFinishedState(deleteFile: true)

        let hasPermission = try await requestMicrophonePermission()
        guard hasPermission else {
            throw RecorderError.microphonePermissionDenied
        }

        guard !isCallAudioModeActive() else {
            throw RecorderError.recordingUnavailableDuringCall
        }

        let url = makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000
        ]

        try configureSessionForRecording()

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = delegateProxy
            recorder.isMeteringEnabled = false
            recorder.prepareToRecord()

            guard recorder.record(forDuration: Self.maxDuration) else {
                try? deactivateSession()
                throw RecorderError.failedToStartRecording
            }

            self.recorder = recorder
            recordingURL = url
            recordingStartedAt = Date()
            isRecording = true
            elapsed = 0
            startElapsedTask()
        } catch {
            cleanupActiveRecording(deleteFile: true)
            try? deactivateSession()
            throw error
        }
    }

    func stop() throws -> (url: URL, duration: Double) {
        if let error = consumeFinishedError() {
            throw error
        }

        if let result = consumeFinishedResult() {
            elapsed = result.duration
            return result
        }

        guard let recorder, let recordingURL else {
            throw RecorderError.notRecording
        }

        let duration = normalizedDuration(from: recorder.currentTime)

        recorder.delegate = nil
        recorder.stop()

        let result = (url: recordingURL, duration: duration)
        resetStateAfterSuccessfulStop(duration: duration)
        try? deactivateSession()
        return result
    }

    func cancel() {
        clearFinishedState(deleteFile: true)
        cleanupActiveRecording(deleteFile: true)
        try? deactivateSession()
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

    private func isCallAudioModeActive() -> Bool {
        let mode = audioSession.mode
        return mode == .voiceChat || mode == .videoChat
    }

    private func configureSessionForRecording() throws {
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
    }

    private func deactivateSession() throws {
        try audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func makeRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-recording-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
    }

    private func startElapsedTask() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    self?.refreshElapsedFromRecorder()
                }
            }
        }
    }

    private func refreshElapsedFromRecorder() {
        if let recorder {
            elapsed = normalizedDuration(from: recorder.currentTime)
            return
        }

        if let recordingStartedAt, isRecording {
            elapsed = min(Date().timeIntervalSince(recordingStartedAt), Self.maxDuration)
        }
    }

    private func normalizedDuration(from rawDuration: TimeInterval) -> Double {
        max(0, min(rawDuration, Self.maxDuration))
    }

    private func handleRecorderFinish(recorder: AVAudioRecorder, successfully: Bool) {
        guard recorder === self.recorder else { return }

        if successfully, let recordingURL {
            let duration = normalizedDuration(from: recorder.currentTime)
            finishedResult = (url: recordingURL, duration: duration)
            elapsed = duration
            cleanupActiveRecording(deleteFile: false)
            try? deactivateSession()
        } else {
            finishWithFailure(RecorderError.failedRecording, deleteFile: true)
        }
    }

    private func handleRecorderError(recorder: AVAudioRecorder, error: Error?) {
        guard recorder === self.recorder else { return }

        let wrappedError: Error
        if let error {
            wrappedError = RecorderError.encodingFailed(error.localizedDescription)
        } else {
            wrappedError = RecorderError.failedRecording
        }

        finishWithFailure(wrappedError, deleteFile: true)
    }

    private func handleInterruption(_ notification: Notification) {
        guard isRecording else { return }

        let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else {
            return
        }

        if type == .began {
            finishWithFailure(RecorderError.interrupted, deleteFile: true)
        }
    }

    private func finishWithFailure(_ error: Error, deleteFile: Bool) {
        finishedError = error
        cleanupActiveRecording(deleteFile: deleteFile)
        try? deactivateSession()
    }

    private func cleanupActiveRecording(deleteFile: Bool) {
        elapsedTask?.cancel()
        elapsedTask = nil

        if let recorder {
            recorder.delegate = nil
            if recorder.isRecording {
                recorder.stop()
            }
        }

        self.recorder = nil
        isRecording = false
        recordingStartedAt = nil

        if deleteFile, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
            elapsed = 0
            self.recordingURL = nil
        } else {
            self.recordingURL = recordingURL
        }
    }

    private func resetStateAfterSuccessfulStop(duration: Double) {
        elapsedTask?.cancel()
        elapsedTask = nil
        recorder = nil
        isRecording = false
        recordingStartedAt = nil
        recordingURL = nil
        finishedResult = nil
        finishedError = nil
        elapsed = duration
    }

    private func clearFinishedState(deleteFile: Bool) {
        if deleteFile, let finishedResult {
            try? FileManager.default.removeItem(at: finishedResult.url)
        }
        finishedResult = nil
        finishedError = nil
    }

    private func consumeFinishedResult() -> (url: URL, duration: Double)? {
        defer { finishedResult = nil }
        return finishedResult
    }

    private func consumeFinishedError() -> Error? {
        defer { finishedError = nil }
        return finishedError
    }
}
