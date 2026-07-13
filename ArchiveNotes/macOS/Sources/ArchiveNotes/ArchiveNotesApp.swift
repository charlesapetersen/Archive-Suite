import SwiftUI
import AppKit
import ArchiveCore

@main
struct ArchiveNotesApp: App {
    /// The single UI façade + organization graph, shared by both windows (§16.1). Bootstraps its
    /// store lazily from each window's `.task`.
    @StateObject private var notesModel = NotesModel()
    @StateObject private var deepLinkRouter = NotesDeepLinkRouter()
    @StateObject private var previewState = SourceBlockPreviewState()
    // Point the client at the configured host/port (Options ▸ Zotero, advanced). Applied at
    // launch; the enabled/clipboard-detect gates are read at point of use in the status model.
    @StateObject private var zoteroStatus = ZoteroStatusModel(
        client: ZoteroClient(config: ZoteroSettingsStore.current.clientConfig))

    var body: some Scene {
        Window("Archive Notes", id: NotesWindowID.notes) {
            NotesBrowserView(kind: .note, model: notesModel)
                .environmentObject(notesModel)
                .environmentObject(deepLinkRouter)
                .environmentObject(previewState)
                .environmentObject(zoteroStatus)
                .onOpenURL { url in
                    NSApp.activate(ignoringOtherApps: true)
                    deepLinkRouter.handle(url)
                }
        }
        .commands {
            FormatCommands()
            SourceBlockCommands()
            ZoteroCommands()
            #if DEBUG
            DebugBlockCommands()
            #endif
        }
        Window("Extracts", id: NotesWindowID.extracts) {
            NotesBrowserView(kind: .extract, model: notesModel)
                .environmentObject(notesModel)
                .environmentObject(previewState)
                .environmentObject(zoteroStatus)
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
