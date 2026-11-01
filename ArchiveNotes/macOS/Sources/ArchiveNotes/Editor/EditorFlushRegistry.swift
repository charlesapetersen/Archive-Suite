import Foundation
import CryptoKit

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
        /// A note pane's editor (nil for a template body): a closed pane's draft can be handed to a pane
        /// that opens the same note, and dropped once its note is trashed.
        let editor: NoteBodyEditorModel?
        let noteWasTrashed: (UUID) -> Bool
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

    /// Closed panes whose draft is still unsaved (kept in memory, retried on quit). A plain property:
    /// nothing observes it, and a published change here would re-render every pane in both windows.
    private(set) var retainedPaneIDs: Set<UUID> = []

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
    /// A note pane also passes its `editor` and how to tell its note was trashed in the app.
    func register(_ id: UUID, flush: @escaping () async -> Bool,
                  draft: @escaping () -> EditorDraft? = { nil },
                  editor: NoteBodyEditorModel? = nil,
                  noteWasTrashed: @escaping (UUID) -> Bool = { _ in false }) {
        generation &+= 1
        handles[id] = Handle(flush: flush, draft: draft, editor: editor, noteWasTrashed: noteWasTrashed,
                             generation: generation)
        retainedPaneIDs.remove(id)
    }

    func heldDraftSource(for itemID: UUID) -> NoteBodyEditorModel? {
        retainedPaneIDs.lazy.compactMap { self.handles[$0]?.editor }
            .first { $0.unsavedDraft?.id == itemID }
    }

    /// W40.fix-notes-held-draft-reopen: `pane` is opening note `itemID`. A closed pane still holding an
    /// unsaved draft of it hands that draft over: the closed pane is dropped and its emergency copy moves
    /// with the draft, so the note's editor shows the text the user last typed rather than the saved body.
    func takeHeldDraft(for itemID: UUID, into pane: UUID) -> NoteBodyEditorModel.HeldDraft? {
        guard handles[pane] != nil,
              let closed = retainedPaneIDs.first(where: { handles[$0]?.editor?.unsavedDraft?.id == itemID }),
              let editor = handles[closed]?.editor, let held = editor.heldDraft else { return nil }
        editor.retire()
        handles[closed] = nil
        retainedPaneIDs.remove(closed)
        if let copy = copies.removeValue(forKey: closed) {
            if let old = copies.updateValue(copy, forKey: pane) { vault?.remove(old.url, ifItHolds: old.markdown) }
        }
        return held
    }

    /// A failed flush whose note was trashed in the app meanwhile: the store can never take the draft, so
    /// once its emergency copy is on disk that copy is its home (it stands, as a deleted template's
    /// does) and the draft is dropped, rather than failing every quit until Quit is chosen.
    private func releaseTrashedDraft(_ id: UUID) -> Bool {
        guard let handle = handles[id], let editor = handle.editor, let draft = editor.unsavedDraft,
              handle.noteWasTrashed(draft.id), writeCopy(for: id) != nil else { return false }
        copies[id] = nil
        editor.retire()
        return true
    }

    /// Remove a pane's flush closure, so a closed window's now-dead editor isn't flushed on a later quit.
    /// Used by the template pane, whose buffer holds nothing unique once flushed: a refused body is held
    /// in `NotesModel` and tracked here under the template's own id (`trackTemplateBody`). A note pane
    /// closes through `paneClosed`.
    func deregister(_ id: UUID) {
        handles[id] = nil
        retainedPaneIDs.remove(id)
        removeCopy(for: id)
    }

    /// A pane's window closed. Flush it; drop it only once its draft is saved. On failure keep it,
    /// write an emergency copy, and offer a retry until it saves or the user defers to quit.
    func paneClosed(_ id: UUID) async {
        guard let handle = handles[id] else { return }
        // Make the closing editor discoverable before its first save suspends, not only after a
        // refusal. A new pane opening meanwhile must wait for this save's outcome too.
        retainedPaneIDs.insert(id)
        while true {
            let saved = await handle.flush()
            guard handles[id]?.generation == handle.generation else { return }
            if saved || releaseTrashedDraft(id) {
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

    /// Await every registered pending flush; true only if every draft is saved afterwards. Each handle is
    /// looked up afresh, so a flush that (indirectly) deregisters another can't break the iteration, and
    /// one that registers a new entry gets it flushed in the same pass: a template save refused for the
    /// first time inside this flush registers its body here, and quit must see that refusal
    /// (W40.fix-notes-failed-save-close-fu1). Serial: the underlying `NoteStore` is an actor, so
    /// concurrent flushes would serialize on it anyway, and there are at most two windows (plus any
    /// retained closed panes and held template bodies).
    @discardableResult
    func flushAll() async -> Bool {
        var allSaved = true
        var visited: Set<UUID> = []
        while case let (id, handle)? = handles.first(where: { !visited.contains($0.key) }) {
            visited.insert(id)
            let saved = await handle.flush()
            if saved || (handles[id]?.generation == handle.generation && releaseTrashedDraft(id)) {
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

    /// A live pane's autosave was refused: copy its draft NOW, so a crash or force-kill before the window
    /// closes or the app quits still leaves the text on disk (the copy is otherwise written only then).
    /// Reuses the previous copy while the text is unchanged, so steady typing against a refusing store
    /// rewrites one file rather than piling up copies.
    @discardableResult
    func copyDraft(for id: UUID) -> URL? { writeCopy(for: id) }

    /// A live pane's save landed: its emergency copy is no longer needed (kept if the user edited it).
    func discardCopy(for id: UUID) { removeCopy(for: id) }

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

    /// Once per launch, after the notes are loaded: delete each emergency copy a past session left whose
    /// note's saved body now holds exactly its text. That is the slow-save path — quit chosen while a save
    /// was still with the store, which then landed after the app stopped waiting — or a crash after a late
    /// save. Every other copy stands (templates', trashed notes', unsaved text), and so does one written
    /// this session.
    func sweepSavedCopies(noteIDs: [UUID], loadBody: (UUID) async -> String?) async {
        guard !didSweep, let vault else { return }
        didSweep = true
        let notes = Set(noteIDs)
        for copy in vault.copies() where notes.contains(copy.itemID) {
            guard !copies.values.contains(where: { $0.url == copy.url }),
                  let body = await loadBody(copy.itemID), body == copy.markdown,
                  !copies.values.contains(where: { $0.url == copy.url }) else { continue }
            vault.remove(copy.url, ifItHolds: copy.markdown)
        }
    }

    private var didSweep = false

    private func removeCopy(for id: UUID) {
        if let old = copies.removeValue(forKey: id) { vault?.remove(old.url, ifItHolds: old.markdown) }
    }

    /// W40.fix-notes-failed-save-close-fu1: a template save finished. The template editor marks its buffer
    /// clean even when the store refuses the body, because `NotesModel` keeps the refused body (so switching
    /// templates still works and returning reloads it). That body is registered here under the TEMPLATE's
    /// id, independent of any pane: quit retries it and is refused while it fails, exactly as for a note
    /// pane, and it is copied to the vault at once so a crash loses nothing. Keyed by template rather than
    /// pane, so the model's single draft per template is the only body ever retried, and a closed window
    /// can never write an older buffer over a newer save from another window.
    func trackTemplateBody(_ id: UUID, in model: NotesModel) {
        guard model.unsavedTemplateBody(id) != nil else {
            if model.templateWasDeleted(id) { copies[id] = nil }   // its copy stands (see the flush below)
            deregister(id)
            return
        }
        if handles[id] == nil {
            register(id, flush: { [weak self, weak model] in
                let saved = await model?.retryTemplateBody(id) ?? true
                // A template trashed with its body still refused: the trash holds only the old body, so
                // the emergency copy is the refused text's last home and stands, as a trashed note's does.
                if model?.templateWasDeleted(id) == true { self?.copies[id] = nil }
                return saved
            }, draft: { [weak model] in model?.unsavedTemplateBody(id) })
        }
        // No live editor stands behind this entry, so it is always dropped once its body saves.
        retainedPaneIDs.insert(id)
        copyDraft(for: id)
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

    /// `~/Library/Application Support/ArchiveNotes/Unsaved Drafts` (inside the sandbox container) — the
    /// same `ArchiveNotes` folder the index, Zotero cache and root-folder bookmarks already use.
    static func standard() -> UnsavedDraftVault? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return UnsavedDraftVault(directory: support.appendingPathComponent("ArchiveNotes/Unsaved Drafts", isDirectory: true))
    }

    func write(_ draft: EditorDraft, now: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: now)
        let safe = String(draft.title.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 })
        var name = Self.truncated(safe.trimmingCharacters(in: .whitespaces), maxBytes: 120)
        if name.hasPrefix(".") { name = "-" + name.dropFirst() }   // never a hidden copy
        let base = "\(name.isEmpty ? "Untitled" : name) — unsaved \(stamp) \(draft.itemID.uuidString.prefix(8))"
        var url = directory.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).md"); n += 1
        }
        try Data(draft.markdown.utf8).write(to: url, options: [.atomic])
        // A receipt proves full item identity and the original bytes after relaunch. Without it the
        // plain copy remains recoverable, but is never swept just because its filename looks like ours.
        let receipt = Receipt(itemID: draft.itemID, digest: Self.digest(draft.markdown))
        if let data = try? JSONEncoder().encode(receipt) {
            try? data.write(to: receiptURL(url), options: [.atomic])
        }
        return url
    }

    private struct Receipt: Codable {
        let itemID: UUID
        let digest: String
    }

    private func receiptURL(_ url: URL) -> URL { url.appendingPathExtension("receipt.json") }
    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Only copies whose receipt still proves their full item ID and original contents. A user edit,
    /// an old copy without a receipt, or a filename that only looks like a copy is never swept.
    func copies() -> [(url: URL, itemID: UUID, markdown: String)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url in
            guard url.pathExtension == "md",
                  let data = try? Data(contentsOf: receiptURL(url)),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  receipt.digest == Self.digest(text) else { return nil }
            return (url, receipt.itemID, text)
        }
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
        if !FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: receiptURL(url)),
           let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
           receipt.digest == Self.digest(markdown) {
            try? FileManager.default.removeItem(at: receiptURL(url))
        }
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
