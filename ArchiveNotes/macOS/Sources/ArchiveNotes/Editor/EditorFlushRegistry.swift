import Foundation

/// An editor's unsaved body, named for an emergency copy.
struct EditorDraft: Equatable, Sendable {
    let itemID: UUID
    let title: String
    let markdown: String
}

/// App-level registry of "flush my pending edit" closures, one per live editor pane (W7-S6).
///
/// Each `NoteEditorPane`'s body controller (`NoteBodyEditorModel`) autosaves on a ~600 ms debounce and
/// flushes on selection-switch / pane-teardown (`.onDisappear`). But a hard ⌘Q / app terminate does NOT
/// reliably fire SwiftUI's `.onDisappear`, so an edit made within the debounce window can be lost on
/// force-quit. `NotesAppDelegate.applicationShouldTerminate` awaits `flushAll()` (under a bounded timeout
/// — never deadlock quit) so every open editor persists its last keystrokes before the process exits.
///
/// W40.fix-notes-failed-save-close: a flush can FAIL (the store refuses the content or recovery write).
/// A pane whose window closes with a failed flush is therefore NOT dropped: `paneClosed` keeps its handle
/// (and so its editor model) alive, writes a durable emergency copy through `vault`, and asks the user via
/// `presentCloseFailure`. Quit then retries it like any open pane and is refused while it still fails.
///
/// The model is a per-pane `@StateObject` and thus not reachable app-level; this registry is the hoisted
/// handle both windows' panes register into. `@MainActor` — panes register/deregister from
/// `onAppear`/`onDisappear` and the delegate calls `flushAll()` on the main thread; the stored closures
/// are the panes' main-actor flush seams.
@MainActor
final class EditorFlushRegistry: ObservableObject {
    private struct Handle {
        let flush: () async -> Bool
        let draft: () -> EditorDraft?
        /// Bumped on every register, so a slow close cannot remove a pane that has since reappeared.
        let generation: Int
    }

    /// Keyed by a stable per-pane id so re-renders don't duplicate entries and a disappear removes
    /// exactly the pane that vanished (never a sibling window's still-live pane).
    private var handles: [UUID: Handle] = [:]
    private var generation = 0
    /// The emergency copy last written for a pane and the text written into it. Removed once the draft
    /// finally saves — unless the user has since edited that file, which then is theirs to keep.
    private var copies: [UUID: (url: URL, markdown: String)] = [:]

    /// Closed panes whose draft is still unsaved (kept in memory, retried on quit).
    @Published private(set) var retainedPaneIDs: Set<UUID> = []

    /// Where emergency copies go. Nil (unit tests that don't exercise it) = no copy.
    var vault: UnsavedDraftVault?
    /// Shown when a closed window's draft could not be saved. Its answer drives the retry loop.
    var presentCloseFailure: (@MainActor (_ title: String, _ copy: URL?) async -> CloseFailureChoice)?

    init(vault: UnsavedDraftVault? = nil) {
        self.vault = vault
    }

    /// No pane has a live editor → the app can terminate immediately (nothing to persist).
    var isEmpty: Bool { handles.isEmpty }

    /// Register (or re-register — `onAppear` may fire more than once) a pane's flush closure. Idempotent
    /// for a given `id`: the same key is overwritten, never duplicated. `flush` returns false while the
    /// pane's draft is still unsaved; `draft` names that unsaved body for an emergency copy.
    func register(_ id: UUID, flush: @escaping () async -> Bool,
                  draft: @escaping () -> EditorDraft? = { nil }) {
        generation &+= 1
        handles[id] = Handle(flush: flush, draft: draft, generation: generation)
        retainedPaneIDs.remove(id)
    }

    /// Remove a pane's flush closure, so a closed window's now-dead editor isn't flushed on a later quit.
    /// Used by the template pane, whose refused body is held in `NotesModel` instead (memory only — quit
    /// does not yet see it: W40.fix-notes-failed-save-close-fu1). A note pane closes through `paneClosed`.
    func deregister(_ id: UUID) {
        handles[id] = nil
        retainedPaneIDs.remove(id)
        removeCopy(for: id)
    }

