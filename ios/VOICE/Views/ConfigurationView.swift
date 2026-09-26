import SwiftUI

struct ConfigurationView: View {
    @EnvironmentObject private var store: AppStore

    @State private var supabaseURL = ""
    @State private var publishableKey = ""
    @State private var livekitURL = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                VoiceBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        brandHeader

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Подключение сервера")
                                .font(.title2.bold())

                            Text("Введите адреса Supabase и LiveKit. Секреты здесь не нужны. Настройки можно сбросить позже в профиле.")
                                .font(.body)
                                .foregroundStyle(.secondary)

                            TextField("Supabase URL", text: $supabaseURL)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textFieldStyle(VOICETextFieldStyle())

                            SecureField("Publishable key", text: $publishableKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(VOICETextFieldStyle())

                            TextField("LiveKit URL", text: $livekitURL)
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textFieldStyle(VOICETextFieldStyle())
                        }
                        .voiceCard()

                        Button {
                            save()
                        } label: {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Сохранить")
                            }
                        }
                        .buttonStyle(VOICEPrimaryButtonStyle())
                        .disabled(!isValid || isSaving)
                        .opacity(isValid ? 1 : 0.55)
                    }
                    .padding(20)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("VOICE")
        }
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOICE")
                .font(.system(size: 44, weight: .black, design: .rounded))
            Text("Личный мессенджер для фото, голоса и звонков.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 28)
    }

    private var isValid: Bool {
        !supabaseURL.voiceTrimmed.isEmpty && !publishableKey.voiceTrimmed.isEmpty && !livekitURL.voiceTrimmed.isEmpty
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            try store.saveConfiguration(
                supabaseURL: supabaseURL.voiceTrimmed,
                publishableKey: publishableKey.voiceTrimmed,
                livekitURL: livekitURL.voiceTrimmed
            )
        } catch {
            store.error = error.localizedDescription
        }
        isSaving = false
    }
}
