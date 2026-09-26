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
                    .task {
                        await store.refreshConversations()
                    }
            }
        }
        .preferredColorScheme(currentAppearance.colorScheme)
        .fullScreenCover(isPresented: callPresentation) {
            CallView()
                .environmentObject(store)
        }
        .alert("Ошибка", isPresented: errorPresentation) {
            Button("ОК", role: .cancel) {
                store.error = nil
            }
        } message: {
            Text(store.error ?? "Неизвестная ошибка")
        }
        .alert("VOICE", isPresented: noticePresentation) {
            Button("ОК", role: .cancel) {
                store.notice = nil
            }
        } message: {
            Text(store.notice ?? "")
        }
    }

    private var currentAppearance: VoiceAppearance {
        VoiceAppearance(rawValue: appearance) ?? .system
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { store.error != nil },
            set: { isPresented in
                if !isPresented { store.error = nil }
            }
        )
    }

    private var noticePresentation: Binding<Bool> {
        Binding(
            get: { store.notice != nil },
            set: { isPresented in
                if !isPresented { store.notice = nil }
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
}