    /// A pane's window closed. Flush it; drop it only once its draft is saved. On failure keep it,
    /// write an emergency copy, and offer a retry until it saves or the user defers to quit.
    func paneClosed(_ id: UUID) async {
        guard let handle = handles[id] else { return }
        while true {
            if await handle.flush() {
                // A pane that reappeared during the flush registered anew; leave that live entry alone.
                if handles[id]?.generation == handle.generation { deregister(id) }
                return
            }
            guard handles[id]?.generation == handle.generation else { return }
            retainedPaneIDs.insert(id)
            let copy = writeCopy(for: id)
            guard let presentCloseFailure else { return }
            let title = handle.draft()?.title ?? "a note"
            guard await presentCloseFailure(title, copy) == .retry else { return }
        }
    }

    /// Await every registered pending flush; true only if every draft is saved afterwards. Snapshotted
    /// first so a flush that (indirectly) triggers a deregistration can't mutate the dictionary
    /// mid-iteration. Serial: the underlying `NoteStore` is an actor, so concurrent flushes would
    /// serialize on it anyway, and there are at most two windows (plus any retained closed panes).
    @discardableResult
    func flushAll() async -> Bool {
        var allSaved = true
        for (id, handle) in handles {
            if await handle.flush() {
                guard handles[id]?.generation == handle.generation else { continue }
                if retainedPaneIDs.contains(id) { deregister(id) } else { removeCopy(for: id) }
            } else {
                allSaved = false
            }
        }
        return allSaved
    }

    /// The unsaved drafts right now (after a failed `flushAll`).
    func unsavedDrafts() -> [EditorDraft] {
        handles.values.compactMap { $0.draft() }
    }

    /// Write an emergency copy of every pane's unsaved draft. Nil when a draft is left that no copy
    /// covers (no vault, or the vault's write failed too), so quitting now would lose it.
    func writeEmergencyCopies() -> [URL]? {
        var written: [URL] = []
        var covered = true
        for id in handles.keys where handles[id]?.draft() != nil {
            // Keep going after a failure: every draft that CAN be copied should be.
            if let url = writeCopy(for: id) { written.append(url) } else { covered = false }
        }
        return covered ? written : nil
    }

    /// A copy of the pane's current draft. The previous copy is reused if it already holds exactly
    /// this text, and otherwise replaced only after the newer one is safely written.
    private func writeCopy(for id: UUID) -> URL? {
        guard let vault, let draft = handles[id]?.draft() else { return nil }
        if let previous = copies[id], previous.markdown == draft.markdown,
           vault.holds(draft.markdown, at: previous.url) { return previous.url }
        guard let url = try? vault.write(draft) else { return nil }
        if let old = copies[id] { vault.remove(old.url, ifItHolds: old.markdown) }
        copies[id] = (url, draft.markdown)
        return url
    }

    private func removeCopy(for id: UUID) {
        if let old = copies.removeValue(forKey: id) { vault?.remove(old.url, ifItHolds: old.markdown) }
    }
}

/// The user's answer to a closed window's failed save.
enum CloseFailureChoice: Sendable { case retry, keep }

/// The user's answer to a failed save at quit.
enum QuitFailureChoice: Sendable { case retry, cancel, quit }

/// Durable emergency copies of drafts the note store refused, kept OUTSIDE the store (whose write just
/// failed), as plain markdown a user can open anywhere. The vault only ever deletes files it wrote.
struct UnsavedDraftVault: Sendable {
    let directory: URL

