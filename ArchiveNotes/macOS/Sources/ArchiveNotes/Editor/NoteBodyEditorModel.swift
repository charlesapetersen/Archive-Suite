import Foundation
import Combine

/// Owns the detail-pane editor's body text for **one selected item at a time** and drives the
/// autosave save-back safely across selection switches (W7-S1a — the editor↔item wiring that W7
/// Extracts depends on: Create-Extract/Append/copy all need a real `sourceNoteId`, i.e. the editor
/// must actually be bound to the selected `Item`).
///
/// The two hazards this class exists to prevent (Tier-2 — a note-body write path; the data is Notes'
/// own store, never the archival corpus, but a lost/mis-targeted note edit is still data loss):
///
///  1. **Cross-item clobber (the classic autosave race).** The user edits note A, then quickly selects
///     note B before the debounce fires. A pending write MUST land on A, never on B, and B's freshly
///     loaded body must not be overwritten by A's edit. Guaranteed by capturing `loadedID` *at schedule
///     time* into the save task and by flushing the outgoing item's pending edit **before** loading the
///     incoming one.
///  2. **Superseded load.** Two selection switches race (A then B) while a slow load is in flight; only
///     the newest load may win. Guaranteed by a monotonic `loadGeneration` checked after each `await`.
///
/// Everything is `@MainActor` (it mirrors `@Published` UI state and the injected `NotesModel` calls are
/// main-actor-isolated). The `load`/`save`/`flushEditor` seams are injected so the safety core unit-tests
/// with no `NoteStore` and no live `NSTextView` (GUI is paused this run).
@MainActor
final class NoteBodyEditorModel: ObservableObject {

    /// The editor-facing body markdown (full body: leading prose + serialized block headers). Bound to
    /// `MarkdownEditorView`. A programmatic load assignment is bracketed by `suppressAutosave`; every
    /// other change is a user edit → mark dirty + (re)schedule the debounced save for the loaded item.
    @Published var markdown: String = "" {
        didSet {
            guard !suppressAutosave, markdown != oldValue, loadedID != nil else { return }
            dirty = true
            scheduleSave()
        }
    }

    /// The item whose body is currently in the editor (nil = nothing loaded / multi- or no selection).
    /// Saves and flushes target THIS id, captured at schedule time — never a newer selection. Published
    /// so the host can gate a jump-to-source scroll on "the target's body is loaded" (W7-S3).
    @Published private(set) var loadedID: UUID?

    // MARK: Injected seams (real wiring in `NoteEditorPane`; closures in tests)

    /// Serialize the item's stored body to full-body markdown (→ `NotesModel.loadBody`).
    var load: (UUID) async -> String? = { _ in nil }
    /// Persist edited body markdown for the item (→ `NotesModel.setBody`).
    var save: (UUID, String) async -> Void = { _, _ in }
    /// Production note editors use this seam: expected body in, actual durable body out; nil means
    /// failure. Templates retain their lease/draft-aware save seam above.
    var checkedSave: ((UUID, String, String) async -> String?)?
    /// Inline asset tasks must land before a recovery snapshot copies the item's assets.
    var prepareSave: () async -> Void = {}
    var onExternalChange: () -> Void = {}
    @Published private(set) var externalChangeMessage: String?
    /// Recreate TextKit after a conflict reload so old undo/serialization cannot restore stale text.
    @Published private(set) var reloadGeneration = 0
    /// Push any text still inside the live editor's own debounce into `markdown` **synchronously**, so a
    /// flush-on-switch captures the last keystrokes (→ the editor coordinator's `flushWriteBack`). A
    /// no-op in tests (which set `markdown` directly to simulate the editor having pushed).
    var flushEditor: () -> Void = {}

    /// Debounce before an idle autosave. The live editor already debounces its serialize (~400 ms); this
    /// coalesces the resulting body writes so rapid typing is one save, not one per keystroke.
    var saveDebounce: Duration = .milliseconds(600)

    // MARK: Private state

    private var baseline = ""
    private var dirty = false
    private var suppressAutosave = false
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0
    private var loadGeneration = 0

    init() {}

    /// A retired editor may finish a delayed serialize after another item has loaded.
    func acceptEditorMarkdown(_ body: String, for editorItemID: UUID?, generation: Int? = nil) {
        guard loadedID == editorItemID,
              generation == nil || generation == reloadGeneration else { return }
        markdown = body
    }

    // MARK: Selection

    /// The selected single item changed (nil = no single selection). Flush the OUTGOING item's pending
    /// edit first (so switching never loses the last keystrokes), then load the incoming body. A repeat
    /// of the already-loaded id is a no-op — it must NOT reload (that would clobber in-progress typing,
    /// e.g. when a post-save `reloadItems()` re-publishes the same selection).
    func select(_ id: UUID?) async {
        guard id != loadedID else { return }
        flushEditor()
        await flush()                       // persist the outgoing item (targets the OLD loadedID)

        // A refused content/recovery write must not discard the outgoing draft on a switch.
        guard !dirty else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        guard let id else { setLoaded(nil, body: "") ; return }

        guard let body = await load(id) else { return }
        guard generation == loadGeneration else { return }   // a newer select() superseded this load
        setLoaded(id, body: body)
    }

