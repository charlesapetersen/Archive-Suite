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
        client: ZoteroClient.appClient(config: ZoteroSettingsStore.current.clientConfig))

    /// Demote the process when it is only acting as a unit-test host, so `xcodebuild test
    /// -only-testing:ArchiveNotesTests` never takes the owner's screen (→ `ArchiveTestHost`).
    init() {
        MainActor.assumeIsolated {
            ArchiveTestHost.suppressWindowsIfUnitTestHost()
#if DEBUG
            let appearanceForced = UITestAppearance.applyIfRequested()   // the layout guard's light/dark passes (W40.e9)
            TransientRecorder.startIfRequested()  // the transient-state check (W40.e13)
            NotesAppearanceUITestDefaults.clearStoredChoiceIfUITest()
            // The layout-loop probe writes beside the harness store, which the harness restores before every
            // test and would otherwise wipe the dump of a test that crashed (W48.notes-stacked-layout).
            if let store = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !store.isEmpty {
                LayoutLoopProbe.outputDirectory = URL(fileURLWithPath: store, isDirectory: true).deletingLastPathComponent()
            }
#else
            let appearanceForced = false
#endif
            // The Appearance setting (W48.appearance-notes), before the first window; a UI test's forced mode wins.
            if !appearanceForced { AppAppearance.follow() }
        }
    }

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
                    // A link can arrive while this first window is still bootstrapping. Hold it until
                    // the complete item list is available, rather than mistaking its target for a
                    // deleted note in the empty pre-bootstrap list.
                    .onReceive(deepLinkRouter.$pendingOpen) { _ in
                        forwardPendingDeepLinkIfReady()
                    }
                    .onReceive(notesModel.$isIndexReady) { _ in
                        forwardPendingDeepLinkIfReady()
                    }
            }
        }
        .commands {
            ReaderRootCommands(previewState: previewState, notesModel: notesModel)
            FormatCommands()
            SourceBlockCommands()
            ZoteroCommands()
            ExtractCommands()
            LayoutCommands()
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

    /// Bridge the parsed external URL into the same open channel used by in-app passage jumps. The
    /// receiving `NoteEditorPane` selects the target, raises its feature window, and consumes the model
    /// request after it has armed an optional block scroll.
    private func forwardPendingDeepLinkIfReady() {
        deepLinkRouter.forwardPendingOpen(whenIndexReady: notesModel.isIndexReady) { request in
            notesModel.openItem(id: request.id, block: request.block)
        }
    }
}

/// App delegate hosting the W7-S6 terminate-flush. Owns the `EditorFlushRegistry` (app-lifetime, not a
/// SwiftUI `@StateObject`, so `applicationShouldTerminate` can reach it directly) which each open
/// `NoteEditorPane` registers its flush into. On quit, every pending editor edit is persisted first —
/// but under a bounded timeout, so a wedged store write can never deadlock quit. A save the store
/// refuses (or one still stuck at the bound) cancels quit behind an alert instead of dropping the draft
/// (W40.fix-notes-failed-save-close); the drafts are first copied into `UnsavedDraftVault`.
@MainActor
final class NotesAppDelegate: NSObject, NSApplicationDelegate {
    /// Registered into both windows' environments by the App; flushed here on terminate.
    let flushRegistry = EditorFlushRegistry(vault: NotesAppDelegate.draftVault())

    /// Upper bound on how long quit waits for the flush before asking. A note-body write is tiny
    /// (atomic local file), so the flush path essentially always wins this race; the bound only guards a
    /// pathological hang, and since passing it now stops quit with an alert, it leaves room for a save
    /// that also re-indexes a large store.
    static let terminateFlushTimeout: Duration = .seconds(5)

    /// True while the closed-window alert is modal. Its `runModal` runs inside a main-queue job, and a
    /// nested run loop started there does not drain the main queue, so a terminate arriving meanwhile
    /// (Dock Quit, logout) would start coordinator tasks that cannot run until the alert is dismissed.
    /// Cancelling the terminate instead keeps the user in the one dialog they are already answering.
    private var isAskingAfterFailedClose = false

