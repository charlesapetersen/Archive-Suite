import SwiftUI
import ArchiveCore

@main
struct ArchiveNotesApp: App {
    var body: some Scene {
        Window("Archive Notes", id: "notes") {
            ContentView()
        }
        Settings {
            Text("Settings — coming soon.")
                .frame(width: 300, height: 100)
        }
    }
}

/// Minimal content view proving ArchiveCore links. Replaced by the 3-pane shell in W1-S2.
private struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Archive Notes")
                .font(.largeTitle)
            Text("Suite marker: \(ArchiveSuiteMarker.tagName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}