    /// Persist any pending edit for the currently-loaded item **now** (cancel the debounce and await the
    /// write). Called on selection switch and when the editor disappears (pane teardown / window close)
    /// so no dirty buffer is dropped. Returns false when the draft is still unsaved afterwards (the store
    /// refused the content or recovery write), so close and quit can keep it instead of dropping it.
    @discardableResult
    func flush() async -> Bool {
        // Keep the tail published while waiting: another flush or a newly scheduled save must also
        // wait for it. If typing extends the chain during the await, drain that newer tail as well.
        while let pending = saveTask {
            let generation = saveGeneration
            pending.cancel()
            await pending.value
            guard generation == saveGeneration else { continue }
            saveTask = nil
        }
        guard dirty else { return true }
        // Publish the forced save too: typing during its awaits must queue BEHIND it, just as it
        // does behind an idle autosave. Otherwise a new debounce can start a parallel stale save.
        let forced = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.dirty, let id = self.loadedID {
                let body = self.markdown
                guard await self.persist(body, for: id) else { return }
            }
        }
        saveGeneration &+= 1
        saveTask = forced
        await forced.value
        return !dirty
    }

    /// Flush BOTH debounces then await the write: first `flushEditor()` (synchronously push the live
    /// editor's own ~400 ms serialize into `markdown`), then `flush()` (cancel this model's ~600 ms
    /// autosave debounce and persist). This is the flush the app-terminate / window-close path uses
    /// (W7-S6, via `EditorFlushRegistry`) so a force-quit within *either* debounce still persists the last
    /// keystrokes instead of dropping them. It mirrors the sequence `select` runs before a selection
    /// switch, but is a distinct method: `select` keeps that sequence *inline* on purpose — the extra
    /// async frame of calling through here perturbs the actor scheduling its superseded-load race relies
    /// on, so the two intentionally do not share a call. Returns false while a draft remains unsaved.
    @discardableResult
    func flushPending() async -> Bool {
        flushEditor()
        return await flush()
    }

    /// The unsaved body and its item, for an emergency copy when the store refuses it (nil when clean).
    var unsavedDraft: (id: UUID, markdown: String)? {
        guard dirty, let loadedID else { return nil }
        return (loadedID, markdown)
    }

    /// The view polls only its open note, and cancels this work on teardown. Flush TextKit's first
    /// debounce before AND after the read: an apparently clean model may still have live keystrokes.
    /// Dirty buffers are never replaced; the checked save will preserve their draft separately.
    func refreshFromDisk() async {
        guard checkedSave != nil, let id = loadedID else { return }
        flushEditor()
        guard !dirty else { return }
        let expected = baseline
        let generation = loadGeneration
        guard let body = await load(id) else { return }
        flushEditor()
        guard loadedID == id, generation == loadGeneration, !dirty, baseline == expected,
              body != expected else { return }
        suppressAutosave = true
        markdown = body
        suppressAutosave = false
        baseline = body
        reloadGeneration &+= 1
        externalChangeMessage = "This note changed outside this editor and was reloaded."
        onExternalChange()
    }

    @discardableResult
    private func persist(_ body: String, for id: UUID) async -> Bool {
        let expected = baseline
        await prepareSave()
        let saved: String
        if let checkedSave {
            guard let actual = await checkedSave(id, body, expected) else { return false }
            saved = actual
        } else {
            await save(id, body)
            saved = body
        }
        // A save may suspend while TextKit receives more keystrokes in its own debounce. Serialize
        // those before deciding the buffer is clean or replacing it with a conflict reload.
        flushEditor()
        guard loadedID == id else { return true }
        // New keystrokes may have arrived during the save. If this was a conflict, those still
        // derive from the OLD baseline and must themselves go through recovery on the next save.
        if markdown == body {
            baseline = saved
            dirty = false
            if saved != body {
                suppressAutosave = true
                markdown = saved
                suppressAutosave = false
                reloadGeneration &+= 1
                externalChangeMessage = "This note changed outside this editor. Your in-app draft was kept separately; the original was reloaded."
            }
        } else if saved == body {
            baseline = saved
        }
        return true
    }

    // MARK: Private

    /// Install a freshly-loaded body without tripping autosave, and reset per-item state.
    private func setLoaded(_ id: UUID?, body: String) {
        saveTask?.cancel()
        saveTask = nil
        saveGeneration &+= 1
        suppressAutosave = true
        markdown = body
        suppressAutosave = false
        loadedID = id
        baseline = body
        dirty = false
        externalChangeMessage = nil
    }

    /// (Re)schedule the debounced idle save, capturing the target id at schedule time so a later
    /// selection switch cannot redirect this write to a different item.
    private func scheduleSave() {
        let previous = saveTask
        previous?.cancel()
        let id = loadedID
        saveGeneration &+= 1
        saveTask = Task { @MainActor [weak self] in
            // A previous task may already be inside the store despite cancellation. Preserve
            // edit order even when typing resumes while that write is still in flight.
            await previous?.value
            try? await Task.sleep(for: self?.saveDebounce ?? .milliseconds(600))
            guard !Task.isCancelled, let self, let id, self.loadedID == id, self.dirty else { return }
            await self.persist(self.markdown, for: id)
        }
    }
}
