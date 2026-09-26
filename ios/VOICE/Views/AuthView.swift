import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var store: AppStore
    @State private var mode: AuthMode = .login
    @State private var email = ""
    @State private var password = ""
    @State private var username = ""
    @State private var displayName = ""
    @State private var isWorking = false
    @State private var didRegister = false

    var body: some View {
        NavigationStack {
            ZStack {
                VoiceBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 8) {
                            Text("VOICE")
                                .font(.system(size: 46, weight: .black, design: .rounded))
                            Text(mode == .login ? "Вход в аккаунт" : "Создание аккаунта")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 34)
                        Picker("Режим", selection: $mode) {
                            ForEach(AuthMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(isWorking)
                        VStack(spacing: 14) {
                            TextField("Email", text: $email)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .textContentType(.emailAddress)
                                .textFieldStyle(VOICETextFieldStyle())
                            SecureField("Пароль, минимум 8 символов", text: $password)
                                .textContentType(mode == .login ? .password : .newPassword)
                                .textFieldStyle(VOICETextFieldStyle())
                            if mode == .register {
                                TextField("Username", text: $username)
                                    .textContentType(.username)
                                    .textFieldStyle(VOICETextFieldStyle())
                                TextField("Имя в профиле", text: $displayName)
                                    .textContentType(.name)
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled(false)
                                    .textFieldStyle(VOICETextFieldStyle())
                            }
                        }
                        .voiceCard()
                        .disabled(isWorking)
                        if didRegister {
                            Label("Проверьте email и подтвердите регистрацию. После подтверждения войдите с email и паролем.", systemImage: "envelope.badge")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .voiceCard(cornerRadius: 18)
                        }
                        Button { Task { await submit() } } label: {
                            if isWorking { ProgressView().tint(.white) }
                            else { Text(mode == .login ? "Войти" : "Зарегистрироваться") }
                        }
                        .buttonStyle(VOICEPrimaryButtonStyle())
                        .disabled(!canSubmit || isWorking)
                        .opacity(canSubmit ? 1 : 0.55)
                    }
                    .padding(20)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("VOICE")
        }
    }

    private var canSubmit: Bool {
        let emailReady = email.contains("@") && email.contains(".")
        let passwordReady = password.count >= 8
        switch mode {
        case .login: return emailReady && passwordReady
        case .register: return emailReady && passwordReady && !username.voiceTrimmed.isEmpty && !displayName.voiceTrimmed.isEmpty
        }
    }

    private func submit() async {
        guard canSubmit, !isWorking else { return }
        isWorking = true
        didRegister = false
        defer { isWorking = false }
        switch mode {
        case .login:
            await store.signIn(email: email.voiceTrimmed, password: password)
        case .register:
            await store.signUp(email: email.voiceTrimmed, password: password, username: username.voiceTrimmed, displayName: displayName.voiceTrimmed)
            if store.error == nil && store.session == nil { didRegister = true; mode = .login }
        }
        if store.error == nil { password = "" }
    }
}

private enum AuthMode: String, CaseIterable, Identifiable {
    case login, register
    var id: String { rawValue }
    var title: String { self == .login ? "Вход" : "Регистрация" }
}
