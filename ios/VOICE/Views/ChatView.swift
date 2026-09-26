import SwiftUI
import PhotosUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    let conversation: ConversationSummary

    @StateObject private var recorder = VoiceRecorder()
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var isSending = false
    @State private var isSendingPhoto = false
    @State private var didInitialScroll = false
    @FocusState private var isFocused: Bool

    private var messages: [ChatMessage] {
        store.messages
            .filter { $0.conversationID == conversation.id }
            .sorted { ($0.createdAt.voiceDate ?? .distantPast) < ($1.createdAt.voiceDate ?? .distantPast) }
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composeBar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(conversation.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    AvatarView(path: conversation.avatarPath, displayName: conversation.displayName, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(conversation.displayName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("@\(conversation.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.startCall(conversationID: conversation.id) }
                } label: {
                    Image(systemName: "phone")
                }
                .accessibilityLabel("Позвонить")
            }
        }
        .task(id: conversation.id) {
            await store.loadMessages(conversationID: conversation.id)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.loadMessages(conversationID: conversation.id) }
            }
        }
        .onChange(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await sendPhoto(newValue) }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if store.isLoading && messages.isEmpty {
                        ProgressView("Загрузка сообщений")
                            .padding(.top, 40)
                    } else if messages.isEmpty {
                        VOICEEmptyState(systemImage: "bubble.left", title: "Нет сообщений", message: "Напишите первое сообщение. Демонстрационные сообщения не создаются.")
                            .frame(minHeight: 420)
                    } else {
                        ForEach(messages) { message in
                            MessageBubbleView(message: message, isOutgoing: message.senderID == store.session?.user.id)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                scrollToBottom(proxy: proxy, animated: didInitialScroll)
                didInitialScroll = true
            }
            .onAppear {
                scrollToBottom(proxy: proxy, animated: false)
                didInitialScroll = true
            }
        }
    }

    private var composeBar: some View {
        VStack(spacing: 8) {
            if recorder.isRecording {
                HStack(spacing: 12) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text("Запись \(formatDuration(recorder.elapsed))")
                        .font(.subheadline.monospacedDigit())
                    Spacer()
                    Button("Отмена", role: .destructive) {
                        recorder.cancel()
                    }
                    Button("Отправить") {
                        Task { await stopAndSendVoice() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: isSendingPhoto ? "hourglass" : "photo")
                        .font(.title3)
                        .frame(width: 38, height: 38)
                }
                .disabled(isSendingPhoto || recorder.isRecording)
                .accessibilityLabel("Отправить фото")

                TextField("Сообщение", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(VOICETextFieldStyle())
                    .focused($isFocused)
                    .disabled(recorder.isRecording)

                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        Task { await toggleRecording() }
                    } label: {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                            .foregroundStyle(recorder.isRecording ? .red : .accentColor)
                    }
                    .accessibilityLabel(recorder.isRecording ? "Остановить запись" : "Записать голос")
                } else {
                    Button {
                        Task { await sendText() }
                    } label: {
                        Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .disabled(isSending)
                    .accessibilityLabel("Отправить сообщение")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(.bar)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let last = messages.last else { return }
        let action = { proxy.scrollTo(last.id, anchor: .bottom) }
        if animated {
            withAnimation(.snappy) { action() }
        } else {
            action()
        }
    }

    private func sendText() async {
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, !isSending else { return }
        isSending = true
        let sent = await store.sendText(draft, conversationID: conversation.id)
        if sent { text = "" }
        isSending = false
    }

    private func sendPhoto(_ item: PhotosPickerItem) async {
        guard !isSendingPhoto else { return }
        isSendingPhoto = true
        defer {
            isSendingPhoto = false
            photoItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let jpeg = image.voiceJPEGData() else {
                store.error = "Не удалось подготовить фото."
                return
            }
            _ = await store.sendPhoto(jpeg, conversationID: conversation.id)
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func toggleRecording() async {
        do {
            if recorder.isRecording {
                await stopAndSendVoice()
            } else {
                try await recorder.start()
            }
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func stopAndSendVoice() async {
        do {
            let result = try recorder.stop()
            _ = await store.sendVoice(fileURL: result.url, duration: result.duration, conversationID: conversation.id)
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
