import AppKit
import Foundation
import ArchiveCore

/// The UI façade every Notes view binds to (00-overview §16.1). It owns the single organization graph
/// (`OrganizationStore`) and — in the app path — the backing index + store-root, and exposes the
/// rendered folder tree + current scope as `@Published` state plus `async` mutation methods.
///
/// W6-S2 delivers the **folder-tree slice**: the rebuilt tree, folder scope selection, and the four
/// mutations (create / rename / move / delete) routed through `OrganizationStore`, whose writes are
/// already atomic (DB + `organization.json`). Later sub-tasks extend this same façade with the item
/// list (S3), search/filter/sort (S4), templates (S6), and `openItem(id:block:)` navigation (W4/W7).
///
/// Concurrency (§16.9): `@MainActor`; the actor-backed I/O it calls (`NotesIndex`, `OrganizationStore`
/// awaits) is awaited from here, and published state is only mutated on the main actor.
@MainActor
final class NotesModel: ObservableObject {
    /// The single organization graph shared by both windows. Mutations persist atomically.
    let organization: OrganizationStore

    // MARK: Rendered tree state (rebuilt after every mutation / store load)

    /// Hierarchical forest of normal folders (the "Folders" section).
    @Published private(set) var normalTree: [NotesFolderNode] = []
    /// Flat list of user smart folders (the "Smart Folders" section), excluding the All-Notes root.
    @Published private(set) var smartFolders: [NotesFolderNode] = []
    /// Distinct items across the whole store — the badge on the "All Notes" pseudo-row. (Membership-
    /// based here; the exact index-served count arrives with the item list in W6-S4.)
    @Published private(set) var allNotesCount: Int = 0

    // MARK: Item list source (W6-S3)

    /// Every indexed item (the `ItemSummary` projection, §16.5), shared by both windows. Each window's
    /// `NotesNavigationModel` filters + sorts this into its own `displayed` list, so the two windows can
    /// differ by kind/sort/selection while reading one source of truth. Loaded on bootstrap and
    /// refreshable via `reloadItems()`.
    @Published private(set) var allItems: [ItemSummary] = []

    /// Bumped on every `replaceItems` (create/rename/delete/reindex). A cheap O(1) signal the extract
    /// editor uses to re-resolve provenance-chip live titles when the shared item set changes, without
    /// diffing the whole list — so a source-note rename recolors chips reactively, not only on the next
    /// re-style (W14.4 c). Monotonic; wraps harmlessly (`&+`) since only inequality is compared.
    @Published private(set) var itemsGeneration = 0

    // MARK: Templates (W6-S6)

    /// Every template on disk (id / name / kind), shared by both windows. Loaded on bootstrap and
    /// after any template mutation. Drives the folder "Template ▸" assignment menu + "New from
    /// template" (06-viewers §6). Kept out of `allItems` so templates never appear in the note list.
    @Published private(set) var templates: [Template] = []

    // MARK: Deterministic index-ready signal (§3.4 — XCUITest polls this before FTS/relevance asserts)

    /// `true` once the initial on-disk index build has settled (app path). A pure injected test store
    /// with no background indexer surfaces ready immediately (nothing to build), so the hidden probe
    /// still resolves rather than polling forever.
    @Published private(set) var isIndexReady = false
    /// Completion token mirrored from `NotesIndexer` — flips `0 → ≥1` once the initial build settles.
    /// Surfaced to XCUITest via the hidden `an.status.indexReady` element (08-testing §3.4).
    @Published private(set) var indexGeneration = 0
    /// Why the index is degraded, when it is (`nil` = healthy) — mirrored from `NotesIndexer.failure`
    /// after the build settles. `isIndexReady` above means *settled*, not *healthy*: it has to flip
    /// even on failure or `awaitSettled()` would never resume, so this is the honest health claim, and
    /// `bootstrap()` puts its message in `statusMessage` where the sidebar shows it (W23.m9).
    @Published private(set) var indexFailure: NotesIndexer.Failure?

    // MARK: Current scope (drives the item list in W6-S3/S4)

    /// The active filter scope: `nil` = All Notes (no scope). A normal folder scopes by `folderId`;
    /// a smart folder applies its decoded `NotesFilter`.
    @Published private(set) var scope: NotesFilter?
    /// Highlighted normal folder (nil when All Notes / a smart folder is selected).
    @Published private(set) var selectedFolderId: UUID?
    /// Highlighted smart folder (nil when All Notes / a normal folder is selected).
    @Published private(set) var selectedSmartId: UUID?

    /// Transient, user-facing status for degradations (cycle refused, unreadable smart query, orphaned
    /// items after a folder delete). The view surfaces it and clears it.
    @Published var statusMessage: String?

    // MARK: In-app navigation (W7-S3 jump-to-source; also consumes external archivenotes:// opens)

    /// A request to reveal an item (and optionally scroll to a block) in the window that features its
    /// kind. Shared across both windows via this single model (§16.1) — the only cross-window channel.
    /// `token` makes a repeat request to the SAME `(id, block)` re-fire, so jumping to the same passage
    /// twice still scrolls (the coalescing-counter idiom, cf. Reader `NavigationModel.requestScroll`).
    struct OpenRequest: Equatable, Sendable {
        let id: UUID
        let block: Int?
        let token: Int
    }
    /// The current pending open request; the featuring window observes it, selects the item + scrolls,
    /// then calls `consumeOpen()`. `nil` when nothing is pending.
    @Published private(set) var pendingOpen: OpenRequest?
    private var openToken = 0

    /// In-process navigation entry point (§16.1) — called by W7's jump-to-source chip and by the
    /// `archivenotes://open` URL router. Publishes an `OpenRequest`; the featuring window consumes it.
    /// Pure signal: resolution/degradation (deleted note, wrong kind, stale ordinal) is the observer's
    /// job via `resolvePassage`/`NotePassageResolve` — this never throws and never touches the store.
    func openItem(id: UUID, block: Int?) {
        openToken &+= 1
        pendingOpen = OpenRequest(id: id, block: block, token: openToken)
    }

    /// Clear the pending open request once a window has handled it.
    func consumeOpen() {
        pendingOpen = nil
    }

    /// Resolve a note-passage provenance anchor against the current item set (W7-S3 degradation logic).
    func resolvePassage(_ anchor: SourceAnchor) -> PassageResolution {
        NotePassageResolve.resolve(anchor: anchor, among: allItems)
    }

    // MARK: App-path lifecycle (nil when a test injects a pre-loaded store)

    private let ownsDataLayer: Bool
    private let index: NotesIndex?
    private let rootStore: RootFolderStore?
    /// Background full-index driver (app path) — shares `index`'s sqlite handle so there is one
    /// connection to the file. Injectable for tests that exercise the disk-build / ready-signal path;
    /// `nil` for a pure injected store.
    private let indexer: NotesIndexer?
    /// The only file-deleting layer (W2, §16.1). Built in `bootstrap()` on the app path; injectable for
    /// tests. `delete(_:)` moves an item dir to the macOS Trash (recoverable) — never `removeItem`.
    private var noteStore: NoteStore?
    private var didBootstrap = false

