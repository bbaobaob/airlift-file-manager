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
                .environmentObject(appState.launchGuard)
                // Pairing files can arrive via the share sheet ("Copy to
                // AirLift File Manager") or Files "Open in…" — a path that
                // never touches the document picker. Import immediately.
                .onOpenURL { url in
                    AppLogger.app.info("Incoming file: \(url.lastPathComponent, privacy: .public)", event: "open")
                    Task {
                        await appState.launchGuard.importPairing(from: url)
                        await appState.launchGuard.recheckConnection()
                    }
                }
        }
    }
}
