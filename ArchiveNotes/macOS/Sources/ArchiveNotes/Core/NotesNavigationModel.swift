// NotesNavigationModel.swift — per-window item-list view model (W6-S3/S4, 06-viewers §3/§4/§9).
//
// The shared `NotesModel` owns the org graph + the single item source (`allItems`) + the current
// folder/smart-folder scope; this object is per-window (@StateObject inside `NotesBrowserView`) and
// owns the list state that legitimately differs between the Notes and Extracts windows: the user
// filter (kind + tags + quality + date), the live keyword search, the sort, the selection, and the
// resulting `displayed` list. That split is what lets "two windows share one shell but differ by
// default kind" (06-viewers §1/§3) coexist with the single shared `NotesModel` that §16.1 mandates.
//
// W6-S4 layers onto the W6-S3 kind-filter + sort:
//   • a full `NotesFilter` (kind proxied by `kindFilter`, plus tags / qualities / date range);
//   • the shared folder/smart-folder SCOPE (`model.scope`) resolved to a subtree membership set;
//   • keyword full-text search (debounced, bm25 relevance) via `NotesModel.search`, intersected +
//     rank-ordered exactly like Reader's `NavigationModel` FTS pipeline.

import Foundation
import Combine

@MainActor
final class NotesNavigationModel: ObservableObject {
    /// Shared source of items + org graph + scope (one instance for both windows). Strong ref is safe:
    /// the shared model never references back, so there is no retain cycle.
    let model: NotesModel

    /// This window's default item kind (Notes window → `.note`, Extracts window → `.extract`). Drives
    /// "New \(kind)" + which templates "New from Template" offers (§6). Distinct from the mutable
    /// `filter.kind`, which the user can retarget via the kind picker.
    let windowKind: Item.Kind

    /// The per-window user filter: kind (proxied by `kindFilter`) + tags + qualities + date range. Its
    /// `searchText` stays empty — the live keyword field (`searchText` below) drives FTS instead of a
    /// title substring, so body matches surface; `searchText` is only folded in on "Save as Smart
    /// Folder" so a persisted smart folder reproduces from durable data without the disposable index.
    @Published var filter: NotesFilter {
        didSet {
            guard filter != oldValue else { return }
            // Remember this window's kind featuring across launches (W7-S4). Only on a kind change,
            // and only when a persistence store was injected (the real app passes `.standard`; tests
            // pass nil so they neither read nor write `UserDefaults`).
            if filter.kind != oldValue.kind, let store = kindPersistStore {
                NotesAppSettings.setWindowKindFilter(filter.kind, for: windowKind, into: store)
            }
            recompute()
        }
    }

    /// Which kinds this window shows. Proxies `filter.kind` so the segmented control's binding and the
    /// W6-S3 tests keep the stable `kindFilter` name while kind lives inside `NotesFilter` (§16.3).
    var kindFilter: KindFilter {
        get { filter.kind }
        set { filter.kind = newValue }
    }

    /// Raw keyword field text. A 150 ms debounce drives the FTS query (`runFullTextSearch`), matching
    /// Reader's as-you-type OCR search (`NavigationModel.swift:109-114`).
    @Published var searchText: String = ""

    /// Active multi-level sort (header-click drives this; `ColumnPickerHeaderView` sets the secondary).
    @Published var sort: [NoteSortDescriptor] = NotesSort.default {
        didSet { if sort != oldValue { recompute() } }
    }

    /// Filtered + sorted items for this window's table.
    @Published private(set) var displayed: [ItemSummary] = []

    /// Bumped whenever `displayed` changes, so the AppKit table rebuilds its O(N) id→row cache and
    /// diffs its snapshot only when needed (mirrors Reader's `NavigationModel.displayedGeneration`).
    @Published private(set) var displayedGeneration = 0

    /// Membership count per item id, for the "instances" column ("▣ N", blank if 1). Recomputed from
    /// the shared org graph each pass; membership mutation UI is W6-S5.
    @Published private(set) var instanceCounts: [UUID: Int] = [:]

    /// Rows selected in the table. A single-row selection loads that item into the detail pane.
    @Published var selection: Set<UUID> = []

    /// Per-window view mode: when true the item pane shows the templates manager instead of the note
    /// list (the sidebar "Templates" row / a folder's "Template ▸ Manage…" toggles it). W6-S6.
    @Published var showingTemplates = false

