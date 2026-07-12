import SwiftUI
import AppKit
import ArchiveCore

@main
struct ArchiveNotesApp: App {
    @StateObject private var deepLinkRouter = NotesDeepLinkRouter()

    var body: some Scene {
        Window("Archive Notes", id: NotesWindowID.notes) {
            NotesShellView(kind: .note)
                .environmentObject(deepLinkRouter)
                .onOpenURL { url in
                    NSApp.activate(ignoringOtherApps: true)
                    deepLinkRouter.handle(url)
                }
        }
        .commands {
            FormatCommands()
            SourceBlockCommands()
            #if DEBUG
            DebugBlockCommands()
            #endif
        }
        Window("Extracts", id: NotesWindowID.extracts) {
            NotesShellView(kind: .extract)
        }
        Settings { NotesSettingsView() }
    }
}

enum NotesWindowID {
    static let notes = "notes"
    static let extracts = "extracts"
}

/// Item kind the shell is scoped to (mirrors 00-overview §3.1 `kind`). Placeholder until W2 defines the store.
enum ItemKindShell: Sendable { case note, extract }
