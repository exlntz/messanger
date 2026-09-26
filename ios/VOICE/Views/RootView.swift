import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("appearance") private var appearance = VoiceAppearance.system.rawValue

    var body: some View {
        Group {
            if store.config == nil {
                ConfigurationView()
            } else if store.session == nil {
                AuthView()
            } else {
                MainView()
            }
        }
        .preferredColorScheme(currentAppearance.colorScheme)
        .fullScreenCover(isPresented: callPresentation) {
            CallView()
                .environmentObject(store)
        }
        .alert(alertTitle, isPresented: alertPresentation) {
            Button("ОК", role: .cancel) {
                dismissAlert()
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var currentAppearance: VoiceAppearance {
        VoiceAppearance(rawValue: appearance) ?? .system
    }

    private var alertTitle: String {
        store.error != nil ? "Ошибка" : "VOICE"
    }

    private var alertMessage: String {
        store.error ?? store.notice ?? "Неизвестное сообщение"
    }

    private var alertPresentation: Binding<Bool> {
        Binding(
            get: { store.error != nil || store.notice != nil },
            set: { isPresented in
                if !isPresented {
                    dismissAlert()
                }
            }
        )
    }

    private var callPresentation: Binding<Bool> {
        Binding(
            get: { store.activeCall != nil },
            set: { isPresented in
                guard !isPresented, store.activeCall != nil else { return }
                Task { await store.endCall() }
            }
        )
    }

    private func dismissAlert() {
        if store.error != nil {
            store.error = nil
        } else {
            store.notice = nil
        }
    }
}
