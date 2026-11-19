import Foundation
import ArchiveCore

// MARK: - The container editor (W47.ct-reader-edit, Tier-2; `SPEC/containers.md`)
//
// The Reader's one write class outside Finder tags: `<directory>/.archivesuite/containers.json` and the tree's
// `container-names.json`, new files or whole-document replacements inside `.archivesuite` only, through
// `ContainerFileStore` (no link followed, `flock`, the stamp of the read checked before the rename). Every edit reads
// the document fresh off the main thread, works the change out on it (`ContainerEdits`) and writes it with that read's
// stamp, so another app's change in between is refused, never overwritten. A document this build cannot read, of a
// newer version or holding values it drops is left alone and the Inspector says so. No document is touched.

/// What the user did to one field of one file.
enum ContainerFieldEdit: Equatable, Sendable {
    /// Typed a value; the same text as the read confirms it, keeping its reader.
    case set(String)
    /// "None here": hides every other source's value.
    case noneHere
    /// Takes the user's own value away, so the file inherits again.
    case remove
}

extension NavigationModel {
    /// Edits `field` where `path`'s value lives (`ContainerEdits.target`): every file the run covers follows.
    func editContainerField(_ field: ContainerField, _ edit: ContainerFieldEdit, forPath path: String) {
        guard let (tree, dir, name) = containerEditLocation(path) else { return }
        let now = Date()
        runContainerEdit(done: "Container saved.") {
            let directory = try Self.containerDirectoryURL(tree, dir)
            try Self.editContainerFile(at: directory) { file in
                let target = ContainerEdits.target(for: field, at: name, in: file)
                let old: ContainerValue?
                switch target {
                case .directory: old = file.directory[field]
                case let .run(start, level):
                    old = file.runs.first { $0.start == start && $0.level == level }?.fields[field]
                case .newRun: old = nil
                }
                let value: ContainerValue?
                switch edit {
                case .set(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    // Confirming a value the folder names gave stores it as the user's where the edit goes.
                    value = ContainerEdits.userValue(trimmed, confirming: old, at: now)
                case .noneHere: value = ContainerValue("", source: .user, at: now)
                case .remove:
                    guard old?.source == .user else { return nil }
                    value = nil
                }
                return ContainerEdits.set(field, to: value, at: target, in: file)
            }
        }
    }

    /// "Set for selection": `field` is `text` for the selected files and no other, each folder's neighbours a run of
    /// the field's level, ended after the last (`ContainerEdits.setForSelection`). Files are taken in each folder's
    /// order on disk, so a file the library does not list still keeps its value.
    func setContainerFieldForSelection(_ field: ContainerField, _ text: String, paths: [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tree = containerTree, containerCatalog.rootPath == tree.path, field.homeLevel != nil else { return }
        var byDirectory: [[String]: Set<String>] = [:]
        for path in paths {
            guard let (dir, name) = ContainerCatalog.split(path, under: tree.path) else { continue }
            byDirectory[dir, default: []].insert(name)
        }
        guard !byDirectory.isEmpty else {
            containerEditError = "These files are outside the archive's main folder, so they have no container."
            return
        }
        let now = Date()
        let count = paths.count
        let directories = byDirectory.sorted { $0.key.joined(separator: "/") < $1.key.joined(separator: "/") }
        runContainerEdit(done: "\(field.label) set for \(count) file\(count == 1 ? "" : "s").") {
            let value = ContainerValue(trimmed, source: .user, at: now)
            for (index, (dir, selected)) in directories.enumerated() {
                do {
                    try Self.setForSelection(field, value, selected: selected,
                                             in: try Self.containerDirectoryURL(tree.url, dir))
                } catch where index > 0 {
                    throw ContainerPartialSave(saved: index, total: directories.count, underlying: error)
                }
            }
        }
    }

    /// One folder's part of "set for selection": its selected files in runs of neighbours among the files on disk.
    nonisolated static func setForSelection(_ field: ContainerField, _ value: ContainerValue, selected: Set<String>,
                                            in directory: URL) throws {
        let all = Array(Set(try fileNames(in: directory)).union(selected)).sorted(by: ContainerOrder.precedes)
        let groups = ContainerEdits.contiguousGroups(selected: selected, fileNames: all)
        try editContainerFile(at: directory) { file in
            var file = file
            for group in groups {
                guard let last = group.last, let i = all.firstIndex(of: last) else { continue }
                let after = i + 1 < all.count ? all[i + 1] : nil
                guard let edited = ContainerEdits.setForSelection(field, to: value, group: group, after: after,
                                                                  in: file) else { return nil }
                file = edited
            }
            return file
        }
    }

    /// "Use this name for …": `written` (and the wordings its entry already matched) in `field` shows as `standard`
    /// across the tree; an empty `standard` stops using one. Written to the nearest standard names file at or above the
    /// file's folder, else at the tree's root (SPEC §Showing a value).
    func setContainerStandardName(_ standard: String, for written: String, field: ContainerField, forPath path: String) {
        guard let (tree, dir, _) = containerEditLocation(path) else { return }
        let now = Date()
        let removing = standard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        runContainerEdit(done: removing ? "Standard name removed." : "Standard name saved.") {
            let root = try Self.nearestNamesRoot(tree, dir)
            let names: ContainerNames
            let stamp: ContainerFileStamp?
            switch ContainerFileStore.loadNames(root: root) {
            case .missing: (names, stamp) = (ContainerNames(), nil)
            case let .loaded(doc, s) where !s.droppedOnReading: (names, stamp) = (doc, s)
            default: throw ContainerWriteError.refusedExisting(ContainerNames.fileName)
            }
            let edited = ContainerEdits.setStandardName(standard, for: written, field: field, in: names, at: now)
            guard edited.names != names.names else { return }
            try ContainerFileStore.writeNames(edited, root: root, expecting: stamp)
        }
    }

    /// Selects the file a warning starts at, if the list shows it.
    func selectContainerWarning(_ row: ContainerWarningRow) {
        let match = displayed.filter { $0.path == row.startPath }
        guard !match.isEmpty else {
            statusMessage = "“\(row.start)” is not in the list as it is filtered now."
            announce(statusMessage)
            return
        }
        selection = Set(match.map(\.id))
    }

    // MARK: Writing

    /// The tree, the directory below it and the name of a file the editor may edit; nil (with the reason shown) when
    /// the catalog is not the open tree's or the file is outside it.
    private func containerEditLocation(_ path: String) -> (URL, [String], String)? {
        guard let tree = containerTree, containerCatalog.rootPath == tree.path,
              let (dir, name) = ContainerCatalog.split(path, under: tree.path) else {
            containerEditError = "This file is outside the archive's main folder, so it has no container."
            return nil
        }
        return (tree.url, dir, name)
    }

    /// Runs one edit off the main thread, one at a time, then reads the container files again.
    private func runContainerEdit(done: String, _ work: @escaping @Sendable () throws -> Void) {
        guard !containerEditSaving else {
            containerEditError = "The last change is still being saved. Try again in a moment."
            return
        }
        containerEditSaving = true
        containerEditError = nil
        let treePath = containerTree?.path
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do { try work(); return nil } catch { return containerEditWriteMessage(error) }
            }.value
            guard let self else { return }
            guard treePath == self.containerTree?.path else { self.containerEditSaving = false; return }
            if let failure {
                self.containerEditError = failure
                self.announce(failure)
            } else {
                self.statusMessage = done
                self.announce(done)
            }
            // The editor stays disabled until the catalog read after this edit is published, so a menu still
            // offering the old value cannot write it back over the one just saved (`refreshContainers` clears it).
            self.containerEditSaving = true
            self.refreshContainers(force: true)
        }
    }