    /// `~/Library/Application Support/Archive Notes/Unsaved Drafts` (inside the sandbox container).
    static func standard() -> UnsavedDraftVault? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return UnsavedDraftVault(directory: support.appendingPathComponent("Archive Notes/Unsaved Drafts", isDirectory: true))
    }

    func write(_ draft: EditorDraft, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: now)
        let safe = String(draft.title.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 })
        let name = Self.truncated(safe.trimmingCharacters(in: .whitespaces), maxBytes: 120)
        let base = "\(name.isEmpty ? "Untitled" : name) — unsaved \(stamp) \(draft.itemID.uuidString.prefix(8))"
        var url = directory.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).md"); n += 1
        }
        try Data(draft.markdown.utf8).write(to: url, options: [.atomic])
        return url
    }

    func holds(_ markdown: String, at url: URL) -> Bool {
        (try? Data(contentsOf: url)) == Data(markdown.utf8)
    }

    /// Delete a copy this vault wrote, and only while it still holds exactly what was written: never a
    /// file outside its own directory, and never one the user has opened and changed since.
    func remove(_ url: URL, ifItHolds markdown: String) {
        guard url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              holds(markdown, at: url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Filenames are limited in BYTES (255), so a long CJK or emoji title is cut by its UTF-8 length,
    /// at a whole character.
    static func truncated(_ text: String, maxBytes: Int) -> String {
        var result = ""
        var bytes = 0
        for ch in text {
            let n = String(ch).utf8.count
            guard bytes + n <= maxBytes else { break }
            result.append(ch); bytes += n
        }
        return result
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()
}

/// Drives the `applicationShouldTerminate` reply for a bounded editor flush (W7-S6). Fires the injected
/// `reply` **exactly once**. A flush that finishes with every draft saved replies true at once. A flush
/// that fails, or does not finish within `timeout`, never lets quit drop a draft silently
/// (W40.fix-notes-failed-save-close): it writes emergency copies, then asks — retry, don't quit, or quit
/// — and replies with that answer. A wedged flush is not awaited before asking, so quit never deadlocks.
///
/// `reply` (`NSApp.reply(toApplicationShouldTerminate:)`), `writeCopies` and `prompt` are injected so the
/// flow is unit-testable without `NSApp` or an alert. `@MainActor` — the once-guards and reply run on the
/// main thread, so the racing tasks serialize on it (no data race on `fired`).
@MainActor
final class TerminateFlushCoordinator {
    private var fired = false
    private var attempt = 0
    private var settledAttempt = 0
    private let reply: @MainActor (Bool) -> Void
    private let writeCopies: @MainActor () -> [URL]?
    private let prompt: @MainActor (_ copies: [URL]?, _ timedOut: Bool) async -> QuitFailureChoice

    /// `writeCopies` returns nil when some draft has no copy; `prompt` then has to warn that quitting
    /// loses it. `timedOut` tells a save still in flight at the bound from one the store refused, so the
    /// alert does not blame the store for a slow write.
    init(reply: @escaping @MainActor (Bool) -> Void,
         writeCopies: @escaping @MainActor () -> [URL]? = { [] },
         prompt: @escaping @MainActor (_ copies: [URL]?, _ timedOut: Bool) async -> QuitFailureChoice = { _, _ in .cancel }) {
        self.reply = reply
        self.writeCopies = writeCopies
        self.prompt = prompt
    }

    /// Start the bounded flush. Two independent tasks race: one runs `flush`; one sleeps `timeout`.
    /// Whichever settles the attempt first wins and the loser is ignored, so a completed flush replies
    /// immediately (the normal case) while a stuck one is asked about after `timeout`. The tasks
    /// capture `self` strongly, keeping the coordinator alive until they finish.
    func begin(flush: @escaping () async -> Bool, timeout: Duration) {
        attempt &+= 1
        let current = attempt
        Task { @MainActor in
            let saved = await flush()
            await self.settle(current, saved: saved, timedOut: false, flush: flush, timeout: timeout)
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            await self.settle(current, saved: false, timedOut: true, flush: flush, timeout: timeout)
        }
    }

    private func settle(_ current: Int, saved: Bool, timedOut: Bool, flush: @escaping () async -> Bool, timeout: Duration) async {
        guard !fired, current == attempt, settledAttempt != current else { return }
        settledAttempt = current
        if saved { fire(true); return }
        switch await prompt(writeCopies(), timedOut) {
        case .retry: begin(flush: flush, timeout: timeout)
        case .cancel: fire(false)
        case .quit: fire(true)
        }
    }

    private func fire(_ terminate: Bool) {
        guard !fired else { return }
        fired = true
        reply(terminate)
    }
}