    /// Where the app-lifecycle triggers for the stale-mirror retry come from (W23.m10-fu) — `.default`
    /// in the app, a private centre under test so one posted notification reaches one model.
    private let notificationCenter: NotificationCenter
    /// Kept so the observers die with the model rather than outliving it on a shared centre.
    private var mirrorRecoveryObservers: NotificationObservers?

    // MARK: Init

    /// Injection init (tests, previews): the caller provides an already-loaded `OrganizationStore`.
    ///
    /// `notificationCenter` is the seam the mirror-recovery triggers are attached to (W23.m10-fu);
    /// tests pass their own so a posted app notification reaches exactly one model.
    init(organization: OrganizationStore, notificationCenter: NotificationCenter = .default) {
        self.organization = organization
        self.ownsDataLayer = false
        self.index = nil
        self.rootStore = nil
        self.indexer = nil
        self.notificationCenter = notificationCenter
        rebuild()
        observeMirrorRecoveryTriggers()
    }

    /// Injection init with a live index — for tests that exercise FTS `search(_:)` or the W6-S5 delete
    /// path (`noteStore`). Like `init(organization:)` but routes keyword search to a real `NotesIndex`
    /// and, when a `noteStore` is supplied, the delete-last-instance path to a real (scratch) store. It
    /// still does **not** own the data layer (`bootstrap()` stays a no-op), so callers seed items via
    /// `replaceItems`.
    init(organization: OrganizationStore, index: NotesIndex, noteStore: NoteStore? = nil,
         indexer: NotesIndexer? = nil, notificationCenter: NotificationCenter = .default) {
        self.organization = organization
        self.ownsDataLayer = false
        self.index = index
        self.rootStore = nil
        self.noteStore = noteStore
        self.indexer = indexer
        self.notificationCenter = notificationCenter
        rebuild()
        observeMirrorRecoveryTriggers()
    }

    /// App init: build the real data layer (index + org store + store-root). The tree stays empty
    /// until `bootstrap()` runs (call it from a `.task` before first render) so no blocking I/O
    /// happens during `App` construction.
    convenience init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
        let index = NotesIndex(url: Self.indexDatabaseURL(inAppSupport: appSupport))
        self.init(organization: OrganizationStore(index: index),
                  index: index,
                  rootStore: RootFolderStore())
    }

    /// The content-index database URL. Normally `notes-index-v1.sqlite3` in Application Support (the
    /// app *container* when sandboxed). Under XCUITest (`-ANUITestStorePath`), a dedicated
    /// `notes-index-uitest.sqlite3` that is RESET on every launch — so a persisted organization graph
    /// can never shadow the fixture's `organization.json` across GUI runs. `OrganizationStore.load`
    /// reads the folder graph DB-first and consults `organization.json` only when the DB has zero
    /// folders (see its `load(storeRoot:)`); a stale container DB from a prior run would otherwise hide
    /// the fixture's folders/replication (the state the W8-S8 G7/G8 checks assert on). The index is a
    /// rebuildable cache — resetting it loses nothing — and the distinct filename keeps the owner's real
    /// `notes-index-v1.sqlite3` untouched. DEBUG-only: the override is compiled out of Release, so the
    /// shipping app can only ever open `notes-index-v1.sqlite3`.
    private static func indexDatabaseURL(inAppSupport appSupport: URL) -> URL {
#if DEBUG
        if let path = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !path.isEmpty {
            let uitestURL = appSupport.appendingPathComponent("notes-index-uitest.sqlite3")
            resetUITestIndexDatabase(at: uitestURL)
            return uitestURL
        }
#endif
        return appSupport.appendingPathComponent("notes-index-v1.sqlite3")
    }

#if DEBUG
    /// Delete the UITest index DB (plus its `-wal`/`-shm` sidecars) and ensure its parent directory
    /// exists, so each XCUITest launch opens a fresh, empty index. Only ever touches the
    /// `notes-index-uitest.sqlite3` triple — never the real `notes-index-v1.sqlite3`, never the store,
    /// never a corpus. Errors are non-fatal (a missing file is the desired post-state anyway).
    private static func resetUITestIndexDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
