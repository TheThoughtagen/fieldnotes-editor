import SwiftUI
import FieldnotesCore

@main
struct FieldnotesApplication: App {
    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}

private struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(AppIdentity.displayName)
                .font(.largeTitle)
            Text("Open a Markdown document to begin.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
