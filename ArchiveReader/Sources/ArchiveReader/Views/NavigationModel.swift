import Foundation
import Combine
import AppKit

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
    @Published var sort = LibrarySort.default
    @Published var selection = Set<ArchiveFile.ID>() { didSet { persistSelection(); refreshSelectionCache() } }
    @Published var fullTextQuery = ""
    // Sheet/dialog presentation lives on the model so menu commands can trigger it too.
    @Published var showingEditor = false
    @Published var showingPreview = false
    @Published var showingSaveDialog = false
    @Published private(set) var displayed: [ArchiveFile] = []
    @Published private(set) var selectedFilesCache: [ArchiveFile] = []
    @Published private(set) var allSubjectsCache: [String] = []
    @Published private(set) var ftsPaths: Set<String>?      // nil = no full-text query active
    @Published private(set) var indexingProgress: (done: Int, total: Int)?
    @Published private(set) var undoDepth = 0
    @Published var statusMessage = ""

    private var undoStack: [[TagWriteResult]] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        filter.read = AppSettings.defaultReadFilter
        filter.subjectCombine = AppSettings.defaultSubjectCombine
        // ArchiveLibrary is @MainActor and only mutates `files` on the main actor, so this publisher
        // fires on main; assumeIsolated keeps the recompute on the MainActor without an async hop.
        library.$files
            // Deliver ASYNC on the main queue. @Published emits in willSet (before the property is
            // committed), so a synchronous sink would read the OLD `library.files` inside recompute()
            // — which made the list show 0 of N. receive(on:) defers until after the value commits.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshSubjectsCache()
                    self.recompute()                                 // also refreshes the selection cache
                    self.indexer.startIndexing(self.library.files)   // incremental; no-op if running
                    self.restoreSelectionIfNeeded()                  // reading-session resume
                }
            }
            .store(in: &cancellables)
        indexer.$progress
            .sink { [weak self] p in MainActor.assumeIsolated { self?.indexingProgress = p } }
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
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
            .store(in: &cancellables)
        if let root = rootStore.root { library.start(scope: root) }
    }

    // MARK: Saved searches

    func saveCurrentSearch(name: String) {
        savedSearches.add(name: name, filter: filter, fullTextQuery: fullTextQuery)
    }
    func applySaved(_ search: SavedSearch) {
        filter = search.filter
        fullTextQuery = search.fullTextQuery
        runFullTextSearch()   // updates ftsPaths + recompute; filter change also recomputes
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
        var base = library.files.filter(filter.matches)
        if let ftsPaths { base = base.filter { ftsPaths.contains($0.url.path) } }
        displayed = LibrarySort.sorted(base, by: sort)
        refreshSelectionCache()   // sort order affects the selection cache too
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

    private func refreshSelectionCache() {
        let sel = selection
        selectedFilesCache = LibrarySort.sorted(library.files.filter { sel.contains($0.id) }, by: sort)
    }
    private func refreshSubjectsCache() {
        allSubjectsCache = Array(Set(library.files.flatMap(\.subjects)))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Tag cloud over the *currently displayed* rows: each non-date / non-read-state tag with the
    /// number of visible files carrying it, in alphabetical order (the view scales font size by count).
    /// Counts each tag once per file.
    var tagCloud: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for f in displayed {
            for t in Set(f.tags.topicalTags) { counts[t, default: 0] += 1 }
        }
        return counts.map { (tag: $0.key, count: $0.value) }
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
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
}
