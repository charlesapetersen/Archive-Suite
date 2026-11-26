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
/// The Advanced Search form's subject: `editing` is the smart folder being edited, nil for a new search.
/// The form edits `draft`, which the request holds, so a sheet that is presented again or rebuilt resumes the
/// rules as edited, not as they opened (W40.fix-reader-advanced-many-rules).
@MainActor
struct AdvancedSearchRequest: Identifiable {
    let id = UUID()
    var editing: SavedSearch?
    /// The smart folder the list was showing when a new search opened (`editing` nil), which the form offers
    /// to save back to (W40.reader-smart-folder-update).
    var origin: SavedSearch?
    let draft: AdvancedSearchDraft

    init(editing: SavedSearch?, origin: SavedSearch? = nil, search: AdvancedSearch) {
        self.editing = editing
        self.origin = editing == nil ? origin : nil
        draft = AdvancedSearchDraft(search)
    }

    var search: AdvancedSearch { draft.search }
}

/// The form's working copy of its rules. A reference, so every view of one request edits the same rules.
@MainActor
final class AdvancedSearchDraft: ObservableObject {
    @Published var search: AdvancedSearch
    init(_ search: AdvancedSearch) { self.search = search }
}

@MainActor
final class NavigationModel: ObservableObject {
    let library: ArchiveLibrary
    let rootStore: RootFolderStore
    let indexer: ContentIndexer
    /// App-owned thumbnail renderer used when the batch Copy Archive Link(s) path vends rich payloads.
    private let thumbnailer: PDFThumbnailer?
    /// Monotonic lease for an async archive-copy enrichment. A later copy command must always win over
    /// an older thumbnail task, even when both began against the same pasteboard change count.
    private var archiveCopyGeneration = 0
    let flags: FlagStore
    let savedSearches: SavedSearchStore
    let excludedFolders: ExcludedFoldersStore
    /// W24.cal1-reader: each document's display calendar, app-side (never written to the corpus).
    let displayCalendars: DisplayCalendarPreferences

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
    let defaults: UserDefaults

    @Published var filter = LibraryFilter()
    /// The text field binds to this; a debounce pipeline copies it into `filter.searchText` after
    /// a 150 ms pause so recompute doesn't fire on every keystroke at 40k+ rows.
    @Published var filterSearchText = ""
    /// W40.suite-item-types: the list marker's colour per item type (Options ▸ Item types); none shows the
    /// type's name instead.
    @Published private(set) var itemTypeMarkerColours = ItemTypePreferences.markerColours()
    @Published var sort = LibrarySort.default
    @Published var selection = Set<ArchiveFile.ID>() {
        didSet {
            followSelectionEnds()
            schedulePersistSelection(); if !patchingSelection { refreshSelectionCache() }
        }
    }
    /// The two ends of the selection, as an `NSTableView` has them (W40.reader-selection-current): ⇧↑/⇧↓ select
    /// the rows from the anchor to the cursor, and move the cursor. One row selected is both. An end that leaves
    /// the selection is forgotten, and the selection's first and last rows stand in for it.
    private(set) var selectionAnchor: ArchiveFile.ID?
    private(set) var selectionCursor: ArchiveFile.ID?
    /// The file the preview sheet or the frontmost document window shows, which the list marks "on view"
    /// among the selected rows (W40.reader-selection-current). Whoever reported it last owns it; only the owner
    /// takes it back, so a closing window cannot clear the file another one shows.
    @Published private(set) var fileOnViewPath: String?
    private var fileOnViewOwner: ObjectIdentifier?
    /// The `displayedGeneration` of the last rebuild of `displayed` (a filter, a sort, a new library). Every change
    /// after it was a row patch (a tag change), so a table that took the rows at or after it holds the surviving rows
    /// where they were on screen rather than where the scroll offset falls (W40.reader-selection-current).
    private(set) var lastRebuildGeneration = 0
    /// Set while a row patch prunes the selection, which then patches the selection cache itself.
    private var patchingSelection = false
    @Published var fullTextQuery = ""
    /// The active smart folder's base scope — the visible universe. `nil` = whole root. User
    /// `filter` narrows *within* this. Selecting a folder / All Files exits the scope. It is either a saved
    /// smart folder or an Advanced Search run without saving (`scopeIsSaved` false), which behaves the same.
    @Published private(set) var scope: SavedSearch?
    @Published private(set) var scopeIsSaved = false
    /// `scope`'s rules as they are tested: folder rules outside the current root left out.
    private var scopeRules: AdvancedSearch?
    /// Per text rule of the scope, the paths its index query matched (`RuleContext.textHits`). A rule not
    /// answered yet is absent and skipped. Separate from `ftsPaths` so a scoped OCR query never lights the user
    /// filter indicators.
    @Published private(set) var baseTextHits: [UUID: Set<String>] = [:]
    private var baseCatalogueHits: [UUID: [UTF8Key: [UUID: Data]]] = [:]
    /// The scope's positive text rules together (`AdvancedSearch.rankingExpression`): their bm25 order, used for
    /// the relevance sort while Find is empty. Scope rules never supply preview snippets.
    private var baseRank: [String: Int]?
    private var baseFtsGeneration = 0
    // Sheet/dialog presentation lives on the model so menu commands can trigger it too.
    /// The non-modal inspector follows the visible selection. Its editor owns explicit target paths.
    @Published var showingEditor = false {
        didSet {
            guard showingEditor != oldValue else { return }
            pruneSelectionToDisplayed(); refreshSelectionCache(); followSelectionInInspector()
        }
    }
    /// What the library window's inspector edits (W40.fix-reader-selection-at-size): the selection's paths, frozen
    /// while it is hidden, so a hidden inspector is not rebuilt for every arrow key, and a draft it holds survives
    /// ⌥⌘I when the selection has not changed meanwhile. `generation` is its identity, and changes only when the set of paths does, not their order.
    private(set) var inspectorTarget = InspectorTarget()
    struct InspectorTarget: Equatable { var paths: [String] = []; var generation = 0 }
    @Published var showingPreview = false
    @Published var showingSaveDialog = false
    @Published var renamingSearch: SavedSearch?     // non-nil while renaming a smart folder
    /// The Advanced Search form, while it is open: a new search, or a smart folder being edited.
    @Published var advancedSearchRequest: AdvancedSearchRequest?
    @Published private(set) var focusSearchRequest = 0      // C5: menu → focus OCR search
    @Published private(set) var focusTagFilterRequest = 0   // C5: menu → focus tag filter
    func requestFocusSearch()    { focusSearchRequest &+= 1 }
    func requestFocusTagFilter() { focusTagFilterRequest &+= 1 }
    @Published private(set) var displayed: [ArchiveFile] = []
    @Published private(set) var duplicatedNames: Set<String> = []   // base names shared by ≥2 displayed rows
    /// Monotonic counter incremented each time `displayed` is set (in `recompute()`). Lets the
    /// AppKit table bridge skip its O(N) snapshot comparison when `updateNSView`
    /// fires for unrelated state changes (selection, scroll, font size).
    private(set) var displayedGeneration: Int = 0
    /// Incremented only when `displayed`'s rows or their order may have changed, not when rows were only
    /// replaced in place (a tag change, W40.fix-reader-change-incremental). The table skips its comparison
    /// of every row id while this stands.
    private(set) var displayedOrderGeneration: Int = 0
    /// Each displayed row's index by id, when the background build made it with the list; the table takes it
    /// instead of hashing every id on the main thread (~60 ms at 116k rows, W40.fix-reader-table-apply-at-size).
    /// Nil once `displayedOrderGeneration` moves on: rows that only changed in place keep their index.
    var displayedRowIndex: [ArchiveFile.ID: Int]? {
        prebuiltRowIndex?.order == displayedOrderGeneration ? prebuiltRowIndex?.index : nil
    }
    private var prebuiltRowIndex: (index: [ArchiveFile.ID: Int], order: Int)?
    @Published private(set) var selectedFilesCache: [ArchiveFile] = [] { didSet { followSelectionInInspector() } }
    @Published private(set) var allSubjectsCache: [String] = []
    @Published private(set) var folderTree: FolderNode?   // sidebar file tree, derived from paths
    @Published private(set) var smartFolderCounts: [UUID: Int] = [:]   // D2: files matching each saved search
    @Published private(set) var ftsPaths: Set<String>?      // nil = no full-text query active
    private var ftsRank: [String: Int]?    // bm25 position map (0 = best); nil = no ranked query
    /// Marked keyword-in-context OCR excerpt (see `SearchSnippet`) per matching path, for the
    /// top-ranked hits of the active full-text query. Empty when no query is active. The list reads it
    /// via `searchSnippet(for:)` to render a preview line under matching rows.
    @Published private(set) var ftsSnippets: [String: String] = [:]
    /// The hits `searchRanked` gave no snippet (past its cap or its time budget) are filled in as their
    /// rows are drawn (W40.fix-reader-fts-snippets): `searchSnippet(for:)` queues the path, and one task at a
    /// time asks the index for a batch, newest request first so the rows on screen come before rows already
    /// scrolled past. `snippetFill` is reset whenever a new result is published.
    private struct SnippetFill {
        var resultGeneration = 0     // the `ftsGeneration` whose result the fill belongs to
        var query = ""
        var pending: [String] = []
        var queued: Set<String> = []  // in `pending`, or already asked for: never asked twice
        var running = false
    }
    private var snippetFill = SnippetFill()
    /// Bumped after each filled batch, so the table reloads those of `filledSnippetPaths` it shows.
    private(set) var snippetFillGeneration = 0
    /// Paths given a snippet since the table last took them (`takeFilledSnippetPaths`).
    private var filledSnippetPaths: Set<String> = []
    /// Rows asked for in one call to the index; the index's own time budget bounds the call as well.
    nonisolated static let snippetFillBatch = 40
    /// The most rows waiting at once, about ten screens. A fast scroll past more drops the oldest; they are
    /// asked for again if they are drawn again, so the index is not kept busy on rows long gone.
    nonisolated static let snippetFillQueueLimit = 400
    /// How many top hits the search itself gives snippets to; the rest are filled in. A test sets it low.
    var ftsSnippetLimit = 300
    /// Page-2 `Classification:` values published by the disposable content index for nav-row display.
    /// Missing/unindexed rows stay absent and render as an em dash; classification never drives a write.
    @Published private(set) var classifications: [String: String] = [:]
    /// W49.reader-item-fields-search: page 2's item fields with the user's corrections over them, per path, from the
    /// content index, for the Item fields column. Display only.
    @Published private(set) var itemFields: [String: IndexedItemFields] = [:] { didSet { itemFieldsRevision &+= 1 } }
    /// Bumped with each change to `itemFields`, so the table redraws its Item fields cells.
    private(set) var itemFieldsRevision = 0
    /// W47.ct-reader-view: where each listed file sits in its archive, from the container files, the level map
    /// and the file names (`ContainerCatalog`). Built off the main thread on each change to the listed paths;
    /// display, sort and filter only.
    @Published var containerCatalog: ContainerCatalog = .empty { didSet { containerCatalogRevision &+= 1 } }
    /// Bumped with each catalog published, so the table redraws its Container cells.
    private(set) var containerCatalogRevision = 0
    /// The level map and the folder it governs, while the sheet is open (`NavigationModel+Containers`).
    @Published var containerLevelsDraft: ReaderContainerLevelsEdit?
    /// An explicit File ▸ Container Levels… command takes priority over the startup offer.
    var containerLevelsOpenRequest: UUID?
    /// Why the last level-map save failed, shown in the sheet.
    @Published var containerLevelsError: String?
    /// Whether a level-map save is being written; the sheet's Save waits for it.
    @Published var containerLevelsSaving = false
    /// W47.ct-reader-edit: why the last container edit was refused, for the Inspector; nil once one succeeds.
    @Published var containerEditError: String?
    /// A container edit is being written (`NavigationModel+ContainerEdits`); one at a time.
    @Published var containerEditSaving = false

    @Published var catalogueEditSaving = false
    @Published var catalogueEditFeedback: String?
    @Published var catalogueEditFailures: [String] = []
    @Published var catalogueHistory = CatalogueEditJournal.Heads()
    var catalogueHistoryRootID: UUID?
    /// W40.reader-item-field-edit: why the last item-field edit was refused, for the Inspector's Checks.
    @Published var itemFieldEditError: String?
    /// W47.ct-folder-date-reader: the offer to date a folder run's undated documents by its confirmed date.
    @Published var folderDatingOffer: FolderDatingOffer?
    /// W49.reader-ct-set-aside: the offer to set aside a container file the last edit could not overwrite.
    @Published var containerSetAsideOffer: ContainerSetAsideOffer?
    /// The file the last item-field edit was for; its error is shown only with that file (nil: with any).
    var itemFieldEditPath: String? { didSet { itemFieldEditForSelection = false } }
    /// The last item-field error came from a selection's edit, so a single file selected after it does not show it.
    /// Set after `itemFieldEditPath`, which clears it.
    var itemFieldEditForSelection = false
    /// Bumped after each `.archivesuite` edit, undo or redo, so the Checks section reads the user's values again.
    @Published var itemFieldRevision = 0
    /// `syncItemFieldsToIndex`: a sync is running, and another was asked for while it ran.
    var itemFieldSyncRunning = false
    var itemFieldSyncQueued = false
    /// `syncSidecarNamesToIndex`: a sync is running (W49.reader-sidecar-names-refresh).
    var sidecarSyncRunning = false
    var containerGeneration = 0
    /// `LibraryChangeSignature.containers` of the catalog last published (W47.ct-reader-facet-rules).
    private var containerValuesSig = 0
    /// The paths the last catalog build started from, so an unchanged set is not rebuilt.
    var containerSignature: ContainerPathSignature?
    /// The paths the published catalog was built from; the level map is offered only once it is the current set.
    var containerBuiltSignature: ContainerPathSignature?
    /// One build at a time: a change during a build asks for one more when it lands, rather than a build per batch
    /// of a first scan.
    var containerBuildInFlight = false
    var containerRebuildPending = false
    /// The pre-filled level map for a root without one, made with the catalog off the main thread.
    var containerPrefilledDraft: ContainerLevelsDraft?
    /// The list columns the user has hidden, from the header's menu (W40.fix-reader-columns-in-header).
    @Published var hiddenColumns: Set<String> = [] {
        didSet { if hiddenColumns != oldValue { AppSettings.setHiddenColumns(hiddenColumns, in: defaults) } }
    }
    /// The columns the list hides: the user's choice, plus Capture marker while no file in the library has one.
    /// Files made before the apps carry no page-2 marker, so for most material the column could only be blank.
    /// The same holds for Container while no file has a container value (W47.ct-reader-view).
    var effectiveHiddenColumns: Set<String> {
        var hidden = hiddenColumns
        if classifications.isEmpty { hidden.insert(AppKitTableView.captureMarkerColumnID) }
        if itemFields.isEmpty { hidden.insert(AppKitTableView.itemFieldsColumnID) }
        if containerCatalog.isEmpty { hidden.insert(AppKitTableView.containerColumnID) }
        return hidden
    }
    /// Whether the user can show `id` now; Capture marker and Container wait for a file that has one.
    func isColumnAvailable(_ id: String) -> Bool {
        switch id {
        case AppKitTableView.captureMarkerColumnID: return !classifications.isEmpty
        case AppKitTableView.itemFieldsColumnID: return !itemFields.isEmpty
        case AppKitTableView.containerColumnID: return !containerCatalog.isEmpty
        default: return true
        }
    }
    func setColumn(_ id: String, visible: Bool) {
        guard id != "name" else { return }   // the file name is always shown
        if visible { hiddenColumns.remove(id) } else { hiddenColumns.insert(id) }
    }
    @Published private(set) var formatStatuses: [String: PDFFormatStatus] = [:]   // non-standard-PDF detection, per path
    @Published private(set) var needsAttentionCount = 0     // indexed files that need attention
    @Published private(set) var ambiguousDateCount = 0      // files with two tags for one date facet (R-47)
    /// Whether an index pass is running. Its count lives in `indexProgress`, which only the status bar observes:
    /// a tick of it used to republish this model, re-running every view of it (W40.fix-reader-selection-at-size).
    @Published private(set) var isIndexing = false
    let indexProgress = IndexProgress()
    var indexingProgress: (done: Int, total: Int)? { indexProgress.value }
    /// Mirrored from `ContentIndexer.failure` — a degraded content index, so the status bar can say so
    /// instead of going idle over a partial or unopenable one (W23.m9). `nil` = healthy.
    @Published private(set) var indexFailure: ContentIndexer.Failure?
    @Published private(set) var undoDepth = 0
    /// How many undos Redo Tag Change can reverse (W40.fix-reader-redo).
    @Published private(set) var redoDepth = 0
    /// Each window's container and item-field undo steps with when each was made, so Edit ▸ Undo can name the next one
    /// and weigh it against the tag ledger (W49.reader-undo-menu-names; `NavigationModel+ContainerEdits`).
    @Published var containerHistory: [ContainerHistory] = []
    @Published var statusMessage = ""
    /// A bulk tag change running off the main actor, for the status bar's count and Cancel button
    /// (W49.reader-batch-writes-async; `NavigationModel+TagBatch`). Nil when none is running.
    @Published var tagBatch: TagBatchStatus?
    var tagBatchControl: TagBatch.Control?
    var tagBatchTask: Task<Void, Never>?
    /// A batch of more files than this runs off the main actor; tests lower it to drive that path.
    var tagBatchInlineLimit = 8
    /// Tests: a batch off the main actor cancels itself once this many files are done.
    var tagBatchStopAfter: Int?
    /// At quit: cancel the running batch, wait for its lanes' current files, and report it there and then.
    var tagBatchQuitFlush: (() -> Void)?
    // G4 keyboard triage: bumped whenever a triage action wants the newly-selected row scrolled into
    // view. The window observes the counter (so scrolling to the *same* id twice still fires) and asks
    // its ScrollViewReader to reveal `scrollTargetID`. Pure UI hint — never a file operation.
    @Published private(set) var scrollRequest = 0
    private(set) var scrollTargetID: ArchiveFile.ID?
    private(set) var scrollTargetAtTop = false
    // W23.m4: bumped when a deep link that cited a PAGE wants the document window opened on it. Same
    // shape as `scrollRequest` — the window observes the counter (so two links to the same page both
    // fire) and calls `openWindow`, which only a View can do. Read-only w.r.t. the corpus.
    @Published private(set) var openViewerRequest = 0
    private(set) var openViewerSelection: DocumentSelection?

    // Deep-link reveal: stashed until the target is visible in library.files (gather deferral).
    private var pendingReveal: String?
    private var pendingRevealPage: Int?
    private var pendingRevealJPEGRelativePath: String?
    private var pendingRevealSettledMisses = 0

    /// W23.m4: app-level carrier so a DOCUMENT window can write page links. This model is the single
    /// writer (see `publishLinkTarget`), so a root switch can never leave another window citing the old
    /// archive. Weak — the context is owned by the app scene, which outlives this model.
    private weak var linkContext: ArchiveLinkContext?

