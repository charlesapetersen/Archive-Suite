import SwiftUI
import AppKit
import ArchiveCore

@main
struct ArchiveNotesApp: App {
    /// W7-S6 — owns the app-lifetime editor-flush registry + the `applicationShouldTerminate` hook that
    /// flushes every open editor's pending edit (bounded) before the process exits.
    @NSApplicationDelegateAdaptor(NotesAppDelegate.self) private var appDelegate
    /// The single UI façade + organization graph, shared by both windows (§16.1). Bootstraps its
    /// store lazily from each window's `.task`.
    @StateObject private var notesModel = NotesModel()
    @StateObject private var deepLinkRouter = NotesDeepLinkRouter()
    @StateObject private var previewState = SourceBlockPreviewState()
    // Point the client at the configured host/port (Options ▸ Zotero, advanced). Applied at
    // launch; the enabled/clipboard-detect gates are read at point of use in the status model.
    @StateObject private var zoteroStatus = ZoteroStatusModel(
        client: ZoteroClient(config: ZoteroSettingsStore.current.clientConfig))

    /// Demote the process when it is only acting as a unit-test host, so `xcodebuild test
    /// -only-testing:ArchiveNotesTests` never takes the owner's screen (→ `ArchiveTestHost`).
    init() { MainActor.assumeIsolated { ArchiveTestHost.suppressWindowsIfUnitTestHost() } }

    var body: some Scene {
        // Under a unit-test host both auto-opening windows render `HiddenWindowStub` instead of their
        // real content, so nothing reaches the owner's screen (→ `ArchiveTestHost`). The branch has to
        // live here in the `ViewBuilder` rather than around the scenes: `SceneBuilder` has no
        // `buildEither`, so a conditional at scene level doesn't compile.
        Window("Archive Notes", id: NotesWindowID.notes) {
            if ArchiveTestHost.isUnitTestHost {
                ArchiveTestHost.HiddenWindowStub()
            } else {
                NotesBrowserView(kind: .note, model: notesModel)
                    .environmentObject(notesModel)
                    .environmentObject(deepLinkRouter)
                    .environmentObject(previewState)
                    .environmentObject(zoteroStatus)
                    .environmentObject(appDelegate.flushRegistry)   // W7-S6
                    .onOpenURL { url in
                        NSApp.activate(ignoringOtherApps: true)
                        deepLinkRouter.handle(url)
                    }
            }
        }
        .commands {
            ReaderRootCommands(previewState: previewState)
            FormatCommands()
            SourceBlockCommands()
            ZoteroCommands()
            ExtractCommands()
            #if DEBUG
            DebugBlockCommands()
            #endif
        }
        Window("Extracts", id: NotesWindowID.extracts) {
            if ArchiveTestHost.isUnitTestHost {
                ArchiveTestHost.HiddenWindowStub()
            } else {
                NotesBrowserView(kind: .extract, model: notesModel)
                    .environmentObject(notesModel)
                    .environmentObject(previewState)
                    .environmentObject(zoteroStatus)
                    .environmentObject(appDelegate.flushRegistry)   // W7-S6
            }
        }
        Settings { NotesSettingsView() }
    }
}

/// App delegate hosting the W7-S6 terminate-flush. Owns the `EditorFlushRegistry` (app-lifetime, not a
/// SwiftUI `@StateObject`, so `applicationShouldTerminate` can reach it directly) which each open
/// `NoteEditorPane` registers its flush into. On quit, every pending editor edit is persisted first —
/// but under a bounded timeout, so a wedged store write can never deadlock quit.
@MainActor
final class NotesAppDelegate: NSObject, NSApplicationDelegate {
    /// Registered into both windows' environments by the App; flushed here on terminate.
    let flushRegistry = EditorFlushRegistry()

    /// Upper bound on how long quit waits for the flush. A note-body write is tiny (atomic local file),
    /// so the flush path essentially always wins this race; the bound only guards a pathological hang.
    static let terminateFlushTimeout: Duration = .seconds(2)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing editing → quit immediately. Otherwise flush every open editor's pending edit first, but
        // reply as soon as the flush finishes OR the bounded timeout elapses (never block quit forever).
        guard !flushRegistry.isEmpty else { return .terminateNow }
        let registry = flushRegistry
        TerminateFlushCoordinator {
            NSApp.reply(toApplicationShouldTerminate: true)
        }.begin(flush: { await registry.flushAll() }, timeout: Self.terminateFlushTimeout)
        return .terminateLater
    }
}

enum NotesWindowID {
    static let notes = "notes"
    static let extracts = "extracts"
}

/// Item kind the shell is scoped to (mirrors 00-overview §3.1 `kind`). Placeholder until W2 defines the store.
enum ItemKindShell: Sendable { case note, extract }
