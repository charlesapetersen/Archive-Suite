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

    /// The per-window user filter: kind (proxied by `kindFilter`) + tags + qualities + date range. Its
    /// `searchText` stays empty — the live keyword field (`searchText` below) drives FTS instead of a
    /// title substring, so body matches surface; `searchText` is only folded in on "Save as Smart
    /// Folder" so a persisted smart folder reproduces from durable data without the disposable index.
    @Published var filter: NotesFilter { didSet { if filter != oldValue { recompute() } } }

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

    private var cancellables: Set<AnyCancellable> = []

    init(model: NotesModel, defaultKind: ItemKindShell) {
        self.model = model
        self.filter = NotesFilter(kind: (defaultKind == .extract) ? .extracts : .notes)
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
    /// yet**) so the view shows the mandatory confirmation. `OrganizationStore.removeMembership` reads
    /// the count FRESH and returns `.wasLastInstance` without mutating, so a concurrent replicate in
    /// the other window can't cause a false "last instance."
    func removeMembership(_ itemId: UUID, from folderId: UUID) async {
        do {
            switch try await model.organization.removeMembership(item: itemId, folder: folderId) {
            case .removed:
                model.rebuild(); recompute()
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

    /// Perform a confirmed delete-last-instance for a specific pending item. **Re-checks the membership
    /// count FRESH at confirm time**, not just when the modal opened: if a replicate in the other
    /// window added another instance in between, this is no longer the last one → we quietly unlink and
    /// KEEP the file (trashing it would strand the new replicant on a trashed note). Only when it is
    /// *still* the last instance do we force-remove the final membership and move the note to Trash
    /// (recoverable) + drop its index row. Membership first, file second — a trash failure leaves a
    /// recoverable, still-findable note (§5).
    func confirmDeletion(_ pending: PendingDeletion) async {
        do {
            switch try await model.organization.removeMembership(item: pending.itemId, folder: pending.folderId) {
            case .removed:
                // A replica appeared between the modal and this confirm — just unlink; do NOT delete.
                model.rebuild(); recompute(); return
            case .wasLastInstance:
                try await model.organization.forceRemoveLastMembership(item: pending.itemId, folder: pending.folderId)
            }
        } catch { model.statusMessage = "Couldn't remove the note from the folder."; return }
        await model.trashItems([pending.itemId])
        recompute()
    }

    /// Dismiss the confirmation without deleting anything (the default / Cancel path).
    func cancelPendingDeletion() { pendingDeletion = nil }

    /// **Replicate** items into `target` (⌥-drag / "Add to Folder…"): add a membership, leaving every
    /// existing membership intact — the DevonThink replicant (one file, K places). Refuses a non-normal
    /// target. Never deletes.
    func replicate(_ ids: [UUID], to target: UUID) async {
        guard isNormalFolder(target) else {
            model.statusMessage = "Smart folders can't hold items directly."; return
        }
        for id in ids {
            do { try await model.organization.addMembership(item: id, folder: target) }
            catch { model.statusMessage = "Couldn't add the note to the folder." }
        }
        model.rebuild(); recompute()
    }

    /// **Move** items into `target` (default drag / "Move to Folder…"), removing them from `source`.
    /// The target add happens FIRST (idempotent) so the item is never transiently member-less and the
    /// source-removal can never be the "last instance" — moving a note between folders must never trip
    /// the delete guard. When `source` is nil (drag from All Notes / a search — no single source
    /// folder) MOVE degrades to a pure add. Refuses a non-normal target.
    func move(_ ids: [UUID], to target: UUID, from source: UUID?) async {
        guard isNormalFolder(target) else {
            model.statusMessage = "Smart folders can't hold items directly."; return
        }
        for id in ids {
            do { try await model.organization.addMembership(item: id, folder: target) }
            catch { model.statusMessage = "Couldn't move the note to the folder."; continue }
            if let source, source != target {
                // Safe: the add above guarantees ≥2 memberships, so this returns `.removed` (never last).
                _ = try? await model.organization.removeMembership(item: id, folder: source)
            }
        }
        model.rebuild(); recompute()
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
