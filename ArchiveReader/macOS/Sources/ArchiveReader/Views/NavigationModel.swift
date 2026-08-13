import Foundation
import Combine
import AppKit
import ArchiveCore

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
    let library: ArchiveLibrary
    let rootStore: RootFolderStore
    let indexer: ContentIndexer
    let notes = NotesStore()
    let savedSearches = SavedSearchStore()
    let excludedFolders: ExcludedFoldersStore

    /// The defaults domain EVERY key this model touches is read from and written to — the fixture pin
    /// (`ARUITestRootPath`), the view state (`ar.viewState`), the resumed selection
    /// (`lastSelectionFileURLs`), and, through the two stores it owns, `archiveRootBookmark` and
    /// `ar.excludedFolders`.
    ///
    /// Injected for the reason `W26.fixturehang` records: a test that writes the pin into the
    /// process-wide `com.archivereader.app` domain and is then KILLED runs no teardown, so the pin
    /// persists into the owner's real defaults and every later launch — the owner's actual app included
    /// — starts in fixture mode pinned to a deleted `mktemp` directory. `ArchiveLibrary` and
    /// `RootFolderStore` already took an injected domain; they were unreachable from a test because the
    /// model that constructs them did not. Production passes `.standard`; only tests pass a throwaway
    /// suite.
    private let defaults: UserDefaults

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
    /// Monotonic counter incremented each time `displayed` is set (in `recompute()`). Lets the
    /// AppKit table bridge skip its O(N) `displayedByID` dictionary rebuild when `updateNSView`
    /// fires for unrelated state changes (selection, scroll, font size).
    private(set) var displayedGeneration: Int = 0
    @Published private(set) var selectedFilesCache: [ArchiveFile] = []
    @Published private(set) var allSubjectsCache: [String] = []
    @Published private(set) var folderTree: FolderNode?   // sidebar file tree, derived from paths
    @Published private(set) var smartFolderCounts: [UUID: Int] = [:]   // D2: files matching each saved search
    @Published private(set) var ftsPaths: Set<String>?      // nil = no full-text query active
    private var ftsRank: [String: Int]?    // bm25 position map (0 = best); nil = no ranked query
    /// Marked keyword-in-context OCR excerpt (see `SearchSnippet`) per matching path, for the
    /// top-ranked hits of the active full-text query. Empty when no query is active. The list reads it
    /// via `searchSnippet(for:)` to render a preview line under matching rows.
    @Published private(set) var ftsSnippets: [String: String] = [:]
    /// Page-2 `Classification:` values published by the disposable content index for nav-row display.
    /// Missing/unindexed rows stay absent and render as an em dash; classification never drives a write.
    @Published private(set) var classifications: [String: String] = [:]
    @Published private(set) var formatStatuses: [String: PDFFormatStatus] = [:]   // non-standard-PDF detection, per path
    @Published private(set) var needsAttentionCount = 0     // indexed files that need attention
    @Published private(set) var indexingProgress: (done: Int, total: Int)?
    /// Mirrored from `ContentIndexer.failure` — a degraded content index, so the status bar can say so
    /// instead of going idle over a partial or unopenable one (W23.m9). `nil` = healthy.
    @Published private(set) var indexFailure: ContentIndexer.Failure?
    @Published private(set) var undoDepth = 0
    @Published var statusMessage = ""
    // G4 keyboard triage: bumped whenever a triage action wants the newly-selected row scrolled into
    // view. The window observes the counter (so scrolling to the *same* id twice still fires) and asks
    // its ScrollViewReader to reveal `scrollTargetID`. Pure UI hint — never a file operation.
    @Published private(set) var scrollRequest = 0
    private(set) var scrollTargetID: ArchiveFile.ID?
    // W23.m4: bumped when a deep link that cited a PAGE wants the document window opened on it. Same
    // shape as `scrollRequest` — the window observes the counter (so two links to the same page both
    // fire) and calls `openWindow`, which only a View can do. Read-only w.r.t. the corpus.
    @Published private(set) var openViewerRequest = 0
    private(set) var openViewerSelection: DocumentSelection?

    // Deep-link reveal: stashed until the target is visible in library.files (gather deferral).
    private var pendingReveal: String?
    private var pendingRevealPage: Int?
    private var pendingRevealSettledMisses = 0

    /// W23.m4: app-level carrier so a DOCUMENT window can write page links. This model is the single
    /// writer (see `publishLinkTarget`), so a root switch can never leave another window citing the old
    /// archive. Weak — the context is owned by the app scene, which outlives this model.
    private weak var linkContext: ArchiveLinkContext?

    /// One undoable tag write plus the `FileIdentity` captured at the edit. Undo re-verifies §6 against
    /// this identity, so a file replaced under its path BETWEEN the edit and the undo aborts rather than
    /// re-tagging a different file. `identity` is nil when the file had no resolvable identity at edit
    /// time — undo then simply skips the §6 check, exactly as the forward write did.
    private struct UndoEntry { let result: TagWriteResult; let identity: FileIdentity? }
    private var undoStack: [[UndoEntry]] = []
    private var cancellables = Set<AnyCancellable>()

    /// `excludedFolders` defaults to the process-wide singleton, which is what production wants: the
    /// Settings scene (`OptionsView`) observes `ExcludedFoldersStore.shared`, so the model must be
    /// looking at that same object or an exclusion added in Settings would not narrow the list. A test
    /// passing a throwaway `defaults` gets its own instance on that domain instead — nothing else
    /// observes it, and nothing it persists reaches the owner's `ar.excludedFolders`.
    init(defaults: UserDefaults = .standard, excludedFolders: ExcludedFoldersStore? = nil,
         indexer: ContentIndexer = ContentIndexer()) {
        self.defaults = defaults
        self.indexer = indexer
        self.library = ArchiveLibrary(defaults: defaults)
        self.rootStore = RootFolderStore(defaults: defaults)
        self.excludedFolders = excludedFolders
            ?? (defaults === UserDefaults.standard ? .shared : ExcludedFoldersStore(defaults: defaults))
        library.setRootResolver { [weak self] in
            guard let self, let url = self.rootStore.reResolveSavedRoot() else { return nil }
            return ResolvedLibraryRoot(url: url, markerGUID: self.rootStore.rootMarker?.guid)
        }
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
        // Debounce the OCR full-text search — 150 ms pause before running the FTS5 query, so
        // results update as-you-type without firing a search on every keystroke. The generation
        // token inside runFullTextSearch() already handles superseded queries.
        $fullTextQuery
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                self?.runFullTextSearch()
            } }
            .store(in: &cancellables)
        indexer.$failure
            .sink { [weak self] f in MainActor.assumeIsolated { self?.indexFailure = f } }
            .store(in: &cancellables)
        indexer.$progress
            .sink { [weak self] p in MainActor.assumeIsolated {
                self?.indexingProgress = p
                if p == nil {
                    self?.refreshFormatStatuses()           // a pass just finished → fold in new detection flags
                    self?.refreshFullTextSearchIfActive()   // Part B: newly indexed files may now match the active query
                }
            } }
            .store(in: &cancellables)
        // Republish when notes/flags change so the table's flag column refreshes.
        notes.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
        // Republish on library changes (phase / scope) so the results-area spinner is reactive.
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
        self.excludedFolders.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                self.folderTree = self.buildFolderTree()
                self.recompute()
                self.pruneExcludedFromIndex()
            } }
            .store(in: &cancellables)
        // W23.m4: keep the app-level link target in step with the granted root — a re-grant, a switch
        // (`chooseRoot`) or a clear (Options) all flow through `rootStore`. Async on main so the sink
        // reads the COMMITTED value (`@Published` emits in willSet), same reason as the library sink.
        rootStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.publishLinkTarget() } }
            .store(in: &cancellables)
        if let root = rootStore.root {
            library.start(scope: root, markerGUID: rootStore.rootMarker?.guid)
        }
    }

    /// Retry a root bookmark after an ejection/mount event, then apply the no-timer fallback for a
    /// volume that cannot provide FSEvents. Called from the navigation window's activation notice.
    func applicationDidBecomeActive(now: Date = Date()) {
        if rootStore.root == nil, rootStore.hasSavedBookmark {
            if let restored = rootStore.reResolveSavedRoot() {
                library.start(scope: restored, markerGUID: rootStore.rootMarker?.guid)
            }
            return
        }
        library.revalidateOnActivation(now: now)
    }

    /// Adopt the app-level link context and seed it with the current root (the store resolved its saved
    /// bookmark in `init`, before the subscription above existed). Called by the navigation window.
    func attach(linkContext: ArchiveLinkContext) {
        self.linkContext = linkContext
        publishLinkTarget()
    }

    /// Mirror the granted root + marker into the app-level context, so any window can build a durable
    /// link. Clears it when either is missing — a link with no marker GUID isn't portable.
    private func publishLinkTarget() {
        linkContext?.update(rootPath: rootStore.discoveredPathPrefix, marker: rootStore.rootMarker)
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
        let sanitized = Self.sanitizedPathPrefix(f.pathPrefix, against: rootStore.discoveredPathPrefix)
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
        ftsRank = nil
        ftsSnippets = [:]
        if sort.first?.field == .relevance { sort = LibrarySort.default }
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
            let result: Set<String>? = q.isEmpty ? nil : Set(await self.indexer.search(q))
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

    /// Spelled once so the read, the write and the removal cannot drift apart — the three-call-sites,
    /// two-spellings defect `W26.fixturehang` found in `ArchiveLibrary`.
    private static let selectionKey = "lastSelectionFileURLs"

    private var didRestoreSelection = false
    private func restoreSelectionIfNeeded() {
        guard !didRestoreSelection, !library.files.isEmpty else { return }
        didRestoreSelection = true
        let saved = Set((defaults.stringArray(forKey: Self.selectionKey) ?? [])
            .compactMap(URL.init(string:)))
        guard !saved.isEmpty else { return }
        let present = Set(library.files.map(\.id)).intersection(saved)
        if !present.isEmpty { selection = present }
    }
    private func persistSelection() {
        // Cap persistence so a huge multi-select (e.g. Select All over 150k) never serializes a giant
        // array on the main actor or bloats the defaults plist; such selections aren't worth restoring.
        let paths = selection.map(\.absoluteString)
        if paths.count <= 500 {
            defaults.set(paths, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }

    // MARK: Derived

    func recompute() {
        var base = library.files
        // Exclude user-designated folders before any other filtering.
        if let rootPath = rootStore.discoveredPathPrefix, !excludedFolders.excludedRelativePaths.isEmpty {
            base = base.filter { !excludedFolders.isExcludedAbsolute($0.url.path, rootPath: rootPath) }
        }
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
        if let ftsRank, sort.first?.field == .relevance {
            // bm25 relevance ordering: sort by the rank map (0 = best match).
            displayed = base.sorted { (ftsRank[$0.url.path] ?? Int.max) < (ftsRank[$1.url.path] ?? Int.max) }
        } else {
            displayed = LibrarySort.sorted(base, by: sort)
        }
        displayedGeneration += 1
        _tagCloudCache = nil
        duplicatedNames = DuplicateNames.duplicatedNames(in: displayed)   // O(n) filename-collision set
        refreshSelectionCache()   // sort order affects the selection cache too
        persistViewState()        // C2: remember filter + sort across launches
    }

    /// The detected non-standard-PDF status for a file, if the content index has seen it yet.
    func formatStatus(for path: String) -> PDFFormatStatus? { formatStatuses[path] }

    /// Box/Folder/Document Start/Continuation from the content index, for the optional provenance column.
    func classification(for path: String) -> String? { classifications[path] }

    /// Whether another currently-displayed row shares this file's base name (case-insensitive) — the
    /// nav list then surfaces the containing folder to disambiguate. Read-only display aid.
    func isDuplicatedName(_ name: String) -> Bool { DuplicateNames.isDuplicated(name, in: duplicatedNames) }

    private var formatGeneration = 0
    /// Fold the content index's per-file classification + format flags (+ needs-attention count) into
    /// the model, then recompute. Generation-guarded so a slower earlier refresh can't clobber a newer one
    /// (same pattern as `runFullTextSearch`). Triggered on library change and when an index pass finishes.
    func refreshFormatStatuses() {
        formatGeneration += 1
        let generation = formatGeneration
        let paths = library.files.map(\.url.path)
        Task { [weak self] in
            guard let self else { return }
            let statuses = await self.indexer.formatStatuses(for: paths)
            let classifications = await self.indexer.classifications(for: paths)
            let count = await self.indexer.needsAttentionCount(among: paths)   // R-5: scope to the current library
            guard generation == self.formatGeneration else { return }   // superseded by a newer refresh
            self.formatStatuses = statuses
            self.classifications = classifications
            self.needsAttentionCount = count
            self.recompute()
        }
    }

    // MARK: View-state persistence (C2) — filter + sort survive relaunch (selection is persisted separately)

    private struct ViewState: Codable { var filter: LibraryFilter; var sort: [ARSortDescriptor]; var scopeID: UUID? }
    private let viewStateKey = "ar.viewState"

#if DEBUG
    /// True when the app was launched for UI testing (`-ARUITestRootPath` set). The UITest build
    /// shares its bundle ID — and therefore its sandbox UserDefaults container — with the owner's
    /// real Archive Reader. So view-state (filter/sort/scope) must NOT be restored (it would inherit
    /// the owner's live filter, e.g. a `read=unread` filter that hides the whole fixture → 0 rows)
    /// nor persisted (it would clobber the owner's saved view-state). Tests start from clean defaults.
    ///
    /// Read from the INJECTED domain, and that is load-bearing rather than tidiness. This guard used to
    /// be the only thing keeping unit tests off the owner's real `ar.viewState`, and it worked purely
    /// because those tests wrote the pin into `.standard` — the very leak `W26.fixturehang` is about.
    /// Moving them onto a throwaway suite without moving this read would have made the guard read
    /// `nil`, turned every such test into "not a UI test", and started clobbering the owner's saved
    /// filter/sort. With both on `defaults`, the pin and the state it suppresses live in one domain.
    private var isUITestMode: Bool { defaults.string(forKey: fixtureRootKey) != nil }
    private let fixtureRootKey = "ARUITestRootPath"
#endif

    private func persistViewState() {
#if DEBUG
        if isUITestMode { return }   // never write the owner's shared view-state during a UI test
#endif
        // Never persist .relevance — it's transient (active only while a query is live).
        let persistedSort = sort.first?.field == .relevance ? LibrarySort.default : sort
        if let d = try? JSONEncoder().encode(ViewState(filter: filter, sort: persistedSort, scopeID: scope?.id)) {
            defaults.set(d, forKey: viewStateKey)
        }
    }
    private func restoreViewState() {
#if DEBUG
        if isUITestMode { return }   // clean defaults for deterministic tests; don't inherit owner state
#endif
        guard let d = defaults.data(forKey: viewStateKey),
              let s = try? JSONDecoder().decode(ViewState.self, from: d) else { return }
        var f = s.filter
        f.pathPrefix = Self.sanitizedPathPrefix(f.pathPrefix, against: rootStore.discoveredPathPrefix)
        filter = f
        // Coerce a persisted .relevance (stale from an older build) to the default sort.
        if !s.sort.isEmpty { sort = s.sort.first?.field == .relevance ? LibrarySort.default : s.sort }
        // Restore the active scope (if its saved search still exists).
        if let sid = s.scopeID, let search = savedSearches.searches.first(where: { $0.id == sid }) {
            var sf = search.filter
            sf.pathPrefix = Self.sanitizedPathPrefix(sf.pathPrefix, against: rootStore.discoveredPathPrefix)
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

    private var ftsGeneration = 0
    /// Run (or clear) the corpus full-text search, then re-filter. AND-combined with the tag facets.
    /// A generation token ensures a slower older search can't overwrite a newer one's result.
    /// Results are returned in **bm25 relevance order** and fed into `ftsRank` so `recompute()` can
    /// sort by relevance when `.relevance` is the active sort.
    func runFullTextSearch() {
        let q = fullTextQuery.trimmingCharacters(in: .whitespaces)
        ftsGeneration += 1
        let generation = ftsGeneration
        // Auto-select relevance sort while a query is active; fall back when cleared.
        if !q.isEmpty && sort.first?.field != .relevance {
            sort = [ARSortDescriptor(field: .relevance)]
        } else if q.isEmpty && sort.first?.field == .relevance {
            sort = LibrarySort.default
        }
        Task { [weak self] in
            guard let self else { return }
            let result: ContentIndex.RankedSearch? = q.isEmpty ? nil : await self.indexer.searchRanked(q)
            guard generation == self.ftsGeneration else { return }   // superseded by a newer search
            if let result {
                self.ftsPaths = Set(result.paths)
                self.ftsRank = Dictionary(uniqueKeysWithValues: result.paths.enumerated().map { ($1, $0) })
                self.ftsSnippets = result.snippets
            } else {
                self.ftsPaths = nil
                self.ftsRank = nil
                self.ftsSnippets = [:]
            }
            self.recompute()
        }
    }

    /// Highlight segments for the active query's keyword-in-context snippet of `path`, or `nil` when
    /// there is no active full-text query, no snippet for the path (a deep hit past the snippet cap, or
    /// an empty-body doc), or the snippet carries no highlighted match. The list cell renders the
    /// returned runs as a dimmed second line under the file name.
    func searchSnippet(for path: String) -> [SearchSnippet.Segment]? {
        guard ftsPaths != nil, let raw = ftsSnippets[path], !raw.isEmpty else { return nil }
        let segments = SearchSnippet.segments(from: raw)
        return SearchSnippet.hasMatch(segments) ? segments : nil
    }

    /// Re-run any active full-text search after an index pass completes (Part B: search-during-index
    /// refresh). The pass may have indexed files that now match the query but were upserted after the
    /// original search ran — re-querying folds them in. Also refreshes the base scope's OCR query.
    private func refreshFullTextSearchIfActive() {
        if !fullTextQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            runFullTextSearch()
        }
        if let scope, !scope.fullTextQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            runBaseFullTextSearch()
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
    private var _tagCloudCache: [(tag: String, count: Int)]?
    var tagCloud: [(tag: String, count: Int)] {
        if let cached = _tagCloudCache { return cached }
        var counts: [String: Int] = [:]
        for f in displayed {
            for t in Set(f.subjects) where !DocumentTags.isDateFacetLike(t) {
                counts[t, default: 0] += 1
            }
        }
        let result = counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
        _tagCloudCache = result
        return result
    }

    // MARK: Folder tree (sidebar)

    // Cheap change-signatures (see `LibraryChangeSignature`) so a tag edit — which never moves files and,
    // for read-state/priority, never touches subjects — doesn't rebuild path-/subject-invariant derived
    // state on every library emission (or re-run it on a repeat emission from a re-walk). A false
    // "unchanged" only ever
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
        // Filter excluded folders before indexing so excluded files are never added to the content index.
        let filesToIndex: [ArchiveFile]
        if let rootPath = rootStore.discoveredPathPrefix, !excludedFolders.excludedRelativePaths.isEmpty {
            filesToIndex = files.filter { !excludedFolders.isExcludedAbsolute($0.url.path, rootPath: rootPath) }
        } else {
            filesToIndex = files
        }
        indexer.startIndexing(filesToIndex)             // incremental; no-op if running
        if pathsChanged { refreshFormatStatuses() }     // format status is path-keyed; tag-only edits can't change it
        restoreSelectionIfNeeded()                      // reading-session resume
        applyPendingRevealIfPossible()                  // deep-link reveal deferral
        // Prune stale index rows — separate from startIndexing (a destructive delete must never ride
        // a harmless-on-empty indexing emission). Gated: settled + non-empty + root known.
        // Uses filesToIndex (excludes user-excluded folders) so excluded paths are eligible for pruning.
        //
        // `phase.isSettled` is strictly narrower than the `!isGathering` it replaced (plan §7a.4): a
        // revalidating OR degraded pass now blocks pruning too, because both hand over a snapshot that
        // omits files they merely failed to reach — and `pruneIfSettled` treats every omission as a
        // deletion candidate.
        if library.phase.isSettled, !filesToIndex.isEmpty, let rootPath = rootStore.discoveredPathPrefix {
            indexer.pruneIfSettled(currentPaths: Set(filesToIndex.map(\.url.path)), rootPrefix: rootPath)
        }
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

    // MARK: Deep-link reveal (archivereader://reveal)

    /// Reveal and select a file identified by a deep link. Exits any active scope/filter so the
    /// target is visible, then selects and scrolls to it. If the library is still gathering, the
    /// reveal is deferred until the target appears (or settled-absence gives up).
    func revealAndSelect(rootGUID: UUID, relativePath: String, page: Int?) {
        guard let rootPath = rootStore.discoveredPathPrefix else {
            statusMessage = "No archive folder is open. Choose one in File ▸ Choose Archive Folder…"
            return
        }
        // An open root whose identity is degraded can't be compared against — say why, rather than
        // blaming the link for pointing somewhere else. (W23.m6)
        guard let marker = rootStore.rootMarker else {
            statusMessage = rootStore.markerState.degradation?.message
                ?? "This archive folder has no identity to match the link against."
            return
        }
        guard marker.guid == rootGUID else {
            statusMessage = "This link points at a different archive. Choose it in File ▸ Choose Archive Folder…"
            return
        }
        // Built from the spelling the LIBRARY holds, because that is what `applyPendingRevealIfPossible`
        // matches `$0.url.path` against. Composed from the root URL, this reported "Document not found
        // in the current archive" for a file visible on screen under any root whose spelling differs
        // from its resolved one. (`W26.symroot-fu1`.)
        // Joined as STRINGS, not through `URL(fileURLWithPath:)`: that initialiser normalises composed
        // Unicode, so on a volume storing a decomposed name it would produce a spelling the walk never
        // emitted and the match below would miss — trading this item's bug for `W26.idx`'s. The same
        // joiner `ExcludedFoldersStore` uses.
        let targetPath = rootPath + "/" + relativePath
        pendingReveal = targetPath
        pendingRevealPage = page
        pendingRevealSettledMisses = 0
        // Exit any narrowing so the target is visible.
        clearUserFilters(recompute: false)
        if scope != nil { setFolderScope(nil) }
        recompute()
        applyPendingRevealIfPossible()
    }

    /// Try to select the pending reveal target. Called after recompute and after each
    /// `libraryDidChange` emission. Gives up after 3 settled (non-gathering) misses.
    func applyPendingRevealIfPossible() {
        guard let targetPath = pendingReveal else { return }
        // Check if the target is in the current library files.
        if let file = library.files.first(where: { $0.url.path == targetPath }) {
            selection = [file.id]
            requestScroll(to: file.id)
            statusMessage = ""
            // W23.m4 defect 3: a link that cited a PAGE has to land ON that page. Selecting the row and
            // dropping `pendingRevealPage` — which is all this did — silently discarded the page half of
            // every `reader-page` citation Notes writes (the reveal contract in
            // `execution-plans/archive-notes/00-overview.md` §8.3 requires it be passed on). Ask the
            // window to open the viewer there; a link with no page keeps the plain select-and-scroll.
            if let page = pendingRevealPage {
                requestOpenViewer(DocumentSelection(filePaths: [file.url.path], initialPage: page))
            }
            pendingReveal = nil
            pendingRevealPage = nil
            pendingRevealSettledMisses = 0
            return
        }
        // Only an authoritative settled pass may count an absence. A revalidating pass is unfinished,
        // and a degraded pass may have omitted the target merely because it could not reach it — counting
        // either one as a miss would turn "I could not look" back into "the document is not here" after
        // three retries, the same category error W26 removes from discovery.
        guard library.phase.isSettled else { return }
        // Settled but target not found — increment the confirmation counter.
        pendingRevealSettledMisses += 1
        if pendingRevealSettledMisses >= 3 {
            statusMessage = "Document not found in the current archive."
            pendingReveal = nil
            pendingRevealPage = nil
            pendingRevealSettledMisses = 0
        }
    }

    /// D2: recompute each smart folder's matching-file count over the whole library (cached; refreshed
    /// on library or saved-search changes, so the sidebar isn't O(searches·N) per render).
    private func refreshSmartFolderCounts() {
        var files = library.files
        if let rootPath = rootStore.discoveredPathPrefix, !excludedFolders.excludedRelativePaths.isEmpty {
            files = files.filter { !excludedFolders.isExcludedAbsolute($0.url.path, rootPath: rootPath) }
        }
        var counts: [UUID: Int] = [:]
        for s in savedSearches.searches { counts[s.id] = files.filter(s.filter.matches).count }
        smartFolderCounts = counts
    }

    /// Build the sidebar folder tree from the discovered file paths under the archive root — no extra
    /// disk scan (stays within the tagged universe). Each node's `fileCount` is its recursive total.
    private func buildFolderTree() -> FolderNode? {
        guard let rootPath = rootStore.discoveredPathPrefix, !library.files.isEmpty else { return nil }
        let root = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        final class Mut { var count = 0; var children: [String: Mut] = [:] }
        let top = Mut()
        let hasExclusions = !excludedFolders.excludedRelativePaths.isEmpty
        for f in library.files {
            let path = f.url.path
            if hasExclusions, excludedFolders.isExcludedAbsolute(path, rootPath: rootPath) { continue }
            top.count += 1                                  // recursive total at the root
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
            // A refused pick used to be an `NSLog` and nothing else — no root, no scan, and a window
            // that looked exactly as it had before the panel opened. Say why, and leave the previous
            // root's view state alone rather than tearing it down for a root we did not get.
            // (`W26.symroot-fu1`.)
            if let refusal = rootStore.setRoot(url) {
                statusMessage = refusal.message
                announce(statusMessage)
                return
            }
            // Scan the root we ADOPTED, which is not necessarily the URL that was picked: a symlinked
            // pick is adopted as its target, because a security-scoped bookmark cannot open a link.
            guard let adopted = rootStore.root else { return }
            // A scope from the old root can't apply to a new one.
            scope = nil; baseFtsGeneration += 1; baseFtsPaths = nil
            indexer.resetPruneState()   // old root's pending-prune set is invalid for the new root
            filter.pathPrefix = nil
            filterSearchText = filter.searchText   // sync debounced field
            // R-3: an OCR search active over the OLD corpus leaves ftsPaths holding old-root paths; once
            // the new library loads, recompute would AND the new files against those → empty/wrong
            // results while the search box + FTS indicator stay lit. Clear the full-text search so the
            // new scope starts clean. (ftsPaths is cleared directly since fullTextQuery="" makes a later
            // runFullTextSearch a no-op reset anyway.)
            fullTextQuery = ""
            ftsPaths = nil
            ftsRank = nil
            ftsSnippets = [:]
            if sort.first?.field == .relevance { sort = LibrarySort.default }
            ftsGeneration += 1   // R-3 race: invalidate any in-flight OLD-root FTS search so its completion
                                 // (which passes the `generation == ftsGeneration` guard) can't repopulate
                                 // ftsPaths with stale old-root paths after the new library loads.
            library.start(scope: adopted, markerGUID: rootStore.rootMarker?.guid)
        }
    }

    /// Re-walk the granted archive folder (File ▸ Rescan Archive Folder, ⌘⌥R).
    ///
    /// External changes normally arrive through `CorpusWatcher`. This read-only command remains the
    /// immediate recovery path when the event channel is unavailable or the operator wants a full proof.
    func rescan() {
        guard rootStore.root != nil else {
            statusMessage = "No archive folder is open. Choose one in File ▸ Choose Archive Folder…"
            announce(statusMessage)
            return
        }
        library.rescan()
        statusMessage = "Rescanning \(library.scopeDescription)…"
        announce(statusMessage)
    }

    /// Immediately prune content-index rows under any excluded folder prefix.
    /// Called when the exclusion list changes so search results don't lag the display filter.
    private func pruneExcludedFromIndex() {
        guard let rootPath = rootStore.discoveredPathPrefix, !excludedFolders.excludedRelativePaths.isEmpty else { return }
        let prefixes = excludedFolders.absolutePrefixes(rootPath: rootPath)
        indexer.pruneExcluded(prefixes: prefixes)
    }

    // MARK: Tag actions (all via TagWriter)

    /// Cache rows are useful for instant display, never for choosing write targets. Re-read only the
    /// cache-provenance subset before a bulk operation derives its selection/deltas; disk rows from
    /// this process can proceed directly. A now-untracked/unreadable/missing path is omitted, never
    /// coerced into an empty tag array and never written merely because an old cache row named it.
    private func reverifyCacheRows(_ files: [ArchiveFile]) -> (files: [ArchiveFile], rejected: Int) {
        var verified: [ArchiveFile] = []
        var rejected = 0
        for file in files {
            guard file.provenance.isCache else { verified.append(file); continue }
            // Against `LibraryIndexPath(root)` this rejected every cache row under any root whose
            // spelling differs from the one the walker reports — a bulk tag write would have dropped
            // all of them. It was MASKED until now: `publishWarmSnapshot` filtered on the same
            // mistaken comparison, so no `.cache` row ever reached `files` to be rejected here. The
            // two had to move together, and this is the half with a write behind it.
            // (`W26.symroot-fu1`.)
            guard let rootPath = rootStore.discoveredPathPrefix,
                  LibraryIndexPath(file.url).isContained(in: LibraryIndexPath(rootPath)) else {
                rejected += 1
                continue
            }
            guard case let .tracked(entry) = CorpusWalker.inspect(file.url) else {
                rejected += 1
                continue
            }
            verified.append(ArchiveLibrary.row(entry, tagNames: entry.tagNames,
                                               labelNumber: entry.labelNumber))
        }
        return (verified, rejected)
    }

    private func reverifyCacheRow(_ file: ArchiveFile) -> ArchiveFile? {
        let result = reverifyCacheRows([file])
        guard let verified = result.files.first else {
            statusMessage = "Could not verify \(file.name)."
            announce(statusMessage)
            return nil
        }
        return verified
    }

    func mark(_ target: ReadState) {
        let reverified = reverifyCacheRows(selectedFiles)
        let files = reverified.files
        guard !files.isEmpty else {
            if reverified.rejected > 0 {
                statusMessage = "Could not verify \(reverified.rejected) selected file"
                    + (reverified.rejected == 1 ? "." : "s.")
                announce(statusMessage)
            }
            return
        }
        var batch: [UndoEntry] = []
        var verified: [TagWriteResult] = []
        var failures = reverified.rejected
        for f in files {
            let identity = f.liveIdentity()   // §6: capture lazily at edit time, per selected file
            do {
                let r = try TagWriter.setReadState(target, on: f.url, expecting: identity)
                verified.append(r)               // verified ground truth (incl. no-op) — safe to display
                if !r.isNoOp { batch.append(UndoEntry(result: r, identity: identity)) }  // real changes → undo
            } catch { failures += 1 }
        }
        // Only verified (non-throwing) writes move a row — a failed write keeps the last-discovered value and
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
        for entry in batch {
            // Undo = OCCURRENCE-AWARE inverse applied to a FRESH read (§9), preserving any concurrent
            // third-party edit AND restoring a duplicated tag's exact count (W15.tu2 — the set-based
            // `.inverse` collapses `["A","A"]`→`["A"]`; `.occurrenceInverse` + `applyOccurrence` do not).
            // Display the inverse-apply's own verified `.after`, not the stale stored `.before`.
            // §6: re-verify against the identity captured at the ORIGINAL edit so undo never re-tags a
            // file swapped under this path since then (a mismatch throws → try? skips just that file).
            if let rr = try? TagWriter.applyOccurrence(entry.result.occurrenceInverse, to: entry.result.url, expecting: entry.identity) {
                verified.append(rr)
            }
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

    /// W23.m4: ask the navigation window to open a document window on this selection (page included).
    /// A counter, like `requestScroll`, so two links to the same page both fire.
    private func requestOpenViewer(_ selection: DocumentSelection) {
        openViewerSelection = selection
        openViewerRequest &+= 1
    }

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
        let reverified = reverifyCacheRows(selectedFiles)
        let files = reverified.files
        guard !files.isEmpty else {
            if reverified.rejected > 0 {
                statusMessage = "Could not verify \(reverified.rejected) selected file"
                    + (reverified.rejected == 1 ? "." : "s.")
                announce(statusMessage)
            }
            return
        }
        var batch: [UndoEntry] = []
        var verified: [TagWriteResult] = []
        var failures = reverified.rejected
        for f in files {
            let delta = TagEditing.delta(for: op, given: f.tags)
            if delta.isEmpty { continue }
            let identity = f.liveIdentity()   // §6: capture lazily at edit time, per selected file
            do {
                let r = try TagWriter.apply(delta, to: f.url, expecting: identity)
                verified.append(r)
                if !r.isNoOp { batch.append(UndoEntry(result: r, identity: identity)) }
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
        let reverified = reverifyCacheRows(library.files.filter { $0.subjects.contains(old) })
        let affected = reverified.files
        guard !affected.isEmpty else {
            statusMessage = reverified.rejected > 0
                ? "Could not verify \(reverified.rejected) matching file"
                    + (reverified.rejected == 1 ? "." : "s.")
                : "No files carry the tag “\(old)”."
            announce(statusMessage)
            return
        }
        var batch: [UndoEntry] = []
        var verified: [TagWriteResult] = []
        var failures = reverified.rejected
        // Capture each affected file's identity lazily (§6), then run the conditional fresh-read rename
        // independently. A file replaced under its path or no longer carrying `old` is never retagged;
        // one failure does not stop its neighbours.
        let items = affected.map { (url: $0.url, identity: $0.liveIdentity()) }
        for (i, item) in items.enumerated() {
            switch Result(catching: {
                try TagWriter.renameToken(from: old, to: new, on: item.url,
                                          expecting: item.identity)
            }) {
            case .success(let r):
                verified.append(r)
                if !r.isNoOp { batch.append(UndoEntry(result: r, identity: items[i].identity)) }
            case .failure:
                failures += 1
            }
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
        guard let file = reverifyCacheRow(file) else { return }
        applyDelta(TagEditing.delta(for: op, given: file.tags), to: file)
    }

    /// Commit an inline subject-token edit. `base` is the token set the user STARTED editing from
    /// (snapshotted by the field at edit-begin) — NOT the file's current `subjects`, which may have moved
    /// under an active edit (a repeat emission from a re-walk / group edit / undo to the same file).
    /// Diffing against the
    /// edit-start base means the delta names ONLY what the user actually changed, so `TagWriter`'s fresh
    /// read preserves any concurrent third-party tag (never dropping an untouched token). Applied as ONE
    /// delta = one write + one undo step; a no-op edit writes nothing. Subjects only — other facets stay.
    func commitSubjectEdit(from base: [String], to edited: [String], for file: ArchiveFile) {
        guard let file = reverifyCacheRow(file) else { return }
        applyDelta(TagEditing.subjectDelta(from: base, to: edited), to: file)
    }

    func setReadStateInline(_ target: ReadState, for file: ArchiveFile) {
        guard let file = reverifyCacheRow(file) else { return }
        let identity = file.liveIdentity()   // §6: capture lazily at edit time
        do { reflect(try TagWriter.setReadState(target, on: file.url, addIfMissing: true, expecting: identity), identity: identity) }
        catch { statusMessage = "Could not update \(file.name)."; announce(statusMessage) }
    }

    /// Single-click toggle for the Read cell: Read → Unread; Unread/none → Read.
    func toggleReadState(for file: ArchiveFile) {
        guard let file = reverifyCacheRow(file) else { return }
        setReadStateInline(file.readState == .read ? .unread : .read, for: file)
    }

    func clearReadState(for file: ArchiveFile) {
        guard let file = reverifyCacheRow(file) else { return }
        let toks = file.tags.raw.filter { t in
            ReadState.allCases.contains { $0.rawValue.caseInsensitiveCompare(t) == .orderedSame }
        }
        applyDelta(TagDelta(remove: toks), to: file)
    }

    private func applyDelta(_ delta: TagDelta, to file: ArchiveFile) {
        guard !delta.isEmpty else { return }
        guard let file = reverifyCacheRow(file) else { return }
        let identity = file.liveIdentity()   // §6: capture lazily at edit time
        do { reflect(try TagWriter.apply(delta, to: file.url, expecting: identity), identity: identity) }
        catch { statusMessage = "Could not edit \(file.name)."; announce(statusMessage) }
    }

    /// Reflect one verified inline write in the display (overlay) and push it as its own undo step.
    private func reflect(_ r: TagWriteResult, identity: FileIdentity?) {
        library.applyVerifiedWrites([r])
        if !r.isNoOp { undoStack.append([UndoEntry(result: r, identity: identity)]); undoDepth = undoStack.count }
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

    func copyArchiveLinks() {
        let files = selectedFiles
        guard !files.isEmpty, let rootPath = rootStore.discoveredPathPrefix else {
            statusMessage = "Choose an archive folder first."
            return
        }
        // A root with no DURABLE identity would mint links that can never resolve, so refuse — and
        // say which of the several possible reasons it is. The old message claimed no folder was
        // open, when one was. (W23.m6)
        guard let marker = rootStore.rootMarker else {
            statusMessage = rootStore.markerState.degradation?.message ?? "Choose an archive folder first."
            return
        }
        Task {
            let item = await ArchiveLinkWriter.pasteboardItem(
                for: files, rootPath: rootPath, marker: marker, thumbnailer: nil
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
            statusMessage = "Copied \(files.count) archive link\(files.count == 1 ? "" : "s")."
        }
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
