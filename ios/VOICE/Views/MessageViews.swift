import SwiftUI
import AVFoundation

struct MessageBubbleView: View {
    let message: ChatMessage
    let isOutgoing: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
                MessageAttachmentView(message: message, isOutgoing: isOutgoing)

                HStack(spacing: 6) {
                    if let body = message.body, !body.isEmpty, message.kind.lowercased() == "text" {
                        Text(body)
                            .font(.body)
                            .foregroundStyle(isOutgoing ? .white : .primary)
                            .textSelection(.enabled)
                    }
                    Text(message.createdAt.voiceShortTime)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isOutgoing ? .white.opacity(0.75) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                if isOutgoing {
                    VOICEGradient()
                } else {
                    Color(.secondarySystemGroupedBackground)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)

            if !isOutgoing { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }
}

struct MessageAttachmentView: View {
    let message: ChatMessage
    let isOutgoing: Bool

    var body: some View {
        let kind = message.kind.lowercased()
        if kind == "photo", let path = message.attachmentPath {
            SignedPhotoView(path: path)
                .frame(maxWidth: 260, minHeight: 120, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if kind == "voice", let path = message.attachmentPath {
            VoicePlayerView(path: path, duration: message.durationSeconds ?? 0, isOutgoing: isOutgoing)
                .frame(minWidth: 180)
        } else if let body = message.body, !body.isEmpty, kind != "text" {
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

    @State private var signedURL: URL?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .background(isOutgoing ? .white.opacity(0.18) : .primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityLabel(isPlaying ? "Пауза" : "Воспроизвести голос")

            Image(systemName: "waveform")
                .font(.title3)
                .foregroundStyle(isOutgoing ? .white.opacity(0.9) : .secondary)
                .accessibilityHidden(true)

            Spacer(minLength: 8)

            if isLoading {
                ProgressView()
                    .tint(isOutgoing ? .white : .accentColor)
            } else {
                Text(formatDuration(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOutgoing ? .white.opacity(0.82) : .secondary)
            }
        }
        .task(id: path) {
            signedURL = await store.signedURL(bucket: "media", path: path)
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private func togglePlayback() async {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }

        if player == nil {
            isLoading = true
            if signedURL == nil {
                signedURL = await store.signedURL(bucket: "media", path: path)
            }
            if let signedURL {
                player = AVPlayer(url: signedURL)
            }
            isLoading = false
        }

        player?.play()
        isPlaying = true
    }

    private func formatDuration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
