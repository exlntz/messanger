import SwiftUI
import AVFoundation

struct MessageBubbleView: View {
    let message: ChatMessage
    let isOutgoing: Bool

    private var kind: String {
        message.kind.lowercased()
    }

    private var bodyText: String? {
        guard let body = message.body?.voiceTrimmed, !body.isEmpty else {
            return nil
        }
        return body
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if isOutgoing {
                Spacer(minLength: 48)
            }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
                MessageAttachmentView(message: message, isOutgoing: isOutgoing)

                if kind == "text", let bodyText {
                    Text(bodyText)
                        .font(.body)
                        .foregroundStyle(isOutgoing ? .white : .primary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 6) {
                    if kind != "text", let bodyText, message.attachmentPath == nil {
                        Text(bodyText)
                            .font(.body)
                            .foregroundStyle(isOutgoing ? .white : .primary)
                            .textSelection(.enabled)
                    }

                    Text(message.createdAt.voiceShortTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isOutgoing ? .white.opacity(0.76) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                if isOutgoing {
                    VOICEGradient()
                } else {
                    Color(.secondarySystemBackground).opacity(0.92)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if !isOutgoing {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
            }
            .accessibilityElement(children: .combine)

            if !isOutgoing {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
}

struct MessageAttachmentView: View {
    let message: ChatMessage
    let isOutgoing: Bool

    var body: some View {
        let kind = message.kind.lowercased()

        if ["photo", "image"].contains(kind), let path = message.attachmentPath {
            SignedPhotoView(path: path)
                .frame(maxWidth: 260, minHeight: 120, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if kind == "voice", let path = message.attachmentPath {
            VoicePlayerView(path: path, duration: message.durationSeconds ?? 0, isOutgoing: isOutgoing)
                .frame(minWidth: 190)
        } else if let body = message.body?.voiceTrimmed, !body.isEmpty, kind != "text" {
            Text(body)
                .font(.body)
                .foregroundStyle(isOutgoing ? .white : .primary)
        }
    }
}

struct SignedPhotoView: View {
    @EnvironmentObject private var store: AppStore

    let path: String

    @State private var signedURL: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)

            if let signedURL {
                AsyncImage(url: signedURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            signedURL = await store.signedURL(bucket: "media", path: path)
        }
        .accessibilityLabel("Фото")
    }
}

struct VoicePlayerView: View {
    @EnvironmentObject private var store: AppStore

    let path: String
    let duration: Double
    let isOutgoing: Bool

    @StateObject private var controller = VoicePlaybackController()
    @State private var signedURL: URL?
    @State private var seekValue = 0.0
    @State private var isSeeking = false

    private var playbackDisabled: Bool {
        store.activeCall != nil
    }

    private var sliderUpperBound: Double {
        max(controller.duration, duration, 1)
    }

    private var currentDisplayTime: Double {
        isSeeking ? seekValue : controller.currentTime
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(width: 36, height: 36)
                    .background(
                        isOutgoing ? .white.opacity(0.18) : .primary.opacity(0.08),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(controller.isLoading || playbackDisabled)
            .accessibilityLabel(controller.isPlaying ? "Пауза" : "Воспроизвести голос")

            VStack(alignment: .leading, spacing: 8) {
                Slider(
                    value: Binding(
                        get: { currentDisplayTime },
                        set: { newValue in
                            seekValue = newValue
                        }
                    ),
                    in: 0...sliderUpperBound,
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if !editing {
                            controller.seek(to: seekValue)
                        }
                    }
                )
                .tint(isOutgoing ? .white : .accentColor)
                .disabled(playbackDisabled || (!controller.hasPlayer && !controller.isLoading))

                HStack {
                    Label(controller.isLoading ? "Загрузка" : "Голосовое сообщение", systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(isOutgoing ? .white.opacity(0.9) : .secondary)

                    Spacer(minLength: 8)

                    Text("\(formatDuration(currentDisplayTime)) / \(formatDuration(max(controller.duration, duration)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .secondary)
                }
            }
        }
        .task(id: path) {
            signedURL = await store.signedURL(bucket: "media", path: path)
        }
        .onChange(of: controller.currentTime) { _, newValue in
            if !isSeeking {
                seekValue = newValue
            }
        }
        .onChange(of: controller.duration) { _, newValue in
            if !isSeeking {
                seekValue = min(seekValue, max(newValue, 0))
            }
        }
        .onChange(of: controller.didFail) { _, didFail in
            guard didFail else { return }
            store.error = "Не удалось воспроизвести голосовое сообщение."
            controller.clearFailure()
        }
        .onChange(of: store.activeCall != nil) { _, hasActiveCall in
            if hasActiveCall {
                controller.stopAndReset()
            }
        }
        .onDisappear {
            controller.teardown()
        }
    }

    private func togglePlayback() async {
        guard !playbackDisabled else { return }

        if controller.isPlaying {
            controller.pause()
            return
        }

        if !controller.hasPlayer {
            controller.isLoading = true
            defer {
                controller.isLoading = false
            }

            if signedURL == nil {
                signedURL = await store.signedURL(bucket: "media", path: path)
            }

            guard let signedURL else {
                store.error = "Не удалось открыть голосовое сообщение."
                return
            }

            controller.prepare(url: signedURL, fallbackDuration: duration)
        }

        controller.play()
    }

    private func formatDuration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

@MainActor
private final class VoicePlaybackController: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var didFail = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    var hasPlayer: Bool {
        player != nil
    }

    func prepare(url: URL, fallbackDuration: Double) {
        teardown()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true

        self.player = player
        currentTime = 0
        duration = max(0, fallbackDuration)
        didFail = false

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    let itemDuration = item.duration.seconds
                    if itemDuration.isFinite && itemDuration > 0 {
                        self.duration = itemDuration
                    }
                case .failed:
                    self.pause()
                    self.didFail = true
                default:
                    break
                }
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                self.currentTime = max(0, seconds)
            }

            let itemDuration = item.duration.seconds
            if itemDuration.isFinite && itemDuration > 0 {
                self.duration = itemDuration
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.finishPlayback()
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.pause()
            self?.didFail = true
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let bounded = max(0, min(seconds, duration > 0 ? duration : seconds))
        let target = CMTime(seconds: bounded, preferredTimescale: 600)
        let shouldResume = isPlaying

        player.pause()
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = bounded
                if shouldResume {
                    self.player?.play()
                }
            }
        }
    }

    func stopAndReset() {
        pause()
        player?.seek(to: .zero)
        currentTime = 0
    }

    func clearFailure() {
        didFail = false
    }

    func teardown() {
        pause()

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }

        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
        currentTime = 0
        duration = 0
        didFail = false
    }

    private func finishPlayback() {
        pause()
        player?.seek(to: .zero)
        currentTime = 0
    }

    deinit {
        teardown()
    }
}
