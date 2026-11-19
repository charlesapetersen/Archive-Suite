import Foundation
import ArchiveCore

// MARK: - Containers (W47.ct-reader-view; `SPEC/containers.md`)
//
// The Container column, its facets and the Inspector's Container section read `containerCatalog`. The level map
// (Route B) is offered once per root, when its scan has settled, the catalog is built from the settled paths, and the
// tree has folders but no map; it is written only when the user saves it, to
// `<main folder>/.archivesuite/container-levels.json`, and only into the tree the sheet was made for.

/// The listed paths a catalog is built from: the tree, the count and an order-free hash of the paths.
struct ContainerPathSignature: Equatable, Sendable {
    let root: String
    let count: Int
    let hash: Int
}

extension NavigationModel {
    /// Defaults key: the roots (by their marker's preference id, else their path) already offered the level map.
    static let containerLevelsAskedKey = "ar.containerLevelsAsked"

    /// The archive's main folder, where the level map lives, and its path as the library spells paths: the granted
    /// folder, or its "Archival Photos" folder when it holds one (`ReaderArchiveLayout`).
    var containerTree: (url: URL, path: String)? {
        guard let granted = rootStore.root, let prefix = rootStore.discoveredPathPrefix else { return nil }
        let layout = ReaderArchiveLayout(grantedRoot: granted)
        guard layout.mainRoot != granted else { return (granted, prefix) }
        return (layout.mainRoot, prefix + "/" + ReaderArchiveLayout.mainDirectoryName)
    }

    func containerRow(for path: String) -> ContainerRow? { containerCatalog.rows[path] }

    /// Rebuild the catalog off the main thread when the listed paths changed, or always when `force` (a rescan, the
    /// level map just saved). One build at a time; a change during one runs a single further build when it lands.
    /// Generation-guarded like `refreshFormatStatuses`, so a build for a root no longer open is dropped.
    func refreshContainers(force: Bool = false) {
        guard let tree = containerTree else {
            containerGeneration += 1
            containerSignature = nil
            containerBuiltSignature = nil
            containerPrefilledDraft = nil
            containerEditSaving = false
            if !containerCatalog.isEmpty { containerCatalog = .empty }
            return
        }
        let files = library.files
        var hash = 0
        for f in files { hash ^= f.pathHash }
        let signature = ContainerPathSignature(root: tree.path, count: files.count, hash: hash)
        if !force, containerSignature == signature {
            if containerBuiltSignature == signature { offerContainerLevelsIfNeeded() }
            return
        }
        if containerBuildInFlight {
            containerRebuildPending = true
            return
        }
        containerSignature = signature
        containerGeneration += 1
        let generation = containerGeneration
        containerBuildInFlight = true
        let paths = files.map(\.path)
        Task { [weak self] in
            let (catalog, draft, valuesSig) = await Task.detached(priority: .utility) {
                let catalog = ContainerCatalog.build(treeRoot: tree.url, rootPath: tree.path, filePaths: paths)
                // The pre-filled map weighs every file's folder, so it is made here and not on the main thread.
                let draft = Self.shouldOfferContainerLevels(catalog: catalog, settled: true, asked: false)
                    ? ContainerLevelsDraft.make(directories: catalog.fileDirectories, tree: tree.url, treePath: tree.path)
                    : nil
                return (catalog, draft, LibraryChangeSignature.containers(catalog.rows))
            }.value
            guard let self else { return }
            self.containerBuildInFlight = false
            if generation == self.containerGeneration {
                self.containerCatalog = catalog
                self.containerEditSaving = false   // an edit's catalog is published (W47.ct-reader-edit)
                self.containerBuiltSignature = signature
                self.containerPrefilledDraft = draft
                let scopeTestsContainers = self.containerValuesChanged(signature: valuesSig)
                if scopeTestsContainers || !self.filter.activeContainerFacets.isEmpty
                    || self.sort.contains(where: { $0.field == .container }) {
                    self.recompute()
                }
                self.offerContainerLevelsIfNeeded()
            }
            if self.containerRebuildPending {
                self.containerRebuildPending = false
                self.refreshContainers(force: true)
            }
        }
    }

    // MARK: The level map

    private var containerLevelsRootKey: String? {
        rootStore.preferenceGUID?.uuidString ?? containerTree?.path
    }

