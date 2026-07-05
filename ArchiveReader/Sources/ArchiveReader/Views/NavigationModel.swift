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

    @Published var filter = LibraryFilter()
    @Published var sort = LibrarySort.default
    @Published var selection = Set<ArchiveFile.ID>()
    @Published var fullTextQuery = ""
    @Published private(set) var displayed: [ArchiveFile] = []
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
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recompute()
                    self.indexer.startIndexing(self.library.files)   // incremental; no-op if running
                }
            }
            .store(in: &cancellables)
        indexer.$progress
            .sink { [weak self] p in MainActor.assumeIsolated { self?.indexingProgress = p } }
            .store(in: &cancellables)
        if let root = rootStore.root { library.start(scope: root) }
    }

    // MARK: Derived

    func recompute() {
        var base = library.files.filter(filter.matches)
        if let ftsPaths { base = base.filter { ftsPaths.contains($0.url.path) } }
        displayed = LibrarySort.sorted(base, by: sort)
    }

    /// Run (or clear) the corpus full-text search, then re-filter. AND-combined with the tag facets.
    func runFullTextSearch() {
        let q = fullTextQuery.trimmingCharacters(in: .whitespaces)
        Task { [weak self] in
            guard let self else { return }
            self.ftsPaths = q.isEmpty ? nil : await self.indexer.search(q)
            self.recompute()
        }
    }

    var selectedFiles: [ArchiveFile] {
        displayed.filter { selection.contains($0.id) }
    }

    /// Unique subject tags across the library, for filter suggestions.
    var allSubjects: [String] {
        Array(Set(library.files.flatMap(\.subjects))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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
        var failures = 0
        for url in urls {
            do {
                let r = try TagWriter.setReadState(target, on: url)
                if !r.isNoOp { batch.append(r) }
            } catch { failures += 1 }
        }
        library.applyOptimisticReadState(target, for: Set(urls))
        if !batch.isEmpty { undoStack.append(batch); undoDepth = undoStack.count }
        statusMessage = failures == 0
            ? "Marked \(batch.count) \(target.rawValue)."
            : "Marked \(batch.count); \(failures) could not update."
    }

    func undoLast() {
        guard let batch = undoStack.popLast() else { return }
        undoDepth = undoStack.count
        var restored = 0
        for r in batch {
            if (try? TagWriter.apply(r.inverse, to: r.url)) != nil {
                library.setExactTags(r.before, label: r.beforeLabel, for: r.url)
                restored += 1
            }
        }
        statusMessage = "Undid \(restored) change\(restored == 1 ? "" : "s")."
    }

    // MARK: Tag editing (single + group, all via TagWriter)

    /// Facet summary across the current selection, for the tag editor's tri-state display.
    var groupSummary: GroupTagSummary { GroupTagSummary(selectedFiles.map(\.tags)) }

    /// Apply one edit operation to every selected file (per-file delta), with grouped undo.
    func applyEdit(_ op: TagEditOp) {
        let files = selectedFiles
        guard !files.isEmpty else { return }
        var batch: [TagWriteResult] = []
        var failures = 0
        for f in files {
            let delta = TagEditing.delta(for: op, given: f.tags)
            if delta.isEmpty { continue }
            do {
                let r = try TagWriter.apply(delta, to: f.url)
                if !r.isNoOp { batch.append(r); library.setExactTags(r.after, label: r.afterLabel, for: f.url) }
            } catch { failures += 1 }
        }
        if !batch.isEmpty { undoStack.append(batch); undoDepth = undoStack.count }
        statusMessage = "Edited \(batch.count) file\(batch.count == 1 ? "" : "s")"
            + (failures > 0 ? "; \(failures) could not update." : ".")
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

    // MARK: Open

    func documentSelection() -> DocumentSelection {
        DocumentSelection(filePaths: selectedFiles.map(\.url.path))
    }
}
