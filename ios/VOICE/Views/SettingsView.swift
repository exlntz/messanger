import SwiftUI
import PhotosUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance = VoiceAppearance.system.rawValue

    @State private var displayName = ""
    @State private var username = ""
    @State private var avatarItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var avatarPreview: UIImage?
    @State private var isSaving = false
    @State private var showsResetConfirmation = false

    var body: some View {
        List {
            profileSection
            appearanceSection
            accountSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(VoiceBackground())
        .navigationTitle("Профиль")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadProfile()
        }
        .onChange(of: store.profile) { _, _ in
            loadProfile()
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await loadAvatar(item) }
        }
        .confirmationDialog("Сбросить сервер?", isPresented: $showsResetConfirmation, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) {
                Task { await store.resetConfiguration() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("После сброса нужно снова ввести Supabase и LiveKit.")
        }
    }

    private var profileSection: some View {
        Section {
            VStack(spacing: 16) {
                PhotosPicker(selection: $avatarItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        if let avatarPreview {
                            Image(uiImage: avatarPreview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())
                        } else {
                            AvatarView(path: store.profile?.avatarPath, displayName: displayName, size: 96)
                        }

                        Image(systemName: "camera.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.accentColor, in: Circle())
                    }
                }
                .accessibilityLabel("Изменить аватар")

                VStack(spacing: 12) {
                    TextField("Имя", text: $displayName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                        .textFieldStyle(VOICETextFieldStyle())

                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textFieldStyle(VOICETextFieldStyle())
                }

                Button {
                    Task { await saveProfile() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Сохранить профиль")
                    }
                }
                .buttonStyle(VOICEPrimaryButtonStyle())
                .disabled(isSaving || displayName.voiceTrimmed.isEmpty || username.voiceTrimmed.isEmpty)
                .opacity(displayName.voiceTrimmed.isEmpty || username.voiceTrimmed.isEmpty ? 0.55 : 1)
            }
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        } header: {
            Text("Аккаунт")
        } footer: {
            if let email = store.session?.user.email {
                Text(email)
            }
        }
    }

    private var appearanceSection: some View {
        Section("Оформление") {
            Picker("Тема", selection: $appearance) {
                ForEach(VoiceAppearance.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .listRowBackground(Color.clear)
        }
    }

    private var accountSection: some View {
        Section("Действия") {
            Button("Выйти") {
                Task { await store.signOut() }
            }
            .listRowBackground(Color.clear)

            Button("Сбросить сервер", role: .destructive) {
                showsResetConfirmation = true
            }
            .listRowBackground(Color.clear)
        }
    }

    private func loadProfile() {
        guard let profile = store.profile else { return }
        displayName = profile.displayName
        username = profile.username
    }

    private func loadAvatar(_ item: PhotosPickerItem) async {
        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data),
                let jpeg = image.voiceJPEGData(maxDimension: 900, compression: 0.84)
            else {
                store.error = "Не удалось подготовить аватар."
                return
            }

            avatarData = jpeg
            avatarPreview = UIImage(data: jpeg)
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func saveProfile() async {
        guard !isSaving else { return }
        isSaving = true
        let saved = await store.updateProfile(
            displayName: displayName.voiceTrimmed,
            username: username.voiceTrimmed,
            avatarData: avatarData
        )
        if saved {
            avatarData = nil
            avatarItem = nil
        }
        isSaving = false
    }
}
