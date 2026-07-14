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
    /// Push any text still inside the live editor's own debounce into `markdown` **synchronously**, so a
    /// flush-on-switch captures the last keystrokes (→ the editor coordinator's `flushWriteBack`). A
    /// no-op in tests (which set `markdown` directly to simulate the editor having pushed).
    var flushEditor: () -> Void = {}

    /// Debounce before an idle autosave. The live editor already debounces its serialize (~400 ms); this
    /// coalesces the resulting body writes so rapid typing is one save, not one per keystroke.
    var saveDebounce: Duration = .milliseconds(600)

    // MARK: Private state

    private var dirty = false
    private var suppressAutosave = false
    private var saveTask: Task<Void, Never>?
    private var loadGeneration = 0

    init() {}

    // MARK: Selection

    /// The selected single item changed (nil = no single selection). Flush the OUTGOING item's pending
    /// edit first (so switching never loses the last keystrokes), then load the incoming body. A repeat
    /// of the already-loaded id is a no-op — it must NOT reload (that would clobber in-progress typing,
    /// e.g. when a post-save `reloadItems()` re-publishes the same selection).
    func select(_ id: UUID?) async {
        guard id != loadedID else { return }
        flushEditor()
        await flush()                       // persist the outgoing item (targets the OLD loadedID)

        loadGeneration &+= 1
        let generation = loadGeneration
        guard let id else { setLoaded(nil, body: "") ; return }

        let body = await load(id) ?? ""
        guard generation == loadGeneration else { return }   // a newer select() superseded this load
        setLoaded(id, body: body)
    }

    /// Persist any pending edit for the currently-loaded item **now** (cancel the debounce and await the
    /// write). Called on selection switch and when the editor disappears (pane teardown / window close)
    /// so no dirty buffer is dropped.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard dirty, let id = loadedID else { return }
        let body = markdown
        await save(id, body)
        if loadedID == id, markdown == body { dirty = false }
    }

    // MARK: Private

    /// Install a freshly-loaded body without tripping autosave, and reset per-item state.
    private func setLoaded(_ id: UUID?, body: String) {
        saveTask?.cancel()
        saveTask = nil
        suppressAutosave = true
        markdown = body
        suppressAutosave = false
        loadedID = id
        dirty = false
    }

    /// (Re)schedule the debounced idle save, capturing the target id + body at schedule time so a later
    /// selection switch cannot redirect this write to a different item.
    private func scheduleSave() {
        saveTask?.cancel()
        let id = loadedID
        let body = markdown
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.saveDebounce ?? .milliseconds(600))
            guard !Task.isCancelled, let self, let id else { return }
            await self.save(id, body)
            if self.loadedID == id, self.markdown == body { self.dirty = false }
        }
    }
}
