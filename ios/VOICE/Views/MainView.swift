import SwiftUI

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTab: MainTab = .chats
    @State private var chatPath: [ConversationSummary] = []
    @State private var showsPeopleSearch = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VoiceBackground()

            ZStack {
                chatsStack
                callsStack
                settingsStack
            }
        }
        .sheet(isPresented: $showsPeopleSearch) {
            PeopleSearchSheet { conversation in
                openConversation(conversation)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MainTabBar(selectedTab: selectedTab) { tab in
                select(tab)
            }
        }
        .task {
            await store.refreshConversations()
            await store.refreshCallHistory()
        }
    }

    private var chatsStack: some View {
        NavigationStack(path: $chatPath) {
            ChatListView(showsPeopleSearch: $showsPeopleSearch)
                .navigationDestination(for: ConversationSummary.self) { conversation in
                    ChatView(conversation: conversation)
                }
        }
        .opacity(selectedTab == .chats ? 1 : 0)
        .allowsHitTesting(selectedTab == .chats)
        .accessibilityHidden(selectedTab != .chats)
    }

    private var callsStack: some View {
        NavigationStack {
            RecentCallsView { conversation in
                openConversation(conversation)
            }
        }
        .opacity(selectedTab == .calls ? 1 : 0)
        .allowsHitTesting(selectedTab == .calls)
        .accessibilityHidden(selectedTab != .calls)
    }

    private var settingsStack: some View {
        NavigationStack {
            SettingsView()
        }
        .opacity(selectedTab == .settings ? 1 : 0)
        .allowsHitTesting(selectedTab == .settings)
        .accessibilityHidden(selectedTab != .settings)
    }

    private func select(_ tab: MainTab) {
        if reduceMotion {
            selectedTab = tab
        } else {
            withAnimation(.snappy(duration: 0.24)) {
                selectedTab = tab
            }
        }
    }

    private func openConversation(_ conversation: ConversationSummary) {
        showsPeopleSearch = false
        select(.chats)
        if chatPath.last?.id != conversation.id {
            chatPath.append(conversation)
        }
    }
}

private enum MainTab: String, CaseIterable, Identifiable {
    case chats
    case calls
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats:
            "Чаты"
        case .calls:
            "Звонки"
        case .settings:
            "Настройки"
        }
    }

    var systemImage: String {
        switch self {
        case .chats:
            "bubble.left.and.bubble.right.fill"
        case .calls:
            "phone.fill"
        case .settings:
            "gearshape.fill"
        }
    }
}

private struct MainTabBar: View {
    let selectedTab: MainTab
    let onSelect: (MainTab) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MainTab.allCases) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.systemImage)
                            .font(.headline)
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? .white : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background {
                        if selectedTab == tab {
                            VOICEGradient()
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
        }
        .padding(8)
        .voiceGlass(cornerRadius: 30)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

struct ChatListView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showsPeopleSearch: Bool

    @State private var searchText = ""

    var body: some View {
        List {
            if store.isLoading && store.conversations.isEmpty {
                loadingRows
            } else if let error = store.error, store.conversations.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .voiceRowCard(cornerRadius: 24)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if filteredConversations.isEmpty {
                VOICEEmptyState(
                    systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    title: searchText.isEmpty ? "Пока нет чатов" : "Ничего не найдено",
                    message: searchText.isEmpty ? "Найдите человека по username или имени и начните диалог." : "Измените текст поиска."
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredConversations) { conversation in
                    NavigationLink(value: conversation) {
                        ConversationRow(conversation: conversation)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
        .refreshable {
            await store.refreshConversations()
        }
        .navigationTitle("Чаты")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsPeopleSearch = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Найти собеседника")
            }
        }
    }

    private var filteredConversations: [ConversationSummary] {
        let query = searchText.voiceTrimmed.lowercased()
        guard !query.isEmpty else {
            return store.conversations
        }

        return store.conversations.filter { conversation in
            conversation.displayName.lowercased().contains(query) ||
            conversation.username.lowercased().contains(query) ||
            (conversation.lastMessage ?? "").lowercased().contains(query)
        }
    }

    private var loadingRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: 12) {
                Circle()
                    .fill(.secondary.opacity(0.18))
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.secondary.opacity(0.18))
                        .frame(width: 160, height: 14)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(.secondary.opacity(0.12))
                        .frame(width: 220, height: 12)
                }
            }
            .redacted(reason: .placeholder)
            .voiceRowCard(cornerRadius: 26)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