    /// Ledger-derived history only; refreshed at launch, action boundaries and archive switches.
    private var undoGroups: [[AuditLedger.Entry]] = []
    private var redoGroups: [[AuditLedger.Entry]] = []
    private var seenRecordingFailures = AuditLedger.shared.recordingFailureCount
    private var cancellables = Set<AnyCancellable>()

    /// `excludedFolders` defaults to the process-wide singleton, which is what production wants: the
    /// Settings scene (`OptionsView`) observes `ExcludedFoldersStore.shared`, so the model must be
    /// looking at that same object or an exclusion added in Settings would not narrow the list. A test
    /// passing a throwaway `defaults` gets its own instance on that domain instead — nothing else
    /// observes it, and nothing it persists reaches the owner's `ar.excludedFolders`.
    init(defaults: UserDefaults = .standard, excludedFolders: ExcludedFoldersStore? = nil,
         indexer: ContentIndexer = ContentIndexer(),
         thumbnailer: PDFThumbnailer? = ArchiveTestHost.isUnitTestHost ? nil : ArchiveLinkThumbnailer.shared) {
        self.defaults = defaults
        self.savedSearches = SavedSearchStore(defaults: defaults)
        self.flags = FlagStore(defaults: defaults)
        self.hiddenColumns = AppSettings.hiddenColumns(in: defaults)
        self.indexer = indexer
        self.thumbnailer = thumbnailer
        self.library = ArchiveLibrary(defaults: defaults)
        self.rootStore = RootFolderStore(defaults: defaults)
        self.displayCalendars = DisplayCalendarPreferences(defaults: defaults)
        self.excludedFolders = excludedFolders
            ?? (defaults === UserDefaults.standard ? .shared : ExcludedFoldersStore(defaults: defaults))
        library.setRootResolver { [weak self] in
            guard let self else { return nil }
            let url = self.rootStore.reResolveSavedRoot()
            self.configureContentIndex(for: url)
            return url.map(self.resolvedLibraryRoot)
        }
        library.onExternalTagChanges = { [weak self] in self?.folderDateRecordsSeeExternal($0) }   // W49…fu2
        filter.read = AppSettings.defaultReadFilter
        restoreViewState()   // last session's filter + sort override the defaults (C2)
        filterSearchText = filter.searchText   // seed from restored state
        // ArchiveLibrary is @MainActor and only mutates `files` on the main actor, so this publisher
        // fires on main. Defer its consumption until the new value commits (@Published uses willSet).
        library.$filesRevision
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                // Invalidate before willSet finishes, including work already preparing off-main.
                self.libraryRevision &+= 1
                self.libraryPreparation?.cancel()
                let revision = self.libraryRevision
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.libraryRevision == revision else { return }
                    ReaderStages.measure("model.libraryDidChange") { self.libraryDidChange() }
                }
            } }
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
            .sink { [weak self] text in MainActor.assumeIsolated {
                guard let self else { return }
                // An empty box whose search is already reset (the ✕, Clear All, a root change) has nothing to
                // rebuild; the reset's recompute put a whole-list build back on main after the ✕'s background one
                // (W40.fix-reader-scope-exit-main). A search still running is dropped all the same.
                if text.trimmingCharacters(in: .whitespaces).isEmpty, self.ftsPaths == nil, self.ftsRank == nil,
                   !(self.sort.first?.field == .relevance && self.scopeRules?.rankingExpression == nil) {
                    self.ftsGeneration += 1
                    return
                }
                self.runFullTextSearch()
            } }
            .store(in: &cancellables)
        indexer.$failure
            .sink { [weak self] f in MainActor.assumeIsolated { self?.indexFailure = f } }
            .store(in: &cancellables)
        indexer.$progress
            .sink { [weak self] p in MainActor.assumeIsolated {
                self?.indexProgress.value = p
                if self?.isIndexing != (p != nil) { self?.isIndexing = p != nil }
                if p == nil {
                    self?.refreshFormatStatuses()           // a pass just finished → fold in new detection flags
                    self?.refreshFullTextSearchIfActive()   // Part B: newly indexed files may now match the active query
                }
            } }
            .store(in: &cancellables)
        // Committed results become visible during a long build. Coalesce fast batches to avoid
        // repeatedly reading/sorting the whole library; the idle callback above still flushes the end.
        indexer.$contentRevision
            .dropFirst()
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshFormatStatuses() } }
            .store(in: &cancellables)
        // A quit straight after a scroll still saves the place (W40.fix-reader-restore-scroll).
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                self?.topRowWrite?.perform(); self?.flushSelectionWrite()
                self?.tagBatchQuitFlush?()   // a running tag batch stops and reports before the process ends
            } }
            .store(in: &cancellables)
        // Republish when flags change so the table's flag column refreshes.
        flags.objectWillChange
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
        // A flag change moves rows in or out of a scope with a Flagged rule, and changes such folders' counts.
        flags.objectWillChange
            .receive(on: DispatchQueue.main)   // after the change commits
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                if self.scopeRules?.uses(.flagged) == true { self.recompute() }
                if self.savedSearches.searches.contains(where: { $0.search.uses(.flagged) }) {
                    self.refreshSmartFolderCounts()
                }
            } }
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
                self.smartFoldersChanged()
                self.reconcileScopeWithStore()
            } }
            .store(in: &cancellables)
        self.excludedFolders.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                self.folderTree = self.buildFolderTree()
                self.refreshSmartFolderCounts()
                self.recompute()
                self.pruneExcludedFromIndex()
            } }
            .store(in: &cancellables)
        // W23.m4: keep the app-level link target in step with the granted root — a re-grant, a switch
        // (`chooseRoot`) or a clear (Options) all flow through `rootStore`. Async on main so the sink
        // reads the COMMITTED value (`@Published` emits in willSet), same reason as the library sink.
        rootStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                self?.publishLinkTarget()
                self?.refreshUndoHistory()
            } }
            .store(in: &cancellables)
        library.$userItemFieldsRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated {
                self?.itemFieldRevision &+= 1   // the Checks read the user's values again
                self?.syncItemFieldsToIndex()
            } }
            .store(in: &cancellables)
        library.$sidecarRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.syncSidecarNamesToIndex() } }
            .store(in: &cancellables)
        library.$jpegPartnerIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.publishLinkTarget() } }
            .store(in: &cancellables)
        library.$jpegPartnerScanStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
        // W40.suite-item-types: the root's older-material colours, before its rows are built, and again
        // whenever the root or either setting changes.
        applyItemTypePreferences()
        rootStore.$preferenceGUID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyItemTypePreferences() } }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: ItemTypePreferences.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyItemTypePreferences() } }
            .store(in: &cancellables)
        // W47.ct-reader-view: the level map is offered once the root's scan has settled.
        library.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in MainActor.assumeIsolated {
                if phase.isSettled { self?.refreshContainers() }   // offers the map once the build is current
            } }
            .store(in: &cancellables)
        if let root = rootStore.root {
            startLibrary(root)
            // A root granted before the question existed is asked once too, after launch; never under a
            // test host or a fixture root, where nobody is there to answer.
            if !ArchiveTestHost.isUnitTestHost, !ProcessInfo.processInfo.arguments.contains("-ARUITestRootPath") {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.askItemTypeColoursIfNeeded() }
                }
            }
        }
        refreshUndoHistory()
    }

    /// W40.suite-item-types: read both item-type settings and give the library the root's colours. Writes
    /// nothing; a root with no answer reads a type from its tag alone.
    func applyItemTypePreferences() {
        let marker = ItemTypePreferences.markerColours()
        if marker != itemTypeMarkerColours { itemTypeMarkerColours = marker }
        let id = rootStore.preferenceGUID
        let name = rootStore.root?.lastPathComponent
        // Published on the next turn: the model can be made inside a view update, which may not publish.
        DispatchQueue.main.async {
            let active = ActiveRootItemTypes.shared
            if active.rootID != id { active.rootID = id }
            if active.rootName != name { active.rootName = name }
        }
        library.setRootItemTypeColours(ItemTypePreferences.rootColours(for: id) ?? .none)
    }

    /// Asked once, when the user chooses a root that has no answer yet: older material may carry the
    /// type only as a Finder colour. The answer is kept app-side, per root; Options ▸ Item types changes it.
    private func askItemTypeColoursIfNeeded() {
        guard let id = rootStore.preferenceGUID, ItemTypePreferences.rootColours(for: id) == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Did this folder mark box and folder photos with a colour?"
        alert.informativeText = "Box and Folder items are tagged “Box” and “Folder”. Material made before that "
            + "may carry only a Finder colour. Nothing is written to your files; you can change this in "
            + "Settings ▸ Item types."
        alert.addButton(withTitle: "Red Means Box, Purple Means Folder")
        alert.addButton(withTitle: "No Colours")
        let colours: ItemTypeColors = alert.runModal() == .alertFirstButtonReturn ? .redBoxPurpleFolder : .none
        ItemTypePreferences.setRootColours(colours, for: id)
    }

    /// Retry a root bookmark after an ejection/mount event, then apply the no-timer fallback for a
    /// volume that cannot provide FSEvents. Called from the navigation window's activation notice.
    func applicationDidBecomeActive(now: Date = Date()) {
        if rootStore.root == nil, rootStore.hasSavedBookmark {
            if let restored = rootStore.reResolveSavedRoot() {
                startLibrary(restored)
            }
            return
        }
        library.revalidateOnActivation(now: now)
        checkImproveOCRReceipts()
    }

    /// Adopt the app-level link context and seed it with the current root (the store resolved its saved
    /// bookmark in `init`, before the subscription above existed). Called by the navigation window.
    func attach(linkContext: ArchiveLinkContext) {
        self.linkContext = linkContext
        linkContext.prepareForCopy = { [weak self] url in self?.prepareArchiveLinkCopy(for: url) }
        linkContext.copyFailureMessage = { [weak self] in self?.statusMessage ?? "Choose an archive folder first." }
        publishLinkTarget()
    }

    /// Mirror the granted root + marker into the app-level context, so any window can build a durable
    /// link. Clears it when either is missing — a link with no marker GUID isn't portable.
    private func publishLinkTarget() {
        let layout = rootStore.root.map { ReaderArchiveLayout(grantedRoot: $0) }
        linkContext?.update(rootPath: rootStore.discoveredPathPrefix,
                            marker: rootStore.rootMarker,
                            mainRootPath: layout?.mainRoot.path,
                            jpegRootPath: layout?.jpegRoot.path,
                            jpegPartnerIndex: library.jpegPartnerIndex,
                            preferenceGUID: rootStore.preferenceGUID)
    }

    // MARK: Saved searches / scope

    /// Save what the list shows as a smart folder: the scope's rules narrowed by the filter bar and Find.
    func saveCurrentSearch(name: String) {
        savedSearches.add(name: name, search: effectiveSearch)
    }

    /// What the list shows, as rules: the base scope (smart folder or Advanced Search) AND the filter bar AND
    /// the Find box, as `rowPredicate` applies them.
    var effectiveSearch: AdvancedSearch {
        (scopeRules ?? AdvancedSearch()).narrowed(by: AdvancedSearch(filter: filter, fullTextQuery: fullTextQuery, catalogueMode: library.usesCatalogue))
    }

    /// A human-readable default name for "save current filters as a smart folder", built from the
    /// active smart folder's name and the active filter facets (e.g. "Unread · Q1 · Jerry Brown · Batch-A").
    var suggestedSmartFolderName: String {
        let f = filter
        var parts: [String] = scope.map { [$0.name] } ?? []
        switch f.read {
        case .all: break
        case .read: parts.append("Read")
        case .unread: parts.append("Unread")
        case .noReadState: parts.append("No read-state")
        }
        if !f.qualities.isEmpty {
            parts.append(f.qualities.sorted().map { "Q\($0)" }.joined(separator: "/"))
        }
        if let years = f.dateYearsSummary { parts.append(years) }
        if !f.subjects.isEmpty {
            parts.append(f.subjects.sorted().joined(separator: " + "))
        }
        if let p = f.pathPrefix, !p.isEmpty { parts.append(URL(fileURLWithPath: p).lastPathComponent) }
        parts += f.activeContainerFacets.map(\.value)
        let fn = f.searchText.trimmingCharacters(in: .whitespaces)
        if !fn.isEmpty { parts.append("name:\(fn)") }
        let q = fullTextQuery.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append("\u{201c}\(q)\u{201d}") }
        return parts.isEmpty ? "Smart Folder" : parts.joined(separator: " \u{b7} ")
    }


    /// Enter a smart-folder scope: the saved search becomes the visible universe; user filters reset.
    /// `saved` false is an Advanced Search run without saving; one with no active rule leaves the scope.
    func applyScope(_ search: SavedSearch, saved: Bool = true) {
        let leaving = visit
        defer { recordMove(leaving: leaving) }
        guard saved || search.search.isActive else { exitScope(); clearUserFilters(); return }
        setScope(search, saved: saved, announce: true)
        clearUserFilters(recompute: false)
        recomputeInBackground()
    }

    /// Open the Advanced Search form on what the list shows now (the scope, the filter bar and Find, as rules),
    /// or on the starter rows when nothing is in effect.
    /// Inside a saved smart folder the form starts from its rules as saved, so saving back keeps a folder rule
    /// that is outside the current root, and it remembers the folder to offer Save to it.
    func openAdvancedSearch() {
        let origin = savedScope
        let current = origin.map { scopeNarrowedByFilters($0) } ?? effectiveSearch
        advancedSearchRequest = AdvancedSearchRequest(editing: nil, origin: origin,
                                                      search: current.isActive ? current : .starter)
    }

    /// The saved smart folder in scope, as the store holds it now; nil for no scope or an unsaved search.
    var savedScope: SavedSearch? {
        guard scopeIsSaved, let id = scope?.id else { return nil }
        return savedSearches.searches.first { $0.id == id }
    }

    /// `folder`'s saved rules AND the filter bar AND the Find box.
    private func scopeNarrowedByFilters(_ folder: SavedSearch) -> AdvancedSearch {
        folder.search.narrowed(by: AdvancedSearch(filter: filter, fullTextQuery: fullTextQuery, catalogueMode: library.usesCatalogue))
    }

    /// Whether the filter bar offers Save to the smart folder in scope: one is, and filters narrow it.
    var canSaveFiltersToScope: Bool {
        guard let folder = savedScope else { return false }
        return scopeNarrowedByFilters(folder) != folder.search
    }

    /// The filter bar's Save to "<name>": the smart folder in scope takes its rules AND the filters as its rules,
    /// and the filters clear, since they are now the folder's own (W40.reader-smart-folder-update).
    func saveFiltersToScope() {
        guard let folder = savedScope else { return }
        saveToSmartFolder(folder.id, search: scopeNarrowedByFilters(folder))
    }

    /// Replace a smart folder's rules with `search` and show it, user filters cleared (the form's Save to
    /// "<name>", and the filter bar's). Nothing happens when the folder is gone.
    func saveToSmartFolder(_ id: UUID, search: AdvancedSearch) {
        guard savedSearches.searches.contains(where: { $0.id == id }) else {
            statusMessage = "That smart folder no longer exists — use Save as New Smart Folder."
            return
        }
        savedSearches.update(id, search: search)
        guard let saved = savedSearches.searches.first(where: { $0.id == id }) else { return }
        applyScope(saved)
    }

    /// A folder rule's value as the form shows it: its path under the archive root, or the folder's own name.
    func relativeFolderName(_ path: String) -> String {
        guard let root = rootStore.discoveredPathPrefix.map({ $0.hasSuffix("/") ? String($0.dropLast()) : $0 }),
              path.hasPrefix(root + "/") else { return URL(fileURLWithPath: path).lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    /// Pick a folder for a folder rule, starting in the archive. Only the path is kept; nothing is opened or
    /// written. nil when cancelled.
    func chooseFolderForRule(startingAt current: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder in the archive."
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current) }
        else if let root = rootStore.root { panel.directoryURL = root }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }

    /// Delete a smart folder, from the sidebar's menu or the toolbar's Saved ▸ Delete. The open one is left first,
    /// with the whole list built off the main actor, so neither the sidebar's selection sync nor the store's
    /// change runs that pass on the main thread (W40.fix-reader-smart-folder-delete). Not a move for Back.
    func deleteSmartFolder(_ id: UUID) {
        if scopeIsSaved, scope?.id == id { exitScope(); recomputeInBackground() }
        savedSearches.delete(id)
    }

    /// Edit Smart Folder: the form, filled in with the folder's rules.
    func editSmartFolder(_ search: SavedSearch) {
        advancedSearchRequest = AdvancedSearchRequest(editing: search, search: search.search)
    }

    /// How many files `search` matches over the whole library (excluded folders left out), for the form's count.
    /// Its text rules run through the index first.
    /// Cancelling the calling task (the form's next edit) stops the row pass too; the count it then returns is
    /// partial, for a caller that drops it.
    func countMatches(_ search: AdvancedSearch) async -> Int {
        await countWithBasis(search, cancellable: true).count
    }

    /// A saved search as it was last counted: its rules as tested and their outside answers (text hits, flagged,
    /// needs attention). A row change then moves the count by that row's difference
    /// (W40.fix-reader-change-incremental). Valid until a refresh: every input that changes these answers
    /// (an index pass, a flag, an exclusion, the saved rules) starts one.
    private struct CountBasis: Sendable {
        let search: AdvancedSearch
        /// From `prepared()`: tested with `matchesPrepared`.
        let rules: AdvancedSearch
        let context: RuleContext
        /// The `library.filesRevision` its rows were counted at.
        let filesRevision: UInt64

        func counts(_ file: ArchiveFile, excluded: [String]) -> Bool {
            !LibraryPresentation.isExcluded(file.path, by: excluded) && rules.matchesPrepared(file, context)
        }
    }

    /// `countMatches`, with the basis it counted on. The row test runs off the main actor over the library as
    /// it is when the text answers arrive. `cancellable`: the caller's cancellation stops the text queries
    /// still to run and the row pass, so a form edited rule after rule at full corpus size does not stack one
    /// whole-library pass per edit (W40.fix-reader-advanced-many-rules).
    private func countWithBasis(_ search: AdvancedSearch,
                                cancellable: Bool = false) async -> (basis: CountBasis, count: Int) {
        let rules = search.droppingFolders(outside: rootStore.discoveredPathPrefix).search
        let hits = await textHits(for: rules, stopOnCancel: cancellable)
        var context = ruleContext(for: rules)
        context.textHits = hits
        context.catalogueHits = await catalogueHits(for: rules, stopOnCancel: cancellable)
        let files = library.files, excluded = excludedAbsolutePrefixes()
        let basis = CountBasis(search: search, rules: rules.prepared(), context: context,
                               filesRevision: library.filesRevision)
        if cancellable, Task.isCancelled { return (basis, 0) }
        let pass = Task.detached(priority: .userInitiated) {
            ReaderStages.measure("model.countMatches.rows") {
                Self.countRows(files, basis: basis, excluded: excluded, cancellable: cancellable)
            }
        }
        let count = await withTaskCancellationHandler { await pass.value } onCancel: { pass.cancel() }
        return (basis, count)
    }

    /// The row pass, in waves of chunks across the cores; between waves a cancelled task stops. 116k rows
    /// under twelve name rules took 1.1 s at -O on one thread (W40.fix-reader-advanced-many-rules).
    private nonisolated static func countRows(_ files: [ArchiveFile], basis: CountBasis, excluded: [String],
                                              cancellable: Bool) -> Int {
        let chunk = 4096
        let chunks = (files.count + chunk - 1) / chunk
        let wave = max(1, ProcessInfo.processInfo.activeProcessorCount)
        // Each worker writes its own chunk's slot, and the waves end before the sum reads them.
        nonisolated(unsafe) let counts = UnsafeMutableBufferPointer<Int>.allocate(capacity: max(chunks, 1))
        counts.initialize(repeating: 0)
        defer { counts.deallocate() }
        var start = 0
        while start < chunks {
            if cancellable, Task.isCancelled { break }
            let first = start, n = min(wave, chunks - start)
            DispatchQueue.concurrentPerform(iterations: n) { k in
                let c = first + k
                var hits = 0
                for i in (c * chunk)..<min(files.count, (c + 1) * chunk)
                where basis.counts(files[i], excluded: excluded) { hits += 1 }
                counts[c] = hits
            }
            start += n
        }
        return counts.reduce(0, +)
    }

    /// The excluded folders as absolute path prefixes, as the list and the counts test them.
    private func excludedAbsolutePrefixes() -> [String] {
        rootStore.discoveredPathPrefix.map { excludedFolders.absolutePrefixes(rootPath: $0) } ?? []
    }

    /// Each active text rule's index answer, by rule id.
    private func textHits(for search: AdvancedSearch, stopOnCancel: Bool = false) async -> [UUID: Set<String>] {
        var hits: [UUID: Set<String>] = [:]
        let catalogueMode = library.usesCatalogue
        for rule in search.textRules {
            if stopOnCancel, Task.isCancelled { break }
            guard let expression = rule.ftsExpression(catalogueMode: catalogueMode) else { continue }
            hits[rule.id] = Set(await indexer.search(expression: expression))
        }
        return hits
    }

    private func catalogueHits(for search: AdvancedSearch, stopOnCancel: Bool = false) async
        -> [UUID: [UTF8Key: [UUID: Data]]] {
        var hits: [UUID: [UTF8Key: [UUID: Data]]] = [:]
        for rule in search.catalogueRules {
            if stopOnCancel, Task.isCancelled { break }
            guard let expression = rule.catalogueExpression else { continue }
            hits[rule.id] = await indexer.catalogueHits(ftsExpression: expression)
        }
        return hits
    }

    /// The form's Search (or Save, when editing a smart folder): what its draft holds now.
    func commitAdvancedSearch(_ request: AdvancedSearchRequest) {
        if let editing = request.editing {
            updateSmartFolder(editing.id, search: request.search)
        } else {
            runAdvancedSearch(request.search)
        }
    }

    /// Run an Advanced Search without saving it: it becomes the base scope, like an unsaved smart folder.
    func runAdvancedSearch(_ search: AdvancedSearch) {
        applyScope(SavedSearch(name: "Advanced Search", search: search), saved: false)
    }

    /// Save an Advanced Search from the form as a new smart folder, and make it the scope.
    func saveAdvancedSearch(_ search: AdvancedSearch, name: String) {
        guard let id = savedSearches.add(name: name, search: search),
              let saved = savedSearches.searches.first(where: { $0.id == id }) else { return }
        applyScope(saved)
    }

    /// Edit Smart Folder: replace its rules; the active one shows the new rules at once.
    func updateSmartFolder(_ id: UUID, search: AdvancedSearch) {
        savedSearches.update(id, search: search)
        if scopeIsSaved, scope?.id == id, let current = savedSearches.searches.first(where: { $0.id == id }) {
            setScope(current, saved: true, announce: true)
            recompute()
        }
    }

    /// Set the scope and start its text rules; the user filters are left alone.
    private func setScope(_ search: SavedSearch, saved: Bool, announce: Bool) {
        let (rules, dropped) = search.search.droppingFolders(outside: rootStore.discoveredPathPrefix)
        if dropped, announce {
            statusMessage = "A folder in this search isn't under the current archive root — that rule is left out."
        }
        let rulesChanged = scope?.id != search.id || scope?.search != search.search
        scope = search
        scopeIsSaved = saved
        guard rulesChanged else { return }   // a rename: the rows, their answers and the sort all stand
        scopeRules = rules
        baseTextHits = [:]
        baseCatalogueHits = [:]
        baseRank = nil
        if rules.rankingExpression != nil, sort.first?.field != .relevance { sort = [ARSortDescriptor(field: .relevance)] }
        runBaseFullTextSearch()
    }

    /// Leave the scope (smart folder or Advanced Search); the caller recomputes.
    private func exitScope() {
        scope = nil; scopeIsSaved = false; scopeRules = nil
        baseFtsGeneration += 1; baseTextHits = [:]; baseCatalogueHits = [:]; baseRank = nil
        if ftsRank == nil, sort.first?.field == .relevance { sort = LibrarySort.default }
    }

    /// Tooltip for every Clear All site: what `clearUserFilters` clears, and that a smart folder's own rules stay.
    var clearAllHelp: String {
        if let scope {
            let base = scopeIsSaved ? "the smart folder \u{201C}\(scope.name)\u{201D}" : "the Advanced Search"
            return "Clear every filter and search you added, returning to \(base)'s own rules"
        }
        return "Clear every filter and search. Each filter's \u{2715} clears just that one"
    }

    /// Reset user-applied filters to neutral (preserving the base scope). Every Clear All site calls this.
    func clearUserFilters(recompute doRecompute: Bool = true) {
        filter = LibraryFilter()
        filter.read = AppSettings.defaultReadFilter
        filterSearchText = ""
        fullTextQuery = ""
        ftsGeneration += 1
        ftsPaths = nil
        ftsRank = nil
        ftsSnippets = [:]
        if sort.first?.field == .relevance, baseRank == nil, scopeRules?.rankingExpression == nil {
            sort = LibrarySort.default
        }
        if doRecompute { recompute() }
    }

    /// Run the base scope's text rules through the index, one query each, into `baseTextHits`. The previous
    /// answers stay until the new ones arrive, so a refresh after an index pass does not flash the whole list.
    private func runBaseFullTextSearch() {
        baseFtsGeneration += 1
        let generation = baseFtsGeneration
        guard let rules = scopeRules, rules.hasTextRules else { return }
        Task { [weak self] in
            guard let self else { return }
            var ranked: ContentIndex.RankedSearch?
            if let expression = rules.rankingExpression(catalogueMode: self.library.usesCatalogue) {
                ranked = await self.indexer.searchRanked(expression: expression, snippetLimit: 0)
            }
            // One positive text rule is its own ranking expression: its hits are the ranked paths, not a second query.
            let textRules = rules.textRules
            let hits: [UUID: Set<String>]
            if textRules.count == 1, textRules[0].op != .noWords, let ranked {
                hits = [textRules[0].id: Set(ranked.paths)]
            } else {
                hits = await self.textHits(for: rules)
            }
            let catalogueHits = await self.catalogueHits(for: rules)
            guard generation == self.baseFtsGeneration else { return }
            self.baseTextHits = hits
            self.baseCatalogueHits = catalogueHits
            self.baseRank = ranked.map { Dictionary($0.paths.enumerated().map { ($1, $0) }) { a, _ in a } }
            self.recompute()
        }
    }

    /// Keep the active scope in sync with the saved-search store (delete → exit, rename or edit → refresh).
    private func reconcileScopeWithStore() {
        guard let scope, scopeIsSaved else { return }
        if let current = savedSearches.searches.first(where: { $0.id == scope.id }) {
            if current != scope { setScope(current, saved: true, announce: false); recompute() }
        } else {
            // The active scope's saved search was deleted — exit the scope.
            exitScope(); recomputeInBackground()
        }
    }

    // MARK: Document-run convenience (opt-in; degrades when classification is absent)

    /// Extend the selection to the full document run(s) — a `Document Start` + its `Continuation`
    /// pages — for each currently-selected file, using the content index's classifications. Works
    /// over the whole library in filename order; a no-op with a note when classification is missing.
    func extendSelectionToDocumentRun() {
        let files = library.files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let paths = files.map(\.path)
        let snapshot = selection                              // the selection we're extending
        let selected = Set(selectedFiles.map(\.path))
        guard !selected.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let cls = await self.indexer.classifications(for: paths)
            // The await releases the main actor; if the user changed the selection meanwhile, abandon
            // this stale run instead of mixing a stale snapshot with the current selection (which would
            // pollute it). The selection itself is the epoch — no separate generation counter needed.
            guard self.selection == snapshot else { return }
            let classifications = paths.map { cls[$0] }
            // Runs are found over the whole library (a filter must not split one), but only the members
            // the list shows join the selection (`W40.fix-reader-phantom-selection`).
            let visible = Set(self.displayed.map(\.id))
            var newSel = snapshot
            for (i, p) in paths.enumerated() where selected.contains(p) {
                if let range = DocumentRuns.runContaining(i, classifications: classifications) {
                    for j in range where visible.contains(files[j].id) { newSel.insert(files[j].id) }
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

    // MARK: Flags (app-side, never written to the corpus)

    func toggleFlagSelection() {
        let paths = selectedFiles.map(\.path)
        guard !paths.isEmpty else { return }
        toggleFlag(paths: paths)
    }

    /// The document window's Toggle Flag (W40.fix-reader-menus-follow-window): the open file, not the list's selection.
    /// Returns false, with the reason in `statusMessage`, when none of the paths is in the library or a catalogue
    /// save could not start. In Catalogue Mode `completed` runs once the save has reported (W49.reader-doc-window-parity).
    @discardableResult func toggleFlag(paths: [String], completed: ((Set<String>) -> Void)? = nil) -> Bool {
        let files = libraryFiles(atPaths: paths)
        guard !files.isEmpty else { reportNotInLibrary(); return false }
        if library.usesCatalogue {
            let on = files.contains { row in
                guard let facts = catalogueFacts(for: row), let file = try? facts.file.get(),
                      case .value(let value) = file.pair.record.fileFields.flagged?.current else { return true }
                return !value
            }
            return applyCatalogueFileField(.flagged, .set(.flag(on)), paths: paths, completed: completed)
        }
        flags.toggleFlag(files.map(\.path))
        resortAfterFlagChange()
        return true
    }

    /// Select every currently-displayed file that carries `tag` (from the tag cloud context menu).
    /// Matches on `subjects` — the same facet the tag filter uses — so it agrees with the cloud below.
    func selectFiles(withTag tag: String) {
        selection = Set(displayed.filter { $0.hasSubject(tag) }.map(\.id))
    }

    // MARK: Display calendars (W24.cal1-reader; app-side, never written to the corpus)

    /// The calendar `file`'s date is shown in: its choice when Options allows it, else nil (as tagged).
    /// A choice is keyed by the root marker's GUID, so without a marker there is none.
    func displayCalendar(for file: ArchiveFile) -> DisplayCalendar? {
        guard DisplayCalendarSettings.isEnabled(defaults), let key = calendarKey(for: file) else { return nil }
        let calendar = displayCalendars.calendar(rootGUID: key.guid, relativePath: key.path)
        return calendar == .standard ? nil : calendar
    }

    /// The choice every selected file shares, for the menu's checkmark; nil when they differ or none
    /// of them can carry a choice.
    var selectionDisplayCalendar: DisplayCalendar? {
        var chosen = Set<DisplayCalendar>()
        for file in selectedFiles {
            guard let key = calendarKey(for: file) else { return nil }
            chosen.insert(displayCalendars.calendar(rootGUID: key.guid, relativePath: key.path))
        }
        return chosen.count == 1 ? chosen.first : nil
    }

    /// Whether a choice can be stored: a container-only root identity needs no archive write.
    var canChooseDisplayCalendar: Bool { rootStore.preferenceGUID != nil }

    func setDisplayCalendar(_ calendar: DisplayCalendar) {
        for file in selectedFiles {
            guard let key = calendarKey(for: file) else { continue }
            displayCalendars.set(calendar, rootGUID: key.guid, relativePath: key.path)
        }
        refreshDisplayedRows()
    }

    /// Re-render the visible rows without re-sorting or re-filtering: their date text changed, their
    /// order did not (sorting and the year filter use the stored date).
    func refreshDisplayedRows() {
        objectWillChange.send()
        displayedGeneration += 1
    }

    private func calendarKey(for file: ArchiveFile) -> (guid: UUID, path: String)? {
        guard let guid = rootStore.preferenceGUID, let root = rootStore.discoveredPathPrefix else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let path = file.path
        guard path.hasPrefix(prefix) else { return nil }
        return (guid, String(path.dropFirst(prefix.count)))
    }

    // MARK: Reading-session resume

    /// Spelled once so the read, the write and the removal cannot drift apart — the three-call-sites,
    /// two-spellings defect `W26.fixturehang` found in `ArchiveLibrary`.
    private static let selectionKey = "lastSelectionFileURLs"
    /// The row at the top of the list when it last stopped moving (W40.fix-reader-restore-scroll).
    private static let topRowKey = "lastTopRowFileURL"

    private var didRestoreSelection = false
    /// The row a relaunch is putting back at the top. Kept while the list is still arriving — a smart
    /// folder's text search and a cold scan both change the rows after the first ones show, and the
    /// table keeps its offset, not its row — so each recompute scrolls back to it. Dropped once the user
    /// scrolls or clicks, when the row leaves the list, or when the folder, filter or sort changes.
    private var pendingTopRow: ArchiveFile.ID?
    /// The folder, filter and sort the place belongs to; a change to any of them is the user's.
    private var pendingTopRowView: ListView?
    private struct ListView: Equatable { var scopeID: UUID?; var filter: LibraryFilter; var sort: [ARSortDescriptor] }
    private var currentListView: ListView { ListView(scopeID: scope?.id, filter: filter, sort: sort) }
    private var lastNotedTopRow: ArchiveFile.ID?
    /// Scrolling passes many rows a second; the place is written once it stops.
    private var topRowWrite: DispatchWorkItem?

    private func restoreSelectionIfNeeded() {
        // On the list, not the library: a restored filter may still be hiding every row (a "needs
        // attention" filter before format statuses arrive), and the resume should wait for it.
        guard !didRestoreSelection, !displayed.isEmpty else { return }
        didRestoreSelection = true
        let shown = Set(displayed.map(\.id))
        let saved = Set((defaults.stringArray(forKey: Self.selectionKey) ?? [])
            .compactMap(URL.init(string:)))
        let present = shown.intersection(saved)   // a restored filter may hide some
        if !present.isEmpty { selection = present }
        // Return to the rows that were on screen; failing that, at least show the selection.
        if let top = defaults.string(forKey: Self.topRowKey).flatMap(URL.init(string:)), shown.contains(top) {
            pendingTopRow = top
            pendingTopRowView = currentListView
            lastNotedTopRow = top
            requestScroll(to: top, atTop: true)
        } else if let first = displayed.first(where: { present.contains($0.id) }) {
            requestScroll(to: first.id)
        }
    }

    /// Keep the relaunch's place while rows are still arriving (see `pendingTopRow`).
    private func reapplyPendingTopRow() {
        guard let top = pendingTopRow else { return }
        if pendingTopRowView == currentListView, displayed.contains(where: { $0.id == top }) {
            requestScroll(to: top, atTop: true)
        } else {
            pendingTopRow = nil
        }
    }

    /// The table reports its top row after each scroll. Ignored until the relaunch's place is restored,
    /// so the first, unscrolled draw cannot overwrite the place it is about to return to.
    func noteTopVisibleRow(_ id: ArchiveFile.ID) {
        guard didRestoreSelection, pendingTopRow == nil, id != lastNotedTopRow else { return }
        lastNotedTopRow = id
        topRowWrite?.cancel()
        let write = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.defaults.set(id.absoluteString, forKey: Self.topRowKey) }
        }
        topRowWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: write)
    }

    /// The user scrolled or clicked in the list: their place wins over the one being restored.
    func userMovedInList() { pendingTopRow = nil }
    /// A run of arrow keys writes the selection once, when it stops (W40.fix-reader-selection-at-size).
    private var selectionWrite: DispatchWorkItem?
    private func schedulePersistSelection() {
        selectionWrite?.cancel()
        let write = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.selectionWrite = nil; self?.persistSelection() }
        }
        selectionWrite = write
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: write)
    }
    /// Writes a selection still waiting for its pause: at quit, and for tests.
    func flushSelectionWrite() {
        guard let write = selectionWrite else { return }
        write.cancel(); selectionWrite = nil
        persistSelection()
    }
    private func persistSelection() { ReaderStages.measure("model.persistSelection") {
        // Cap persistence so a huge multi-select (e.g. Select All over 150k) never serializes a giant
        // array on the main actor or bloats the defaults plist; such selections aren't worth restoring.
        let paths = selection.map(\.absoluteString)
        if paths.count <= 500 {
            defaults.set(paths, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    } }

    // MARK: Derived

    private var viewRevision: UInt64 = 0

    private func presentationInput(_ files: [ArchiveFile]) -> LibraryPresentation.Input {
        LibraryPresentation.Input(files: files, excludedPrefixes: excludedAbsolutePrefixes(),
            matches: rowPredicate(scope: scope, filter: filter, ftsPaths: ftsPaths),
            sort: sort, marks: sortMarks(), rank: ftsRank ?? baseRank)
    }

    func recompute() {
        viewRevision &+= 1
        builtFilterAndSort = (filter, sort)
        let input = presentationInput(library.files)
        present(ReaderStages.measure("presentation.build") { input.build() }, marks: input.marks,
                filesRevision: library.filesRevision)
    }

    /// The filter and sort the last recompute was asked for.
    private var builtFilterAndSort: (filter: LibraryFilter, sort: [ARSortDescriptor])?

    /// The window's filter or sort changed. Most changes made in the model recompute already, so the view's
    /// change handler ran a second whole-list build on the main thread; and leaving a smart folder sorted by
    /// relevance puts the sort back, which undid the background build of a deletion
    /// (W40.fix-reader-smart-folder-delete). A list already asked for with this filter and sort is not built again.
    func filterOrSortChanged() {
        if let built = builtFilterAndSort, built.filter == filter, built.sort == sort { return }
        recompute()
    }

    /// `recompute`, with the list built off the main actor at corpus size, where the whole-library pass held the
    /// main thread 1.2 s in Debug (W40.fix-reader-smart-folder-delete). The list shows the old rows until it is
    /// presented. Any recompute meanwhile supersedes it; so does a library change, whose own rebuild presents,
    /// since no row patch applies to a list that is not presented yet.
    /// Choosing a folder, a smart folder or All Files, and a chip's ✕, build this way too
    /// (W40.fix-reader-scope-exit-main).
    private func recomputeInBackground() {
        guard library.files.count >= 1_000 else { recompute(); return }
        viewRevision &+= 1
        builtFilterAndSort = (filter, sort)
        let view = viewRevision, filesRevision = library.filesRevision
        let input = presentationInput(library.files)
        presentedFilesRevision = nil
        listBuildPending = true
        listBuild = Task { [weak self] in
            let (result, rowIndex) = await Task.detached(priority: .userInitiated) {
                let result = ReaderStages.measure("presentation.build (background)") { input.build() }
                let rowIndex = ReaderStages.measure("presentation.rowIndex (background)") {
                    ArchiveFile.rowIndex(result.displayed.map(\.id))
                }
                return (result, rowIndex)
            }.value
            guard let self, self.viewRevision == view, self.library.filesRevision == filesRevision else { return }
            self.present(result, marks: input.marks, filesRevision: filesRevision, rowIndex: rowIndex)
        }
    }

    /// The background build in flight, if any; `listBuildPending` until a list is presented.
    private var listBuild: Task<Void, Never>?
    private var listBuildPending = false

    /// Returns once the list asked for is presented: a background build's, or a rebuild that superseded it.
    /// For tests that read `displayed` straight after a scope change.
    func listPresented(timeout: TimeInterval = 30) async {
        await listBuild?.value
        let deadline = Date().addingTimeInterval(timeout)
        while listBuildPending, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// The `library.filesRevision` that `displayed` was built from, so a row patch knows whether its change
    /// set starts where the list stands (W40.fix-reader-change-incremental).
    private var presentedFilesRevision: UInt64?

    private func present(_ result: LibraryPresentation, marks: SortMarks, filesRevision: UInt64,
                         rowIndex: [ArchiveFile.ID: Int]? = nil) {
        presentedFilesRevision = filesRevision
        listBuildPending = false
        if result.ambiguousCount != ambiguousDateCount { ambiguousDateCount = result.ambiguousCount }
        let causes = result.displayed.isEmpty ? emptyCauses(in: result.universe) : []
        if causes != emptyListCauses { emptyListCauses = causes }
        lastSortMarks = marks
        displayed = result.displayed
        displayedGeneration += 1
        lastRebuildGeneration = displayedGeneration
        displayedOrderGeneration += 1
        prebuiltRowIndex = rowIndex.map { ($0, displayedOrderGeneration) }
        _tagCloudCache = nil
        duplicatedNames = result.duplicatedNames
        let selectedBefore = selection
        ReaderStages.measure("model.pruneSelection") { pruneSelectionToDisplayed() }
        // The first list after a Back that is built off main prunes the selection of the place left, which is not
        // the user's change: the restore survives it. Only that one: a later prune is a filter's, and a row it
        // removed must not come back selected when the filter clears (W40.fix-reader-scope-exit-main).
        if visitAwaitsList {
            visitAwaitsList = false
            if pendingVisitSelection?.applied == selectedBefore { pendingVisitSelection?.applied = selection }
        }
        refreshSelectionCache()
        checkSelectionEnds()
        persistViewState()
        reapplyPendingTopRow()
        reapplyVisitSelection()
    }

    /// Whether a row is listed. The base scope (smart folder) is the visible universe; the user filter layers on
    /// top, the OCR search and the needs-attention status (both from the content index) beside it.
    private func rowPredicate(scope: SavedSearch?, filter: LibraryFilter,
                              ftsPaths: Set<String>?) -> @Sendable (ArchiveFile) -> Bool {
        let rules = scope == nil ? nil : scopeRules
        let context = rules.map { ruleContext(for: $0) }
        let statuses = formatStatuses
        // Not applied until the catalog for this root has been built (a facet restored at launch would hide
        // every row until then).
        let containers = filter.activeContainerFacets.isEmpty || containerCatalog.rootPath != containerTree?.path
            ? nil : containerCatalog.rows
        return { file in
            if let rules, let context, !rules.matches(file, context) { return false }
            guard filter.matches(file) else { return false }
            if let ftsPaths, !ftsPaths.contains(file.path) { return false }
            if filter.needsAttentionOnly, statuses[file.path]?.needsAttention != true { return false }
            if let containers, !filter.matchesContainer(containers[file.path]) { return false }
            return true
        }
    }

    /// What `search`'s rules need from outside the file: the scope's text hits, and the needs-attention and
    /// flagged sets, built only when a rule asks for them.
    private func ruleContext(for search: AdvancedSearch) -> RuleContext {
        var context = RuleContext(textHits: baseTextHits, catalogueHits: baseCatalogueHits)
        if search.uses(.needsAttention) {
            context.needsAttention = Set(formatStatuses.lazy.filter { $0.value.needsAttention }.map(\.key))
        }
        if search.uses(.flagged) { context.flagged = flags.flagged }
        // Only the catalog built for this root: an older one's rows would match the wrong files.
        if search.uses(.container), containerCatalog.rootPath == containerTree?.path {
            context.containers = containerCatalog.rows
        }
        return context
    }

    // MARK: What is in effect (W40.fix-reader-filter-bar)

    /// Filters and searches shown in the In effect row. The ordinary folder is already selected in the
    /// sidebar; a smart folder stays here because its saved rules keep narrowing the list.
    var activeFilterChips: [ActiveFilterChip] {
        listConstraints.filter { $0.facet != .folder }
    }

    /// All constraints, including the sidebar location, for empty-list explanations and recovery actions.
    var listConstraints: [ActiveFilterChip] {
        ActiveFilterChip.chips(filter: filter, smartFolderName: scope?.name,
                               fullTextQuery: ftsPaths == nil ? nil : fullTextQuery)
    }

    /// While the filters hide every row: the chips that, removed alone, would bring rows back. A location (the
    /// folder, the smart folder) is blamed only when nothing else alone is, since it says where the list looks,
    /// not what for; searching a name and then choosing another folder blames the name.
    @Published private(set) var emptyListCauses: [FilterFacet] = []

    private func emptyCauses(in universe: [ArchiveFile]) -> [FilterFacet] {
        guard !universe.isEmpty else { return [] }
        func bringsRowsBack(_ facet: FilterFacet) -> Bool {
            let pred = rowPredicate(scope: facet == .smartFolder ? nil : scope, filter: filter.removing(facet),
                                    ftsPaths: facet == .text ? nil : ftsPaths)
            return universe.contains(where: pred)
        }
        let facets = listConstraints.map(\.facet)
        let causes = facets.filter { !$0.isLocation && bringsRowsBack($0) }
        return causes.isEmpty ? facets.filter { $0.isLocation && bringsRowsBack($0) } : causes
    }

    var emptyListState: LibraryEmptyState? {
        let state = LibraryEmptyState.forPhase(library.phase, rowCount: library.files.count,
                                               displayedCount: displayed.count)
        if state == .filteredOut, case .unavailable = indexFailure,
           ftsPaths?.isEmpty == true, !fullTextQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return .ocrSearchUnavailable
        }
        return state
    }

    /// The empty list's sentence, naming what hides the rows.
    var emptyListExplanation: String {
        ActiveFilterChip.emptyExplanation(chips: listConstraints, causes: emptyListCauses)
    }

    /// A chip's ✕: turn that one filter or search off, leaving the rest.
    func removeFilter(_ facet: FilterFacet) {
        let leaving = visit   // the smart folder's chip leaves it, a move Back returns from
        defer { recordMove(leaving: leaving) }
        switch facet {
        case .smartFolder:
            exitScope()
        case .text:
            // `runFullTextSearch`'s reset, without its task's main-thread recompute, which would undo the
            // background build below (W40.fix-reader-scope-exit-main).
            fullTextQuery = ""
            ftsGeneration += 1   // a search still running is dropped
            if sort.first?.field == .relevance, scopeRules?.rankingExpression == nil { sort = LibrarySort.default }
            ftsPaths = nil; ftsRank = nil; ftsSnippets = [:]
        case .name:
            filterSearchText = ""
            filter = filter.removing(facet)
        default:
            filter = filter.removing(facet)
        }
        recomputeInBackground()
    }

    /// The marks `displayed` was sorted with, so the selection cache sorts the same way without rebuilding them on
    /// every selection change.
    private var lastSortMarks = SortMarks()

    /// The ⚑ and ⚠︎ sort keys, built only when the sort uses them (W40.fix-reader-columns).
    private func sortMarks() -> SortMarks {
        var marks = SortMarks()
        if sort.contains(where: { $0.field == .flag }) { marks.flagged = flags.flagged }
        if sort.contains(where: { $0.field == .attention }) {
            marks.needsAttention = Set(formatStatuses.lazy.filter { $0.value.needsAttention }.map(\.key))
        }
        if sort.contains(where: { $0.field == .container }) {
            marks.containers = containerCatalog.rows.compactMapValues { $0.cell.isEmpty ? nil : $0.cell }
        }
        if sort.contains(where: { $0.field == .itemFields }) {
            marks.itemFields = itemFields.compactMapValues(\.columnText)
        }
        return marks
    }

    /// A flag toggled while the list is sorted by ⚑ moves its row, as a tag edit does under a tag sort.
    private func resortAfterFlagChange() {
        if sort.contains(where: { $0.field == .flag }) { recompute() }
    }

    /// The detected non-standard-PDF status for a file, if the content index has seen it yet.
    func formatStatus(for path: String) -> PDFFormatStatus? { formatStatuses[path] }

    /// Box/Folder/Document Start/Continuation from the content index, for the optional provenance column.
    func classification(for path: String) -> String? { classifications[path] }

    /// A file's item fields as the Inspector shows them, for the Item fields column (W49.reader-item-fields-search).
    func itemFields(for path: String) -> IndexedItemFields? { itemFields[path] }

    /// Whether another currently-displayed row shares this file's base name (case-insensitive) — the
    /// nav list then surfaces the containing folder to disambiguate. Read-only display aid.
    func isDuplicatedName(_ name: String) -> Bool { DuplicateNames.isDuplicated(name, in: duplicatedNames) }

    private var formatGeneration = 0
    /// Fold the content index's per-file classification + format flags (+ needs-attention count) into
    /// the model, then recompute. Generation-guarded so a slower earlier refresh can't clobber a newer one
    /// (same pattern as `runFullTextSearch`). Triggered on library change, committed batches and pass end.
    func refreshFormatStatuses() {
        formatGeneration += 1
        let generation = formatGeneration
        let paths = ReaderStages.measure("model.formatStatuses.paths") { library.files.map(\.path) }
        Task { [weak self] in
            guard let self else { return }
            let statuses = await self.indexer.formatStatuses(for: paths)
            let classifications = await self.indexer.classifications(for: paths)
            let itemFields = await self.indexer.itemFields(for: paths)
            let count = await self.indexer.needsAttentionCount(among: paths)   // R-5: scope to the current library
            guard generation == self.formatGeneration else { return }   // superseded by a newer refresh
            ReaderStages.measure("model.formatStatuses.publish") {
                self.formatStatuses = statuses
                self.classifications = classifications
                if self.itemFields != itemFields { self.itemFields = itemFields }
                self.needsAttentionCount = count
            }
            self.recompute()
            if self.savedSearches.searches.contains(where: { $0.search.uses(.needsAttention) || $0.search.hasTextRules }) {
                self.refreshSmartFolderCounts()   // counts follow committed content and format statuses
            }
        }
    }

    // MARK: View-state persistence (C2) — filter + sort survive relaunch (selection is persisted separately)

    /// `unsavedScope` is an Advanced Search run without saving, which comes back like a smart folder does.
    private struct ViewState: Codable {
        var filter: LibraryFilter; var sort: [ARSortDescriptor]; var scopeID: UUID?; var unsavedScope: AdvancedSearch?
    }
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
        if let d = try? JSONEncoder().encode(ViewState(filter: filter, sort: persistedSort,
                                                               scopeID: scopeIsSaved ? scope?.id : nil,
                                                               unsavedScope: scopeIsSaved ? nil : scope?.search)) {
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
            setScope(search, saved: true, announce: false)
            clearUserFilters(recompute: false)
        } else if let unsaved = s.unsavedScope, unsaved.isActive {
            setScope(SavedSearch(name: "Advanced Search", search: unsaved), saved: false, announce: false)
            clearUserFilters(recompute: false)
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
        } else if q.isEmpty && sort.first?.field == .relevance && scopeRules?.rankingExpression == nil {
            sort = LibrarySort.default   // a scope with text rules keeps its own relevance order
        }
        Task { [weak self] in
            guard let self else { return }
            let result: ContentIndex.RankedSearch? = q.isEmpty
                ? nil : await self.indexer.searchRanked(q, snippetLimit: self.ftsSnippetLimit, bodyOnly: self.library.usesCatalogue)
            guard generation == self.ftsGeneration else { return }   // superseded by a newer search
            if let result {
                self.ftsPaths = Set(result.paths)
                self.ftsRank = Dictionary(uniqueKeysWithValues: result.paths.enumerated().map { ($1, $0) })
                self.ftsSnippets = result.snippets
                self.snippetFill = SnippetFill(resultGeneration: generation, query: q)
            } else {
                self.ftsPaths = nil
                self.ftsRank = nil
                self.ftsSnippets = [:]
            }
            self.recompute()
        }
    }

    /// Highlight segments for the active query's keyword-in-context snippet of `path`, or `nil` when
    /// there is no active full-text query, no snippet for the path yet (one the search left out is then
    /// queued, and arrives with a later table reload), an empty-body doc, or the snippet carries no
    /// highlighted match. The list cell renders the returned runs as a dimmed second line under the name.
    func searchSnippet(for path: String) -> [SearchSnippet.Segment]? {
        guard !fullTextQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let hits = ftsPaths else { return nil }
        guard let raw = ftsSnippets[path], !raw.isEmpty else {
            if hits.contains(path) { requestSnippet(for: path) }
            return nil
        }
        let segments = SearchSnippet.segments(from: raw)
        return SearchSnippet.hasMatch(segments) ? segments : nil
    }

    /// The paths filled since the last call, for the table to reload the rows among them it shows.
    func takeFilledSnippetPaths() -> Set<String> {
        defer { filledSnippetPaths = [] }
        return filledSnippetPaths
    }

#if DEBUG
    /// Publishes a full-text result without an index, as `runFullTextSearch` would: the 150k list lane
    /// (`ReaderAtSizeTests`) measures the rows' cost with a query active and every snippet still to fill.
    func setFullTextResultForTesting(query: String, paths: [String], snippets: [String: String]) {
        fullTextQuery = query
        ftsGeneration += 1
        ftsPaths = Set(paths)
        ftsRank = Dictionary(uniqueKeysWithValues: paths.enumerated().map { ($1, $0) })
        ftsSnippets = snippets
        snippetFill = SnippetFill(resultGeneration: ftsGeneration, query: query)
    }

    var pendingSnippetCountForTesting: Int { snippetFill.pending.count }
#endif

    private func requestSnippet(for path: String) {
        // Only for the result on screen: between a new query and its result the old hits are still shown.
        guard snippetFill.resultGeneration == ftsGeneration, !snippetFill.query.isEmpty,
              snippetFill.queued.insert(path).inserted else { return }
        snippetFill.pending.append(path)
        if snippetFill.pending.count > Self.snippetFillQueueLimit {
            let dropped = snippetFill.pending.prefix(snippetFill.pending.count - Self.snippetFillQueueLimit)
            snippetFill.queued.subtract(dropped)
            snippetFill.pending.removeFirst(dropped.count)
        }
        guard !snippetFill.running else { return }
        snippetFill.running = true
        let generation = snippetFill.resultGeneration
        Task { [weak self] in await self?.fillSnippets(for: generation) }
    }

    /// Drains `snippetFill.pending` a batch at a time, off the main thread in the index actor. Stops when
    /// the queue is empty or a newer result replaced the one it was filling.
    private func fillSnippets(for generation: Int) async {
        let query = snippetFill.query
        while snippetFill.resultGeneration == generation, !snippetFill.pending.isEmpty {
            let batch = Array(snippetFill.pending.suffix(Self.snippetFillBatch).reversed())
            snippetFill.pending.removeLast(batch.count)
            let filled = await indexer.snippets(query, for: batch, bodyOnly: library.usesCatalogue)
            guard snippetFill.resultGeneration == generation, ftsGeneration == generation else { return }
            // What the time budget did not reach goes back on the queue, still first in line.
            snippetFill.pending.append(contentsOf: batch[filled.attempted...].reversed())
            if !filled.snippets.isEmpty {
                ftsSnippets.merge(filled.snippets) { old, _ in old }
                filledSnippetPaths.formUnion(filled.snippets.keys)
                snippetFillGeneration += 1
            }
            if filled.attempted == 0 { break }   // the index is unavailable; rows simply stay without one
        }
        if snippetFill.resultGeneration == generation { snippetFill.running = false }
    }

    /// Re-run any active full-text search after an index pass completes (Part B: search-during-index
    /// refresh). The pass may have indexed files that now match the query but were upserted after the
    /// original search ran — re-querying folds them in. Also refreshes the base scope's OCR query.
    func refreshFullTextSearchIfActive() {
        if !fullTextQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            runFullTextSearch()
        }
        if scopeRules?.hasTextRules == true { runBaseFullTextSearch() }
    }

    /// Selected files resolved against the DISPLAYED rows only, in sort order — every selection-wide
    /// action (the Inspector, Mark Read, Open, Copy Links, Flag) acts on this, so none can reach a file the
    /// list does not show. It once resolved against the whole library, which let a filtered-away
    /// selection be tagged unseen (`W40.fix-reader-phantom-selection`). Cached (recomputed on
    /// selection / sort / library change) to avoid an O(N) scan + sort on every SwiftUI render.
    var selectedFiles: [ArchiveFile] { selectedFilesCache }

    /// Unique subject tags across the library, for filter/editor suggestions. Cached (see above).
    var allSubjects: [String] { allSubjectsCache }

    /// File-count per distinct subject across the WHOLE library (not just the displayed rows), for
    /// the near-duplicate tag finder. Counts each tag once per file, case variants as one tag in the
    /// spelling most files use (`tagCounts`). Computed on demand (the finder is opened rarely) — never
    /// on the render path.
    var subjectFileCounts: [String: Int] {
        Dictionary(uniqueKeysWithValues: tagCounts(library.files.lazy.map(\.subjects)).map { ($0.tag, $0.count) })
    }

    /// The spelling the library already uses for `tag`, by tag identity, or nil when it has no such tag.
    func librarySpelling(of tag: String) -> String? { subjectSpellingByKey[tagKey(tag)] }

    /// The spelling a new tag is written in: tags that differ only in case are one tag, so a typed
    /// "lincoln" is written "Lincoln" when the library has "Lincoln" (W40.fix-tags-case-insensitive).
    func spellingForNewTag(_ tag: String) -> String { librarySpelling(of: tag) ?? tag }

    private func refreshSelectionCache() {
        let sel = selection
        selectedFilesCache = ReaderStages.measure("model.selectionCache") {
            guard !sel.isEmpty else { selectionPositions = nil; return [] }
            let positions = followedSelectionPositions(sel)
                ?? displayedPositions(of: sel)?.sorted()
                ?? displayed.indices.filter { sel.contains(displayed[$0].id) }
            selectionPositions = SelectionPositions(order: displayedOrderGeneration, ids: sel, positions: positions)
            return positions.map { displayed[$0] }
        }
    }

    /// Where the selection's rows stand in `displayed`, ascending, while the list keeps its order: a selection
    /// change is then resolved from what it added and removed, so ⇧-arrow with 500 selected looks up one row,
    /// not 501 (W40.fix-reader-selection-at-size). A row replaced in place keeps its position, and the cache
    /// reads every row from `displayed`, so it always holds the list's current values.
    private struct SelectionPositions { var order: Int; var ids: Set<ArchiveFile.ID>; var positions: [Int] }
    private var selectionPositions: SelectionPositions?

    /// The selection's positions, from the last ones and the rows added and removed since; nil when the list
    /// changed order since, or the change is too large to be worth following.
    private func followedSelectionPositions(_ sel: Set<ArchiveFile.ID>) -> [Int]? {
        guard let last = selectionPositions, last.order == displayedOrderGeneration,
              abs(last.ids.count - sel.count) <= 64 else { return nil }
        let removed = last.ids.subtracting(sel), added = sel.subtracting(last.ids)
        guard removed.count + added.count <= 64 else { return nil }
        var positions = removed.isEmpty ? last.positions : last.positions.filter { !removed.contains(displayed[$0].id) }
        guard let found = added.isEmpty ? [] : displayedPositions(of: added) else { return nil }
        for i in found {
            var lo = 0, hi = positions.count
            while lo < hi { let mid = (lo + hi) / 2; if positions[mid] < i { lo = mid + 1 } else { hi = mid } }
            positions.insert(i, at: lo)
        }
        return positions
    }

    /// Up to this many selected rows are found in the list one by one; more, and one pass over it is cheaper.
    private static let selectionLookupLimit = 4_096

    /// Where each of these rows stands in `displayed`, found by binary search on the list's sort keys
    /// (W40.fix-reader-selection-at-size), so the cost is the selection's, not the library's: a scan of every row
    /// took 90-116 ms at 116k on each arrow key. Nil when any is not found that way (a row the list does not
    /// show, or one the library changed since the list was built), or there are too many: the caller scans.
    private func displayedPositions(of ids: Set<ArchiveFile.ID>) -> [Int]? {
        guard ids.count <= Self.selectionLookupLimit, !displayed.isEmpty else { return nil }
        let rows = library.files(atPaths: ids.map(\.path))
        guard rows.count == ids.count else { return nil }
        let sort = self.sort, marks = lastSortMarks, rank = ftsRank ?? baseRank
        var positions: [Int] = []
        positions.reserveCapacity(rows.count)
        for row in rows {
            guard ids.contains(row.id), let i = Self.sortedPosition(of: row, in: displayed, before: {
                LibraryPresentation.listedBefore($0, $1, sort: sort, marks: marks, rank: rank)
            }) else { return nil }
            positions.append(i)
        }
        return positions
    }

    /// Where `file`'s row is in `list`, a list sorted by `before`: a binary search, then a walk over the rows
    /// whose sort keys equal its own. Nil when it is not there, or `list` is sorted some other way.
    private static func sortedPosition(of file: ArchiveFile, in list: [ArchiveFile],
                                       before: (ArchiveFile, ArchiveFile) -> Bool) -> Int? {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if before(list[mid], file) { lo = mid + 1 } else { hi = mid }
        }
        var k = lo
        while k < list.count, !before(file, list[k]) {
            if list[k].path == file.path { return k }
            k += 1
        }
        return nil
    }

    /// The inspector follows the selection only while it is shown (`inspectorTarget`).
    private func followSelectionInInspector() {
        guard showingEditor else { return }
        let files = selectedFilesCache
        let old = inspectorTarget.paths
        if files.count == old.count, zip(files, old).allSatisfy({ $0.path == $1 }) { return }
        let paths = files.map(\.path)
        if paths.count == old.count, Set(paths) == Set(old) {
            inspectorTarget.paths = paths   // the same files in a new order: the same editor
        } else {
            inspectorTarget = InspectorTarget(paths: paths, generation: inspectorTarget.generation &+ 1)
        }
    }

    /// A row the filter hid leaves the selection, as it leaves the table's highlight; kept, it was
    /// counted in the status bar and came back selected when the filter cleared
    /// (`W40.fix-reader-phantom-selection`). Losing a selection to a narrowing filter is the price,
    /// as in Finder.
    private func pruneSelectionToDisplayed() {
        guard !selection.isEmpty, displayedPositions(of: selection) == nil else { return }
        let visible = Set(displayed.map(\.id))
        if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
    }
    private var subjectSpellingByKey: [String: String] = [:]

    /// Tag cloud over the *currently displayed* rows: each **subject** tag with the number of visible
    /// files carrying it, alphabetical (the view scales font size by count via log). Counts each tag
    /// once per file. Built from `subjects` (not `topicalTags`) so clicking a chip is always a valid
    /// subject filter — quality (Q1–Q3) and marker-color have their own dedicated controls.
    /// Date-facet-like tokens (year/month/day/decade) are excluded even if they were demoted to
    /// `subjects` during a facet collision — they clutter the cloud and have their own column.
    private var _tagCloudCache: [(tag: String, count: Int)]?
    var tagCloud: [(tag: String, count: Int)] {
        if let cached = _tagCloudCache { return cached }
        // Case variants are one tag, shown in the spelling most of the visible files use.
        let result = tagCounts(displayed.lazy.map(\.subjects), include: { !DocumentTags.isDateFacetLike($0) })
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
        _tagCloudCache = result
        return result
    }

    /// The tag cloud's minimum-count control (W40.fix-reader-tagcloud-threshold): the tags used on at least
    /// `minimumCount` of the visible files. A tag that is in the tag filter stays, whatever its count, so it can
    /// still be clicked off.
    nonisolated static func tagCloud(_ cloud: [(tag: String, count: Int)], minimumCount: Int,
                         keeping active: Set<String>) -> [(tag: String, count: Int)] {
        guard minimumCount > 1 else { return cloud }
        let activeKeys = Set(active.map(tagKey))
        return cloud.filter { $0.count >= minimumCount || activeKeys.contains(tagKey($0.tag)) }
    }

    // MARK: Folder tree (sidebar)

    // Cheap change-signatures (see `LibraryChangeSignature`) so a tag edit — which never moves files and,
    // for read-state/quality, never touches subjects — doesn't rebuild path-/subject-invariant derived
    // state on every library emission (or re-run it on a repeat emission from a re-walk). A false
    // "unchanged" only ever
    // yields a briefly-stale derived cache, self-healing on the next real change; never a data risk.
    private var pathsSig = 0, subjectsSig = 0, matchSig = 0
    private var libraryRevision: UInt64 = 0
    private var libraryPreparation: Task<LibraryPresentation.Refresh?, Never>?

    /// React to a new `library.files`: rebuild only what actually changed, then recompute + index.
    private func libraryDidChange() {
        let change = library.takeChange()
        if ReaderStages.measure("model.applyRowChanges", { applyRowChanges(change) }) {
#if DEBUG
            rowPatchesForTesting += 1
#endif
            return
        }
        let files = library.files
        let ps = LibraryChangeSignature.paths(files)
        let pathsChanged = ps != pathsSig
        if pathsChanged { pathsSig = ps; folderTree = ReaderStages.measure("model.buildFolderTree") { buildFolderTree() } }            // paths → folder tree
        // Tag edits leave the path set alone. At scale the cache + sort pass used to block the
        // first frame with the verified chip for ~400 ms (50k rows, Debug). Prepare immutable data
        // off-main; smaller libraries keep the cheap synchronous path. No write or ledger work moves.
        if !pathsChanged, files.count >= 1_000 {
            let revision = libraryRevision, view = viewRevision, filesRevision = library.filesRevision
            let input = presentationInput(files), previousSubjects = subjectsSig
            let preparation = Task.detached(priority: .userInitiated) {
                ReaderStages.measure("presentation.prepare") {
                    LibraryPresentation.Refresh.prepare(input, previousSubjects: previousSubjects)
                }
            }
            libraryPreparation = preparation
            Task { [weak self] in
                guard let self else { return }
                guard let result = await preparation.value, !preparation.isCancelled,
                      self.libraryRevision == revision else {
                    // Superseded unapplied: the change it was rebuilding for (signatures, counts, indexing) is
                    // done by nothing else, so the next change must rebuild too, not patch.
                    if self.libraryPreparation == preparation {
                        self.libraryPreparation = nil
                        self.presentedFilesRevision = nil
                    }
                    return
                }
                self.libraryPreparation = nil
                ReaderStages.measure("model.libraryDidChange (prepared)") {
                    self.updateLibraryCaches(subjects: result.subjectsSignature, matches: result.matchSignature,
                                             spellings: result.spellings)
                    // A filter/sort/flag change may already have recomputed a newer presentation.
                    if self.viewRevision == view {
                        self.present(result.presentation, marks: input.marks, filesRevision: filesRevision)
                    }
                    self.finishLibraryChange(files, pathsChanged: false)
                }
            }
            return
        }
        libraryPreparation = nil   // an interrupted preparation is superseded by this whole rebuild
        let ss = LibraryChangeSignature.subjects(files)
        let spellings = ss == subjectsSig ? nil : LibraryPresentation.subjectSpellings(files)
        updateLibraryCaches(subjects: ss, matches: LibraryChangeSignature.matchFacets(files), spellings: spellings)
        recompute()
        finishLibraryChange(files, pathsChanged: pathsChanged)
    }

    /// A change that only replaced rows (their tags; no row came or went, no file's content changed) is
    /// patched from those rows alone (W40.fix-reader-change-incremental): each moves in `displayed` only if its
    /// sort key changed, enters or leaves it as the filter says, the smart-folder counts move by its
    /// difference, and the selection loses only a row that left. No indexing pass, format-status read, prune
    /// or second recompute starts: a tag change cannot change what those read. False: rebuild instead,
    /// because rows came or went, a file's content changed (the index must read it), or the list is in a
    /// state a patch cannot extend (empty, or a rebuild still preparing).
    private func applyRowChanges(_ change: LibraryChangeSet) -> Bool {
        guard let rows = change.rows, !rows.isEmpty, libraryPreparation == nil, !displayed.isEmpty,
              change.fields.isSubset(of: .tags) else { return false }
        let changed = rows.values.compactMap { row in row.old.flatMap { old in row.new.map { (old, $0) } } }
        guard changed.count == rows.count else { return false }
        // The list must stand where the change set starts. A recompute in between (a filter, a sort, a
        // flag) already shows the new rows, and only the parts that do not read the list remain.
        if presentedFilesRevision == change.toRevision {
            applyFacetChanges(changed, change: change)
            return true
        }
        guard presentedFilesRevision == change.fromRevision else { return false }

        let predicate = rowPredicate(scope: scope, filter: filter, ftsPaths: ftsPaths)
        let excluded = excludedAbsolutePrefixes()
        let sort = self.sort, marks = lastSortMarks, rank = ftsRank ?? baseRank
        func before(_ a: ArchiveFile, _ b: ArchiveFile) -> Bool {
            LibraryPresentation.listedBefore(a, b, sort: sort, marks: marks, rank: rank)
        }
        /// Where `file`'s row is in `list`: by binary search on its sort keys, else (a list sorted some other
        /// way) by a scan.
        func position(of file: ArchiveFile, in list: [ArchiveFile]) -> Int? {
            Self.sortedPosition(of: file, in: list, before: before) ?? list.firstIndex { $0.path == file.path }
        }

        var list = displayed
        var membershipChanged = false, orderChanged = false, cloudChanged = false
        var left = Set<ArchiveFile.ID>()
        var ambiguous = ambiguousDateCount
        for (old, new) in changed {
            if LibraryPresentation.isExcluded(new.path, by: excluded) { continue }
            ambiguous += (new.dateIsAmbiguous ? 1 : 0) - (old.dateIsAmbiguous ? 1 : 0)
            if old.subjects != new.subjects { cloudChanged = true }
            let shown = predicate(new)
            if let i = position(of: old, in: list) {
                if shown, i == 0 || !before(new, list[i - 1]), i == list.count - 1 || !before(list[i + 1], new) {
                    list[i] = new
                    continue
                }
                list.remove(at: i)
                orderChanged = true
                if !shown { membershipChanged = true; left.insert(new.id); continue }
            } else if !shown {
                continue
            } else {
                membershipChanged = true
            }
            var lo = 0, hi = list.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if before(list[mid], new) { lo = mid + 1 } else { hi = mid }
            }
            list.insert(new, at: lo)
        }
        guard !list.isEmpty else { return false }   // the empty list's explanation needs the whole rebuild

        // Every selected row left: the next row stays selected in their place, the previous at the end, so the arrow
        // keys carry on from there (owner, 2026-11-10, W40.reader-selection-current). Found in the list as it stood.
        let successor = selection.isEmpty || !selection.isSubset(of: left) ? nil
            : Self.rowAfterLeaving(selection, in: displayed, left: left,
                                   oldRows: Dictionary(changed.map { ($0.0.id, $0.0) }, uniquingKeysWith: { a, _ in a }),
                                   position: position(of:in:))

        displayed = list
        displayedGeneration += 1
        if orderChanged || membershipChanged { displayedOrderGeneration += 1 }
        if membershipChanged {
            duplicatedNames = DuplicateNames.duplicatedNames(in: list)
            cloudChanged = true
        }
        if cloudChanged { _tagCloudCache = nil }
        if ambiguous != ambiguousDateCount { ambiguousDateCount = ambiguous }

        // The selection: a row that left goes, and the cache takes the changed rows' new values.
        let changedIDs = Set(changed.map(\.1.id))
        if !left.isEmpty, !selection.isDisjoint(with: left) {
            patchingSelection = successor == nil
            selection = successor.map { [$0] } ?? selection.subtracting(left)   // a successor's cache is built anew
            patchingSelection = false
        }
        if successor != nil {
            // `refreshSelectionCache` ran against the new list.
        } else if selection.isEmpty {
            if !selectedFilesCache.isEmpty { selectedFilesCache = [] }
        } else if !selection.isDisjoint(with: changedIDs) || !left.isEmpty {
            let shownNow = changed.map(\.1).filter { selection.contains($0.id) && !left.contains($0.id)
                                                     && !LibraryPresentation.isExcluded($0.path, by: excluded)
                                                     && predicate($0) }
            let kept = selectedFilesCache.filter { !changedIDs.contains($0.id) }
            selectedFilesCache = ReaderStages.measure("model.selectionCache (patch)") {
                (kept + shownNow).sorted(by: before)   // the list's order, as `refreshSelectionCache` gives
            }
        }

        presentedFilesRevision = change.toRevision
        applyFacetChanges(changed, change: change)

        if orderChanged || membershipChanged { checkSelectionEnds() }
        restoreSelectionIfNeeded()
        applyPendingRevealIfPossible()
        if membershipChanged { reapplyPendingTopRow() }
        return true
    }

    /// The row that takes the selection's place when every selected row leaves the list: the first row after the
    /// last of them that stays, else the last row before the first of them that stays (W40.reader-selection-current).
    /// `list` is the list before the change, `oldRows` the selected rows as they were in it; nil if none is found.
    static func rowAfterLeaving(_ selection: Set<ArchiveFile.ID>, in list: [ArchiveFile], left: Set<ArchiveFile.ID>,
                                oldRows: [ArchiveFile.ID: ArchiveFile],
                                position: (ArchiveFile, [ArchiveFile]) -> Int?) -> ArchiveFile.ID? {
        let positions = selection.compactMap { oldRows[$0].flatMap { position($0, list) } }
        guard let first = positions.min(), let last = positions.max() else { return nil }
        if last + 1 < list.count, let after = list[(last + 1)...].first(where: { !left.contains($0.id) }) {
            return after.id
        }
        return list[..<first].last { !left.contains($0.id) }?.id
    }

    /// What the changed rows' facets feed besides the list: the match signature, the smart-folder counts, and
    /// the subjects only if they moved.
    private func applyFacetChanges(_ changed: [(ArchiveFile, ArchiveFile)], change: LibraryChangeSet) {
        for (old, new) in changed {
            matchSig ^= LibraryChangeSignature.matchFacets(of: old) ^ LibraryChangeSignature.matchFacets(of: new)
        }
        applyCountChanges(change)
        if changed.contains(where: { $0.0.subjects != $0.1.subjects }) { refreshSubjectsInBackground() }
    }

    private var subjectsGeneration = 0