    /// A pending single-item **delete-last-instance** confirmation (§3.6, W6-S5). Non-nil ⟹ the view
    /// MUST present the mandatory modal before anything is deleted; `nil` = nothing pending. (The
    /// batched folder-delete variant lives on the shared tree, since folder structure is shared.)
    @Published var pendingDeletion: PendingDeletion?

    /// The item + folder whose removal would delete the item's sole remaining instance (§3.6).
    struct PendingDeletion: Identifiable, Equatable {
        let id = UUID()
        let itemId: UUID
        let folderId: UUID
        let title: String
    }

    // MARK: FTS state (keyword search)

    /// Item ids matching the active keyword query (bm25). `nil` = no active query (don't intersect).
    private var ftsIDs: Set<UUID>? = nil
    /// bm25 position map (0 = best match) for the active query; empty when no ranked query is live.
    private var ftsRank: [UUID: Int] = [:]
    /// Monotonic token so a slower older search can't overwrite a newer one's result.
    private var ftsGeneration = 0

    /// Mirror of `model.scope` (the shared folder/smart-folder selection). Kept in sync from the
    /// publisher's DELIVERED value rather than read back from `model.scope`, because `@Published`
    /// emits in `willSet` — reading `model.scope` inside the sink would see the STALE prior value.
    private var scope: NotesFilter?

    /// Where per-window kind featuring is persisted (W7-S4). `nil` ⟹ don't touch `UserDefaults` (tests);
    /// the real app injects `.standard` via `NotesBrowserView`.
    private let kindPersistStore: UserDefaults?

    private var cancellables: Set<AnyCancellable> = []