struct ConversationRow: View {
    let conversation: ConversationSummary

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(path: conversation.avatarPath, displayName: conversation.displayName, size: 54)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(conversation.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if let time = conversation.lastMessageAt {
                        Text(time.voiceListTime)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    if let systemImage = lastKindImage {
                        Image(systemName: systemImage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .voiceRowCard(cornerRadius: 26)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var normalizedLastKind: String {
        conversation.lastKind?.lowercased() ?? ""
    }

    private var lastKindImage: String? {
        switch normalizedLastKind {
        case "image", "photo":
            "photo"
        case "voice":
            "waveform"
        default:
            nil
        }
    }

    private var subtitle: String {
        let lastMessage = conversation.lastMessage?.voiceTrimmed ?? ""
        if !lastMessage.isEmpty {
            return lastMessage
        }

        switch normalizedLastKind {
        case "image", "photo":
            return "Фото"
        case "voice":
            return "Голосовое сообщение"
        default:
            return "@\(conversation.username)"
        }
    }
}

struct PeopleSearchSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    let onOpen: (ConversationSummary) -> Void

    @State private var query = ""
    @State private var isOpening: UUID?

    var body: some View {
        NavigationStack {
            List {
                if query.voiceTrimmed.isEmpty {
                    VOICEEmptyState(
                        systemImage: "person.2",
                        title: "Найдите человека",
                        message: "Введите username или имя. Группы и каналы не поддерживаются."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if store.isLoading && store.searchResults.isEmpty {
                    ProgressView("Поиск")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if store.searchResults.isEmpty {
                    VOICEEmptyState(
                        systemImage: "person.crop.circle.badge.questionmark",
                        title: "Нет результатов",
                        message: "Проверьте запрос и попробуйте ещё раз."
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.searchResults) { profile in
                        Button {
                            Task { await open(profile) }
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(path: profile.avatarPath, displayName: profile.displayName, size: 48)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Text("@\(profile.username)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if isOpening == profile.id {
                                    ProgressView()
                                }
                            }
                            .voiceRowCard(cornerRadius: 24)
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpening != nil)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(VoiceBackground())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Username или имя")
            .task(id: query) {
                let trimmed = query.voiceTrimmed
                guard !trimmed.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await store.searchPeople(trimmed)
            }
            .navigationTitle("Новый чат")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func open(_ profile: Profile) async {
        isOpening = profile.id
        if let conversation = await store.openConversation(with: profile) {
            onOpen(conversation)
            dismiss()
        }
        isOpening = nil
    }
}

struct RecentCallsView: View {
    @EnvironmentObject private var store: AppStore

    let onOpenConversation: (ConversationSummary) -> Void

    var body: some View {
        List {
            if store.isLoading && store.callHistory.isEmpty {
                loadingRows
            } else if store.callHistory.isEmpty {
                VOICEEmptyState(
                    systemImage: "phone.arrow.up.right",
                    title: "Пока нет звонков",
                    message: "История появится после первого реального звонка."
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(store.callHistory, id: \.id) { record in
                    RecentCallRow(
                        record: record,
                        conversation: store.conversations.first { $0.id == record.conversationID },
                        currentUserID: store.session?.user.id,
                        onOpenConversation: { conversation in
                            onOpenConversation(conversation)
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.refreshCallHistory()
        }
        .navigationTitle("Звонки")
        .task {
            if store.callHistory.isEmpty {
                await store.refreshCallHistory()
            }
        }
    }

    private var loadingRows: some View {
        ForEach(0..<5, id: \.self) { _ in
            HStack(spacing: 12) {
                Circle()
                    .fill(.secondary.opacity(0.18))
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.secondary.opacity(0.18))
                        .frame(width: 140, height: 14)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(.secondary.opacity(0.12))
                        .frame(width: 200, height: 12)
                }
            }
            .redacted(reason: .placeholder)
            .voiceRowCard(cornerRadius: 26)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
    }
}

private struct RecentCallRow: View {
    let record: CallRecord
    let conversation: ConversationSummary?
    let currentUserID: UUID?
    let onOpenConversation: (ConversationSummary) -> Void

    var body: some View {
        Group {
            if let conversation {
                Button {
                    onOpenConversation(conversation)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            if let conversation {
                AvatarView(path: conversation.avatarPath, displayName: conversation.displayName, size: 54)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.14))
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "phone.fill")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(callTimestamp)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Image(systemName: directionImage)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)

                    Text(statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if conversation != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .voiceRowCard(cornerRadius: 26)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var title: String {
        conversation?.displayName ?? "Неизвестный контакт"
    }

    private var directionImage: String {
        isOutgoing ? "arrow.up.right.circle.fill" : "arrow.down.left.circle.fill"
    }

    private var statusColor: Color {
        switch record.status.lowercased() {
        case "missed", "declined", "rejected", "canceled", "cancelled":
            .red
        default:
            .secondary
        }
    }

    private var statusLine: String {
        var parts = [localizedStatus]
        if let durationText {
            parts.append(durationText)
        }
        return parts.joined(separator: " • ")
    }

    private var localizedStatus: String {
        switch record.status.lowercased() {
        case "ringing":
            isOutgoing ? "Исходящий вызов" : "Входящий вызов"
        case "connected", "active":
            "Идёт разговор"
        case "ended", "completed":
            isOutgoing ? "Исходящий звонок" : "Входящий звонок"
        case "missed":
            "Пропущенный звонок"
        case "declined", "rejected":
            "Отклонён"
        case "canceled", "cancelled":
            "Отменён"
        default:
            record.status
        }
    }

    private var callTimestamp: String {
        let endedAtText = record.endedAt ?? ""
        let source = endedAtText.voiceTrimmed.isEmpty ? record.createdAt : endedAtText
        return source.voiceListTime
    }

    private var durationText: String? {
        guard
            let endedAtText = record.endedAt,
            let startedAt = record.createdAt.voiceDate,
            let endedAt = endedAtText.voiceDate,
            endedAt > startedAt
        else {
            return nil
        }

        let duration = endedAt.timeIntervalSince(startedAt)
        guard duration >= 1 else {
            return nil
        }

        let seconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var isOutgoing: Bool {
        guard let currentUserID else { return false }
        return record.callerID == currentUserID
    }
}
