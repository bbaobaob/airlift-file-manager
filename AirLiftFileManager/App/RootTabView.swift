import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var activation: ActivationManager
    @State private var startupCheckDone = false

    var body: some View {
        TabView {
            AirLiftView()
                .tabItem {
                    Label("AirLift", systemImage: "airplane.departure")
                }
            FilesView(service: appState.fileSystem,
                      operations: appState.operations,
                      permission: appState.permission)
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
        }
        .task {
            guard !startupCheckDone else { return }
            startupCheckDone = true
            await appState.performStartupVerification()
        }
    }
}

#Preview {
    RootTabView()
}
