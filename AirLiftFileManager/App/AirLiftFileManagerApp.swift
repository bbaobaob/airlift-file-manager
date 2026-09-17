import SwiftUI

@main
struct AirLiftFileManagerApp: App {
    @StateObject private var appState: AppState

    init() {
        AppLogger.app.info("App launch")
        _appState = StateObject(wrappedValue: AppState())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .environmentObject(appState.activation)
        }
    }
}
