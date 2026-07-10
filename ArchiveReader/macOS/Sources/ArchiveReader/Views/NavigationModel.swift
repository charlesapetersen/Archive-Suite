import Foundation
import Combine
import AppKit

/// A node in the sidebar folder tree, derived from discovered file paths. `path` is the absolute
/// directory path (identity); `fileCount` is the recursive number of files in the subtree.
struct FolderNode: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    var fileCount: Int
    var children: [FolderNode]
    var id: String { path }
    /// `OutlineGroup` wants `nil` (not `[]`) for leaves, so they get no disclosure triangle.
    var childrenOrNil: [FolderNode]? { children.isEmpty ? nil : children }
}

/// View model for the navigation window: owns the library + root store, the filter/sort/selection
/// state, and the (safe) actions. All tag mutations go through `TagWriter`.
@MainActor
final class NavigationModel: ObservableObject {
    let library = ArchiveLibrary()
    let rootStore = RootFolderStore()
    let indexer = ContentIndexer()
    let notes = NotesStore()
    let savedSearches = SavedSearchStore()

    @Published var filter = LibraryFilter()
    /// The text field binds to this; a debounce pipeline copies it into `filter.searchText` after
    /// a 150 ms pause so recompute doesn't fire on every keystroke at 40k+ rows.
    @Published var filterSearchText = ""
    @Published var sort = LibrarySort.default
    @Published var selection = Set<ArchiveFile.ID>() { didSet { persistSelection(); refreshSelectionCache() } }
    @Published var fullTextQuery = ""
    /// The active smart folder's base scope — the visible universe. `nil` = whole root. User
    /// `filter` narrows *within* this. Selecting a folder / All Files exits the scope.
    @Published private(set) var scope: SavedSearch?
    /// Paths matching the base scope's own OCR query. `nil` = scope has no query (or no scope).
    /// Separate from `ftsPaths` so a scoped OCR query never lights the user filter indicators.
    @Published private(set) var baseFtsPaths: Set<String>?
    private var baseFtsGeneration = 0
    // Sheet/dialog presentation lives on the model so menu commands can trigger it too.
    @Published var showingEditor = false
    @Published var showingPreview = false
    @Published var showingSaveDialog = false
    @Published var renamingSearch: SavedSearch?     // non-nil while renaming a smart folder
    @Published private(set) var focusSearchRequest = 0      // C5: menu → focus OCR search
    @Published private(set) var focusTagFilterRequest = 0   // C5: menu → focus tag filter
    func requestFocusSearch()    { focusSearchRequest &+= 1 }
    func requestFocusTagFilter() { focusTagFilterRequest &+= 1 }
    @Published private(set) var displayed: [ArchiveFile] = []
    @Published private(set) var duplicatedNames: Set<String> = []   // base names shared by ≥2 displayed rows
    @Published private(set) var selectedFilesCache: [ArchiveFile] = []
    @Published private(set) var allSubjectsCache: [String] = []
    @Published private(set) var folderTree: FolderNode?   // sidebar file tree, derived from paths
    @Published private(set) var smartFolderCounts: [UUID: Int] = [:]   // D2: files matching each saved search
    @Published private(set) var ftsPaths: Set<String>?      // nil = no full-text query active
    @Published private(set) var formatStatuses: [String: PDFFormatStatus] = [:]   // non-standard-PDF detection, per path
    @Published private(set) var needsAttentionCount = 0     // indexed files that need attention
    @Published private(set) var indexingProgress: (done: Int, total: Int)?
    @Published private(set) var undoDepth = 0
    @Published var statusMessage = ""
    // G4 keyboard triage: bumped whenever a triage action wants the newly-selected row scrolled into
    // view. The window observes the counter (so scrolling to the *same* id twice still fires) and asks
    // its ScrollViewReader to reveal `scrollTargetID`. Pure UI hint — never a file operation.
    @Published private(set) var scrollRequest = 0
    private(set) var scrollTargetID: ArchiveFile.ID?

