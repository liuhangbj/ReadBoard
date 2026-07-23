import SwiftUI

@main
struct ReadBoardApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 780)
    }
}

struct RootView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label("阅读", systemImage: "doc.text") }
                .tag(0)
            SourcesView()
                .tabItem { Label("订阅源", systemImage: "dot.radiowaves.left.and.right") }
                .tag(1)
        }
    }
}