#if DEBUG
    /// Library changes `applyRowChanges` patched rather than rebuilt.
    private(set) var rowPatchesForTesting = 0
#endif

    /// The subject union and its spellings after a patch that changed a row's subjects, off the main actor. A
    /// newer refresh, or a whole rebuild that set them itself, supersedes it.
    private func refreshSubjectsInBackground() {
        subjectsGeneration += 1
        let generation = subjectsGeneration, files = library.files, previous = subjectsSig
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                ReaderStages.measure("model.subjects (background)") { () -> (Int, [String]?) in
                    let ss = LibraryChangeSignature.subjects(files)
                    return (ss, ss == previous ? nil : LibraryPresentation.subjectSpellings(files))
                }
            }.value
            guard let self, generation == self.subjectsGeneration else { return }
            self.subjectsSig = result.0
            if let spellings = result.1 {
                self.allSubjectsCache = spellings
                self.subjectSpellingByKey = Dictionary(spellings.map { (tagKey($0), $0) }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    private func updateLibraryCaches(subjects: Int, matches: Int, spellings: [String]?) {
        subjectsGeneration += 1   // supersedes a background subjects refresh
        subjectsSig = subjects
        if let spellings {
            allSubjectsCache = spellings
            subjectSpellingByKey = Dictionary(spellings.map { (tagKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        }
        if matches != matchSig { matchSig = matches; refreshSmartFolderCounts() }
    }

    private func finishLibraryChange(_ files: [ArchiveFile], pathsChanged: Bool) {
        ReaderStages.measure("model.finishLibraryChange") { finishLibraryChangeStages(files, pathsChanged: pathsChanged) }
    }

    /// The files the content index covers: excluded folders are never added to it.
    func indexableFiles(_ files: [ArchiveFile]) -> [ArchiveFile] {
        if let rootPath = rootStore.discoveredPathPrefix, !excludedFolders.excludedRelativePaths.isEmpty {
            return files.filter { !excludedFolders.isExcludedAbsolute($0.path, rootPath: rootPath) }
        }
        return files
    }

    private func finishLibraryChangeStages(_ files: [ArchiveFile], pathsChanged: Bool) {
        // Filter excluded folders before indexing so excluded files are never added to the content index.
        let filesToIndex = indexableFiles(files)
        indexer.startIndexing(filesToIndex)             // incremental; no-op if running
        if library.usesCatalogue { refreshCatalogueEditHistory() }
        checkImproveOCRReceipts(libraryChanged: true)   // W44.reocr-reader: replaced files keep their dates
        if pathsChanged {
            refreshFormatStatuses()     // format status is path-keyed; tag-only edits can't change it
            refreshContainers()         // so are containers: a container file is read for the paths listed
        }
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
            indexer.pruneIfSettled(currentPaths: filesToIndex.map(\.path), rootPrefix: rootPath)
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
        let leaving = visit
        defer { recordMove(leaving: leaving) }
        let scopeWasActive = scope != nil
        if scopeWasActive { exitScope() }
        guard scopeWasActive || filter.pathPrefix != path else { return }
        filter.pathPrefix = path
        recomputeInBackground()
    }

    /// Whether the list is narrowed by anything "Show in All Files" would lift: a folder, a smart folder or
    /// search, the filter bar or Find.
    var canShowInAllFiles: Bool {
        guard !selection.isEmpty else { return false }
        var neutral = LibraryFilter()
        neutral.read = AppSettings.defaultReadFilter
        return scope != nil || filter != neutral || !fullTextQuery.isEmpty || !filterSearchText.isEmpty
    }

    /// "Show in All Files" (W40.reader-show-in-all-files, owner 2026-11-17): the selected rows among their
    /// neighbours. Lifts the scope, folder, filters and Find as a deep-link reveal does, then selects the same
    /// rows and scrolls to the first. A read filter left by the default that would hide one of them is
    /// lifted too, since a row not shown is not among its neighbours. A move for Back, which returns to the
    /// search with its selection.
    /// The list is built off main at corpus size, as choosing All Files is; the selection is put back as a Back's
    /// is, once the list is presented. It is emptied first so that putting it back scrolls to it.
    func showInAllFiles() {
        guard !selection.isEmpty else { return }
        showInAllFiles(ids: selection, files: selectedFiles)
    }

    /// Shows `files` (their `ids`) among their neighbours, as `showInAllFiles()` does with the selection: also how a
    /// container warning's Show reaches a file the list does not show now (W49.reader-ct-warnings-all).
    func showInAllFiles(ids: Set<ArchiveFile.ID>, files: [ArchiveFile]) {
        guard !ids.isEmpty else { return }
        let leaving = visit
        clearUserFilters(recompute: false)
        if scope != nil { exitScope() }
        filter.pathPrefix = nil
        if !files.allSatisfy(filter.matches) { filter.read = .all }
        selection = []
        recomputeInBackground()
        recordMove(leaving: leaving)
        pendingVisitSelection = (.folder(nil), ids, selection)
        visitAwaitsList = listBuildPending
        reapplyVisitSelection()
    }

    // MARK: Back and Forward (W40.reader-back-forward)

    /// What the navigation window shows, for Go ▸ Back and Forward: a folder (nil is All Files), a saved smart
    /// folder, or an Advanced Search run without saving.
    enum Place: Equatable {
        case folder(String?)
        case smartFolder(UUID)
        case search(SavedSearch)
    }

    /// A place and the rows selected there when it was left, which a return selects again, as Finder does.
    struct Visit {
        let place: Place
        let selection: Set<ArchiveFile.ID>
    }

    /// The folders, smart folders and searches this window has shown. A move is recorded by `setFolderScope`,
    /// `applyScope` and the smart folder chip's ✕, which every way of choosing a place goes through; a smart
    /// folder's edit or rename, its deletion and a new archive folder are not moves.
    @Published private(set) var placeHistory = NavigationHistory<Visit>()
    /// A return's selection still waiting for rows a smart folder's text rules have not answered yet.
    private var pendingVisitSelection: (place: Place, ids: Set<ArchiveFile.ID>, applied: Set<ArchiveFile.ID>)?
    /// A Back or Forward whose list is still being built: its first presentation's prune is not the user's.
    private var visitAwaitsList = false
    private var travelling = false

    var currentPlace: Place {
        guard let scope else { return .folder(filter.pathPrefix) }
        return scopeIsSaved ? .smartFolder(scope.id) : .search(scope)
    }

    private var visit: Visit { Visit(place: currentPlace, selection: selection) }

    var canGoBack: Bool { placeHistory.back.contains(where: placeExists) }
    var canGoForward: Bool { placeHistory.forward.contains(where: placeExists) }

    func goBack() {
        guard let to = placeHistory.goBack(from: visit, isAvailable: placeExists) else { return }
        travel(to)
    }

    func goForward() {
        guard let to = placeHistory.goForward(from: visit, isAvailable: placeExists) else { return }
        travel(to)
    }

    /// A smart folder deleted since it was shown is skipped.
    private func placeExists(_ visit: Visit) -> Bool {
        guard case .smartFolder(let id) = visit.place else { return true }
        return savedSearches.searches.contains { $0.id == id }
    }

    private func recordMove(leaving: Visit) {
        guard !travelling, leaving.place != currentPlace else { return }
        placeHistory.record(leaving: leaving)
        pendingVisitSelection = nil
    }

    private func travel(_ to: Visit) {
        pendingVisitSelection = nil
        travelling = true
        switch to.place {
        case .folder(let path): setFolderScope(path)
        case .smartFolder(let id):
            if let search = savedSearches.searches.first(where: { $0.id == id }) { applyScope(search) }
        case .search(let search): applyScope(search, saved: false)
        }
        travelling = false
        pendingVisitSelection = (to.place, to.selection, selection)
        visitAwaitsList = listBuildPending
        reapplyVisitSelection()
    }

    /// Select the returned-to place's rows that are listed. Rows a smart folder's text rules bring in later are
    /// added as they arrive, until the user changes the selection or the place.
    private func reapplyVisitSelection() {
        guard let pending = pendingVisitSelection, !listBuildPending else { return }   // the list is the place left
        guard pending.place == currentPlace, selection == pending.applied else { pendingVisitSelection = nil; return }
        let listed = pending.ids.isEmpty ? [] : pending.ids.intersection(displayed.lazy.map(\.id))
        if listed == pending.ids { pendingVisitSelection = nil }
        guard listed != selection else { return }
        let firstNew = displayed.first { listed.contains($0.id) && !selection.contains($0.id) }
        selection = listed
        pendingVisitSelection?.applied = listed
        if let firstNew { requestScroll(to: firstNew.id) }
    }

    // MARK: Deep-link reveal (archivereader://reveal)

    /// Reveal and select a file identified by a deep link. Exits any active scope/filter so the
    /// target is visible, then selects and scrolls to it. If the library is still gathering, the
    /// reveal is deferred until the target appears (or settled-absence gives up).
    func revealAndSelect(rootGUID: UUID, relativePath: String, page: Int?, jpegRelativePath: String? = nil) {
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
        // matches `$0.path` against. Composed from the root URL, this reported "Document not found
        // in the current archive" for a file visible on screen under any root whose spelling differs
        // from its resolved one. (`W26.symroot-fu1`.)
        // Joined as STRINGS, not through `URL(fileURLWithPath:)`: that initialiser normalises composed
        // Unicode, so on a volume storing a decomposed name it would produce a spelling the walk never
        // emitted and the match below would miss — trading this item's bug for `W26.idx`'s. The same
        // joiner `ExcludedFoldersStore` uses.
        let targetPath = rootPath + "/" + relativePath
        pendingReveal = targetPath
        pendingRevealPage = page
        pendingRevealJPEGRelativePath = jpegRelativePath
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
        if let file = library.files.first(where: { $0.path == targetPath }) {
            selection = [file.id]
            requestScroll(to: file.id)
            statusMessage = ""
            // W23.m4 defect 3: a link that cited a PAGE has to land ON that page. Selecting the row and
            // dropping `pendingRevealPage` — which is all this did — silently discarded the page half of
            // every `reader-page` citation Notes writes (the reveal contract in
            // `execution-plans/archive-notes/00-overview.md` §8.3 requires it be passed on). Ask the
            // window to open the viewer there; a link with no page keeps the plain select-and-scroll.
            if let page = pendingRevealPage {
                requestOpenViewer(DocumentSelection(filePaths: [file.path], initialPage: page,
                                                     jpegRelativePath: pendingRevealJPEGRelativePath,
                                                     pinsJPEGPartner: true))
            }
            pendingReveal = nil
            pendingRevealPage = nil
            pendingRevealJPEGRelativePath = nil
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
            pendingRevealJPEGRelativePath = nil
            pendingRevealSettledMisses = 0
        }
    }

    /// A catalog was published with values signed `signature`. When they changed, the smart folders with a
    /// container rule are recounted, and the list rebuilt when the scope tests a container (W47.ct-reader-facet-rules).
    /// Returns whether the scope's rules test one, so the caller can fold the list rebuild into its own.
    func containerValuesChanged(signature: Int) -> Bool {
        guard signature != containerValuesSig else { return false }
        containerValuesSig = signature
        if savedSearches.searches.contains(where: { $0.search.uses(.container) }) { refreshSmartFolderCounts() }
        return scopeRules?.uses(.container) == true
    }

    private var smartFolderCountGeneration = 0
    private var smartFolderBasis: [UUID: CountBasis] = [:]
    /// True while `smartFolderCounts` counts the library at `smartFolderCountsRevision`: the last refresh
    /// finished with every search counted at that one revision, and each row change since moved the counts.
    private var smartFolderCountsLive = false
    private var smartFolderCountsRevision: UInt64 = 0

    /// Count each saved rule tree over the whole library, independently of the open scope and user filters.
    /// Text rules use the same index answers as the Advanced Search form. Keep the previous counts until
    /// refreshed answers arrive; a changed library, rule, flag, exclusion or index pass supersedes the task.
    private func refreshSmartFolderCounts() {
        smartFolderCountGeneration += 1
        smartFolderCountsLive = false
        let generation = smartFolderCountGeneration
        let searches = savedSearches.searches
        smartFolderCounts = smartFolderCounts.filter { id, _ in searches.contains { $0.id == id } }
        Task { [weak self] in
            guard let self, generation == self.smartFolderCountGeneration else { return }
            var counts: [UUID: Int] = [:]
            var bases: [UUID: CountBasis] = [:]
            for search in searches {
                let (basis, count) = await self.countWithBasis(search.search)
                guard generation == self.smartFolderCountGeneration else { return }
                counts[search.id] = count
                bases[search.id] = basis
            }
            guard generation == self.smartFolderCountGeneration else { return }
            self.smartFolderCounts = counts
            self.smartFolderBasis = bases
            // Searches counted at different revisions (a change landed between them) are not one state to
            // move from; the change's own pass, already queued, recounts.
            let revisions = Set(bases.values.map(\.filesRevision))
            self.smartFolderCountsRevision = revisions.first ?? self.library.filesRevision
            self.smartFolderCountsLive = revisions.count <= 1
        }
    }

    /// The saved searches changed. A deletion, a rename or a reorder leaves every remaining folder's rules as they
    /// were counted, so their counts stand and only the deleted ones' are dropped; anything else is recounted.
    /// Deleting one used to recount every other folder over the whole library (W40.fix-reader-smart-folder-delete).
    private func smartFoldersChanged() {
        let searches = savedSearches.searches
        guard smartFolderCountsLive,
              searches.allSatisfy({ smartFolderBasis[$0.id]?.search == $0.search && smartFolderCounts[$0.id] != nil })
        else { refreshSmartFolderCounts(); return }
        let ids = Set(searches.map(\.id))
        if smartFolderBasis.count != ids.count { smartFolderBasis = smartFolderBasis.filter { ids.contains($0.key) } }
        if smartFolderCounts.count != ids.count { smartFolderCounts = smartFolderCounts.filter { ids.contains($0.key) } }
    }

    /// Move each smart folder's count by the changed rows' difference, the rows before against the rows after.
    /// A count that is not live (a refresh running, the saved searches changed since) is refreshed instead,
    /// off the main actor.
    private func applyCountChanges(_ change: LibraryChangeSet) {
        let searches = savedSearches.searches
        guard smartFolderCountsLive, searches.count == smartFolderBasis.count,
              searches.allSatisfy({ smartFolderBasis[$0.id]?.search == $0.search && smartFolderCounts[$0.id] != nil })
        else { refreshSmartFolderCounts(); return }
        if smartFolderCountsRevision == change.toRevision { return }   // counted after the change already
        guard smartFolderCountsRevision == change.fromRevision, let rows = change.rows?.values
        else { refreshSmartFolderCounts(); return }
        smartFolderCountsRevision = change.toRevision
        let excluded = excludedAbsolutePrefixes()
        var counts = smartFolderCounts
        ReaderStages.measure("model.countChanges") {
            for search in searches {
                guard let basis = smartFolderBasis[search.id], var count = counts[search.id] else { continue }
                for row in rows {
                    if let old = row.old, basis.counts(old, excluded: excluded) { count -= 1 }
                    if let new = row.new, basis.counts(new, excluded: excluded) { count += 1 }
                }
                counts[search.id] = count
            }
        }
        if counts != smartFolderCounts { smartFolderCounts = counts }
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
            let path = f.path
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

    private var choosingRoot = false

    func chooseRoot() {
        guard !choosingRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Common Archive Folder"
        panel.message = "Choose the folder that contains both “\(ReaderArchiveLayout.mainDirectoryName)” and “\(ReaderArchiveLayout.jpegDirectoryName)”."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choosingRoot = true
        Task {
            defer { choosingRoot = false }
            guard await CloudDriveWarning.confirmUse(of: [url]) else { return }
            adoptChosenRoot(url)
        }
    }

    private func adoptChosenRoot(_ url: URL) {
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
        // A scope from the old root can't apply to a new one, nor can its folders' Back and Forward.
        exitScope()
        placeHistory.clear()
        pendingVisitSelection = nil
        indexer.resetPruneState()   // old root's pending-prune set is invalid for the new root
        filter.pathPrefix = nil
        filter.containerFacets = nil   // another root's boxes and collections
        containerGeneration += 1       // a build for the old root still running is dropped when it lands
        containerCatalog = .empty
        containerSignature = nil
        containerBuiltSignature = nil
        containerPrefilledDraft = nil
        containerLevelsDraft = nil     // a sheet for the old root must not save into this one
        containerLevelsOpenRequest = nil
        containerLevelsError = nil
        containerEditError = nil       // the old root's refusal
        containerSetAsideOffer = nil   // and its offer
        itemFieldEditError = nil
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
        // Asked before the scan, so the first rows are read through the answer.
        askItemTypeColoursIfNeeded()
        applyItemTypePreferences()
        startLibrary(adopted)
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
        refreshContainers(force: true)   // the container files are read again, though no path changed
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
    /// `readState` widens the write boundary from MAIN to the read-state trees (MAIN and JPEGS): the
    /// owner marks JPEGs Read and Unread (W40.reader-jpeg-read). `outside` counts the rows refused for
    /// lying outside that boundary; it is part of `rejected`.
    func reverifyCacheRows(_ files: [ArchiveFile], readState: Bool = false)
        -> (files: [ArchiveFile], rejected: Int, outside: Int) {
        var verified: [ArchiveFile] = []
        var rejected = 0
        var outside = 0
        for file in files {
            // The granted root now covers the sibling JPEGS tree as well. Reader may discover rows
            // there; other tag mutations stay inside MAIN, whose ownership contract predates the wider
            // bookmark. Apply this before provenance handling so fresh and cached rows share the gate.
            guard readState ? isInsideReadStateTree(file.url) : isInsideMainArchive(file.url) else {
                rejected += 1
                outside += 1
                continue
            }
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
        return (verified, rejected, outside)
    }

    private func reverifyCacheRow(_ file: ArchiveFile, readState: Bool = false) -> ArchiveFile? {
        let result = reverifyCacheRows([file], readState: readState)
        guard let verified = result.files.first else {
            statusMessage = result.outside > 0
                ? "\(file.name) is outside the folders whose tags Reader changes, so it was not changed."
                : "Could not verify \(file.name)."
            announce(statusMessage)
            return nil
        }
        return verified
    }

    func isInsideMainArchive(_ url: URL) -> Bool {
        guard let root = rootStore.root else { return false }
        let layout = ReaderArchiveLayout(grantedRoot: root)
        guard !layout.needsCommonParentGrant else { return false }
        let mainRoot = layout.mainRoot
        return ReaderArchiveLayout.isContained(url, inRootPath: mainRoot.path)
    }

    /// The trees whose Read and Unread tags Reader may change: MAIN and, beside it under the granted
    /// parent, the JPEGS tree (W40.reader-jpeg-read). Every other tag change stays inside MAIN.
    func readStateRoots() -> [URL] {
        guard let root = rootStore.root else { return [] }
        let layout = ReaderArchiveLayout(grantedRoot: root)
        guard !layout.needsCommonParentGrant else { return [] }
        return layout.mainRoot == layout.grantedRoot ? [layout.mainRoot] : [layout.mainRoot, layout.jpegRoot]
    }

    func isInsideReadStateTree(_ url: URL) -> Bool {
        readStateRoots().contains { ReaderArchiveLayout.isContained(url, inRootPath: $0.path) }
    }

    /// The library rows for these paths, in the order given; a path the library does not hold is left out.
    /// The document window names its open file by path, and acts through the same `TagWriter` actions as the
    /// list (W40.fix-reader-menus-follow-window), so the row still passes `reverifyCacheRows` before any write.
    func libraryFiles(atPaths paths: [String]) -> [ArchiveFile] {
        ReaderStages.measure("model.libraryFiles(atPaths:)") { libraryFilesStage(atPaths: paths) }
    }

    private func libraryFilesStage(atPaths paths: [String]) -> [ArchiveFile] {
        library.files(atPaths: paths)
    }

    /// The tag actions' targets: the named paths when the document window asks, else the list's selection.
    func tagTargets(_ paths: [String]?) -> [ArchiveFile] {
        guard let paths else { return selectedFiles }
        return libraryFiles(atPaths: paths)
    }

    private func reportNotInLibrary() {
        statusMessage = "This file is not in the archive's library, so its tags cannot be changed here."
        announce(statusMessage)
    }

    /// `paths` nil acts on the list's selection; the document window passes its open file.
    func mark(_ target: ReadState, paths: [String]? = nil) {
        if refuseWhileTagBatchRuns() { return }
        if library.usesCatalogue { markCatalogue(target, paths: paths); return }
        let targets = tagTargets(paths)
        if paths != nil, targets.isEmpty { reportNotInLibrary(); return }
        let reverified = ReaderStages.measure("model.reverifyCacheRows") {
            reverifyCacheRows(targets, readState: true)
        }
        let files = reverified.files
        let counts = MarkCounts(outside: reverified.outside, failed: reverified.rejected - reverified.outside)
        guard !files.isEmpty else {
            if reverified.rejected > 0 {
                statusMessage = reverified.outside == 0
                    ? "Could not verify \(reverified.rejected) selected file" + (reverified.rejected == 1 ? "." : "s.")
                    : Self.markStatus(target, counts)
                announce(statusMessage)
            }
            return
        }
        let group = UUID()                       // §12: the whole action is one ledger group, as it is one undo
        // The intent lists the files expected to change, so a crash leaves only those in doubt.
        let expected = files.filter { $0.readState.map { $0 != target } == true }.map(\.url)
        runTagBatch("Marking \(target.rawValue)", count: files.count,
                    keys: { TagBatch.keys(path: files[$0].url.path, file: AuditLedger.fileNumber(files[$0].url)) },
                    group: group, files: expected, written: { $0.result },
                    lane: TagBatch.each { i -> TagBatchWrite in
            let f = files[i]
            let identity = f.liveIdentity()   // §6: capture lazily at edit time, per selected file
            // No `addIfMissing`: "Mark Read" never adds a read-state tag to a marker/neither file
            // (Safety §10, hard-coded); the status line says how many it left alone.
            do { return .wrote(try TagWriter.setReadState(target, on: f.url, expecting: identity)) }
            catch { return .failed }
        }) { [self] outcomes, stale in
            var counts = counts
            var verified: [TagWriteResult] = []
            for i in files.indices {
                switch outcomes[i] {
                case .wrote(let r):
                    verified.append(r)               // verified ground truth (incl. no-op) — safe to display
                    if !r.isNoOp { counts.changed += 1 }  // real changes → undo
                    else if r.after.contains(where: isReadStateWord) { counts.already += 1 }
                    else { counts.noReadState += 1 }
                case .failed: counts.failed += 1
                case nil: counts.stopped += 1
                }
            }
            // Only verified (non-throwing) writes move a row — a failed write keeps the last-discovered value and
            // must NOT vanish from a filtered view (Safety §11). The row shows TagWriter's re-read `.after`.
            library.applyVerifiedWrites(verified.filter { !stale.contains($0.url) })
            refreshUndoHistory()
            statusMessage = Self.markStatus(target, counts)
            announce(statusMessage)
        }
    }

    /// What one Mark Read / Mark Unread did, file by file. `stopped`: not reached before a cancel.
    struct MarkCounts: Equatable {
        var changed = 0, already = 0, noReadState = 0, outside = 0, failed = 0, stopped = 0
    }

    /// The status line for a mark: what changed, and why each file that did not change was left alone
    /// (W40.reader-jpeg-read: a bare "Marked 0 Read." told the owner nothing).
    static func markStatus(_ target: ReadState, _ c: MarkCounts) -> String {
        func isAre(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }
        var parts: [String] = []
        if c.failed > 0 {
            parts.append("Marked \(c.changed); \(c.failed) could not update.")
        } else if c.changed > 0 || c.already + c.noReadState + c.outside == 0 {
            parts.append("Marked \(c.changed) \(target.rawValue).")
        }
        if c.already > 0 {
            parts.append("\(c.already) \(isAre(c.already, "was", "were")) already \(target.rawValue).")
        }
        if c.noReadState > 0 {
            parts.append("\(c.noReadState) \(isAre(c.noReadState, "has", "have")) no Read or Unread tag, so "
                + "\(isAre(c.noReadState, "it was", "they were")) left alone.")
        }
        if c.outside > 0 {
            parts.append("\(c.outside) \(isAre(c.outside, "is", "are")) outside the folders whose tags Reader "
                + "changes, so \(isAre(c.outside, "it was", "they were")) not changed.")
        }
        return parts.joined(separator: " ") + cancelledNote(c.stopped)
    }

    func refreshUndoHistory() { ReaderStages.measure("model.refreshUndoHistory") { refreshUndoHistoryStage() } }

    private func refreshUndoHistoryStage() {
        // While a batch runs, its own step is not offered yet and an older one must not be undone under it.
        if tagBatch != nil {
            undoGroups = []; redoGroups = []
        } else if let root = rootStore.root {
            // MAIN, and the JPEGS tree whose read state Reader also changes (W40.reader-jpeg-read).
            let readStateRoots = readStateRoots()
            let roots = readStateRoots.isEmpty ? [ReaderArchiveLayout(grantedRoot: root).mainRoot] : readStateRoots
            undoGroups = AuditLedger.shared.undoGroups(in: roots)
            redoGroups = AuditLedger.shared.redoGroups(in: roots)
        } else { undoGroups = []; redoGroups = [] }
        undoDepth = undoGroups.count
        redoDepth = redoGroups.count
    }

    /// The names of the files the next `undoLast()` reverts, read fresh from the ledger. The document window
    /// says them, since its undo may revert a file other than the one it shows (W40.fix-reader-menus-follow-window).
    func nextUndoFileNames() -> [String] {
        refreshUndoHistory()
        return Self.fileNames(undoGroups.last ?? [])
    }

    /// When the change the next `undoLast()` reverts was made, read fresh from the ledger; for `redoLast()`, when
    /// its undo was. A window's rotations are ordered against these, most recent first (W40.reader-rotate-undo).
    func nextUndoDate() -> Date? { refreshUndoHistory(); return knownUndoDate }
    func nextRedoDate() -> Date? { refreshUndoHistory(); return knownRedoDate }
    /// The same from the history last read, without reading the ledger: for a menu title drawn in a view update.
    var knownUndoDate: Date? { undoGroups.last?.map(\.timestamp).max() }
    var knownRedoDate: Date? { redoGroups.last?.map(\.timestamp).max() }

    /// `nextUndoFileNames()` for `redoLast()`.
    func nextRedoFileNames() -> [String] {
        refreshUndoHistory()
        return Self.fileNames(redoGroups.last ?? [])
    }

    private static func fileNames(_ batch: [AuditLedger.Entry]) -> [String] {
        var seen = Set<String>()
        return batch.map { URL(fileURLWithPath: $0.path).lastPathComponent }.filter { seen.insert($0).inserted }
    }

    /// `then` runs once the undo has reported, which for a large batch is after it has run off the main actor.
    func undoLast(then: (@MainActor () -> Void)? = nil) {
        if refuseWhileTagBatchRuns() { then?(); return }
        refreshUndoHistory()
        guard let batch = undoGroups.last else { then?(); return }
        reverse(batch, redo: false, then: then)
    }

    /// Redo Tag Change (⇧⌘Z; W40.fix-reader-redo): reverse the newest undo that no new change has followed.
    /// The undo's own lines are applied the way undo applies a forward line, so redo carries every guard
    /// undo does: identity, the main archive, the fresh read, no token past its count before the undo.
    func redoLast(then: (@MainActor () -> Void)? = nil) {
        if refuseWhileTagBatchRuns() { then?(); return }
        refreshUndoHistory()
        guard let batch = redoGroups.last else { then?(); return }
        reverse(batch, redo: true, then: then)
    }

    /// What one line of an undo or redo did. A line a cancel stopped has no outcome.
    private enum Reversal: Sendable {
        case reversed(TagWriteResult)
        /// `retry`: the line comes back as its own undo step.
        case failed(retry: Bool)

        var result: TagWriteResult? { if case .reversed(let r) = self { r } else { nil } }
    }

    /// Apply the inverse of every line of `batch` (one ledger group): an undo of a forward action or a redo,
    /// or (`redo`) a redo of an undo.
    private func reverse(_ batch: [AuditLedger.Entry], redo: Bool, then: (@MainActor () -> Void)?) {
        guard let group = batch.first?.group else { then?(); return }
        let verb = redo ? "redo" : "undo", undone = redo ? "redone" : "undone"
        // Reserve durably before the first inverse. An append failure must never allow a later
        // relaunch to replay a non-idempotent occurrence addition.
        guard redo ? AuditLedger.shared.beginRedo(group) : AuditLedger.shared.beginUndo(group) else {
            statusMessage = "Could not record \(verb) safely; no files were changed."
            announce(statusMessage)
            then?()
            return
        }
        let bounds = tagWriteBounds()
        let reversal = UUID()
        // A lane holds every line of one file (`TagBatch.lanes`), so this per-lane order is the batch's order
        // for that file. A batch lists one file's writes newest first. Once one of them fails, its older
        // writes are left alone too: undoing an older write under a newer one that is still on disk, and then
        // retrying the newer one, could put back a tag the step removed. They share the first failure's fate.
        // A cancel stops a lane between lines, so an older line is never reversed under an unreversed newer one,
        // and the lines it leaves are kept to undo later, unless they share an earlier line's failure.
        let lane: @Sendable ([Int], TagBatch.Control) -> [(Int, Reversal)] = { members, control in
            var failedFiles: [AuditLedger.FileNumber: Bool] = [:]
            var out: [(Int, Reversal)] = []
            var stopped = false
            for i in members {
                let entry = batch[i]
                // Before the cancel check: a line that shares a failure's fate writes nothing, and one a cancel
                // left unreached would come back as an undo step of its own, under the newer line that failed.
                if let file = entry.file, let mayRetry = failedFiles[file] {
                    out.append((i, .failed(retry: mayRetry && (entry.attempt ?? 1) < AuditLedger.undoAttemptLimit)))
                    control.step()
                    continue
                }
                if stopped || control.isCancelled { stopped = true; continue }
                defer { control.step() }
                do {
                    let target = try AuditLedger.undoTarget(entry)
                    // A line that changes only Read/Unread may be reversed in the JPEGS tree too; any other
                    // line only inside MAIN, even when its file has since moved into JPEGS. Judged by the
                    // inverse, not the op: a redo line's op is `.undo` whatever it changed.
                    let readStateOnly = entry.inverse.label == nil
                        && (entry.inverse.add + entry.inverse.remove).allSatisfy(isReadStateWord)
                    guard bounds.allows(target.url, readStateOnly: readStateOnly) else {
                        throw TagWriteError.identityMismatch("file is outside the current archive")
                    }
                    let inverse = TagOccurrenceDelta(add: entry.inverse.add, remove: entry.inverse.remove,
                        color: entry.inverse.label.map { .restoreLabel($0) })
                    out.append((i, .reversed(try TagWriter.applyOccurrence(inverse, to: target.url,
                        expecting: target.identity,
                        undoing: .init(before: entry.before, afterLabel: entry.afterLabel), op: redo ? .redo : .undo))))
                } catch {
                    let mayRetry = AuditLedger.undoMayBeRetried(after: error, attempt: entry.attempt ?? 1)
                    out.append((i, .failed(retry: mayRetry)))
                    if let file = entry.file { failedFiles[file] = mayRetry }
                }
            }
            return out
        }
        runTagBatch(redo ? "Redoing" : "Undoing", count: batch.count,
                    keys: { TagBatch.keys(path: batch[$0].path, file: batch[$0].file) },
                    group: reversal, undoes: redo ? nil : group, redoes: redo ? group : nil,
                    written: { $0.result }, lane: lane) { [self] outcomes, stale in
            var verified: [TagWriteResult] = []
            var failures: [String] = []
            // Read back in the batch's order, whatever order the lanes finished in.
            var kept: [(entry: AuditLedger.Entry, attempted: Bool)] = []
            var retried = 0, stopped = 0
            for (i, entry) in batch.enumerated() {
                switch outcomes[i] {
                case .reversed(let r): verified.append(r)
                case .failed(let retry):
                    failures.append(URL(fileURLWithPath: entry.path).lastPathComponent)
                    if retry { kept.append((entry, true)); retried += 1 }
                case nil:
                    kept.append((entry, false)); stopped += 1
                }
            }
            // The batch is already consumed; only the members that failed for a cause that may pass come
            // back, as their own undo step (W40.fix-reader-undo-partial), with any a cancel never reached.
            // Re-recorded oldest first, as they were written, so the history reads them back newest first again.
            let keptOK = AuditLedger.shared.keepForRetry(kept.reversed(), of: group, redo: redo)
            let keptRetries = keptOK ? retried : 0
            library.applyVerifiedWrites(verified.filter { !stale.contains($0.url) })
            // A retry step (a failure's, or what a cancel left) reverses the group its lines were first part of.
            folderDateRecordsFollow(verified, reversed: batch.first?.retryOf ?? group,
                                    reversal: reversal)   // W49.reader-folder-date-undo-fu
            refreshUndoHistory()
            let again = redo ? "Redo" : "Undo"
            var message = TagChangeStatus.reversal(verified, redo: redo)
            if !failures.isEmpty {
                message += "; \(failures.count) could not be \(undone) (\(failures.prefix(3).joined(separator: ", ")))."
                if keptRetries > 0 {
                    message += keptRetries == failures.count
                        ? " \(again) again to retry." : " \(again) again to retry \(keptRetries)."
                }
            } else { message += "." }
            if stopped > 0 {
                message += keptOK
                    ? " Cancelled; \(stopped) change\(stopped == 1 ? " was" : "s were") not \(undone). \(again) again to finish."
                    : " Cancelled; \(stopped) change\(stopped == 1 ? "" : "s") could not be kept to \(verb) later."
            }
            statusMessage = message
            announce(statusMessage)
            then?()
        }
    }

    // MARK: Keyboard triage (G4) — fast next/previous-unread navigation + mark-read-and-advance.
    //
    // These move the selection and, for the combined action, mark Read; ALL read-state mutation routes
    // through `mark(.read)` → `TagWriter` (with undo). They add NO new write path — the next/previous
    // helpers are pure selection math (`TriageNavigation`) and never touch a file.

    /// `atTop` puts the row at the top of the list (a relaunch's place) rather than just into view.
    private func requestScroll(to id: ArchiveFile.ID, atTop: Bool = false) {
        if !atTop { pendingTopRow = nil }   // any other scroll is the user's, or a link's, and wins
        scrollTargetID = id; scrollTargetAtTop = atTop; scrollRequest &+= 1
    }

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
        if refuseWhileTagBatchRuns() { return }
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
        if library.usesCatalogue {
            markCatalogue(.read) { [weak self] verified in
                guard let self, self.selection == sel, !verified.isEmpty, let target else { return }
                self.selection = [target]
                self.requestScroll(to: target)
            }
            return
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
    /// `paths` nil acts on the list's selection; the tag editor opened from the document window passes its file.
    func applyEdit(_ op: TagEditOp, paths: [String]? = nil, physicalPageIndex: Int? = nil) {
        if refuseWhileTagBatchRuns() { return }
        let op = inLibrarySpelling(op)
        if library.usesCatalogue {
            applyCatalogueTagEdit(op, paths: paths, physicalPageIndex: physicalPageIndex)
            return
        }
        let targets = tagTargets(paths)
        if paths != nil, targets.isEmpty { reportNotInLibrary(); return }
        let reverified = ReaderStages.measure("model.reverifyCacheRows") { reverifyCacheRows(targets) }
        let files = reverified.files
        guard !files.isEmpty else {
            if reverified.rejected > 0 {
                statusMessage = "Could not verify \(reverified.rejected) selected file"
                    + (reverified.rejected == 1 ? "." : "s.")
                announce(statusMessage)
            }
            return
        }
        let rejected = reverified.rejected
        let group = UUID()                       // §12: one ledger group, as it is one undo
        let planned = files.map { (f: $0, delta: TagEditing.userDelta(for: op, given: $0.tags)) }   // a date edit is its check too
            .filter { !$0.delta.isEmpty }
        runTagBatch("Editing tags", count: planned.count,
                    keys: { TagBatch.keys(path: planned[$0].f.url.path, file: AuditLedger.fileNumber(planned[$0].f.url)) },
                    group: group, files: planned.map(\.f.url), written: { $0.result },
                    lane: TagBatch.each { i -> TagBatchWrite in
            let (f, delta) = planned[i]
            let identity = f.liveIdentity()   // §6: capture lazily at edit time, per selected file
            do { return .wrote(try TagWriter.apply(delta, to: f.url, expecting: identity)) }
            catch { return .failed }
        }) { [self] outcomes, stale in
            var changed = 0, failures = rejected, stopped = 0
            var verified: [TagWriteResult] = []
            for i in planned.indices {
                switch outcomes[i] {
                case .wrote(let r):
                    verified.append(r)
                    if !r.isNoOp { changed += 1 }
                case .failed: failures += 1
                case nil: stopped += 1
                }
            }
            // one O(N+M) overlay pass (was per-file O(N*M))
            library.applyVerifiedWrites(verified.filter { !stale.contains($0.url) })
            if case .addSubject(let subject) = op, verified.contains(where: { DocumentTags.parse(raw: $0.after, labelNumber: $0.afterLabel).subjects.contains(subject) }) {
                // The next Return may precede the background autocomplete refresh.
                subjectSpellingByKey[tagKey(subject)] = subject
            }
            refreshUndoHistory()
            statusMessage = "Edited \(changed) file\(changed == 1 ? "" : "s")"
                + (failures > 0 ? "; \(failures) could not update." : ".") + Self.cancelledNote(stopped)
            announce(statusMessage)
        }
    }

    // MARK: Corpus-wide tag rename (D1, Tier-2). Every file carrying `old` gets `old` removed + `new`
    // added, via the audited TagWriter — one grouped undo, partial failures surfaced, never all-or-nothing.

    @Published var renamingTag: String?     // non-nil while the rename-tag sheet is open (the old tag)
    @Published var showingSimilarTags = false   // near-duplicate subject-tag finder sheet

    /// Number of files carrying `tag` (for the rename sheet's "affects N files").
    func affectedFileCount(forTag tag: String) -> Int {
        library.files.filter { isInsideMainArchive($0.url) && $0.hasSubject(tag) }.count
    }

    /// Whether some file carries `tag` in another spelling, so renaming it to itself still re-spells it:
    /// the cloud shows the spelling most files use, and that is the one a rename most often unifies on.
    func hasOtherSpellings(of tag: String) -> Bool {
        library.files.contains { f in f.hasSubject(tag) && f.subjects.contains { $0 != tag && isSameTag($0, tag) } }
    }

    /// Open the rename-tag sheet from a menu — seed with the active tag filter, else the top visible tag.
    func beginRenameTag() {
        renamingTag = filter.subjects.sorted().first ?? tagCloud.first?.tag
        if renamingTag == nil { statusMessage = "No tags to rename in the current view."; announce(statusMessage) }
    }

    func renameTag(from oldTag: String, to newTag: String) {
        if refuseWhileTagBatchRuns() { return }
        let old = oldTag                                    // tag identity — must match the sheet's
        let typed = newTag.trimmingCharacters(in: .whitespaces)  // affectedFileCount(forTag: oldTag)
        // Renaming into another existing tag merges into it in its spelling; a case-only rename of the
        // same tag is how its spelling is changed, so that keeps the case as typed.
        let new = isSameTag(typed, old) ? typed : spellingForNewTag(typed)
        guard !old.isEmpty, !new.isEmpty, new != old || hasOtherSpellings(of: old) else { return }
        if library.usesCatalogue {
            let paths = library.files.filter { $0.hasSubject(old) }.map(\.path)
            editCatalogueSubjects(paths: paths) { subjects in
                if isSameTag(old, new) {
                    return subjects.map { isSameTag($0, old) ? new : $0 }
                }
                let retained = subjects.filter { !isSameTag($0, old) }
                return retained.contains { isSameTag($0, new) } ? retained : retained + [new]
            }
            return
        }
        let reverified = reverifyCacheRows(library.files.filter { $0.hasSubject(old) })
        let affected = reverified.files
        guard !affected.isEmpty else {
            statusMessage = reverified.rejected > 0
                ? "Could not verify \(reverified.rejected) matching file"
                    + (reverified.rejected == 1 ? "." : "s.")
                : "No files carry the tag “\(old)”."
            announce(statusMessage)
            return
        }
        let rejected = reverified.rejected
        // Capture each affected file's identity now (§6), when the rename is confirmed, then run the conditional
        // fresh-read rename independently. A file replaced under its path while the batch runs, or no longer
        // carrying `old`, is never retagged; one failure does not stop its neighbours.
        let urls = affected.map(\.url)
        let identities = affected.map { $0.liveIdentity() }
        let group = UUID()                                  // §12: one ledger group, as it is one undo
        runTagBatch("Renaming “\(old)”", count: urls.count,
                    keys: { TagBatch.keys(path: urls[$0].path, file: AuditLedger.fileNumber(urls[$0])) },
                    group: group, files: urls, written: { $0.result },
                    lane: TagBatch.each { i -> TagBatchWrite in
            let url = urls[i]
            do { return .wrote(try TagWriter.renameToken(from: old, to: new, on: url, expecting: identities[i])) }
            catch { return .failed }
        }) { [self] outcomes, stale in
            var changed = 0, failures = rejected, stopped = 0
            var verified: [TagWriteResult] = []
            for i in urls.indices {
                switch outcomes[i] {
                case .wrote(let r):
                    verified.append(r)
                    if !r.isNoOp { changed += 1 }
                case .failed: failures += 1
                case nil: stopped += 1
                }
            }
            library.applyVerifiedWrites(verified.filter { !stale.contains($0.url) })
            refreshUndoHistory()   // ONE grouped undo
            statusMessage = (failures == 0
                ? "Renamed “\(old)” → “\(new)” on \(changed) file\(changed == 1 ? "" : "s")."
                : "Renamed \(changed); \(failures) could not update.") + Self.cancelledNote(stopped)
            announce(statusMessage)
        }
    }

    // MARK: Inline single-file edits (from the list cells). Editing MULTIPLE files uses the ⌥⌘I
    // group editor; these act on exactly one file, still via the audited TagWriter + grouped undo.

    func applyEdit(_ op: TagEditOp, to file: ArchiveFile) {
        if refuseWhileTagBatchRuns() { return }
        if library.usesCatalogue { applyEdit(op, paths: [file.path]); return }
        guard let file = reverifyCacheRow(file) else { return }
        applyDelta(TagEditing.userDelta(for: inLibrarySpelling(op), given: file.tags), to: file)
    }

    /// An added subject is written in the library's spelling of it (`spellingForNewTag`).
    private func inLibrarySpelling(_ op: TagEditOp) -> TagEditOp {
        guard case .addSubject(let s) = op else { return op }
        return .addSubject(spellingForNewTag(s.trimmingCharacters(in: .whitespaces)))
    }

    /// Commit an inline subject-token edit. `base` is the token set the user STARTED editing from
    /// (snapshotted by the field at edit-begin) — NOT the file's current `subjects`, which may have moved
    /// under an active edit (a repeat emission from a re-walk / group edit / undo to the same file).
    /// Diffing against the
    /// edit-start base means the delta names ONLY what the user actually changed, so `TagWriter`'s fresh
    /// read preserves any concurrent third-party tag (never dropping an untouched token). Applied as ONE
    /// delta = one write + one undo step; a no-op edit writes nothing. Subjects only — other facets stay.
    /// Returns whether the file now has the edit: false when it could not be verified or written.
    @discardableResult
    func commitSubjectEdit(from base: [String], to edited: [String], for file: ArchiveFile) -> Bool {
        if refuseWhileTagBatchRuns() { return false }
        if library.usesCatalogue {
            let delta = TagEditing.subjectDelta(from: base, to: edited.map(spellingForNewTag))
            guard !delta.isEmpty else { return true }
            return editCatalogueSubjects(paths: [file.path]) { subjects in
                let retained = subjects.filter { subject in !delta.remove.contains { isSameTag($0, subject) } }
                return retained + delta.add.filter { new in !retained.contains { isSameTag($0, new) } }
            }
        }
        guard let file = reverifyCacheRow(file) else { return false }
        return applyDelta(TagEditing.subjectDelta(from: base, to: edited.map(spellingForNewTag)), to: file)
    }

    func setReadStateInline(_ target: ReadState, for file: ArchiveFile) {
        if refuseWhileTagBatchRuns() { return }
        if library.usesCatalogue { markCatalogue(target, paths: [file.path]); return }
        guard let file = reverifyCacheRow(file, readState: true) else { return }
        let identity = file.liveIdentity()   // §6: capture lazily at edit time
        let group = UUID()
        do {
            let r = try AuditLedger.withContext(group: group) {
                try TagWriter.setReadState(target, on: file.url, addIfMissing: true, expecting: identity)
            }
            reflect(r)
        }
        catch { statusMessage = "Could not update \(file.name)."; announce(statusMessage) }
    }

    /// A click on the Read cell: Read → Unread; Unread/none → Read.
    func toggleReadState(for file: ArchiveFile) {
        if library.usesCatalogue {
            setReadStateInline(file.readState == .read ? .unread : .read, for: file)
            return
        }
        guard let file = reverifyCacheRow(file, readState: true) else { return }
        setReadStateInline(file.readState == .read ? .unread : .read, for: file)
    }

    /// The Read cell's Clear Read State. Both tokens are named, not the row's: `TagWriter` re-reads the file and
    /// matches Read/Unread in any case, so a row that is behind the file still clears whatever the file holds.
    func clearReadState(for file: ArchiveFile) {
        if refuseWhileTagBatchRuns() { return }
        if library.usesCatalogue {
            applyCatalogueFileField(.readState, .clear, paths: [file.path])
            return
        }
        guard let file = reverifyCacheRow(file, readState: true) else { return }
        applyDelta(TagDelta(remove: ReadState.allCases.map(\.rawValue)), to: file, readState: true)
    }

    /// `readState`: the delta touches only Read/Unread, so the JPEGS tree is in bounds too.
    @discardableResult
    private func applyDelta(_ delta: TagDelta, to file: ArchiveFile, readState: Bool = false) -> Bool {
        guard !delta.isEmpty else { return true }
        guard let file = reverifyCacheRow(file, readState: readState) else { return false }
        let identity = file.liveIdentity()   // §6: capture lazily at edit time
        let group = UUID()
        do {
            let r = try AuditLedger.withContext(group: group) { try TagWriter.apply(delta, to: file.url, expecting: identity) }
            reflect(r)
            return true
        }
        catch { statusMessage = "Could not edit \(file.name)."; announce(statusMessage); return false }
    }

    /// Reflect one verified inline write in the display (overlay) and push it as its own undo step.
    private func reflect(_ r: TagWriteResult) {
        library.applyVerifiedWrites([r])
        if !r.isNoOp { refreshUndoHistory() }
        if AuditLedger.shared.hasRecordingGap || AuditLedger.shared.recordingFailureCount != seenRecordingFailures {
            statusMessage = "Edited a file."
            announce(statusMessage)
        }
    }

    /// Library data-quality snapshot (for the health popover).
    struct DataQuality: Sendable {
        var total = 0, noDate = 0, noQuality = 0, dateUncertain = 0, bothReadUnread = 0, markers = 0
    }
    var dataQuality: DataQuality {
        var q = DataQuality(); q.total = library.files.count
        for f in library.files {
            if f.tags.year == nil { q.noDate += 1 }
            if f.tags.quality == nil { q.noQuality += 1 }
            if f.tags.dateUncertain { q.dateUncertain += 1 }
            if f.itemType != nil { q.markers += 1 }
            let hasRead = f.tags.raw.contains { $0.caseInsensitiveCompare("Read") == .orderedSame }
            let hasUnread = f.tags.raw.contains { $0.caseInsensitiveCompare("Unread") == .orderedSame }
            if hasRead && hasUnread { q.bothReadUnread += 1 }   // corruption: both state tokens
        }
        return q
    }

    /// VoiceOver announcement (accessibility). Silent no-op if there is no key window.
    func announce(_ messageToAnnounce: String) {
        let message: String
        if AuditLedger.shared.hasRecordingGap {
            if !statusMessage.contains("Audit history could not be saved") {
                statusMessage += " Audit history could not be saved; undo is unavailable."
            }
            message = statusMessage
        } else if AuditLedger.shared.recordingFailureCount != seenRecordingFailures {
            statusMessage += " Some audit history could not be saved; undo history is incomplete."
            message = statusMessage
        } else { message = messageToAnnounce }
        seenRecordingFailures = AuditLedger.shared.recordingFailureCount
        guard !message.isEmpty, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The library's spelling of `candidate` when it is the same tag typed in another case, for the note
    /// that it will be written in that spelling; nil when the tag is new or typed as it is spelt.
    func existingSpelling(differingFrom candidate: String) -> String? {
        let c = candidate.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, let s = librarySpelling(of: c), s != c else { return nil }
        return s
    }

    // MARK: Copy links

    func copyLinks() {
        let urls = selectedFiles.map(\.url)
        guard !urls.isEmpty else { return }
        statusMessage = Self.copyLinks(urls)
    }

    /// Puts the links on the clipboard and returns the status line; the document window copies its own file's.
    static func copyLinks(_ urls: [URL]) -> String {
        let text = AppSettings.linkFormatter.clipboardString(for: urls)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return "Copied \(urls.count) link\(urls.count == 1 ? "" : "s")."
    }

    /// Keep the status line to the copy confirmation (owner, reader-2 row 25).
    static func archiveLinksCopiedMessage(count: Int) -> String {
        "Copied \(count) archive link\(count == 1 ? "" : "s")."
    }

    /// `paths` nil copies the list's selection; the document window passes its open file.
    func copyArchiveLinks(paths: [String]? = nil) {
        let files = tagTargets(paths)
        guard !files.isEmpty, let rootPath = rootStore.discoveredPathPrefix else {
            statusMessage = "Choose an archive folder first."
            return
        }
        guard let target = prepareArchiveLinkCopy(for: paths == nil ? nil : files.first?.url), let marker = target.marker,
              let jpegPartnerIndex = library.jpegPartnerIndex else { return }
        let mainRootPath = target.mainRootPath
        // Durable links are the primary copy result. Put them on the clipboard before optional page
        // previews render, then replace this item only if we still own the clipboard.
        let immediateItem = ArchiveLinkWriter.pasteboardItemWithoutThumbnails(
            for: files, rootPath: rootPath, marker: marker, mainRootPath: mainRootPath,
            jpegPartnerIndex: jpegPartnerIndex
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([immediateItem])
        let expectedChangeCount = NSPasteboard.general.changeCount
        archiveCopyGeneration &+= 1
        let generation = archiveCopyGeneration
        statusMessage = Self.archiveLinksCopiedMessage(count: files.count)
        Task {
            let item = await ArchiveLinkWriter.pasteboardItem(
                for: files, rootPath: rootPath, marker: marker, thumbnailer: thumbnailer,
                mainRootPath: mainRootPath, jpegPartnerIndex: jpegPartnerIndex
            )
            guard archiveCopyGeneration == generation,
                  NSPasteboard.general.changeCount == expectedChangeCount else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
        }
    }

    /// Shared by navigation and document/preview copies. No marker write until every read-side
    /// prerequisite is ready. Return the committed target synchronously (Combine publishes later).
    func prepareArchiveLinkCopy(for fileURL: URL? = nil) -> ArchiveLinkTarget? {
        guard let root = rootStore.root, let rootPath = rootStore.discoveredPathPrefix else {
            statusMessage = "Choose an archive folder first."
            return nil
        }
        if let fileURL, !ReaderArchiveLayout.isContained(fileURL, inRootPath: rootPath) {
            statusMessage = "This document belongs to a different archive. Reopen its archive folder to copy a link."
            return nil
        }
        // Preserve the precise refusal even while the optional JPEG partner scan is pending.
        if let reason = RootMarkerState.reading(root).degradation {
            statusMessage = reason.message
            return nil
        }
        guard library.jpegPartnerScanStatus == .ready,
              let index = library.jpegPartnerIndex, index.isClean else {
            statusMessage = jpegPartnerUnavailableMessage
            announce(statusMessage)
            return nil
        }
        guard let marker = rootStore.prepareMarkerForLinkCopy() else {
            statusMessage = rootStore.markerState.degradation?.message ?? "Choose an archive folder first."
            return nil
        }
        publishLinkTarget()
        return ArchiveLinkTarget(rootPath: rootPath, marker: marker,
                                 mainRootPath: ReaderArchiveLayout(grantedRoot: root).mainRoot.path,
                                 preferenceGUID: rootStore.preferenceGUID)
    }

    private var jpegPartnerUnavailableMessage: String {
        switch library.jpegPartnerScanStatus {
        case .needsCommonParentGrant:
            return "Choose the common folder containing both “\(ReaderArchiveLayout.mainDirectoryName)” and “\(ReaderArchiveLayout.jpegDirectoryName)” to use JPEG partners."
        case .scanning:
            return "JPEG partner scan is still running. Try copying the link again when it finishes."
        case .incomplete:
            return "Reader could not verify the JPEG partner index. Rescan the archive before copying a durable link."
        case .notConfigured, .ready:
            return "Choose an archive folder before copying a durable link."
        }
    }

    // MARK: Open / reveal

    func documentSelection() -> DocumentSelection {
        DocumentSelection(filePaths: selectedFiles.map(\.path))
    }

    /// The files whose image pages the preview is likely to show next, most likely first: the selection's
    /// first two files (Space opens on the first, → steps to the second), and with the preview up, the rows
    /// above and below a single selection, where ↑/↓ go (W40.fix-reader-preview-image-speed).
    func previewPrefetchPaths(neighbours: Bool) -> [String] {
        let files = selectedFiles
        guard let first = files.first else { return [] }
        var paths = files.prefix(2).map(\.path)
        guard neighbours, files.count == 1,
              let i = displayedPositions(of: [first.id])?.first ?? displayed.firstIndex(where: { $0.id == first.id })
        else { return paths }
        if i + 1 < displayed.count { paths.append(displayed[i + 1].path) }
        if i > 0 { paths.append(displayed[i - 1].path) }
        return paths
    }

    /// Move the selection one row up/down the *currently displayed* list (single-select), for browsing
    /// via the preview's ↑/↓. Anchors on the current selection's position in `displayed`.
    func moveSelectionInList(_ delta: Int) {
        guard !displayed.isEmpty else { return }
        let next: ArchiveFile.ID = ReaderStages.measure("model.moveSelectionInList.find") {
            let positions = currentSelectionPositions()
            let anchor = delta < 0 ? (positions.min() ?? 0) : (positions.max() ?? -1)
            return displayed[max(0, min(displayed.count - 1, anchor + delta))].id
        }
        selection = [next]
        requestScroll(to: next)
    }

    /// ⇧↑/⇧↓, in the list and in the preview sheet alike (W40.reader-selection-current): move the cursor one row
    /// and select every row from the anchor to it, so going back past the anchor shrinks the run and then grows
    /// it the other way, as an `NSTableView` does. Rows selected outside that run (⌘-clicked) stay selected. With
    /// no ends to go by (⌘-clicked rows, or a re-sort scattered the run) the run starts at the selection's last row
    /// for ⇧↓ and its first for ⇧↑, so one key adds one row. With nothing selected it is a plain move.
    func extendSelectionInList(_ delta: Int) {
        guard !displayed.isEmpty else { return }
        let positions = currentSelectionPositions()
        guard let first = positions.first, let last = positions.last else { moveSelectionInList(delta); return }
        var anchor = delta > 0 ? last : first, from = anchor
        if let a = selectionAnchor.flatMap(position(ofListed:)), let c = selectionCursor.flatMap(position(ofListed:)) {
            anchor = a; from = c
        }
        let cursor = max(0, min(displayed.count - 1, from + delta))
        let anchorID = displayed[anchor].id, cursorID = displayed[cursor].id
        let oldRun = displayed[min(anchor, from)...max(anchor, from)].lazy.map(\.id)
        let outside = selection.count > oldRun.count ? selection.subtracting(oldRun) : []
        selection = outside.union(displayed[min(anchor, cursor)...max(anchor, cursor)].lazy.map(\.id))
        selectionAnchor = anchorID
        selectionCursor = cursorID
        requestScroll(to: cursorID)
    }

    /// The list reports the ends after the user changed its selection (`tableViewSelectionDidChange`): the
    /// cursor is the row it last selected; the anchor stays while it is still selected and is not the cursor,
    /// else the selected row farthest from the cursor takes its place. A ⌘-click leaves rows unselected between
    /// the anchor and the row clicked; that row is then the anchor too, as it is the table's.
    func noteSelectionEnds(cursor: ArchiveFile.ID?, otherEnd: ArchiveFile.ID?) {
        guard selection.count > 1 else { return }       // one row is both ends already (`followSelectionEnds`)
        if let cursor, selection.contains(cursor) { selectionCursor = cursor }
        if selectionAnchor == nil || selectionAnchor == selectionCursor, let otherEnd, selection.contains(otherEnd) {
            selectionAnchor = otherEnd
        }
        if let a = selectionAnchor, let c = selectionCursor, a != c,
           let pa = position(ofListed: a), let pc = position(ofListed: c),
           !displayed[min(pa, pc)...max(pa, pc)].allSatisfy({ selection.contains($0.id) }) {
            selectionAnchor = c
        }
    }

    private func followSelectionEnds() {
        if selection.count == 1 {
            selectionAnchor = selection.first; selectionCursor = selectionAnchor
            return
        }
        if let a = selectionAnchor, !selection.contains(a) { selectionAnchor = nil }
        if let c = selectionCursor, !selection.contains(c) { selectionCursor = nil }
    }

    /// The selection's positions in `displayed`, ascending.
    private func currentSelectionPositions() -> [Int] {
        let sel = selection
        return selectionPositions.flatMap { $0.order == displayedOrderGeneration && $0.ids == sel ? $0.positions : nil }
            ?? displayedPositions(of: sel)?.sorted()
            ?? displayed.indices.filter { sel.contains(displayed[$0].id) }
    }

    /// After the list is rebuilt or reordered, the ends stand only while the run between them is still the
    /// selection: a re-sort can carry them far apart, and one ⇧↓ would then select every row between
    /// (W40.reader-selection-current). An `NSTableView` forgets its anchor on a reload in the same way.
    private func checkSelectionEnds() {
        guard selection.count > 1, let a = selectionAnchor, let c = selectionCursor else { return }
        guard let pa = position(ofListed: a), let pc = position(ofListed: c), abs(pa - pc) + 1 == selection.count else {
            selectionAnchor = nil; selectionCursor = nil
            return
        }
    }

    private func position(ofListed id: ArchiveFile.ID) -> Int? {
        displayedPositions(of: [id])?.first ?? displayed.firstIndex { $0.id == id }
    }

    // MARK: The file on view (W40.reader-selection-current)

    /// The preview sheet or a document window now shows `path` (nil: nothing loaded).
    func noteFileOnView(_ path: String?, by owner: AnyObject) {
        fileOnViewOwner = ObjectIdentifier(owner)
        if fileOnViewPath != path { fileOnViewPath = path }
    }

    /// `owner` closed. Nothing is on view any more, unless someone else has reported since.
    func endFileOnView(by owner: AnyObject) {
        guard fileOnViewOwner == ObjectIdentifier(owner) else { return }
        fileOnViewOwner = nil
        if fileOnViewPath != nil { fileOnViewPath = nil }
    }

    /// The cursor's path, which the preview sheet opens on after ⇧↑/⇧↓ so the row just added is the one shown.
    var selectionCursorPath: String? {
        guard let cursor = selectionCursor else { return nil }
        return selectedFiles.first { $0.id == cursor }?.path
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

    /// File ▸ Print… from the list prints one file; with several selected it is off (W49.reader-print-open-app).
    var printFileURL: URL? { selectedFiles.count == 1 ? selectedFiles.first?.url : nil }

    func printSelection() {
        guard let url = printFileURL else { return }
        if let refusal = ReaderPrinting.print(url) { statusMessage = refusal }
    }
}
