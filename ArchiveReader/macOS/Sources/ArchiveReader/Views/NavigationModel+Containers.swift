import Foundation
import ArchiveCore

// MARK: - Containers (W47.ct-reader-view; `SPEC/containers.md`)
//
// The Container column, its facets and the Inspector's Container section read `containerCatalog`. The level map
// (Route B) is offered once per root, when its first full scan has settled and the tree has folders but no map; it
// is written only when the user saves it, to `<main folder>/.archivesuite/container-levels.json`.

extension NavigationModel {
    /// Defaults key: the roots (by their marker's preference id, else their path) already offered the level map.
    static let containerLevelsAskedKey = "ar.containerLevelsAsked"

    /// The archive's main folder, where the level map lives, and its path as the library spells paths.
    var containerTree: (url: URL, path: String)? {
        guard let granted = rootStore.root, let prefix = rootStore.discoveredPathPrefix else { return nil }
        let layout = ReaderArchiveLayout(grantedRoot: granted)
        guard layout.mainRoot != granted else { return (granted, prefix) }
        return (layout.mainRoot, prefix + "/" + ReaderArchiveLayout.mainDirectoryName)
    }

    func containerRow(for path: String) -> ContainerRow? { containerCatalog.rows[path] }

    /// Rebuild the catalog off the main thread when the listed paths changed, or always when `force` (the level map
    /// was just saved). Generation-guarded like `refreshFormatStatuses`, so a slower earlier build never lands last.
    func refreshContainers(force: Bool = false) {
        guard let tree = containerTree else {
            if !containerCatalog.isEmpty { containerCatalog = .empty }
            return
        }
        let files = library.files
        var hash = 0
        for f in files { hash ^= f.pathHash }
        let signature = (root: tree.path, count: files.count, hash: hash)
        if !force, let last = containerSignature, last == signature { return }
        containerSignature = signature
        containerGeneration += 1
        let generation = containerGeneration
        let paths = files.map(\.path)
        Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) {
                ContainerCatalog.build(treeRoot: tree.url, rootPath: tree.path, filePaths: paths)
            }.value
            guard let self, generation == self.containerGeneration else { return }
            self.containerCatalog = catalog
            if !self.filter.activeContainerFacets.isEmpty || self.sort.contains(where: { $0.field == .container }) {
                self.recompute()
            }
            self.offerContainerLevelsIfNeeded()
        }
    }

    // MARK: The level map

    private var containerLevelsRootKey: String? {
        rootStore.preferenceGUID?.uuidString ?? containerTree?.path
    }

    /// Whether to offer the level map now: never asked for this root, its scan settled, no map at the tree's root
    /// (an unreadable one is left alone), and folders below it to map.
    static func shouldOfferContainerLevels(catalog: ContainerCatalog, settled: Bool, asked: Bool) -> Bool {
        guard settled, !asked, case .missing = catalog.rootLevelMap else { return false }
        return catalog.fileDirectories.contains { !$0.isEmpty }
    }

    func offerContainerLevelsIfNeeded() {
        guard containerLevelsDraft == nil, let key = containerLevelsRootKey else { return }
        // Nobody is there to answer under a test host or a fixture root, unless a UI test asks for the sheet.
        let args = ProcessInfo.processInfo.arguments
        if ArchiveTestHost.isUnitTestHost { return }
        if args.contains("-ARUITestRootPath"), !args.contains("-ARUITestOfferContainerLevels") { return }
        let asked = (defaults.stringArray(forKey: Self.containerLevelsAskedKey) ?? []).contains(key)
        guard Self.shouldOfferContainerLevels(catalog: containerCatalog, settled: library.phase.isSettled,
                                              asked: asked) else { return }
        markContainerLevelsAsked()
        containerLevelsError = nil
        containerLevelsDraft = ContainerLevelsDraft.make(directories: containerCatalog.fileDirectories)
    }

    private func markContainerLevelsAsked() {
        guard let key = containerLevelsRootKey else { return }
        var asked = defaults.stringArray(forKey: Self.containerLevelsAskedKey) ?? []
        if !asked.contains(key) { asked.append(key) }
        defaults.set(asked, forKey: Self.containerLevelsAskedKey)
    }

    /// Library ▸ Container Levels…: the stored map to edit, or a pre-filled one. A map this build cannot read is
    /// left alone, and the sheet says so instead of offering to replace it.
    func openContainerLevels() {
        guard let tree = containerTree else { return }
        containerLevelsError = nil
        switch ContainerFileStore.loadLevelMap(root: tree.url) {
        case .missing:
            containerLevelsDraft = ContainerLevelsDraft.make(directories: containerCatalog.fileDirectories)
        case let .loaded(map, stamp):
            containerLevelsDraft = ContainerLevelsDraft.make(directories: containerCatalog.fileDirectories,
                                                             existing: map, expecting: stamp)
        default:
            statusMessage = "The folder levels file in this archive could not be read by this version, so it is left as it is."
            announce(statusMessage)
        }
    }

    /// The user's Save: writes the map, then rebuilds the catalog with it. Off the main thread; the sheet stays open
    /// with the reason if the write is refused.
    func saveContainerLevels(_ draft: ContainerLevelsDraft) {
        guard let tree = containerTree else { return }
        var edited = draft.map
        edited.updatedAt = Date()
        let map = edited, expecting = draft.expecting
        let root = tree.url.resolvingSymlinksInPath()
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try ContainerFileStore.writeLevelMap(map, root: root, expecting: expecting)
                    return nil
                } catch {
                    return containerLevelsWriteMessage(error)
                }
            }.value
            guard let self else { return }
            if let failure {
                self.containerLevelsError = failure
                return
            }
            self.containerLevelsDraft = nil
            self.statusMessage = "Folder levels saved."
            self.announce(self.statusMessage)
            self.refreshContainers(force: true)
        }
    }

    /// Not Now: nothing is written, and the sheet is not offered again for this root (Library ▸ Container Levels…
    /// opens it).
    func dismissContainerLevels() {
        markContainerLevelsAsked()
        containerLevelsDraft = nil
        containerLevelsError = nil
    }
}

/// Why a level-map save was refused, for the sheet.
func containerLevelsWriteMessage(_ error: Error) -> String {
    switch error as? ContainerWriteError {
    case .changedSinceRead?: return "The folder levels changed in another app since this sheet opened. Close it and open it again."
    case .busy?: return "Another app is writing the folder levels. Try again in a moment."
    default: return "The folder levels could not be saved: \(error.localizedDescription)"
    }
}
