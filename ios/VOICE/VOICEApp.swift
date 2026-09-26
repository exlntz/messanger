import SwiftUI

@main
struct VOICEApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .task { await store.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    store.setSceneActive(phase == .active)
                }
        }
    }
}
