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
