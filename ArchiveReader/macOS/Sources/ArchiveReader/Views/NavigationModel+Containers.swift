import Foundation
import ArchiveCoreUI
import ArchiveCore

// MARK: - Containers (W47.ct-reader-view; `SPEC/containers.md`)
//
// The Container column, its facets and the Inspector's Container section read `containerCatalog`. The level map
// (Route B) is offered once per root, when its scan has settled, the catalog is built from the settled paths, and the
// tree has folders but no map. File ▸ Container Levels… edits the map governing the selected folder.
// Only Save writes, into the sheet's original map folder through ContainerFileStore.

/// The listed paths a catalog is built from: the tree, the count and an order-free hash of the paths.
struct ContainerPathSignature: Equatable, Sendable {
    let root: String
    let count: Int
    let hash: Int
}

/// The archive and folder selected when this sheet opened, and the map that governed them at that point.
struct ReaderContainerLevelsEdit: Identifiable, Sendable {
    let archivePath: String
    let selectedDirectory: [String]
    let mapDirectory: [String]
    let draft: ContainerLevelsDraft

    var id: UUID { draft.id }

    /// Match ContainerLookup.context: even an unreadable nearest map governs. A wholly unmapped branch uses
    /// the archive root, where the Reader offers to create a map.
    static func governingMap(in lookup: ContainerLookup, directory: [String])
        -> (directory: [String], load: ContainerLoad<ContainerLevelMap>) {
        for depth in (0...directory.count).reversed() {
            let prefix = Array(directory.prefix(depth))
            let load = lookup.levelMap(prefix)
            if case .missing = load { continue }
            return (prefix, load)
        }
        return ([], .missing)
    }
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
                    ? Self.prepareContainerLevels(tree: tree.url, treePath: tree.path, selectedDirectory: [],
                                                  directories: catalog.fileDirectories)?.draft
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
        guard containerLevelsDraft == nil, containerLevelsOpenRequest == nil,
              let key = containerLevelsRootKey, let draft = containerPrefilledDraft,
              draft.expecting == nil, draft.sampleDirectory != nil,
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
        containerLevelsDraft = ReaderContainerLevelsEdit(archivePath: draft.treePath, selectedDirectory: [],
                                                         mapDirectory: [], draft: draft)
    }

    private func markContainerLevelsAsked() {
        guard let key = containerLevelsRootKey else { return }
        var asked = defaults.stringArray(forKey: Self.containerLevelsAskedKey) ?? []
        if !asked.contains(key) { asked.append(key) }
        defaults.set(asked, forKey: Self.containerLevelsAskedKey)
    }

    /// File ▸ Container Levels…: an explicit sidebar folder, else the containing folder of a single selected file,
    /// else the archive root. Selection is captured before reading the map.
    func openContainerLevels() {
        guard containerLevelsDraft == nil, containerLevelsOpenRequest == nil,
              !containerLevelsSaving, let tree = containerTree else { return }
        let directory: [String]?
        if case let .folder(path?) = currentPlace {
            directory = path.utf8.elementsEqual(tree.path.utf8) ? []
                : ContainerCatalog.relativeComponents(path, under: tree.path)
        } else if selectedFiles.count == 1, let file = selectedFiles.first {
            directory = ContainerCatalog.split(file.path, under: tree.path)?.directory
        } else {
            directory = []
        }
        guard let selectedDirectory = directory else {
            statusMessage = "The selected folder is outside the archive’s main folder and has no container levels."
            announce(statusMessage)
            return
        }
        let request = UUID()
        containerLevelsOpenRequest = request
        let directories = containerCatalog.rootPath == tree.path ? containerCatalog.fileDirectories : []
        Task { [weak self] in
            let edit = await Task.detached(priority: .userInitiated) {
                Self.prepareContainerLevels(tree: tree.url, treePath: tree.path,
                                            selectedDirectory: selectedDirectory, directories: directories)
            }.value
            guard let self, self.containerLevelsOpenRequest == request else { return }
            self.containerLevelsOpenRequest = nil
            guard tree.path == self.containerTree?.path, tree.url == self.containerTree?.url else { return }
            guard let edit else {
                self.statusMessage = "The folder levels for the selection couldn’t be opened. "
                    + "The folder may be unavailable or this version may be unable to read its settings file."
                self.announce(self.statusMessage)
                return
            }
            self.containerLevelsError = nil
            self.containerLevelsDraft = edit
        }
    }

    nonisolated static func prepareContainerLevels(tree: URL, treePath: String, selectedDirectory: [String],
                                                  directories: [[String]]) -> ReaderContainerLevelsEdit? {
        guard (try? containerDirectoryURL(tree, selectedDirectory)) != nil else { return nil }
        let lookup = ContainerLookup(treeRoot: tree.resolvingSymlinksInPath())
        let target = ReaderContainerLevelsEdit.governingMap(in: lookup, directory: selectedDirectory)
        let map: ContainerLevelMap?
        let stamp: ContainerFileStamp?
        switch target.load {
        case .missing: (map, stamp) = (nil, nil)
        case let .loaded(value, readStamp) where !readStamp.droppedOnReading: (map, stamp) = (value, readStamp)
        default: return nil
        }
        // Examples and inferred depths come from folders that actually use this map.
        var governed: [[String]: Bool] = [:]
        let relative = directories.compactMap { directory -> [String]? in
            guard directory.starts(with: target.directory, by: { $0.utf8.elementsEqual($1.utf8) }) else { return nil }
            let usesMap = governed[directory] ?? {
                let result = ReaderContainerLevelsEdit.governingMap(in: lookup, directory: directory)
                    .directory.count == target.directory.count
                governed[directory] = result
                return result
            }()
            return usesMap ? Array(directory.dropFirst(target.directory.count)) : nil
        }
        let draft = ContainerLevelsDraft.make(directories: relative, existing: map, expecting: stamp,
                                             tree: lookup.url(target.directory),
                                             treePath: ContainerCatalog.directoryPath(target.directory, under: treePath))
        return ReaderContainerLevelsEdit(archivePath: treePath, selectedDirectory: selectedDirectory,
                                         mapDirectory: target.directory, draft: draft)
    }

    /// The user's Save rechecks the governing folder and writes against the stamp captured by the sheet.
    func saveContainerLevels(_ edit: ReaderContainerLevelsEdit, map edited: ContainerLevelMap) {
        guard !containerLevelsSaving else { return }
        guard let tree = containerTree, edit.archivePath.utf8.elementsEqual(tree.path.utf8),
              edit.id == containerLevelsDraft?.id else {
            containerLevelsError = "The archive folder changed since this sheet opened, so nothing was saved."
            return
        }
        var dated = edited
        dated.updatedAt = Date()
        let map = dated
        containerLevelsSaving = true
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try Self.writeContainerLevels(edit, map: map, archive: tree.url)
                    return nil
                } catch {
                    return containerLevelsWriteMessage(error)
                }
            }.value
            guard let self else { return }
            self.containerLevelsSaving = false
            guard self.containerLevelsDraft?.id == edit.id else { return }
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

    nonisolated static func writeContainerLevels(_ edit: ReaderContainerLevelsEdit, map: ContainerLevelMap,
                                                 archive: URL) throws {
        let selected = try containerDirectoryURL(archive, edit.selectedDirectory)
        let attributes = try FileManager.default.attributesOfItem(atPath: selected.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw ContainerWriteError.changedSinceRead
        }
        let lookup = ContainerLookup(treeRoot: archive.resolvingSymlinksInPath())
        let target = ReaderContainerLevelsEdit.governingMap(in: lookup, directory: edit.selectedDirectory)
        let folder = try containerDirectoryURL(archive, target.directory)
        guard folder.path.utf8.elementsEqual(edit.draft.tree.path.utf8) else {
            throw ContainerWriteError.changedSinceRead
        }
        try ContainerFileStore.writeLevelMap(map, root: folder, expecting: edit.draft.expecting)
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
    case .changedSinceRead?: return "The folder or its levels changed since this sheet opened. Close it and open it again."
    case .busy?: return "Another app is writing the folder levels. Try again in a moment."
    case .refusedExisting?: return "The folder levels file in this archive was written by a newer version, so it is left as it is."
    default: return "The folder levels could not be saved: \(error.localizedDescription)"
    }
}