    /// Whether a root may be offered the level map: never asked, its scan settled, no map at the tree's root (an
    /// unreadable one is left alone), and folders below it to map.
    nonisolated static func shouldOfferContainerLevels(catalog: ContainerCatalog, settled: Bool, asked: Bool) -> Bool {
        guard settled, !asked, case .missing = catalog.rootLevelMap else { return false }
        return catalog.fileDirectories.contains { !$0.isEmpty }
    }

    /// Offers the pre-filled map once the published catalog was built from the settled library's current paths.
    func offerContainerLevelsIfNeeded() {
        guard containerLevelsDraft == nil, let key = containerLevelsRootKey, let draft = containerPrefilledDraft,
              draft.treePath == containerTree?.path, containerBuiltSignature != nil,
              containerBuiltSignature == containerSignature, !containerBuildInFlight else { return }
        // Nobody is there to answer under a test host or a fixture root, unless a UI test asks for the sheet.
        let args = ProcessInfo.processInfo.arguments
        if ArchiveTestHost.isUnitTestHost { return }
        if args.contains("-ARUITestRootPath"), !args.contains("-ARUITestOfferContainerLevels") { return }
        let asked = (defaults.stringArray(forKey: Self.containerLevelsAskedKey) ?? []).contains(key)
        guard Self.shouldOfferContainerLevels(catalog: containerCatalog, settled: library.phase.isSettled,
                                              asked: asked) else { return }
        markContainerLevelsAsked()
        containerLevelsError = nil
        containerLevelsDraft = draft
    }

    private func markContainerLevelsAsked() {
        guard let key = containerLevelsRootKey else { return }
        var asked = defaults.stringArray(forKey: Self.containerLevelsAskedKey) ?? []
        if !asked.contains(key) { asked.append(key) }
        defaults.set(asked, forKey: Self.containerLevelsAskedKey)
    }

    /// File ▸ Container Levels…: the stored map to edit, or a pre-filled one, made off the main thread. A map this
    /// build cannot read, or one holding values it would drop, is left alone and the status line says so.
    func openContainerLevels() {
        guard let tree = containerTree else { return }
        let directories = containerCatalog.rootPath == tree.path ? containerCatalog.fileDirectories : []
        Task { [weak self] in
            let draft: ContainerLevelsDraft? = await Task.detached(priority: .userInitiated) {
                switch ContainerFileStore.loadLevelMap(root: tree.url) {
                case .missing:
                    return ContainerLevelsDraft.make(directories: directories, tree: tree.url, treePath: tree.path)
                case let .loaded(map, stamp) where !stamp.droppedOnReading:
                    return ContainerLevelsDraft.make(directories: directories, existing: map, expecting: stamp,
                                                     tree: tree.url, treePath: tree.path)
                default:
                    return nil
                }
            }.value
            guard let self, tree.path == self.containerTree?.path else { return }
            guard let draft else {
                self.statusMessage = "The folder levels file in this archive could not be read by this version, "
                    + "so it is left as it is."
                self.announce(self.statusMessage)
                return
            }
            self.containerLevelsError = nil
            self.containerLevelsDraft = draft
        }
    }

    /// The user's Save: writes the map into the tree the sheet was made for, then rebuilds the catalog with it. Off
    /// the main thread; the sheet stays open with the reason if the write is refused.
    func saveContainerLevels(_ draft: ContainerLevelsDraft) {
        guard !containerLevelsSaving else { return }
        guard draft.treePath == containerTree?.path else {
            containerLevelsError = "The archive folder changed since this sheet opened, so nothing was saved."
            return
        }
        var edited = draft.map
        edited.updatedAt = Date()
        let map = edited, expecting = draft.expecting
        let root = draft.tree.resolvingSymlinksInPath()
        containerLevelsSaving = true
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
            self.containerLevelsSaving = false
            if let failure {
                self.containerLevelsError = failure
                return
            }
            self.containerLevelsDraft = nil
            self.containerLevelsError = nil
            self.statusMessage = "Folder levels saved."
            self.announce(self.statusMessage)
            self.refreshContainers(force: true)
        }
    }

    /// Not Now: nothing is written, and the sheet is not offered again for this root (File ▸ Container Levels…
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
    case .refusedExisting?: return "The folder levels file in this archive was written by a newer version, so it is left as it is."
    default: return "The folder levels could not be saved: \(error.localizedDescription)"
    }
}
