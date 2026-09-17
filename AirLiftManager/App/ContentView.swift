import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ActivationView()
                .tabItem { Label("AirLift", systemImage: "bolt.horizontal.circle") }
            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
        }
    }
}

#Preview {
    ContentView()
}
