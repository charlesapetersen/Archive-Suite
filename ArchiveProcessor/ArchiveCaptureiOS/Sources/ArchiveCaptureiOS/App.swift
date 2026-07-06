import SwiftUI

/// Archive Capture (iOS) — a capture companion for the Archive Processor Mac app. It photographs
/// documents and streams them to the Mac (which does OCR + tagging); it holds no API keys.
@main
struct ArchiveCaptureiOSApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