    init(model: NotesModel, defaultKind: ItemKindShell, persistingKindTo store: UserDefaults? = nil) {
        self.model = model
        let windowKind: Item.Kind = (defaultKind == .extract) ? .extract : .note
        self.windowKind = windowKind
        self.kindPersistStore = store
        // Restore this window's last-shown kind (W7-S4); fall back to the window default when never set
        // (or when no store is injected). Setting `filter` in init does NOT fire `didSet`, so restoring
        // never re-persists.
        let windowDefaultKind: KindFilter = (defaultKind == .extract) ? .extracts : .notes
        let restoredKind = store.flatMap { NotesAppSettings.windowKindFilter(for: windowKind, from: $0) }
        self.filter = NotesFilter(kind: restoredKind ?? windowDefaultKind)
        // Recompute whenever the shared item source changes (index load / refresh).
        model.$allItems
            .sink { [weak self] items in self?.recompute(items: items) }
            .store(in: &cancellables)
        // Mirror the shared folder/smart-folder scope from the DELIVERED value (fresh; `@Published`
        // emits in willSet, so reading model.scope back here would be stale), then recompute.
        model.$scope
            .sink { [weak self] newScope in
                guard let self else { return }
                self.scope = newScope
                self.recompute()
            }
            .store(in: &cancellables)
        // Debounce the keyword field → FTS as-you-type (150 ms). The generation token inside
        // runFullTextSearch() handles superseded queries. dropFirst so the initial "" doesn't search.
        $searchText
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.runFullTextSearch() }
            .store(in: &cancellables)
        recompute()
    }

    // MARK: Selection → detail

    /// The single selected item (nil unless exactly one row is selected), resolved from the shared
    /// item source. The detail pane renders this; multi-select shows no single detail.
    var selectedItemID: UUID? { selection.count == 1 ? selection.first : nil }
    var selectedSummary: ItemSummary? {
        guard let id = selectedItemID else { return nil }
        return model.allItems.first { $0.id == id }
    }

    /// Select a single item (context-menu "Open" / double-click). Loads it into the detail pane.
    func select(_ id: UUID?) {
        selection = id.map { [$0] } ?? []
    }

    // MARK: Metadata edits (W6-S7 — front-matter date + front-matter-backed Quality mirror)

    /// Set the date + precision for `id`, forwarding to the shared model (§16.1). The metadata inspector
    /// composes the canonical string for the chosen precision; the model normalizes + persists + re-indexes.
    func setDate(_ date: String?, precision: Item.DatePrecision?, for id: UUID) async {
        await model.setDate(date, precision: precision, for: id)
    }

    /// Toggle the "date uncertain" flag for `id` (italic date; still sorts by its value).
    func setDateUncertain(_ uncertain: Bool, for id: UUID) async {
        await model.setDateUncertain(uncertain, for: id)
    }

    /// Set 0...3 Quality for `id`. The model persists front matter and mirrors valid Q1...Q3 plus the
    /// date's existing Year/Month/Day/Decade facets onto this note's own `.md`; authors stay front
    /// matter only.
    func setQuality(_ quality: Int?, for id: UUID) async {
        await model.setQuality(quality, for: id)
    }

    // MARK: Sort control (from the table header)

    func setSort(_ descriptors: [NoteSortDescriptor]) {
        guard !descriptors.isEmpty else { return }
        sort = descriptors
    }

    // MARK: Filter control (from the filter bar)

    /// Reset the per-window user filter + keyword to neutral, keeping only the window's kind (the
    /// segmented control is always visible). Mirrors Reader's `clearUserFilters`
    /// (`NavigationModel.swift:239-248`): also invalidates any in-flight search and drops relevance sort.
    func clearUserFilters() {
        ftsGeneration &+= 1        // invalidate any in-flight FTS result so it can't repopulate
        ftsIDs = nil
        ftsRank = [:]
        searchText = ""
        if sort.first?.field == .relevance { sort = NotesSort.default }
        filter = NotesFilter(kind: filter.kind)   // triggers didSet → recompute (if changed)
        recompute()                                // ensure a recompute even when filter was already neutral
    }

    /// The current user filter with the live keyword folded into `searchText` (the durable title
    /// predicate) — the basis for "Save as Smart Folder".
    var currentUserFilter: NotesFilter {
        var f = filter
        f.searchText = searchText.trimmingCharacters(in: .whitespaces)
        return f
    }

    /// Persist the current effective filter (shared scope folded with this window's user filter) as a
    /// root-level smart folder (06-viewers §4, "Save as Smart Folder").
    func saveAsSmartFolder(named name: String) async {
        let effective = NotesFilter.effective(base: scope ?? NotesFilter(), user: currentUserFilter)
        await model.createSmartFolder(name: name, query: effective)
    }

    // MARK: Replication + delete-last-instance guard (W6-S5, Tier-2 — 06-viewers §5)

    /// The folders an item belongs to — the "Show all locations" inspector (§5). Only normal folders
    /// hold memberships (smart folders are queries), sorted by localized name.
    func locations(of itemId: UUID) -> [VFolder] {
        let ids = Set(model.organization.foldersContaining(item: itemId))
        return model.organization.folders
            .filter { ids.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Is `folderId` a normal (item-holding) folder? Smart folders + the All-Notes pseudo-root are
    /// queries, not containers, so a drop / "Add to Folder" onto them is refused (§5).
    func isNormalFolder(_ folderId: UUID) -> Bool {
        model.organization.folders.first { $0.id == folderId }?.kind == .normal
    }

    /// Remove `itemId` from `folderId`, guarding the delete-last-instance case (§3.6). A replicant
    /// (≥2 memberships) is removed quietly; the LAST membership sets `pendingDeletion` (**no mutation
    /// yet**) so the view shows the mandatory confirmation. `OrganizationStore.removeMembership` verifies
    /// the `(item, folder)` pair still exists and reads the count FRESH, so neither a concurrent
    /// replicate nor a concurrent move in the other window can cause a false "last instance."
    func removeMembership(_ itemId: UUID, from folderId: UUID) async {
        do {
            switch try await model.organization.removeMembership(item: itemId, folder: folderId) {
            case .removed:
                model.rebuild(); recompute(); model.adoptMirrorFailure()
            case .notPresent:
                // The other window already moved or removed this membership. Nothing to remove — resync
                // this window's view. NEVER a last instance: some *other* folder may hold the note
                // (W23.h3).
                model.rebuild(); recompute(); model.adoptMirrorFailure()
            case .wasLastInstance:
                let title = model.allItems.first { $0.id == itemId }?.title ?? ""
                pendingDeletion = PendingDeletion(itemId: itemId, folderId: folderId,
                                                  title: title.isEmpty ? "Untitled" : title)
            }
        } catch { model.statusMessage = "Couldn't remove the note from the folder." }
    }

    /// Confirm the currently-pending delete-last-instance (test/programmatic entry point). Reads
    /// `pendingDeletion`, clears it, and performs the delete. The VIEW instead calls
    /// `confirmDeletion(_:)` with the value captured when the alert was shown, because SwiftUI clears
    /// `pendingDeletion` (via the presentation binding) the instant the button is tapped — before this
    /// async work runs — so reading it back here would see `nil`.
    func confirmPendingDeletion() async {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        await confirmDeletion(pending)
    }

    /// Perform a confirmed delete-last-instance for a specific pending item. The alert may be **stale**
    /// by the time it is confirmed — the other window can replicate, move, or remove the note while it
    /// sits open — so the verdict is taken from the membership the removal *actually applied to*, in one
    /// `OrganizationStore` call, and only a genuine `.deletedLastInstance` licenses the trash. The other
    /// two outcomes KEEP the file: trashing a note that still has a live membership would strand that
    /// membership on a trashed note. Membership first, file second — a trash failure leaves a
    /// recoverable, still-findable note (§5).
    ///
    /// W23.h3-fu: the verdict is only worth as much as its shelf life. `.deletedLastInstance` means
    /// "zero memberships **now**", and the trash below is a suspension point on a reentrant actor — so
    /// the hard-delete window opens the instant the verdict lands and stays open until the note is gone,
    /// which is what keeps a replicate arriving in that gap from re-filing a note into the Trash.
    func confirmDeletion(_ pending: PendingDeletion) async {
        do {
            switch try await model.organization.removeConfirmedLastMembership(
                item: pending.itemId, folder: pending.folderId) {
            case .unlinkedNotLast:
                // A replica appeared between the modal and this confirm — just unlink; do NOT delete.
                model.rebuild(); recompute(); model.adoptMirrorFailure(); return
            case .notPresent:
                // A STALE alert: the other window already moved or removed this membership, so nothing
                // was removed here and the note may still be filed elsewhere. Keep it (W23.h3).
                model.rebuild(); recompute(); return
            case .deletedLastInstance:
                break                                   // genuinely the last — fall through to the trash
            }
        } catch { model.statusMessage = "Couldn't remove the note from the folder."; return }
        model.organization.beginHardDelete([pending.itemId])
        defer { model.organization.endHardDelete([pending.itemId]) }
        await model.trashItems([pending.itemId])
        recompute()
        // The membership removal committed; say so if it never reached organization.json (W23.m10).
        // The trash decision itself is unchanged — the note is in the macOS Trash (recoverable) and
        // the graph is consistent in SQLite; making the *durable mirror* transactional is W23.m13.
        model.adoptMirrorFailure()
    }

    /// Dismiss the confirmation without deleting anything (the default / Cancel path).
    func cancelPendingDeletion() { pendingDeletion = nil }

    /// **Replicate** items into `target` (⌥-drag / "Add to Folder…"): add a membership, leaving every
    /// existing membership intact — the DevonThink replicant (one file, K places). Refuses a non-normal
    /// target. Never deletes.
    ///
    /// A refusal now prefers the store's own sentence when it has one, because W23.h3-fu introduced a
    /// refusal the user can actually provoke — dropping a note into a folder while its confirmed delete
    /// is in flight — and "Couldn't add the note to the folder" would leave them guessing at a drag that
    /// simply did nothing.
    func replicate(_ ids: [UUID], to target: UUID) async {
        guard isNormalFolder(target) else {
            model.statusMessage = "Smart folders can't hold items directly."; return
        }
        for id in ids {
            do { try await model.organization.addMembership(item: id, folder: target) }
            catch {
                model.statusMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Couldn't add the note to the folder."
            }
        }
        model.rebuild(); recompute(); model.adoptMirrorFailure()
    }

    /// **Move** items into `target` (default drag / "Move to Folder…"), removing them from `source`.
    /// Each item moves as ONE transaction (`OrganizationStore.moveMembership`), whose insert precedes
    /// its delete so the item is never transiently member-less and the source-removal can never be the
    /// "last instance" — moving a note between folders must never trip the delete guard. When `source`
    /// is nil (drag from All Notes / a search — no single source folder) MOVE degrades to a pure add.
    /// Refuses a non-normal target.
    ///
    /// W23.m13: the source-removal failure is no longer swallowed. It used to be a bare `try?`, so a
    /// refused removal left the item in BOTH folders — a replicate — while the UI said it had moved.
    /// The transaction makes the failure total, which is what lets the message below promise the item
    /// is still exactly where it was.
    func move(_ ids: [UUID], to target: UUID, from source: UUID?) async {
        guard isNormalFolder(target) else {
            model.statusMessage = "Smart folders can't hold items directly."; return
        }
        var failed = 0
        for id in ids {
            do {
                if let source, source != target {
                    try await model.organization.moveMembership(item: id, from: source, to: target)
                } else {
                    try await model.organization.addMembership(item: id, folder: target)
                }
            } catch { failed += 1 }
        }
        if failed > 0 {
            model.statusMessage = failed == 1
                ? "Couldn't move a note to that folder — it's still where it was."
                : "Couldn't move \(failed) notes to that folder — they're still where they were."
        }
        model.rebuild(); recompute(); model.adoptMirrorFailure()
    }

    // MARK: Keyword search (FTS)

    /// Debounced entry point (from the keyword field). Runs the FTS query off the main path.
    func runFullTextSearch() {
        let (q, generation) = beginSearch()
        Task { [weak self] in await self?.applySearch(q, generation: generation) }
    }

    /// Test/direct entry point: run the current `searchText` query and await the result
    /// deterministically (bypasses the 150 ms debounce + fire-and-forget `Task`). Prefer in unit tests.
    func runSearchAwaitingResult() async {
        let (q, generation) = beginSearch()
        await applySearch(q, generation: generation)
    }

    /// Shared prologue: bump the generation token and auto-switch the sort to/from relevance while a
    /// query is active (mirrors `NavigationModel.runFullTextSearch` L457-466). Returns the trimmed
    /// query + this search's generation.
    private func beginSearch() -> (query: String, generation: Int) {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        ftsGeneration &+= 1
        if !q.isEmpty && sort.first?.field != .relevance {
            sort = [NoteSortDescriptor(field: .relevance)]
        } else if q.isEmpty && sort.first?.field == .relevance {
            sort = NotesSort.default
        }
        return (q, ftsGeneration)
    }

    /// Fold a completed FTS result into `ftsIDs`/`ftsRank` (generation-guarded) and recompute. A `nil`
    /// ranked result (empty query) clears the keyword filter. Awaitable core of `runFullTextSearch`.
    private func applySearch(_ query: String, generation: Int) async {
        let ranked: [UUID]? = query.isEmpty ? nil : await model.search(query)
        guard generation == ftsGeneration else { return }   // superseded by a newer search
        if let ranked {
            ftsIDs = Set(ranked)
            ftsRank = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
        } else {
            ftsIDs = nil
            ftsRank = [:]
        }
        recompute()
    }

    // MARK: Recompute

    /// Rebuild `displayed` from the shared item source: shared scope → per-window user filter → live
    /// keyword (FTS) intersection → order (bm25 relevance while a query is active, else `NotesSort`).
    func recompute(items: [ItemSummary]? = nil) {
        let source = items ?? model.allItems
        var base = source

        // 1. Shared scope (folder / smart-folder selection from the tree, mirrored in `scope`). A smart
        //    folder carries a full NotesFilter (title-substring + facets); a normal folder just folderId.
        if let scope {
            let scopeSet = scope.folderId.map { model.organization.subtreeItemIDs(of: $0) }
            base = base.filter { scope.matches($0, folderItemIDs: scopeSet) }
        }

        // 2. Per-window user filter (kind + tags + quality + date; searchText stays empty here).
        let userSet = filter.folderId.map { model.organization.subtreeItemIDs(of: $0) }
        base = base.filter { filter.matches($0, folderItemIDs: userSet) }

        // 3. Live keyword: intersect the bm25 FTS result (nil = no active query).
        if let ftsIDs { base = base.filter { ftsIDs.contains($0.id) } }

        // 4. Order: bm25 rank while a relevance query is live, else the multi-level NotesSort.
        let ordered: [ItemSummary]
        if !ftsRank.isEmpty, sort.first?.field == .relevance {
            ordered = base.sorted { (ftsRank[$0.id] ?? .max) < (ftsRank[$1.id] ?? .max) }
        } else {
            ordered = NotesSort.sorted(base, by: sort)
        }

        // Drop selections that no longer exist in the visible set (e.g. after a refresh / filter).
        let visibleIDs = Set(ordered.map(\.id))
        let prunedSelection = selection.intersection(visibleIDs)
        if prunedSelection != selection { selection = prunedSelection }

        instanceCounts = Dictionary(grouping: model.organization.memberships, by: \.itemId)
            .mapValues(\.count)
        displayed = ordered
        displayedGeneration &+= 1
    }
}