#endif

    private init(organization: OrganizationStore, index: NotesIndex, rootStore: RootFolderStore) {
        self.organization = organization
        self.ownsDataLayer = true
        self.index = index
        self.rootStore = rootStore
        self.indexer = NotesIndexer(index: index)   // shares the one NotesIndex handle
        self.notificationCenter = .default
        // Tree stays empty until bootstrap().
        observeMirrorRecoveryTriggers()
    }

    /// App path only: open the index and load persisted organization, then rebuild. Idempotent — safe
    /// to call from a `.task` that may re-run. A no-op for an injected (test) store.
    func bootstrap() async {
        guard ownsDataLayer, !didBootstrap else { return }
        didBootstrap = true
        guard let index, let rootStore, let root = rootStore.root else {
            // No store chosen yet: nothing to index. Still flip ready so the probe resolves.
            rebuild(); markIndexReady(generation: max(indexGeneration, 1)); return
        }
        noteStore = NoteStore(root: root)
        do {
            try await index.open()
            try await organization.load(storeRoot: root)
        } catch {
            report(error, "open the notes store")
        }
        rebuild()
        await reloadItems()          // fast first paint from whatever is already indexed
        await reloadTemplates()
        await buildIndexFromDisk()   // (re)build the disposable index from disk, then flip ready (§3.4)
    }

    // MARK: Item list loading (W6-S3)

    /// Reload the shared item set from the index (app path). A no-op for an injected (test) store,
    /// which seeds items via `replaceItems(_:)` instead.
    ///
    /// Routed through `openIndexForQuery()`, so a read the index couldn't answer is reported instead of
    /// published: `allSummaries()` returns `[]` for an unopenable index exactly as it does for an empty
    /// one, and publishing that would erase the visible library on the strength of a query that never
    /// ran (W23.m9-fu). A *successful* read still publishes whatever it found, empty included.
    func reloadItems() async {
        guard let index = await openIndexForQuery() else { return }
        let items = await index.allSummaries()
        replaceItems(items)
    }

    /// Replace the shared item set. The app path calls this from `reloadItems()`; tests call it
    /// directly to seed synthetic summaries without a real index. Published, so each window's
    /// navigation model recomputes its `displayed` list.
    func replaceItems(_ items: [ItemSummary]) {
        allItems = items
        itemsGeneration &+= 1
    }

    // MARK: Initial index build + ready signal (§3.4)

    /// App-path initial build: (re)index every on-disk item into the disposable FTS index, then refresh
    /// the shared item list and flip the deterministic index-ready signal. Awaits the background build so
    /// `isIndexReady` / `indexGeneration` reflect a **settled** index — XCUITest polls the hidden
    /// `an.status.indexReady` element for this before asserting search / relevance (08-testing §3.4).
    /// The index is a disposable cache, so this is read-only w.r.t. the store (mtime-skipped upserts
    /// only; no prune here — that stays gated on a settled snapshot elsewhere).
    ///
    /// Also the mid-session recovery pass: `repopulateIndexAfterRecovery()` reuses this verbatim so a
    /// repaired index is refilled the same way a fresh one is (W23.m9-fu2).
    func buildIndexFromDisk() async {
        guard let indexer, let noteStore else {
            // Pure injected store (no background indexer/store): nothing to build — surface ready anyway.
            markIndexReady(generation: max(indexGeneration, 1))
            return
        }
        let refs = await noteStore.allItemRefs()
        indexer.startIndexing(refs)
        await indexer.awaitSettled()
        await reloadItems()
        markIndexReady(generation: indexer.indexGeneration)
        // Settled ≠ healthy: adopt whatever the build actually achieved, so a partial or unopenable
        // index is visible rather than presented as a Ready one (W23.m9).
        adoptIndexFailure(indexer.failure)
    }

    /// Mirror the indexer's health onto the model and, when degraded, into the sidebar status line.
    /// Never clears a message it didn't set — `statusMessage` is shared with other degradations, so
    /// clearing one this model didn't post would swallow another subsystem's report.
    ///
    /// Two properties matter now that the query paths call this per search (W23.m9-fu):
    /// a degraded index **re-posts** its line every time a read hits it, so a banner the operator
    /// dismissed comes back rather than leaving the next empty result unexplained; and the assignment
    /// to `@Published indexFailure` is change-guarded, since a 150 ms-debounced search would otherwise
    /// republish the identical value on every keystroke.
    private func adoptIndexFailure(_ failure: NotesIndexer.Failure?) {
        if indexFailure != failure { indexFailure = failure }
        if let failure {
            statusMessage = failure.message
            postedIndexMessage = failure.message
        } else {
            // The claim is no longer true — retract it, but only if our own line is still the one showing.
            if let posted = postedIndexMessage, statusMessage == posted { statusMessage = nil }
            postedIndexMessage = nil
        }
    }

    /// The index-health line this model last put in `statusMessage`, so it can be retracted when the
    /// index recovers — and *only* it. Without this, a recovered index either left a false "unavailable"
    /// banner up for the rest of the session or cleared a line some other failure had posted.
    private var postedIndexMessage: String?

    /// The shared index, but only once it has actually opened — the one health-aware accessor every
    /// model-level read goes through (W23.m9-fu).
    ///
    /// `NotesIndex`'s reads answer `[]`/`nil` on a nil handle, so a read that skipped the open was
    /// indistinguishable from "nothing matches": before this, `search`/`reloadItems` queried the index
    /// directly, never attempted an open, and so never reported a dead index nor noticed a repaired one.
    ///
    /// Routed through `NotesIndexer.openForQuery()` whenever there is a driver, so the driver stays the
    /// single owner of index health and this only mirrors it. A model injected with a bare index (tests,
    /// previews) has no driver, so it opens under the same all-or-nothing contract and publishes the
    /// same typed failure itself — the report must not depend on which initializer ran.
    ///
    /// **Recovering the handle is not recovering the rows** (W23.m9-fu2). An index that opens after
    /// having been `unavailable` is queryable but, in the case that matters, EMPTY — the operator
    /// replaced the corrupt file, a sync client healed it, the volume came back. Retracting the banner
    /// on its own therefore traded one silent wrong answer ("no matches", because nothing could be read)
    /// for another ("no matches", because nothing has been written yet). The `unavailable → open` edge
    /// is what schedules the rebuild that fills it, hence reading the prior health *before* the open.
    private func openIndexForQuery() async -> NotesIndex? {
        guard let index else { return nil }          // pure injected store: no index to be unhealthy
        // The driver owns `failure` when there is one; only a driver-less model answers for itself. Read
        // it from the owner, since `buildIndexFromDisk()` adopts the driver's verdict only at the end of
        // the pass — mid-pass the model's mirror can still be nil while the driver knows better.
        var wasUnavailable = false
        if case .unavailable = indexer?.failure ?? indexFailure { wasUnavailable = true }

        let opened: Bool
        if let indexer {
            opened = await indexer.openForQuery()
            adoptIndexFailure(indexer.failure)
        } else {
            do {
                try await index.open()
                // It opened, so an `unavailable` claim is now false. An `incomplete` one still stands — a
                // successful open says nothing about rows a previous pass failed to write.
                if case .unavailable = indexFailure { adoptIndexFailure(nil) }
                opened = true
            } catch {
                adoptIndexFailure(.unavailable(detail: NotesIndexer.failureDetail(error)))
                opened = false
            }
        }
        guard opened else { return nil }
        if wasUnavailable { scheduleIndexRepopulationAfterRecovery() }
        return index
    }

    /// The in-flight post-recovery rebuild (W23.m9-fu2) — `nil` when none is running.
    private var indexRecoveryTask: Task<Void, Never>?

    /// The in-flight post-recovery rebuild, so a test can await it rather than sleep on a task the query
    /// path scheduled. (`nil` also means "already finished" — the assertions are on the rebuilt state.)
    var inFlightIndexRecoveryTask: Task<Void, Never>? { indexRecoveryTask }

    /// Kick a from-disk rebuild after the index recovered from `unavailable`, WITHOUT making the read
    /// that noticed wait for it (W23.m9-fu2).
    ///
    /// Three properties are the whole design:
    /// - **Edge-triggered, not per-read.** Only the `unavailable → open` transition schedules it, so the
    ///   directory walk happens once per recovery rather than once per keystroke of a 150 ms-debounced
    ///   search. This is the "a full disk walk from a keystroke" objection that deferred the fix, and it
    ///   is the edge — not the failure state — that answers it.
    /// - **Off the read's critical path.** The caller returns its (still empty) result immediately and
    ///   the rows land on a later read, exactly as they do after a launch build. A search must never
    ///   block on a store walk.
    /// - **One at a time.** `buildIndexFromDisk()` re-enters `openIndexForQuery()` via `reloadItems()`,
    ///   and a file that flaps would otherwise stack rebuilds on each other.
    ///
    /// Nothing to rebuild *from* — no driver, or no store yet (an injected model, or one pre-`bootstrap`)
    /// — is a no-op: the handle recovered and the banner is retracted either way, there is simply no
    /// disk to walk.
    private func scheduleIndexRepopulationAfterRecovery() {
        guard indexer != nil, noteStore != nil, indexRecoveryTask == nil else { return }
        indexRecoveryTask = Task { [weak self] in
            await self?.repopulateIndexAfterRecovery()
            self?.indexRecoveryTask = nil
        }
    }

    /// The rebuild itself: the same from-disk pass the app runs at launch (W23.m9-fu2).
    ///
    /// Deliberately `buildIndexFromDisk()` and not a bespoke recovery path — the two cannot drift, its
    /// upserts are mtime-skipped (so a volume that came back with its rows intact costs one directory
    /// walk and no writes), and it also repairs the *partial* index a mid-pass failure leaves behind,
    /// which an "only rebuild when the index reads empty" shortcut would skip. It is read-only w.r.t.
    /// the note store and prunes nothing, so the worst case of a needless run is wasted work.
    ///
    /// It does re-mark `isIndexReady` and bump `indexGeneration` — the deliberate behaviour change this
    /// item exists to make, rather than smuggle into the LOW visibility fix it fell out of. The token's
    /// contract is "a build settled", and one did; `isIndexReady` only ever goes true, so the hidden
    /// `an.status.indexReady` probe cannot regress to "building" underneath a test.
    ///
    /// Internal so a test can drive the rebuild deterministically instead of racing the scheduler.
    func repopulateIndexAfterRecovery() async {
        guard indexer != nil, noteStore != nil else { return }
        await buildIndexFromDisk()
    }

    private func markIndexReady(generation: Int) {
        indexGeneration = generation
        isIndexReady = true
    }

    // MARK: Keyword search (W6-S4)

    /// Full-text search over the disposable index, in bm25 relevance order (best match first). Returns
    /// `[]` for a blank query or an injected (index-less) store. The per-window `NotesNavigationModel`
    /// intersects this with its filtered set and orders by rank (06-viewers §4, §11).
    ///
    /// An unopenable index answers `[]` too, so the read goes through `openIndexForQuery()`: an empty
    /// result then means "no matches", and a dead index says so in the sidebar instead (W23.m9-fu). The
    /// blank-query check stays first — not searching is not a failed search, and must raise no banner.
    func search(_ query: String) async -> [UUID] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard let index = await openIndexForQuery() else { return [] }
        return await index.search(query)
    }

    // MARK: Templates (W6-S6 — §3.7, §6, §16.4)

    /// Reload the template list from the store. A no-op with no `noteStore` (an injected test store
    /// built without one); template tests inject a scratch `noteStore`.
    func reloadTemplates() async {
        guard let noteStore else { return }
        templates = await noteStore.allTemplates()
    }

    /// Templates whose kind matches `kind` — the offering set for "New from template" (§6).
    func templates(matching kind: Item.Kind) -> [Template] {
        templates.filter { $0.kind == kind }
    }

    /// Assign `templateId` to `folderId` (`nil` clears it). Persisted atomically via `OrganizationStore`
    /// (DB + organization.json). Template↔folder lives only in `template_assignments` (§16.4).
    func assignTemplate(_ templateId: UUID?, to folderId: UUID) async {
        do {
            if let templateId { try await organization.assignTemplate(templateId, to: folderId) }
            else { try await organization.removeTemplateAssignment(folder: folderId) }
            adoptMirrorFailure()
        } catch { report(error, "assign the template") }
    }

    /// The effective template for `folderId`: the nearest ancestor's live assignment (self first),
    /// else `nil` ("Blank"). An assignment pointing at a deleted template is skipped **and** lazily
    /// cleared (§6 dangling edge case), off the resolve path so this stays a pure read.
    func effectiveTemplate(for folderId: UUID?) -> Template? {
        let existing = Set(templates.map(\.id))
        let (tid, dangling) = TemplateResolution.resolve(
            folderId: folderId, folders: organization.folders,
            assignments: organization.assignments, existingTemplateIDs: existing)
        if !dangling.isEmpty { Task { await clearDanglingAssignments(dangling) } }
        guard let tid else { return nil }
        return templates.first { $0.id == tid }
    }

    private func clearDanglingAssignments(_ folderIds: [UUID]) async {
        for f in folderIds { try? await organization.removeTemplateAssignment(folder: f) }
        rebuild()
        adoptMirrorFailure()
    }

    /// Create a new template of `kind` named `name` (empty body). Returns the new id.
    @discardableResult
    func createTemplate(name rawName: String, kind: Item.Kind) async -> UUID? {
        guard let noteStore else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A template needs a name."; return nil }
        let item = blankItem(kind: kind, title: uniqueTemplateName(name))
        do {
            _ = try await noteStore.createTemplate(item)
            await reloadTemplates()
            return item.id
        } catch { report(error, "create the template"); return nil }
    }

    /// Duplicate a template (fresh id + " copy" name), preserving kind + front-matter defaults + body.
    @discardableResult
    func duplicateTemplate(_ id: UUID) async -> UUID? {
        guard let noteStore else { return nil }
        do {
            var item = try await noteStore.loadTemplate(id)
            item.id = UUID()
            item.title = uniqueTemplateName("\(item.title) copy")
            item.created = Date(); item.modified = Date()
            _ = try await noteStore.createTemplate(item)
            await reloadTemplates()
            return item.id
        } catch { report(error, "duplicate the template"); return nil }
    }

    /// Rename a template (its title = its display name = its filename).
    func renameTemplate(_ id: UUID, to rawName: String) async {
        guard let noteStore else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A template needs a name."; return }
        do {
            // W23.h2: one atomic transaction, not load + save — two windows renaming the same
            // template would otherwise let the later whole-item save drop the other's edit.
            _ = try await noteStore.withTemplate(id) { item in
                item.title = name; item.modified = Date()
            }
            await reloadTemplates()
        } catch { report(error, "rename the template") }
    }

    /// Delete a template (to Trash) and clear every folder assignment that pointed at it (batched, §6).
    ///
    /// **The trash goes FIRST, and the assignments are only cleared once it succeeded (W23.m13).** The
    /// old order cleared every assignment before attempting the trash, so a refused trash reported a
    /// failure about a template that was still there while its folder assignments were already,
    /// silently and unrecoverably, gone. Reversed, a refused trash changes nothing at all. The cost of
    /// the other direction — trashed, then the clear fails — is only a dangling assignment, which
    /// `TemplateResolution.resolve` already skips and `effectiveTemplate` lazily clears; and the clear
    /// is itself one transaction, so it can't half-apply across folders.
    func deleteTemplate(_ id: UUID) async {
        guard let noteStore else { return }
        do { try await noteStore.deleteTemplate(id) }
        catch {
            report(error, "delete the template")
            await reloadTemplates(); rebuild(); adoptMirrorFailure()
            return
        }
        // Read AFTER the trash, not before: this method is `@MainActor` but reentrant at that await, so
        // an assignment made to this template while the trash was in flight would be missed by a set
        // captured earlier — and by then it is already an assignment to a trashed template.
        let referencing = organization.assignments.filter { $0.templateId == id }.map(\.folderId)
        do { try await organization.removeTemplateAssignments(folders: referencing) }
        catch { report(error, "clear the deleted template's folder assignments") }
        await reloadTemplates()
        rebuild()
        adoptMirrorFailure()
    }

    // MARK: New item (blank or from a template) (W6-S6)

    /// Create a new item of `kind` in `folderId` (`nil` ⟹ the system default: Inbox for a note,
    /// Extracts for an extract, §16.6), instantiated from `templateId` when given: the template's
    /// front-matter defaults (title/date/quality/tags/authors/roundup) + body are cloned into a fresh
    /// item (new UUID, fresh created/modified). Returns the new item id (nil on failure / no store).
    @discardableResult
    func newItem(kind: Item.Kind, in folderId: UUID?, from templateId: UUID?) async -> UUID? {
        guard let noteStore else { return nil }
        var item: Item
        if let templateId {
            do { item = try await noteStore.loadTemplate(templateId) }
            catch { report(error, "read the template"); return nil }
            item.id = UUID()
            item.kind = kind
            item.created = Date(); item.modified = Date()
        } else {
            item = blankItem(kind: kind, title: "")
        }
        let target = folderId ?? (kind == .extract ? organization.extractsHomeFolderId
                                                    : OrganizationStore.inboxFolderId)
        do {
            _ = try await noteStore.create(item)
            try await organization.addMembership(item: item.id, folder: target)
            await reloadItems()
            rebuild()
            adoptMirrorFailure()
            return item.id
        } catch { report(error, "create the note"); return nil }
    }

    /// A fresh, empty item shell (schema 1) — a blank new item or a new template.
    private func blankItem(kind: Item.Kind, title: String) -> Item {
        let now = Date()
        return Item(id: UUID(), kind: kind, title: title, authors: [], date: nil,
                    datePrecision: nil, dateUncertain: false, quality: nil, tags: [],
                    zotero: [], roundup: false, created: now, modified: now, schema: 1,
                    blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    /// A name-unique template name (case-insensitive), appending " 2", " 3", … if taken.
    private func uniqueTemplateName(_ base: String) -> String {
        let taken = Set(templates.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Extracts (W7-S2 — create / append from a note-editor selection)
    //
    // The extract experience mints a new, independently-editable `Item(kind: .extract)` holding a
    // SNAPSHOT copy of a note passage plus a durable note-passage provenance link (07-extracts §2/§5).
    // Persistence goes ONLY through the audited `NoteStore` (via `ExtractBuilder`) + the atomic
    // `OrganizationStore` membership write — W7 adds no new file-writing choke-point (keeps it Tier-1).
    // The source note is READ-ONLY at snapshot; the archival corpus is never touched (Prime Directive
    // #1). Unlike `newItem`, these upsert the one new/changed index row inline so the extract appears
    // in the Extracts window's list immediately (no full re-index pass needed) — same idiom as
    // `mutateItem`.

    /// Create a new extract from a live note selection and file it into the Extracts home folder
    /// (or `folderId`). Returns the new extract's id (nil on empty selection / no store / failure).
    /// Both windows observe `allItems`, so the Extracts window features the new extract at once.
    @discardableResult
    func createExtract(from source: PassageSelectionSource, into folderId: UUID? = nil) async -> UUID? {
        guard let noteStore else { return nil }
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn: source)
        guard !passages.isEmpty else {
            statusMessage = "Select text in a note to make an extract."
            return nil
        }
        do {
            let created = try await ExtractBuilder(store: noteStore).createExtract(from: passages)
            try await organization.addMembership(item: created.id,
                                                 folder: folderId ?? organization.extractsHomeFolderId)
            if let index {
                try await index.upsertBatch([NoteIndexRow(item: created,
                                                          mtime: created.modified.timeIntervalSince1970)])
            }
            await reloadItems()
            rebuild()
            adoptMirrorFailure()
            // W14.4(b): route the new extract through the open channel so the Extracts window selects
            // it (and, if open, raises itself) — the extract is no longer silently filed into the list.
            openItem(id: created.id, block: nil)
            return created.id
        } catch { report(error, "create the extract"); return nil }
    }

    /// Append a live note selection to an EXISTING extract (cross-note segmentation, §D7). No-op on an
    /// empty selection. The source note is never mutated; errors surface via `statusMessage`.
    func appendToExtract(_ id: UUID, from source: PassageSelectionSource) async {
        guard let noteStore else { return }
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn: source)
        guard !passages.isEmpty else {
            statusMessage = "Select text in a note to append to an extract."
            return
        }
        do {
            // W23.h2: `append` is one atomic transaction and hands back the extract exactly as
            // written, so the index row reflects what landed (no second read to race with).
            let updated = try await ExtractBuilder(store: noteStore).append(toExtract: id,
                                                                           passages: passages)
            if let index {
                try await index.upsertBatch([NoteIndexRow(item: updated,
                                                          mtime: updated.modified.timeIntervalSince1970)])
            }
            await reloadItems()
            rebuild()
            // W14.4(b): surface the appended-to extract in the Extracts window (select + raise-if-open),
            // mirroring create — confirms the segment landed without hunting the list.
            openItem(id: id, block: nil)
        } catch { report(error, "append to the extract") }
    }

    /// The extracts currently in the store (id + display title), for the "Append to Extract…" chooser.
    /// Sorted by localized title for a stable menu; empty titles render as "Untitled".
    var existingExtracts: [(id: UUID, title: String)] {
        allItems.filter { $0.kind == .extract }
            .map { (id: $0.id, title: $0.title.isEmpty ? "Untitled" : $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: Metadata edits (W6-S7 — dates & quality, §16.1)
    //
    // Front-matter ONLY (00-overview D2/D9): a note's date + quality live in its own `.md` YAML, never
    // in a macOS Finder tag. These methods DELIBERATELY do not touch `NotesTagProjector` — subjects are
    // the one projected facet. Each loads the item through the `NoteStore` actor, mutates a single
    // field, writes it back atomically, re-indexes that one row, and refreshes the shared `allItems` so
    // both windows' lists + the detail header update live.

    /// Set the item's date + precision (a `nil`/blank date clears the date entirely). The pair is
    /// normalized (`Item.normalizedDate`) so the stored string always matches its precision, keeping
    /// `sortDate` correct — decade → `decade * 10_000`; an uncertain date still sorts by its value
    /// (rendered italic), never dumped last.
    func setDate(_ date: String?, precision: Item.DatePrecision?, for id: UUID) async {
        let n = Item.normalizedDate(date, precision: precision)
        await mutateItem(id, "set the date") { item in
            item.date = n.date
            item.datePrecision = n.precision
        }
    }

    /// Toggle the "date uncertain" flag (the date renders italic but still sorts by its value).
    func setDateUncertain(_ uncertain: Bool, for id: UUID) async {
        await mutateItem(id, "set date uncertainty") { $0.dateUncertain = uncertain }
    }

    /// Set the quality rating (1...5, 5 highest; `nil` clears it — the "None" case). Written to the
    /// front-matter `quality` key ONLY (priority-style, D9) — never a Finder tag. Values are clamped
    /// into 1...5 defensively (the UI offers only None + 1…5).
    func setQuality(_ quality: Int?, for id: UUID) async {
        let clamped = quality.map { min(max($0, 1), 5) }
        await mutateItem(id, "set the quality") { $0.quality = clamped }
    }

    // MARK: Note body load / save (W7-S1a — the editor↔item wiring that gates W7 Extracts)
    //
    // The detail-pane editor edits the note's FULL body markdown: the leading prose plus the serialized
    // `<!-- block: -->` source-block headers (00-overview §5/§6). Load serializes the stored
    // `(trailingBodyRaw, blocks)` back to that markdown; save parses it and writes through the SAME
    // audited `mutateItem` path the date/quality editors use (load-fresh → atomic `.md` save → one-row
    // re-index → publish). Body text is Notes' OWN store only — never a Finder tag, never the archival
    // corpus (Prime Directive #1). `setBody` bumps `modified` (via `mutateItem`) since it is a real edit.

    /// Serialize the item's stored body to the editor's full-body markdown, or nil if it can't be read
    /// (missing/unreadable note — the caller then leaves the editor empty rather than showing a stale
    /// buffer). Read-only: does not touch the store.
    func loadBody(for id: UUID) async -> String? {
        guard let noteStore else { return nil }
        do {
            let item = try await noteStore.load(id)
            return BlockParser.serialize(leadingText: item.trailingBodyRaw, blocks: item.blocks)
        } catch { report(error, "load the note body"); return nil }
    }

    /// Parse edited body markdown back into `(leadingText, blocks)` and persist it atomically through
    /// `mutateItem`, so it shares the date/quality write path's guarantees (fresh load → atomic save →
    /// single-row re-index → publish). A failed write surfaces via `statusMessage` and leaves the
    /// on-disk `.md` untouched (the disk is the source of truth). A no-op with no `noteStore`.
    func setBody(_ markdown: String, for id: UUID) async {
        let parsed = BlockParser.parse(markdown)
        await mutateItem(id, "save the note") { item in
            item.trailingBodyRaw = parsed.leadingText
            item.blocks = parsed.blocks
        }
    }

    /// W7-S5 — an item-scoped inline-image asset store over the audited `NoteStore`, or nil before
    /// bootstrap / for an injected (store-less) test model. The editor pane creates one and retargets it
    /// to the selected item so pasted/dropped images persist into that item's `assets/`.
    func makeAssetStore() -> ItemAssetStore? {
        guard let noteStore else { return nil }
        return ItemAssetStore(store: noteStore, root: noteStore.rootURL)
    }

    /// Shared atomic-transaction → single-row re-index → publish path for the field editors above. A
    /// no-op with no `noteStore` (an injected test model built without one). The on-disk `.md` is the
    /// source of truth and the index is a rebuilt-from-disk projection, so nothing here can corrupt
    /// data; errors surface via `statusMessage` like the other mutations.
    ///
    /// **W23.h2 — the whole load→mutate→save runs inside ONE `NoteStore.withItem` call.** Spelling it
    /// out here as separate `load` / `save` awaits made it a lost-update race: `NotesModel` is
    /// `@MainActor` but *reentrant at every `await`*, so a body autosave and a metadata edit could both
    /// load the same old item and the later save would silently drop the other's field. `mutate` must
    /// therefore stay synchronous — that is what makes the transaction atomic.
    private func mutateItem(_ id: UUID, _ action: String,
                            _ mutate: @Sendable (inout Item) -> Void) async {
        guard let noteStore else { return }
        do {
            let tx = try await noteStore.withItem(id) { item in
                mutate(&item)
                item.modified = Date()
            }
            if let index {
                try await index.upsertBatch([NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)])
            }
            await reloadItems()
        } catch { report(error, action) }
    }

    // MARK: Tree rebuild

    /// Recompute the rendered tree + counts from the current organization graph. Call after any
    /// mutation. Cheap (O(F + M)); the shared model is the single source of tree state for both windows.
    func rebuild() {
        let folders = organization.folders
        let memberships = organization.memberships
        normalTree = NotesFolderNode.buildNormalForest(folders: folders, memberships: memberships)
        smartFolders = NotesFolderNode.smartFolderNodes(
            folders: folders, excluding: [OrganizationStore.allNotesFolderId])
        allNotesCount = Set(memberships.map(\.itemId)).count
    }

    // MARK: Scope selection

    /// Scope to a normal folder. `nil` or the All-Notes root clears the scope (show everything). The
    /// no-op guard (already scoped to `id`) is the second half of the sidebar selection-sync
    /// loop-breaker (the view holds the first; see Reader `SidebarView.swift:8-13`).
    func setFolderScope(_ id: UUID?) {
        guard let id, id != OrganizationStore.allNotesFolderId else { setAllNotesScope(); return }
        guard selectedFolderId != id || selectedSmartId != nil else { return }
        selectedFolderId = id
        selectedSmartId = nil
        scope = NotesFilter(folderId: id)
    }

    /// Clear the scope — the "All Notes" pseudo-row.
    func setAllNotesScope() {
        guard selectedFolderId != nil || selectedSmartId != nil || scope != nil else { return }
        selectedFolderId = nil
        selectedSmartId = nil
        scope = nil
    }

    /// Apply a smart folder's saved query as the scope. An unreadable `queryJSON` degrades to All
    /// Notes with a status message (mirrors Reader's `sanitizedPathPrefix` degrade,
    /// `NavigationModel.swift:417-422`).
    func applySmartScope(_ id: UUID) {
        guard let f = organization.folders.first(where: { $0.id == id }), f.kind == .smart else { return }
        guard let json = f.queryJSON, let data = json.data(using: .utf8),
              let filter = try? JSONDecoder().decode(NotesFilter.self, from: data) else {
            statusMessage = "This smart folder's saved query is unreadable."
            setAllNotesScope()
            return
        }
        selectedSmartId = id
        selectedFolderId = nil
        scope = filter
    }

    // MARK: Mutations (routed through OrganizationStore — atomic DB + organization.json writes)

    /// Create a normal folder under `parent`. Whitespace-trimmed; empty rejected; the name is deduped
    /// against siblings with the ` 2`, ` 3` suffix logic (copied in spirit from
    /// `SavedSearchStore.uniqueName`, `SavedSearch.swift:63-69`).
    @discardableResult
    func createFolder(name rawName: String, under parent: UUID?) async -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A folder needs a name."; return nil }
        let unique = uniqueSiblingName(name, parent: parent, excluding: nil)
        do {
            let created = try await organization.createFolder(name: unique, parent: parent, kind: .normal)
            rebuild()
            adoptMirrorFailure()
            return created.id
        } catch { report(error, "create the folder"); return nil }
    }

    /// Create a root-level **smart** folder whose saved `NotesFilter` is persisted as `queryJSON`
    /// (§16.3) — the "Save as Smart Folder" action from the filter bar (W6-S4). Name trimmed, empty
    /// rejected, sibling-deduped. Returns the new folder id.
    @discardableResult
    func createSmartFolder(name rawName: String, query: NotesFilter) async -> UUID? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A smart folder needs a name."; return nil }
        let unique = uniqueSiblingName(name, parent: nil, excluding: nil)
        guard let data = try? JSONEncoder().encode(query),
              let json = String(data: data, encoding: .utf8) else {
            statusMessage = "Couldn't encode the smart folder's query."; return nil
        }
        do {
            let created = try await organization.createFolder(
                name: unique, parent: nil, kind: .smart, queryJSON: json)
            rebuild()
            adoptMirrorFailure()
            return created.id
        } catch { report(error, "create the smart folder"); return nil }
    }

    /// Rename a folder. Whitespace-trimmed; empty rejected; deduped against siblings (excluding self).
    func renameFolder(_ id: UUID, to rawName: String) async {
        guard !refuseSystemFolder(id) else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { statusMessage = "A folder needs a name."; return }
        let parent = organization.folders.first { $0.id == id }?.parentId
        let unique = uniqueSiblingName(name, parent: parent, excluding: id)
        do { try await organization.renameFolder(id, to: unique); rebuild(); adoptMirrorFailure() }
        catch { report(error, "rename the folder") }
    }

    /// Move `id` under `newParent` at position `index`. `OrganizationStore.moveFolder` silently no-ops
    /// a cycle-creating move; we detect the same condition first so the user gets an explanation rather
    /// than a mystery no-op.
    func moveFolder(_ id: UUID, newParent: UUID?, at index: Int) async {
        if wouldCreateCycle(moving: id, to: newParent) {
            statusMessage = "You can't move a folder into itself or one of its own subfolders."
            return
        }
        do {
            try await organization.moveFolder(id, newParent: newParent, sortOrder: index)
            rebuild(); adoptMirrorFailure()
        } catch { report(error, "move the folder") }
    }

    /// Delete a folder (never its items). `OrganizationStore.deleteFolder` reparents children to the
    /// deleted folder's parent and returns the ids of items left in **no** folder; those remain
    /// reachable under All Notes, and we surface a status message. The batched sole-instance
    /// confirmation UI is W6-S5 (delete path, Tier-2). Returns the orphaned item ids for the caller.
    @discardableResult
    func deleteFolder(_ id: UUID) async -> [UUID] {
        guard !refuseSystemFolder(id) else { return [] }
        do {
            let orphaned = try await organization.deleteFolder(id)
            if selectedFolderId == id { setAllNotesScope() }
            rebuild()
            if !orphaned.isEmpty {
                let n = orphaned.count
                statusMessage = "\(n) item\(n == 1 ? "" : "s") \(n == 1 ? "is" : "are") no longer in any folder — find \(n == 1 ? "it" : "them") under All Notes."
            }
            adoptMirrorFailure()
            return orphaned
        } catch { report(error, "delete the folder"); return [] }
    }

    // MARK: Delete-last-instance path (W6-S5, Tier-2 — §3.6, 06-viewers §5)

    /// Items that would be **permanently deleted** (moved to Trash) by deleting `folderId`: those whose
    /// *only* membership is this folder. Read FRESH from the org graph at call time (no cached count),
    /// so a concurrent replicate in the other window can't cause a false positive (§5, analogous to
    /// TagWriter's fresh-read-inside-the-write rule). Empty ⟹ deleting the folder loses no note (its
    /// items live elsewhere too, and its subfolders are reparented, not deleted).
    func strandedByDeletingFolder(_ folderId: UUID) -> [UUID] {
        organization.items(in: folderId).filter { organization.membershipCount(item: $0) == 1 }
    }

    /// Titles for `ids` (from the shared item source), for the delete-confirmation copy. Missing items
    /// fall back to "Untitled".
    func titles(for ids: [UUID]) -> [String] {
        let byID = Dictionary(allItems.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return ids.map { byID[$0].map { $0.isEmpty ? "Untitled" : $0 } ?? "Untitled" }
    }

    /// Delete `folderId` and permanently delete (to Trash) the `stranded` sole-instance notes it held.
    /// The caller has shown + confirmed the §3.6 batched modal. Order is deliberate: remove memberships
    /// (the durable org graph) FIRST via `OrganizationStore.deleteFolder`, THEN trash the files — so if
    /// a trash fails the note is still on disk *and* discoverable under All Notes (0 memberships),
    /// never silently lost. Subfolders are reparented (never deleted) by `deleteFolder`.
    func deleteFolderDeletingStranded(_ folderId: UUID, stranded: [UUID]) async {
        // Before anything is trashed. The store refuses a system folder anyway, but its throw would
        // arrive after the caller had already shown a modal naming the notes it was about to delete —
        // and this method's whole job is to delete notes, so the refusal has to come first (W23.m15).
        guard !refuseSystemFolder(folderId) else { return }
        let orphaned: [UUID]
        do {
            orphaned = try await organization.deleteFolder(folderId)   // removes memberships, reparents children
        } catch { report(error, "delete the folder"); return }
        if selectedFolderId == folderId { setAllNotesScope() }
        // Trash ONLY items that (a) the user confirmed as stranded AND (b) are *actually* orphaned now
        // (0 memberships) — `deleteFolder` returns the fresh orphan set, so a replicate between the
        // modal and this confirm rescues its item from deletion (it keeps its other membership).
        let confirmed = Set(stranded)
        let toTrash = orphaned.filter { confirmed.contains($0) }
        // The orphan verdict must stay true until the files are gone, so the hard-delete window opens
        // here rather than inside `trashItems` alone (W23.h3-fu) — `deleteFolder` already suspended on
        // the DB, and the trash suspends again. Nested with the primitive's own window; the refcount
        // composes, and `defer` balances it on every exit path.
        organization.beginHardDelete(toTrash)
        defer { organization.endHardDelete(toTrash) }
        // Trashes, drops the rows of the ones that really went, reloads, and says so when the disk
        // refused one — that refusal is what makes this method's "still discoverable" promise real.
        await trashItems(toTrash)
        rebuild()                                                      // covers the empty case
        adoptMirrorFailure()
    }

    #if DEBUG
    /// Awaited inside `trashItems` while the hard-delete window is open and before anything has been
    /// trashed, so a test can deterministically drive a concurrent replicate/move *into* the window
    /// (W23.h3-fu). DEBUG-only and instance-scoped — same shape as `NotesIndex.executeForTesting`.
    var hardDeleteWindowHookForTesting: (@MainActor () async -> Void)?
    #endif

    /// Move the given items' folders to the macOS Trash (recoverable — `NoteStore.delete` never
    /// `removeItem`s) and drop the index rows of the ones that are **actually gone**. The caller must
    /// have already removed the items' memberships (0 remaining) — the §3.6 guard passed. Reloads the
    /// shared item list + rebuilds the tree. Returns the ids that SURVIVED (still on disk), so a
    /// caller can react; the empty array is the all-clear.
    ///
    /// W23.m12 — this used to drop the row of every *requested* id no matter what the disk said, which
    /// broke the invariant its own callers document ("a trash failure leaves the note on disk **and**
    /// discoverable under All Notes"): `reloadItems` serves the list from the index, nothing watches
    /// the store, and the full disk rebuild only runs at bootstrap — so a note the disk refused to
    /// trash vanished from All Notes for the rest of the run while sitting safe on disk, un-findable.
    /// A row now goes only once its note is provably absent.
    ///
    /// W23.h3-fu — this is the hard-delete primitive, so it holds `OrganizationStore`'s hard-delete
    /// window for the whole call: `await noteStore.delete(id)` is a suspension point, and `@MainActor`
    /// is reentrant there, so without it the other window's drag-to-folder could file a note between
    /// the caller's "zero memberships" verdict and the note actually reaching the Trash. Guarding here
    /// rather than only at the callers means a future third caller inherits it; the refcount is what
    /// lets a caller nest a wider window around this one.
    @discardableResult
    func trashItems(_ ids: [UUID]) async -> [UUID] {
        guard !ids.isEmpty else { return [] }
        organization.beginHardDelete(ids)
        defer { organization.endHardDelete(ids) }
        #if DEBUG
        // Test seam (W23.h3-fu): the deterministic way to run a concurrent mutation *inside* the
        // hard-delete window. Racing two tasks and hoping to hit a sub-millisecond gap is not a test.
        if let hook = hardDeleteWindowHookForTesting { await hook() }
        #endif
        var removed: [UUID] = []          // provably no longer on disk ⟹ their rows must go
        var survived: [UUID] = []         // the disk refused ⟹ still on disk, so keep them findable
        if let noteStore {
            for id in ids {
                do { try await noteStore.delete(id); removed.append(id) }
                catch {
                    NSLog("NotesModel: could not move note \(id) to Trash: \(error)")
                    // Ask the disk instead of classifying the error: `delete` also throws when the
                    // directory was ALREADY gone (`StoreError.notFound`, e.g. the other window got
                    // there first), and keeping THAT row would strand a phantom note pointing at
                    // nothing. So the row goes whenever the item is absent, whatever the reason, and
                    // stays only while the file is genuinely still there.
                    if await noteStore.itemExists(id) { survived.append(id) } else { removed.append(id) }
                }
            }
        } else {
            removed = ids                 // injected test store with no `noteStore`: bookkeeping only
        }
        var indexWriteFailed = false
        if let index, !removed.isEmpty {
            do { try await index.deleteItems(removed) }
            catch {
                // The files ARE in the Trash but their rows outlived them, so the list still offers
                // notes that no longer exist until the next launch rebuilds from disk. Same rule as
                // above, opposite direction: don't present a half-done delete as a clean one (W23.m9).
                NSLog("NotesModel: trashed \(removed.count) note(s) but could not delete their index rows: \(error)")
                indexWriteFailed = true
            }
        }
        await reloadItems()
        rebuild()
        // Last, so neither `reloadItems` nor `rebuild` can outrun it. A survivor outranks a stale
        // index because the note is still there to be found; `adoptMirrorFailure()` still wins in the
        // folder-delete path, which is the m10 precedence ("a real degradation wins") — both are
        // logged, and either way the note stays listed under All Notes.
        if !survived.isEmpty {
            let n = survived.count
            statusMessage = "Couldn't move \(n) note\(n == 1 ? "" : "s") to the Trash — "
                + "\(n == 1 ? "it is" : "they are") still on disk, under All Notes."
        } else if indexWriteFailed {
            statusMessage = "Moved \(removed.count) note\(removed.count == 1 ? "" : "s") to the Trash, "
                + "but the note list couldn't be updated — it will catch up on the next launch."
        }
        return survived
    }

    // MARK: Pure helpers (unit-tested)

    /// Would moving `id` under `newParent` create a cycle? True if `newParent == id` or `id` is an
    /// ancestor of `newParent`. Mirrors `OrganizationStore.wouldCreateCycle` so the view can explain a
    /// refused move; a `guardCount` cap makes it total even against a corrupt graph.
    func wouldCreateCycle(moving id: UUID, to newParent: UUID?) -> Bool {
        guard let newParent else { return false }
        if newParent == id { return true }
        let byID = Dictionary(organization.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var cursor: UUID? = newParent
        var guardCount = 0
        while let c = cursor, guardCount < 100_000 {
            if c == id { return true }
            cursor = byID[c]?.parentId
            guardCount += 1
        }
        return false
    }

    /// A sibling-unique folder name: returns `base` if no sibling under `parent` (other than
    /// `excluding`) already uses it (case-insensitively), else `base 2`, `base 3`, … until free.
    func uniqueSiblingName(_ base: String, parent: UUID?, excluding: UUID?) -> String {
        let taken = Set(organization.folders
            .filter { $0.parentId == parent && $0.id != excluding }
            .map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// Say so when an organization mutation committed but its durable mirror didn't (W23.m10).
    ///
    /// Called at the END of each organization-mutating path — last, so a real degradation wins over
    /// that path's own status text. The change itself DID commit (SQLite + in memory), so every caller
    /// still completes its UI work and still returns what it created: this only stops the app from
    /// presenting a half-saved change as saved. Never clears a message it didn't set (`statusMessage`
    /// is shared with other degradations), matching `adoptIndexFailure`.
    ///
    /// It also *retracts* its own line once the mirror is back in sync (W23.m10-fu). Before the
    /// recovery retry below, the only way to reach `mirrorFailure == nil` here was a later successful
    /// mutation, and leaving the warning up through it was merely untidy; now that a retry can heal the
    /// mirror with the operator doing nothing at all, a line still claiming the durable mirror is
    /// behind would be a false statement the app never takes back.
    func adoptMirrorFailure() {
        if let failure = organization.mirrorFailure {
            statusMessage = failure.message
            postedMirrorMessage = failure.message
        } else {
            // Only our own line — another subsystem's report must survive the mirror recovering.
            if let posted = postedMirrorMessage, statusMessage == posted { statusMessage = nil }
            postedMirrorMessage = nil
        }
    }

    /// The mirror-health line this model last put in `statusMessage`, so it can be retracted when the
    /// mirror recovers — and *only* it. The `postedIndexMessage` idiom, for the other degradation.
    private var postedMirrorMessage: String?

    /// Re-attempt a durable-mirror export that failed earlier, and update what the sidebar says
    /// (W23.m10-fu). A no-op unless `organization.isMirrorStale`, so it costs nothing on a healthy
    /// store and never rewrites `organization.json` behind the operator's back.
    ///
    /// Wired to the two moments that matter (see `observeMirrorRecoveryTriggers`), and public so the
    /// app can call it from anywhere else that turns out to be a good moment.
    func retryStaleMirrorExport() {
        guard organization.retryStaleMirrorExport() else { return }
        adoptMirrorFailure()
    }

    /// Retry the stale-mirror export when the app is **activated** and when it is about to **quit**.
    ///
    /// Activation is the moment the operator comes back to the app — the one correlated with having
    /// plugged the volume in, emptied the disk, or fixed permissions in another app — and it doubles as
    /// the re-post of a warning that was dismissed while the volume is still bad, the way a degraded
    /// index re-posts on every read (W23.m9-fu). Terminate is the last chance to write the mirror
    /// before the session ends, after which the stale file is what the next launch inherits (the DB
    /// wins at startup, so nothing else re-syncs it).
    ///
    /// Deliberately **not** a timer: this app does no background polling (the Zotero clipboard check
    /// makes the same call), and the export is a disk write — tying it to something the operator did
    /// keeps it to moments a write is expected. `queue: nil` runs the block synchronously on the
    /// poster's thread, which is what makes the terminate leg useful at all; AppKit posts both of these
    /// on the main thread, hence `assumeIsolated`.
    private func observeMirrorRecoveryTriggers() {
        let observers = NotificationObservers(center: notificationCenter)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.willTerminateNotification] {
            observers.observe(name) { [weak self] _ in
                MainActor.assumeIsolated { self?.retryStaleMirrorExport() }
            }
        }
        mirrorRecoveryObservers = observers
    }

    // MARK: Private

    /// `true` (having set the explanation) when `id` is a system folder and the caller must stop
    /// (W23.m15). The sidebar disables Rename/Delete on those rows, so this is the second of three
    /// layers — the third is `OrganizationStore`'s own throw — but it is the one that produces a
    /// sentence the user can read, since `report` would only say "Couldn't delete the folder."
    private func refuseSystemFolder(_ id: UUID) -> Bool {
        guard let name = OrganizationStore.systemFolderName(id) else { return false }
        statusMessage = "“\(name)” is a built-in folder — it can't be renamed or deleted."
        return true
    }

    private func report(_ error: Error, _ action: String) {
        statusMessage = "Couldn't \(action)."
        NSLog("NotesModel: failed to \(action): \(error)")
    }
}

/// Block-based notification observers whose lifetime is the object that owns this box (W23.m10-fu).
///
/// A separate, *non-isolated* class on purpose: a `@MainActor` type's `deinit` is nonisolated and so
/// cannot read main-actor state, and the observer tokens (`[any NSObjectProtocol]`, not `Sendable`)
/// count as exactly that. Parking them here keeps the un-registration automatic — without it, every
/// model ever built would keep observing the shared centre for the life of the process.
private final class NotificationObservers {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter) { self.center = center }

    /// `queue: nil` runs `block` **synchronously on the posting thread** — the property the terminate
    /// leg depends on, since an operation hopped onto the main queue would not run before the process
    /// exits. AppKit posts the notifications this is used for on the main thread.
    func observe(_ name: Notification.Name, using block: @escaping @Sendable (Notification) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: nil, using: block))
    }

    deinit { for token in tokens { center.removeObserver(token) } }
}
