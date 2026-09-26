import SwiftUI

struct MainView: View {
    @State private var path: [ConversationSummary] = []
    @State private var showsPeopleSearch = false

    var body: some View {
        NavigationStack(path: $path) {
            ChatListView(showsPeopleSearch: $showsPeopleSearch)
                .navigationDestination(for: ConversationSummary.self) { conversation in
                    ChatView(conversation: conversation)
                }
                .sheet(isPresented: $showsPeopleSearch) {
                    PeopleSearchSheet { conversation in
                        showsPeopleSearch = false
                        path.append(conversation)
                    }
                }
        }
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
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
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
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
        .refreshable {
            await store.refreshConversations()
        }
        .navigationTitle("VOICE")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsPeopleSearch = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Найти собеседника")
            }
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    SettingsView()
                } label: {
                    if let profile = store.profile {
                        AvatarView(path: profile.avatarPath, displayName: profile.displayName, size: 34)
                    } else {
                        Image(systemName: "person.crop.circle")
                            .font(.title3)
                    }
                }
                .accessibilityLabel("Профиль и настройки")
            }
        }
    }

    private var filteredConversations: [ConversationSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.conversations }
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
            .listRowSeparator(.hidden)
        }
    }
}

struct ConversationRow: View {
    let conversation: ConversationSummary

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(path: conversation.avatarPath, displayName: conversation.displayName, size: 54)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let time = conversation.lastMessageAt {
                        Text(time.voiceListTime)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    if conversation.lastKind == "photo" {
                        Image(systemName: "photo")
                            .accessibilityHidden(true)
                    } else if conversation.lastKind == "voice" {
                        Image(systemName: "waveform")
                            .accessibilityHidden(true)
                    }
                    Text(conversation.lastMessage ?? "@\(conversation.username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
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
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VOICEEmptyState(systemImage: "person.2", title: "Найдите человека", message: "Введите username или имя. Группы и каналы не поддерживаются.")
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if store.isLoading && store.searchResults.isEmpty {
                    ProgressView("Поиск")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                } else if store.searchResults.isEmpty {
                    VOICEEmptyState(systemImage: "person.crop.circle.badge.questionmark", title: "Нет результатов", message: "Проверьте запрос и попробуйте ещё раз.")
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
                        }
                        .disabled(isOpening != nil)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Username или имя")
            .onChange(of: query) { _, newValue in
                Task { await store.searchPeople(newValue) }
            }
            .navigationTitle("Новый чат")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private func open(_ profile: Profile) async {
        isOpening = profile.id
        if let conversation = await store.openConversation(with: profile) {
            onOpen(conversation)
        }
        isOpening = nil
    }
}