    private var undoStack: [[TagWriteResult]] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        filter.read = AppSettings.defaultReadFilter
        filter.subjectCombine = AppSettings.defaultSubjectCombine
        restoreViewState()   // last session's filter + sort override the defaults (C2)
        filterSearchText = filter.searchText   // seed from restored state
        // ArchiveLibrary is @MainActor and only mutates `files` on the main actor, so this publisher
        // fires on main; assumeIsolated keeps the recompute on the MainActor without an async hop.
        library.$files
            // Deliver ASYNC on the main queue. @Published emits in willSet (before the property is
            // committed), so a synchronous sink would read the OLD `library.files` inside recompute()
            // — which made the list show 0 of N. receive(on:) defers until after the value commits.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.libraryDidChange() } }
            .store(in: &cancellables)
        // Debounce the filename search text — 150 ms pause before recomputing (fixes the typing
        // beachball at 40k+ rows by keeping recompute off the per-keystroke path).
        $filterSearchText
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] text in MainActor.assumeIsolated {
                guard let self, self.filter.searchText != text else { return }
                self.filter.searchText = text
            } }
            .store(in: &cancellables)
        indexer.$progress
            .sink { [weak self] p in MainActor.assumeIsolated {
                self?.indexingProgress = p
                if p == nil { self?.refreshFormatStatuses() }   // a pass just finished → fold in new detection flags
            } }
            .store(in: &cancellables)
        // Republish when notes/flags change so the table's flag column refreshes.
        notes.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
        // Republish on library changes (isGathering / scope) so the results-area spinner is reactive.
        library.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
        savedSearches.objectWillChange
            .receive(on: DispatchQueue.main)   // run after the change commits, so counts see the new set
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                self.objectWillChange.send()
                self.refreshSmartFolderCounts()
                self.reconcileScopeWithStore()
            } }
            .store(in: &cancellables)
        if let root = rootStore.root { library.start(scope: root) }
    }

    // MARK: Saved searches / scope

    func saveCurrentSearch(name: String) {
        let ef = effectiveFilter
        let eq = effectiveFullTextQuery
        savedSearches.add(name: name, filter: ef, fullTextQuery: eq)
    }

    /// The merged filter for Save/summary: when a scope is active, fold user facets onto the base.
    private var effectiveFilter: LibraryFilter {
        guard let scope else { return filter }
        return LibraryFilter.effective(base: scope.filter, user: filter)
    }
    /// The merged OCR query for Save/summary: user query wins if set, else the scope's.
    private var effectiveFullTextQuery: String {
        let uq = fullTextQuery.trimmingCharacters(in: .whitespaces)
        if !uq.isEmpty { return fullTextQuery }
        return scope?.fullTextQuery ?? ""
    }

    /// A human-readable default name for "save current filters as a smart folder", built from the
    /// active filter facets (e.g. "Unread · P8 · Jerry Brown · Batch-A").
    var suggestedSmartFolderName: String {
        let f = effectiveFilter
        var parts: [String] = []
        switch f.read {
        case .all: break
        case .read: parts.append("Read")
        case .unread: parts.append("Unread")
        case .noReadState: parts.append("No read-state")
        }
        if !f.priorities.isEmpty {
            parts.append(f.priorities.sorted(by: >).map { "P\($0)" }.joined(separator: "/"))
        }
        if !f.subjects.isEmpty {
            parts.append(f.subjects.sorted().joined(separator: f.subjectCombine == .all ? " + " : " / "))
        }
        if let p = f.pathPrefix, !p.isEmpty { parts.append(URL(fileURLWithPath: p).lastPathComponent) }
        let fn = f.searchText.trimmingCharacters(in: .whitespaces)
        if !fn.isEmpty { parts.append("name:\(fn)") }
        let q = effectiveFullTextQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append("\u{201c}\(q)\u{201d}") }
        return parts.isEmpty ? "Smart Folder" : parts.joined(separator: " \u{b7} ")
    }

    /// A human-readable summary of the active filter for the status bar (nil when nothing is filtered).
    var activeFilterSummary: String? {
        let f = effectiveFilter
        var parts: [String] = []
        if let scope { parts.append("[\(scope.name)]") }
        switch f.read {
        case .all: break
        case .read: parts.append("Read")
        case .unread: parts.append("Unread")
        case .noReadState: parts.append("No read-state")
        }
        if !f.priorities.isEmpty {
            parts.append(f.priorities.sorted(by: >).map { "P\($0)" }.joined(separator: "/"))
        }
        if !f.subjects.isEmpty {
            parts.append("tags: " + f.subjects.sorted().joined(separator: f.subjectCombine == .all ? " + " : " / "))
        }
        if let p = f.pathPrefix, !p.isEmpty { parts.append("folder: " + URL(fileURLWithPath: p).lastPathComponent) }
        let fn = f.searchText.trimmingCharacters(in: .whitespaces)
        if !fn.isEmpty { parts.append("name: \(fn)") }
        let q = effectiveFullTextQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append("text: \u{201c}\(q)\u{201d}") }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{b7} ")
    }

    /// Enter a smart-folder scope: the saved search becomes the visible universe; user filters reset.
    func applyScope(_ search: SavedSearch) {
        var f = search.filter
        let sanitized = Self.sanitizedPathPrefix(f.pathPrefix, against: rootStore.root?.path)
        if sanitized != f.pathPrefix {
            f.pathPrefix = sanitized
            statusMessage = "Smart folder's folder scope isn't under the current archive root — showing the whole root."
        }
        var s = search; s.filter = f
        scope = s
        clearUserFilters(recompute: false)
        runBaseFullTextSearch()
        recompute()
    }

    /// Reset user-applied filters to neutral (preserving the base scope). Both Clear sites call this.
    func clearUserFilters(recompute doRecompute: Bool = true) {
        filter = LibraryFilter()
        filter.read = AppSettings.defaultReadFilter
        filter.subjectCombine = AppSettings.defaultSubjectCombine
        filterSearchText = ""
        fullTextQuery = ""
        ftsGeneration += 1
        ftsPaths = nil
        if doRecompute { recompute() }
    }

    /// Run (or clear) the base scope's full-text search. Mirrors `runFullTextSearch` but uses
    /// `scope?.fullTextQuery` and writes `baseFtsPaths`/`baseFtsGeneration`.
    private func runBaseFullTextSearch() {
        let q = scope?.fullTextQuery.trimmingCharacters(in: .whitespaces) ?? ""
        baseFtsGeneration += 1
        let generation = baseFtsGeneration
        Task { [weak self] in
            guard let self else { return }
            let result: Set<String>? = q.isEmpty ? nil : await self.indexer.search(q)
            guard generation == self.baseFtsGeneration else { return }
            self.baseFtsPaths = result
            self.recompute()
        }
    }

    /// Keep the active scope in sync with the saved-search store (delete → exit, rename → refresh).
    private func reconcileScopeWithStore() {
        guard let scope else { return }
        if let current = savedSearches.searches.first(where: { $0.id == scope.id }) {
            if current != scope { self.scope = current; runBaseFullTextSearch(); recompute() }
        } else {
            // The active scope's saved search was deleted — exit the scope.
            self.scope = nil; baseFtsGeneration += 1; baseFtsPaths = nil; recompute()
        }
    }

    // MARK: Document-run convenience (opt-in; degrades when classification is absent)

    /// Extend the selection to the full document run(s) — a `Document Start` + its `Continuation`
    /// pages — for each currently-selected file, using the content index's classifications. Works
    /// over the whole library in filename order; a no-op with a note when classification is missing.
    func extendSelectionToDocumentRun() {
        let files = library.files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        let paths = files.map(\.url.path)
        let snapshot = selection                              // the selection we're extending
        let selected = Set(selectedFiles.map(\.url.path))
        guard !selected.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let cls = await self.indexer.classifications(for: paths)
            // The await releases the main actor; if the user changed the selection meanwhile, abandon
            // this stale run instead of mixing a stale snapshot with the current selection (which would
            // pollute it). The selection itself is the epoch — no separate generation counter needed.
            guard self.selection == snapshot else { return }
            let classifications = paths.map { cls[$0] }
            var newSel = snapshot
            for (i, p) in paths.enumerated() where selected.contains(p) {
                if let range = DocumentRuns.runContaining(i, classifications: classifications) {
                    for j in range { newSel.insert(files[j].id) }
                }
            }
            if newSel != self.selection {
                self.selection = newSel
                self.statusMessage = "Extended selection to document run(s)."
            } else {
                self.statusMessage = "No document-run info (classification unavailable)."
            }
        }
    }

    // MARK: Notes & flags (app-side, never written to the corpus)

    func toggleFlagSelection() { notes.toggleFlag(selectedFiles.map(\.url.path)) }

    /// Select every currently-displayed file that carries `tag` (from the tag cloud context menu).
    /// Matches on `subjects` — the same facet the tag filter uses — so it agrees with the cloud below.
    func selectFiles(withTag tag: String) {
        selection = Set(displayed.filter { $0.subjects.contains(tag) }.map(\.id))
    }
    func setNote(_ note: String, forPath path: String) { notes.setNote(note, for: path) }

    // MARK: Reading-session resume

    private var didRestoreSelection = false
    private func restoreSelectionIfNeeded() {
        guard !didRestoreSelection, !library.files.isEmpty else { return }
        didRestoreSelection = true
        let saved = Set(UserDefaults.standard.stringArray(forKey: "lastSelectionPaths") ?? [])
        guard !saved.isEmpty else { return }
        let present = Set(library.files.map(\.id)).intersection(saved)
        if !present.isEmpty { selection = present }
    }
    private func persistSelection() {
        // Cap persistence so a huge multi-select (e.g. Select All over 150k) never serializes a giant
        // array on the main actor or bloats the defaults plist; such selections aren't worth restoring.
        let paths = Array(selection)
        if paths.count <= 500 {
            UserDefaults.standard.set(paths, forKey: "lastSelectionPaths")
        } else {
            UserDefaults.standard.removeObject(forKey: "lastSelectionPaths")
        }
    }

    // MARK: Derived

    func recompute() {
        var base = library.files
        // Base scope = the visible universe (smart folder). User filter layers on top.
        if let scope {
            base = base.filter(scope.filter.matches)
            if let baseFtsPaths { base = base.filter { baseFtsPaths.contains($0.url.path) } }
            if scope.filter.needsAttentionOnly {
                base = base.filter { formatStatuses[$0.url.path]?.needsAttention == true }
            }
        }
        base = base.filter(filter.matches)
        if let ftsPaths { base = base.filter { ftsPaths.contains($0.url.path) } }
        if filter.needsAttentionOnly {
            base = base.filter { formatStatuses[$0.url.path]?.needsAttention == true }
        }
        displayed = LibrarySort.sorted(base, by: sort)
        duplicatedNames = DuplicateNames.duplicatedNames(in: displayed)   // O(n) filename-collision set
        refreshSelectionCache()   // sort order affects the selection cache too
        persistViewState()        // C2: remember filter + sort across launches
    }

    /// The detected non-standard-PDF status for a file, if the content index has seen it yet.
    func formatStatus(for path: String) -> PDFFormatStatus? { formatStatuses[path] }

    /// Whether another currently-displayed row shares this file's base name (case-insensitive) — the
    /// nav list then surfaces the containing folder to disambiguate. Read-only display aid.
    func isDuplicatedName(_ name: String) -> Bool { DuplicateNames.isDuplicated(name, in: duplicatedNames) }

    private var formatGeneration = 0
    /// Fold the content index's per-file format flags (+ the corpus needs-attention count) into the
    /// model, then recompute. Generation-guarded so a slower earlier refresh can't clobber a newer one
    /// (same pattern as `runFullTextSearch`). Triggered on library change and when an index pass finishes.
    func refreshFormatStatuses() {
        formatGeneration += 1
        let generation = formatGeneration
        let paths = library.files.map(\.url.path)
        Task { [weak self] in
            guard let self else { return }
            let statuses = await self.indexer.formatStatuses(for: paths)
            let count = await self.indexer.needsAttentionCount(among: paths)   // R-5: scope to the current library
            guard generation == self.formatGeneration else { return }   // superseded by a newer refresh
            self.formatStatuses = statuses
            self.needsAttentionCount = count
            self.recompute()
        }
    }

    // MARK: View-state persistence (C2) — filter + sort survive relaunch (selection is persisted separately)

    private struct ViewState: Codable { var filter: LibraryFilter; var sort: [ARSortDescriptor]; var scopeID: UUID? }
    private let viewStateKey = "ar.viewState"

    private func persistViewState() {
        if let d = try? JSONEncoder().encode(ViewState(filter: filter, sort: sort, scopeID: scope?.id)) {
            UserDefaults.standard.set(d, forKey: viewStateKey)
        }
    }
    private func restoreViewState() {
        guard let d = UserDefaults.standard.data(forKey: viewStateKey),
              let s = try? JSONDecoder().decode(ViewState.self, from: d) else { return }
        var f = s.filter
        f.pathPrefix = Self.sanitizedPathPrefix(f.pathPrefix, against: rootStore.root?.path)
        filter = f
        if !s.sort.isEmpty { sort = s.sort }
        // Restore the active scope (if its saved search still exists).
        if let sid = s.scopeID, let search = savedSearches.searches.first(where: { $0.id == sid }) {
            var sf = search.filter
            sf.pathPrefix = Self.sanitizedPathPrefix(sf.pathPrefix, against: rootStore.root?.path)
            var restored = search; restored.filter = sf
            scope = restored
            clearUserFilters(recompute: false)
            runBaseFullTextSearch()
        }
    }

    /// Drop a folder scope (`pathPrefix`) that isn't under `rootPath` — returns nil for a stale prefix,
    /// otherwise the prefix unchanged. Uses a path-component boundary (the same test as
    /// `LibraryFilter.matches`) so a sibling root whose path merely shares a name prefix
    /// (`Archive` vs `ArchiveBox`) doesn't keep a stale scope. When either input is nil there is
    /// nothing to validate against, so the prefix passes through untouched (preserves prior behavior).
    /// Pure/`nonisolated` so it's unit-testable off the main actor. Shared by `restoreViewState` and
    /// `applySaved`, which both restore a persisted filter that may predate a root change.
    nonisolated static func sanitizedPathPrefix(_ prefix: String?, against rootPath: String?) -> String? {
        guard let p = prefix, let rawRoot = rootPath else { return prefix }
        let root = rawRoot.hasSuffix("/") ? String(rawRoot.dropLast()) : rawRoot
        if p != root, !p.hasPrefix(root + "/") { return nil }
        return prefix
    }

    // MARK: Column-header sorting (bridges the SwiftUI Table sortOrder ↔ the descriptor model)

    /// The current multi-level sort expressed as Table sort comparators, so a clicked column header
    /// shows the active-sort chevron/direction. Derived from `sort` (the single source of truth).
    var sortComparators: [ArchiveFileComparator] {
        sort.map { ArchiveFileComparator(field: $0.field, order: $0.ascending ? .forward : .reverse) }
    }

    /// Apply a header-click sort order back into `sort` (preserving first/second-level order). The
    /// final filename/path tiebreak lives in `LibrarySort.sorted`, so no tiebreak is appended here.
    func applyTableSort(_ comparators: [ArchiveFileComparator]) {
        let d = comparators.map { ARSortDescriptor(field: $0.field, ascending: $0.order == .forward) }
        if !d.isEmpty { sort = d }   // ignore an empty order (keep the current sort)
    }

    private var ftsGeneration = 0
    /// Run (or clear) the corpus full-text search, then re-filter. AND-combined with the tag facets.
    /// A generation token ensures a slower older search can't overwrite a newer one's result.
    func runFullTextSearch() {
        let q = fullTextQuery.trimmingCharacters(in: .whitespaces)
        ftsGeneration += 1
        let generation = ftsGeneration
        Task { [weak self] in
            guard let self else { return }
            let result: Set<String>? = q.isEmpty ? nil : await self.indexer.search(q)
            guard generation == self.ftsGeneration else { return }   // superseded by a newer search
            self.ftsPaths = result
            self.recompute()
        }
    }

    /// Selected files resolved against the WHOLE library (not just filtered `displayed` rows), in sort
    /// order — so a run/filtered selection still opens/copies/marks every member. Cached (recomputed on
    /// selection / sort / library change) to avoid an O(N) scan + sort on every SwiftUI render.
    var selectedFiles: [ArchiveFile] { selectedFilesCache }

    /// Unique subject tags across the library, for filter/editor suggestions. Cached (see above).
    var allSubjects: [String] { allSubjectsCache }

    /// File-count per distinct subject across the WHOLE library (not just the displayed rows), for
    /// the near-duplicate tag finder. Counts each subject once per file. Computed on demand (the
    /// finder is opened rarely) — never on the render path.
    var subjectFileCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for f in library.files {
            for t in Set(f.subjects) { counts[t, default: 0] += 1 }
        }
        return counts
    }

    private func refreshSelectionCache() {
        let sel = selection
        selectedFilesCache = LibrarySort.sorted(library.files.filter { sel.contains($0.id) }, by: sort)
    }
    private func refreshSubjectsCache() {
        allSubjectsCache = Array(Set(library.files.flatMap(\.subjects)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Tag cloud over the *currently displayed* rows: each **subject** tag with the number of visible
    /// files carrying it, alphabetical (the view scales font size by count via log). Counts each tag
    /// once per file. Built from `subjects` (not `topicalTags`) so clicking a chip is always a valid
    /// subject filter — priority (P7–P10) and marker-color have their own dedicated controls.
    /// Date-facet-like tokens (year/month/day/decade) are excluded even if they were demoted to
    /// `subjects` during a facet collision — they clutter the cloud and have their own column.
    var tagCloud: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for f in displayed {
            for t in Set(f.subjects) where !DocumentTags.isDateFacetLike(t) {
                counts[t, default: 0] += 1
            }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    // MARK: Folder tree (sidebar)

    // Cheap change-signatures (see `LibraryChangeSignature`) so a tag edit — which never moves files and,
    // for read-state/priority, never touches subjects — doesn't rebuild path-/subject-invariant derived
    // state on every library emission (or re-run it on the Spotlight echo). A false "unchanged" only ever
    // yields a briefly-stale derived cache, self-healing on the next real change; never a data risk.
    private var pathsSig = 0, subjectsSig = 0, matchSig = 0

    /// React to a new `library.files`: rebuild only what actually changed, then recompute + index.
    private func libraryDidChange() {
        let files = library.files
        let ps = LibraryChangeSignature.paths(files)
        let pathsChanged = ps != pathsSig
        if pathsChanged { pathsSig = ps; folderTree = buildFolderTree() }            // paths → folder tree
        let ss = LibraryChangeSignature.subjects(files)
        if ss != subjectsSig { subjectsSig = ss; refreshSubjectsCache() }            // subjects → autocomplete
        let ms = LibraryChangeSignature.matchFacets(files)
        if ms != matchSig { matchSig = ms; refreshSmartFolderCounts() }              // match facets → badges
        recompute()                                     // always — a row's read-state/tags may have moved it
        indexer.startIndexing(files)                    // incremental; no-op if running
        if pathsChanged { refreshFormatStatuses() }     // format status is path-keyed; tag-only edits can't change it
        restoreSelectionIfNeeded()                      // reading-session resume
    }

    /// Scope the list to a folder subtree (nil = whole root), then recompute.
    ///
    /// Recomputes explicitly rather than leaning on `NavigationWindowView`'s `.onChange(of: filter)`:
    /// this is driven from the sidebar's `List(selection:)` binding, whose `set` runs *inside* SwiftUI's
    /// selection-commit (a mutation during a view update). `.onChange` can miss such a change (it may
    /// reconcile its tracked value to the new one before comparing), which left the highlight moving to
    /// the clicked row while the list + status bar stayed on the old scope. Recompute here is the
    /// deterministic path; the `.onChange` still covers filter-bar edits made from their own closures.
    func setFolderScope(_ path: String?) {
        let scopeWasActive = scope != nil
        if scopeWasActive { scope = nil; baseFtsGeneration += 1; baseFtsPaths = nil }
        guard scopeWasActive || filter.pathPrefix != path else { return }
        filter.pathPrefix = path
        recompute()
    }

    /// D2: recompute each smart folder's matching-file count over the whole library (cached; refreshed
    /// on library or saved-search changes, so the sidebar isn't O(searches·N) per render).
    private func refreshSmartFolderCounts() {
        var counts: [UUID: Int] = [:]
        for s in savedSearches.searches { counts[s.id] = library.files.filter(s.filter.matches).count }
        smartFolderCounts = counts
    }

    /// Build the sidebar folder tree from the discovered file paths under the archive root — no extra
    /// disk scan (stays within the tagged universe). Each node's `fileCount` is its recursive total.
    private func buildFolderTree() -> FolderNode? {
        guard let rootPath = rootStore.root?.path, !library.files.isEmpty else { return nil }
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        final class Mut { var count = 0; var children: [String: Mut] = [:] }
        let top = Mut()
        for f in library.files {
            top.count += 1                                  // recursive total at the root
            let path = f.url.path
            guard path.hasPrefix(root + "/") else { continue }
            var comps = String(path.dropFirst(root.count + 1)).split(separator: "/").map(String.init)
            guard comps.count >= 1 else { continue }
            comps.removeLast()                              // drop the file name → directory components
            var cur = top
            for c in comps {
                let child = cur.children[c] ?? { let m = Mut(); cur.children[c] = m; return m }()
                child.count += 1
                cur = child
            }
        }
        func convert(_ m: Mut, path: String, name: String) -> FolderNode {
            let kids = m.children
                .map { convert($0.value, path: path + "/" + $0.key, name: $0.key) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return FolderNode(path: path, name: name, fileCount: m.count, children: kids)
        }
        return convert(top, path: root, name: URL(fileURLWithPath: root).lastPathComponent)
    }

    // MARK: Root selection

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Archive Root"
        panel.message = "Choose the folder that contains your tagged archive PDFs."
        if panel.runModal() == .OK, let url = panel.url {
            rootStore.setRoot(url)
            // A scope from the old root can't apply to a new one.
            scope = nil; baseFtsGeneration += 1; baseFtsPaths = nil
            filter.pathPrefix = nil
            filterSearchText = filter.searchText   // sync debounced field
            // R-3: an OCR search active over the OLD corpus leaves ftsPaths holding old-root paths; once
            // the new library loads, recompute would AND the new files against those → empty/wrong
            // results while the search box + FTS indicator stay lit. Clear the full-text search so the
            // new scope starts clean. (ftsPaths is cleared directly since fullTextQuery="" makes a later
            // runFullTextSearch a no-op reset anyway.)
            fullTextQuery = ""
            ftsPaths = nil
            ftsGeneration += 1   // R-3 race: invalidate any in-flight OLD-root FTS search so its completion
                                 // (which passes the `generation == ftsGeneration` guard) can't repopulate
                                 // ftsPaths with stale old-root paths after the new library loads.
            library.start(scope: url)
        }
    }

    // MARK: Tag actions (all via TagWriter)

    func mark(_ target: ReadState) {
        let urls = selectedFiles.map(\.url)
        guard !urls.isEmpty else { return }
        var batch: [TagWriteResult] = []
        var verified: [TagWriteResult] = []
        var failures = 0
        for url in urls {
            do {
                let r = try TagWriter.setReadState(target, on: url)
                verified.append(r)               // verified ground truth (incl. no-op) — safe to display
                if !r.isNoOp { batch.append(r) }  // only real changes go on the undo stack
            } catch { failures += 1 }
        }
        // Only verified (non-throwing) writes move a row — a failed write keeps the Spotlight value and
        // must NOT vanish from a filtered view (Safety §11). The row shows TagWriter's re-read `.after`.
        library.applyVerifiedWrites(verified)
        if !batch.isEmpty { undoStack.append(batch); undoDepth = undoStack.count }
        statusMessage = failures == 0
            ? "Marked \(batch.count) \(target.rawValue)."
            : "Marked \(batch.count); \(failures) could not update."
        announce(statusMessage)
    }

    func undoLast() {
        guard let batch = undoStack.popLast() else { return }
        undoDepth = undoStack.count
        var verified: [TagWriteResult] = []
        for r in batch {
            // Undo = inverse delta applied to a FRESH read (§9), preserving any concurrent third-party
            // edit. Display the inverse-apply's own verified `.after`, not the stale stored `.before`.
            if let rr = try? TagWriter.apply(r.inverse, to: r.url) { verified.append(rr) }
        }
        library.applyVerifiedWrites(verified)
        statusMessage = "Undid \(verified.count) change\(verified.count == 1 ? "" : "s")."
    }

    // MARK: Keyboard triage (G4) — fast next/previous-unread navigation + mark-read-and-advance.
    //
    // These move the selection and, for the combined action, mark Read; ALL read-state mutation routes
    // through `mark(.read)` → `TagWriter` (with undo). They add NO new write path — the next/previous
    // helpers are pure selection math (`TriageNavigation`) and never touch a file.

    private func requestScroll(to id: ArchiveFile.ID) { scrollTargetID = id; scrollRequest &+= 1 }

    /// Select the next document still tagged `Unread` (after the current selection), scrolling it in.
    func selectNextUnread()     { advanceToUnread(forward: true) }
    /// Select the previous document still tagged `Unread` (before the current selection).
    func selectPreviousUnread() { advanceToUnread(forward: false) }

    private func advanceToUnread(forward: Bool) {
        let rows = displayed
        guard !rows.isEmpty else { statusMessage = "No documents in view."; announce(statusMessage); return }
        let ids = rows.map(\.id)
        let sel = selection
        let positions = ids.enumerated().filter { sel.contains($0.element) }.map(\.offset)
        let isUnread: (Int) -> Bool = { rows[$0].readState == .unread }
        let target = forward
            ? TriageNavigation.nextUnread(after: positions.max(), count: rows.count, isUnread: isUnread)
            : TriageNavigation.previousUnread(before: positions.min(), count: rows.count, isUnread: isUnread)
        guard let t = target else {
            statusMessage = "No unread documents in view."; announce(statusMessage); return
        }
        let id = ids[t]
        statusMessage = (sel == [id]) ? "No further unread documents." : ""
        if !statusMessage.isEmpty { announce(statusMessage) }
        selection = [id]
        requestScroll(to: id)
    }

    /// One-key triage: mark the current selection Read (audited `TagWriter` + undo), then jump to the
    /// next still-unread document. The next target is resolved BEFORE the write — the just-read rows may
    /// leave a read-state-filtered view — and excludes the current selection so we never re-land on a row
    /// we just marked. If nothing unread remains, the selection stays and `mark`'s status stands.
    func markReadAndAdvance() {
        let sel = selection
        guard !sel.isEmpty else { return }
        var target: ArchiveFile.ID?
        let rows = displayed
        if !rows.isEmpty {
            let ids = rows.map(\.id)
            let positions = ids.enumerated().filter { sel.contains($0.element) }.map(\.offset)
            let isNextUnread: (Int) -> Bool = { rows[$0].readState == .unread && !sel.contains(ids[$0]) }
            if let t = TriageNavigation.nextUnread(after: positions.max(), count: rows.count, isUnread: isNextUnread) {
                target = ids[t]
            }
        }
        mark(.read)                       // removes Unread / adds Read via TagWriter; pushes one undo step
        if let target {
            selection = [target]
            requestScroll(to: target)
        }
    }

    // MARK: Tag editing (single + group, all via TagWriter)

    /// Facet summary across the current selection, for the tag editor's tri-state display.
    var groupSummary: GroupTagSummary { GroupTagSummary(selectedFiles.map(\.tags)) }

    /// Apply one edit operation to every selected file (per-file delta), with grouped undo.
    func applyEdit(_ op: TagEditOp) {
        let files = selectedFiles
        guard !files.isEmpty else { return }
        var batch: [TagWriteResult] = []
        var verified: [TagWriteResult] = []
        var failures = 0
        for f in files {
            let delta = TagEditing.delta(for: op, given: f.tags)
            if delta.isEmpty { continue }
            do {
                let r = try TagWriter.apply(delta, to: f.url)
                verified.append(r)
                if !r.isNoOp { batch.append(r) }
            } catch { failures += 1 }
        }
        library.applyVerifiedWrites(verified)   // one O(N+M) overlay pass (was per-file O(N*M))
        if !batch.isEmpty { undoStack.append(batch); undoDepth = undoStack.count }
        statusMessage = "Edited \(batch.count) file\(batch.count == 1 ? "" : "s")"
            + (failures > 0 ? "; \(failures) could not update." : ".")
        announce(statusMessage)
    }

    // MARK: Corpus-wide tag rename (D1, Tier-2). Every file carrying `old` gets `old` removed + `new`
    // added, via the audited TagWriter — one grouped undo, partial failures surfaced, never all-or-nothing.

    @Published var renamingTag: String?     // non-nil while the rename-tag sheet is open (the old tag)
    @Published var showingSimilarTags = false   // near-duplicate subject-tag finder sheet

    /// Number of files carrying `tag` (for the rename sheet's "affects N files").
    func affectedFileCount(forTag tag: String) -> Int {
        library.files.filter { $0.subjects.contains(tag) }.count
    }

    /// Open the rename-tag sheet from a menu — seed with the active tag filter, else the top visible tag.
    func beginRenameTag() {
        renamingTag = filter.subjects.sorted().first ?? tagCloud.first?.tag
        if renamingTag == nil { statusMessage = "No tags to rename in the current view."; announce(statusMessage) }
    }

    func renameTag(from oldTag: String, to newTag: String) {
        let old = oldTag                                    // verbatim token identity — must match the
        let new = newTag.trimmingCharacters(in: .whitespaces)  // sheet's affectedFileCount(forTag: oldTag)
        guard !old.isEmpty, !new.isEmpty, new != old else { return }
        let affected = library.files.filter { $0.subjects.contains(old) }
        guard !affected.isEmpty else { statusMessage = "No files carry the tag “\(old)”."; announce(statusMessage); return }
        var batch: [TagWriteResult] = []
        var verified: [TagWriteResult] = []
        var failures = 0
        for f in affected {
            do {
                let r = try TagWriter.apply(TagDelta(add: [new], remove: [old]), to: f.url)
                verified.append(r)
                if !r.isNoOp { batch.append(r) }
            } catch { failures += 1 }
        }
        library.applyVerifiedWrites(verified)
        if !batch.isEmpty { undoStack.append(batch); undoDepth = undoStack.count }   // ONE grouped undo
        statusMessage = failures == 0
            ? "Renamed “\(old)” → “\(new)” on \(batch.count) file\(batch.count == 1 ? "" : "s")."
            : "Renamed \(batch.count); \(failures) could not update."
        announce(statusMessage)
    }

    // MARK: Inline single-file edits (from the list cells). Editing MULTIPLE files uses the ⌘I
    // group editor; these act on exactly one file, still via the audited TagWriter + grouped undo.

    func applyEdit(_ op: TagEditOp, to file: ArchiveFile) {
        applyDelta(TagEditing.delta(for: op, given: file.tags), to: file)
    }

    /// Commit an inline subject-token edit. `base` is the token set the user STARTED editing from
    /// (snapshotted by the field at edit-begin) — NOT the file's current `subjects`, which may have moved
    /// under an active edit (a Spotlight echo / group edit / undo to the same file). Diffing against the
    /// edit-start base means the delta names ONLY what the user actually changed, so `TagWriter`'s fresh
    /// read preserves any concurrent third-party tag (never dropping an untouched token). Applied as ONE
    /// delta = one write + one undo step; a no-op edit writes nothing. Subjects only — other facets stay.
    func commitSubjectEdit(from base: [String], to edited: [String], for file: ArchiveFile) {
        applyDelta(TagEditing.subjectDelta(from: base, to: edited), to: file)
    }

    func setReadStateInline(_ target: ReadState, for file: ArchiveFile) {
        do { reflect(try TagWriter.setReadState(target, on: file.url, addIfMissing: true)) }
        catch { statusMessage = "Could not update \(file.name)."; announce(statusMessage) }
    }

    /// Single-click toggle for the Read cell: Read → Unread; Unread/none → Read.
    func toggleReadState(for file: ArchiveFile) {
        setReadStateInline(file.readState == .read ? .unread : .read, for: file)
    }

    func clearReadState(for file: ArchiveFile) {
        let toks = file.tags.raw.filter { t in
            ReadState.allCases.contains { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }
        }
        applyDelta(TagDelta(remove: toks), to: file)
    }

    private func applyDelta(_ delta: TagDelta, to file: ArchiveFile) {
        guard !delta.isEmpty else { return }
        do { reflect(try TagWriter.apply(delta, to: file.url)) }
        catch { statusMessage = "Could not edit \(file.name)."; announce(statusMessage) }
    }

    /// Reflect one verified inline write in the display (overlay) and push it as its own undo step.
    private func reflect(_ r: TagWriteResult) {
        library.applyVerifiedWrites([r])
        if !r.isNoOp { undoStack.append([r]); undoDepth = undoStack.count }
    }

    /// Library data-quality snapshot (for the health popover).
    struct DataQuality: Sendable {
        var total = 0, noDate = 0, noPriority = 0, dateUncertain = 0, bothReadUnread = 0, markers = 0
    }
    var dataQuality: DataQuality {
        var q = DataQuality(); q.total = library.files.count
        for f in library.files {
            if f.tags.year == nil { q.noDate += 1 }
            if f.tags.priority == nil { q.noPriority += 1 }
            if f.tags.dateUncertain { q.dateUncertain += 1 }
            if f.color != nil { q.markers += 1 }
            let hasRead = f.tags.raw.contains { $0.caseInsensitiveCompare("Read") == .orderedSame }
            let hasUnread = f.tags.raw.contains { $0.caseInsensitiveCompare("Unread") == .orderedSame }
            if hasRead && hasUnread { q.bothReadUnread += 1 }   // corruption: both state tokens
        }
        return q
    }

    /// VoiceOver announcement (accessibility). Silent no-op if there is no key window.
    private func announce(_ message: String) {
        guard !message.isEmpty, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Existing corpus subjects that differ from `candidate` only by case — a likely typo/duplicate.
    func nearDuplicateSubjects(of candidate: String) -> [String] {
        guard AppSettings.warnNearDuplicateTags else { return [] }
        let c = candidate.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return [] }
        return allSubjects.filter { $0 != c && $0.caseInsensitiveCompare(c) == .orderedSame }
    }

    // MARK: Copy links

    func copyLinks() {
        let urls = selectedFiles.map(\.url)
        guard !urls.isEmpty else { return }
        let text = AppSettings.linkFormatter.clipboardString(for: urls)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied \(urls.count) link\(urls.count == 1 ? "" : "s")."
    }

    // MARK: Open / reveal

    func documentSelection() -> DocumentSelection {
        DocumentSelection(filePaths: selectedFiles.map(\.url.path))
    }

    /// Move the selection one row up/down the *currently displayed* list (single-select), for browsing
    /// via the preview's ↑/↓. Anchors on the current selection's position in `displayed`.
    func moveSelectionInList(_ delta: Int) {
        guard !displayed.isEmpty else { return }
        let ids = displayed.map(\.id)
        let sel = selection
        let positions = ids.enumerated().filter { sel.contains($0.element) }.map(\.offset)
        let anchor = delta < 0 ? (positions.min() ?? 0) : (positions.max() ?? -1)
        let next = max(0, min(ids.count - 1, anchor + delta))
        selection = [ids[next]]
    }

    /// Reveal (and select) the chosen files in Finder. Read-only — opens Finder pointing at the files;
    /// never moves, renames, or alters anything.
    func revealInFinder() {
        let urls = selectedFiles.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Open the selected files in their default app (e.g. Preview). Read-only — just launches/opens.
    func openInDefaultApp() {
        for url in selectedFiles.map(\.url) { NSWorkspace.shared.open(url) }
    }
}
