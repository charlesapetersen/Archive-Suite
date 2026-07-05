import Foundation
import Combine
import AppKit

/// View model for the navigation window: owns the library + root store, the filter/sort/selection
/// state, and the (safe) actions. All tag mutations go through `TagWriter`.
@MainActor
final class NavigationModel: ObservableObject {
    let library = ArchiveLibrary()
    let rootStore = RootFolderStore()

    @Published var filter = LibraryFilter()
    @Published var sort = LibrarySort.default
    @Published var selection = Set<ArchiveFile.ID>()
    @Published private(set) var displayed: [ArchiveFile] = []
    @Published private(set) var undoDepth = 0
    @Published var statusMessage = ""

    private var undoStack: [[TagWriteResult]] = []
    private var linkFormatter = FileLinkFormatter()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // ArchiveLibrary is @MainActor and only mutates `files` on the main actor, so this publisher
        // fires on main; assumeIsolated keeps the recompute on the MainActor without an async hop.
        library.$files
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recompute() } }
            .store(in: &cancellables)
        if let root = rootStore.root { library.start(scope: root) }
    }

    // MARK: Derived

    func recompute() {
        displayed = LibrarySort.sorted(library.files.filter(filter.matches), by: sort)
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

    // MARK: Copy links

    func copyLinks() {
        let urls = selectedFiles.map(\.url)
        guard !urls.isEmpty else { return }
        let text = linkFormatter.clipboardString(for: urls)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Copied \(urls.count) link\(urls.count == 1 ? "" : "s")."
    }

    // MARK: Open

    func documentSelection() -> DocumentSelection {
        DocumentSelection(filePaths: selectedFiles.map(\.url.path))
    }
}
