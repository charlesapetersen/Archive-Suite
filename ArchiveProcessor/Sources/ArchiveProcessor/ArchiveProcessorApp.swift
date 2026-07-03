import SwiftUI

@main
struct ArchiveProcessorApp: App {
    init() {
        OCRProcessor.requestNotificationPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}
