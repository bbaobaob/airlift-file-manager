import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var activation: ActivationManager
    @State private var startupCheckDone = false

    var body: some View {
        Group {
            if iOS27Gate.isSupported {
                tabs
            } else {
                unsupportedView
            }
        }
    }

    private var tabs: some View {
        TabView {
            AirLiftView()
                .tabItem {
                    Label("AirLift", systemImage: "airplane.departure")
                }
            FilesView(service: appState.fileSystem,
                      operations: appState.operations)
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

    private var unsupportedView: some View {
        ContentUnavailableView {
            Label("Requires iOS 27", systemImage: "exclamationmark.iphone")
        } description: {
            Text("AirLift File Manager supports iOS 27 developer beta 1 through iOS 27 final only. This device is running iOS \(iOS27Gate.currentVersionString).")
        }
    }
}

enum iOS27Gate {
    /// The app intentionally supports iOS 27.x only (beta 1 → final).
    static var isSupported: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    static var currentVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}

#Preview {
    RootTabView()
}
