import SwiftUI

struct CallView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack {
            VoiceBackground()
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                AvatarView(path: peerAvatarPath, displayName: peerName, size: 132)
                    .environmentObject(store)

                VStack(spacing: 12) {
                    Text(peerName)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(statusText)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .voiceGlass(cornerRadius: 28)
                .padding(.horizontal, 24)

                Spacer()

                HStack(spacing: 24) {
                    if isIncomingRinging {
                        CallCircleButton(title: "Отклонить", systemImage: "phone.down.fill", color: .red) {
                            Task { await store.declineCall() }
                        }

                        CallCircleButton(title: "Ответить", systemImage: "phone.fill", color: .green) {
                            Task { await store.acceptCall() }
                        }
                    } else {
                        CallCircleButton(
                            title: store.isMuted ? "Включить" : "Без звука",
                            systemImage: store.isMuted ? "mic.slash.fill" : "mic.fill",
                            color: .white.opacity(0.24)
                        ) {
                            Task { await store.toggleMute() }
                        }

                        CallCircleButton(title: "Завершить", systemImage: "phone.down.fill", color: .red) {
                            Task { await store.endCall() }
                        }
                    }
                }
                .padding(18)
                .voiceGlass(cornerRadius: 32)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
            }
            .padding(.top, 32)
        }
        .interactiveDismissDisabled(store.activeCall != nil)
    }

    private var peerName: String {
        if let conversation = currentConversation {
            return conversation.displayName
        }
        return "VOICE"
    }

    private var peerAvatarPath: String? {
        currentConversation?.avatarPath
    }

    private var currentConversation: ConversationSummary? {
        guard let call = store.activeCall else { return nil }
        return store.conversations.first { $0.id == call.conversationID }
    }

    private var isIncomingRinging: Bool {
        guard let call = store.activeCall, let currentUserID = store.session?.user.id else {
            return false
        }
        return call.calleeID == currentUserID && call.status.lowercased() == "ringing"
    }

    private var statusText: String {
        if !store.callConnectionLabel.isEmpty {
            return store.callConnectionLabel
        }

        guard let status = store.activeCall?.status.lowercased() else {
            return "Звонок"
        }

        switch status {
        case "ringing":
            return isIncomingRinging ? "Входящий звонок" : "Вызов"
        case "active", "connected":
            return "На связи"
        case "ended":
            return "Завершено"
        default:
            return "Соединение"
        }
    }
}

private struct CallCircleButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(color, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(minWidth: 92)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