    /// The directory below the tree's root. Only the root is resolved: a folder inside the tree that is a link (one
    /// swapped in since the scan) is refused here, and the store refuses a linked final folder again as it opens it.
    nonisolated static func containerDirectoryURL(_ tree: URL, _ components: [String]) throws -> URL {
        var url = tree.resolvingSymlinksInPath()
        for name in components {
            url.appendPathComponent(name, isDirectory: true)
            // lstat: a link is not followed. A folder that is missing is the store's to report.
            let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            if let type, type != .typeDirectory { throw ContainerWriteError.notOrdinary(name) }
        }
        return url
    }

    /// The folder whose standard names apply to `components`: the nearest at or above it holding a
    /// `container-names.json` of any kind, else the tree's root. One this build cannot read is refused rather than
    /// passed over, since the catalog shows that one's names (nearest wins), not an outer file's.
    nonisolated static func nearestNamesRoot(_ tree: URL, _ components: [String]) throws -> URL {
        for depth in (0...components.count).reversed() {
            let folder = try containerDirectoryURL(tree, Array(components[0..<depth]))
            let doc = ContainerFileStore.namesURL(in: folder).path
            if (try? FileManager.default.attributesOfItem(atPath: doc)) != nil { return folder }
        }
        return tree.resolvingSymlinksInPath()
    }

    /// The visible files directly in `directory` (no folders, no hidden files): the order runs are taken in.
    nonisolated static func fileNames(in directory: URL) throws -> [String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? nil : url.lastPathComponent
        }
    }

    /// Reads `directory`'s container file, applies `change` (nil: nothing to write) and writes it with the read's
    /// stamp. A document this build would not overwrite is refused before `change` runs.
    nonisolated static func editContainerFile(at directory: URL,
                                              _ change: (ContainerFile) -> ContainerFile?) throws {
        let file: ContainerFile
        let stamp: ContainerFileStamp?
        switch ContainerFileStore.load(directory: directory) {
        case .missing: (file, stamp) = (ContainerFile(), nil)
        case let .loaded(doc, s) where !s.droppedOnReading: (file, stamp) = (doc, s)
        default: throw ContainerWriteError.refusedExisting(ContainerFile.fileName)
        }
        guard var edited = change(file), edited != file else { return }
        edited.updatedAt = Date()
        try ContainerFileStore.write(edited, directory: directory, expecting: stamp)
    }
}

/// "Set for selection" wrote the first `saved` of `total` folders before one was refused.
struct ContainerPartialSave: Error {
    let saved: Int
    let total: Int
    let underlying: Error
}

/// Why a container edit was refused, for the Inspector.
func containerEditWriteMessage(_ error: Error) -> String {
    if let partial = error as? ContainerPartialSave {
        return "\(partial.saved) of \(partial.total) folders were saved; the rest were not. "
            + containerEditWriteMessage(partial.underlying)
    }
    switch error as? ContainerWriteError {
    case .changedSinceRead?: return "Another app changed this folder's containers just now. Look again and redo the change."
    case .busy?: return "Another app is writing this folder's containers. Try again in a moment."
    case .refusedExisting?: return "This folder's container file was written by a newer version, or holds values this "
        + "version cannot read, so it is left as it is and nothing was changed."
    case .notOrdinary?: return "This folder's “.archivesuite” is a link or not a folder, so nothing was written."
    case .tooBig?: return "This folder's container file would pass its 1 MB limit, so nothing was written."
    default: return "The change could not be saved: \(error.localizedDescription)"
    }
}