    override init() {
        super.init()
        flushRegistry.presentCloseFailure = { [weak self] title, copy in
            self?.isAskingAfterFailedClose = true
            defer { self?.isAskingAfterFailedClose = false }
            return Self.askAfterFailedClose(title: title, copy: copy)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing editing → quit immediately. Otherwise flush every open editor's pending edit first, and
        // reply as soon as it succeeds; a failure or the bound asks the user instead of quitting.
        guard !isAskingAfterFailedClose else { return .terminateCancel }
        guard !flushRegistry.isEmpty else { return .terminateNow }
        let registry = flushRegistry
        var retriedSilently = false
        TerminateFlushCoordinator(
            reply: { NSApp.reply(toApplicationShouldTerminate: $0) },
            writeCopies: { registry.writeEmergencyCopies() },
            prompt: { copies, timedOut in
                let drafts = registry.unsavedDrafts()
                // A refusal that resolved meanwhile (a closed window's own Retry saved it while this
                // attempt's flush had already failed): nothing is unsaved, so one silent retry saves
                // nothing and quits. Once only — a flush that keeps failing with no draft is asked about.
                if drafts.isEmpty, !timedOut, !retriedSilently { retriedSilently = true; return .retry }
                return Self.askAfterFailedQuit(drafts: drafts, copies: copies, timedOut: timedOut)
            }
        ).begin(flush: { await registry.flushAll() }, timeout: Self.terminateFlushTimeout)
        return .terminateLater
    }

    /// The emergency-copy folder. A UITest store keeps its copies beside the scratch store, never in the
    /// owner's real Application Support.
    private static func draftVault() -> UnsavedDraftVault? {
#if DEBUG
        if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty {
            return UnsavedDraftVault(directory: URL(fileURLWithPath: p + " Unsaved Drafts", isDirectory: true))
        }
#endif
        return UnsavedDraftVault.standard()
    }

    private static func askAfterFailedQuit(drafts: [EditorDraft], copies: [URL]?, timedOut: Bool) -> QuitFailureChoice {
        let alert = NSAlert()
        if drafts.isEmpty {
            // The bound passed, but every editor's text is already saved or still being written.
            alert.messageText = "Archive Notes is still saving."
            alert.informativeText = "A save hasn't finished yet. Choose Retry to wait for it."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Don't Quit")
            alert.addButton(withTitle: "Quit")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .retry
            case .alertThirdButtonReturn: return .quit
            default: return .cancel
            }
        }
        alert.alertStyle = .critical
        let what = drafts.count == 1 ? "\u{201C}\(drafts[0].title)\u{201D}" : "\(drafts.count) notes"
        alert.messageText = timedOut ? "Archive Notes hasn't finished saving \(what)."
            : "Archive Notes couldn't save \(what)."
        let cause = timedOut ? "The save is taking longer than expected." : "The note store refused the write."
        if let copies, !copies.isEmpty {
            alert.informativeText = cause + " A copy of the unsaved text is in "
                + "\(copies[0].deletingLastPathComponent().path). Fix the problem and choose Retry, or keep "
                + "Archive Notes open."
        } else {
            alert.informativeText = cause + " A backup copy could not be written for every note "
                + "either. Quitting now loses unsaved text."
        }
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Don't Quit")
        let quit = alert.addButton(withTitle: copies == nil ? "Quit and Lose Changes" : "Quit")
        quit.hasDestructiveAction = copies == nil
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertThirdButtonReturn: return .quit
        default: return .cancel
        }
    }

    private static func askAfterFailedClose(title: String, copy: URL?) -> CloseFailureChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive Notes couldn't save \u{201C}\(title)\u{201D}."
        alert.informativeText = "Its editor closed, but the note store refused the write. The unsaved text "
            + "is kept and will be retried when you quit"
            + (copy.map { "; a copy is in \($0.deletingLastPathComponent().path)." } ?? ".")
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "OK")
        if copy != nil { alert.addButton(withTitle: "Show Copy in Finder") }
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .retry
        case .alertThirdButtonReturn:
            if let copy { NSWorkspace.shared.activateFileViewerSelecting([copy]) }
            return .keep
        default: return .keep
        }
    }
}

enum NotesWindowID {
    static let notes = "notes"
    static let extracts = "extracts"
}

/// Item kind the shell is scoped to (mirrors 00-overview §3.1 `kind`). Placeholder until W2 defines the store.
enum ItemKindShell: Sendable { case note, extract }
