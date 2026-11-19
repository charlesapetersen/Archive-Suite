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
//
// Undo (W47.ct-reader-edit-undo): each edit hands the window's undo manager what every file it wrote held before and
// the stamp of what it wrote. Undo reads each file fresh, puts the old document back only where the file is still the
// one the edit wrote, and leaves any other alone with the reason; Redo is the same step the other way. Where there was
// no file, undo writes an empty one (the store deletes nothing), which reads as no values at all.

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
    func editContainerField(_ field: ContainerField, _ edit: ContainerFieldEdit, forPath path: String,
                            undo: UndoManager? = nil) {
        guard let (tree, dir, name) = containerEditLocation(path) else { return }
        let now = Date()
        let action = switch edit {
        case .set: "Container Change"
        case .noneHere: "None Here"
        case .remove: "Remove Your Value"
        }
        runContainerEdit(done: "Container saved.", action: action, undo: undo) {
            let directory = try Self.containerDirectoryURL(tree, dir)
            return try Self.editContainerFile(at: directory) { file in
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
            }.map { ContainerUndoStep(restores: [$0]) }
        }
    }

    /// "Set for selection": `field` is `text` for the selected files and no other, each folder's neighbours a run of
    /// the field's level, ended after the last (`ContainerEdits.setForSelection`). Files are taken in each folder's
    /// order on disk, so a file the library does not list still keeps its value. All or nothing: every folder's file
    /// is read and checked before any is written, and a write that still fails partway puts the folders already
    /// written back (`setForSelection(_:_:in:)`).
    func setContainerFieldForSelection(_ field: ContainerField, _ text: String, paths: [String],
                                       undo: UndoManager? = nil) {
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
        runContainerEdit(done: "\(field.label) set for \(count) file\(count == 1 ? "" : "s").",
                         action: "Set \(field.label) for Selection", undo: undo) {
            let value = ContainerValue(trimmed, source: .user, at: now)
            let folders = try directories.map { (try Self.containerDirectoryURL(tree.url, $0.key), $0.value) }
            return try Self.setForSelection(field, value, in: folders)
        }
    }

    /// "Set for selection" across folders, all or nothing. Every folder's file is read, checked and edited first, and
    /// one refusal writes nothing. A write that still fails (another app in between) puts back the folders already
    /// written, with the same restore Undo uses, and the error says whether that worked.
    nonisolated static func setForSelection(_ field: ContainerField, _ value: ContainerValue,
                                            in folders: [(URL, Set<String>)]) throws -> ContainerUndoStep? {
        let prepared = try folders.compactMap { directory, selected in
            try prepareSetForSelection(field, value, selected: selected, in: directory)
        }
        return try commitAll(prepared)
    }

    /// Writes every prepared edit; if one fails, puts back those already written and throws.
    nonisolated static func commitAll(_ prepared: [PreparedContainerEdit]) throws -> ContainerUndoStep? {
        var written: [ContainerDocumentRestore] = []
        for edit in prepared {
            do {
                written.append(try edit.commit())
            } catch {
                guard !written.isEmpty else { throw error }
                let undone = ContainerUndoStep(restores: written).apply()
                throw ContainerSelectionRolledBack(written: written.count, total: prepared.count,
                                                   notRestored: undone.failures, underlying: error)
            }
        }
        return written.isEmpty ? nil : ContainerUndoStep(restores: written)
    }

    /// One folder's part of "set for selection": its selected files in runs of neighbours among the files on disk.
    @discardableResult
    nonisolated static func setForSelection(_ field: ContainerField, _ value: ContainerValue, selected: Set<String>,
                                            in directory: URL) throws -> ContainerDocumentRestore? {
        try prepareSetForSelection(field, value, selected: selected, in: directory)?.commit()
    }

    nonisolated static func prepareSetForSelection(_ field: ContainerField, _ value: ContainerValue,
                                                   selected: Set<String>, in directory: URL) throws
        -> PreparedContainerEdit? {
        let all = Array(Set(try fileNames(in: directory)).union(selected)).sorted(by: ContainerOrder.precedes)
        let groups = ContainerEdits.contiguousGroups(selected: selected, fileNames: all)
        return try prepareContainerEdit(at: directory) { file in
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
    func setContainerStandardName(_ standard: String, for written: String, field: ContainerField, forPath path: String,
                                  undo: UndoManager? = nil) {
        guard let (tree, dir, _) = containerEditLocation(path) else { return }
        let now = Date()
        let removing = standard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        runContainerEdit(done: removing ? "Standard name removed." : "Standard name saved.",
                         action: removing ? "Stop Using the Standard Name" : "Standard Name", undo: undo) {
            let root = try Self.nearestNamesRoot(tree, dir)
            let names: ContainerNames
            let stamp: ContainerFileStamp?
            switch ContainerFileStore.loadNames(root: root) {
            case .missing: (names, stamp) = (ContainerNames(), nil)
            case let .loaded(doc, s) where !s.droppedOnReading: (names, stamp) = (doc, s)
            default: throw ContainerWriteError.refusedExisting(ContainerNames.fileName)
            }
            let edited = ContainerEdits.setStandardName(standard, for: written, field: field, in: names, at: now)
            guard edited.names != names.names else { return nil }
            let wrote = try ContainerFileStore.writeNames(edited, root: root, expecting: stamp)
            return ContainerUndoStep(restores: [ContainerDocumentRestore(folder: root, restore: .names(names),
                                                                         expecting: wrote)])
        }
    }

    // MARK: Undo

    /// Gives `undo` the step that takes `step`'s files back, under `action` ("Undo Container Change").
    private func registerContainerUndo(_ step: ContainerUndoStep, action: String, on undo: UndoManager?) {
        guard let undo, !step.restores.isEmpty else { return }
        let tree = containerTree?.path
        // An edit's save lands after its event has ended, outside any undo group, where the action's name is lost
        // (Edit ▸ Undo read a bare "Undo"); an undo or redo already has its group, and the reverse step goes in it.
        let ownGroup = !undo.isUndoing && !undo.isRedoing
        if ownGroup { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.applyContainerUndo(step, action: action, tree: tree, on: undo) }
        }
        undo.setActionName(action)
        if ownGroup { undo.endUndoGrouping() }
    }

    /// Undo or Redo of a container edit. Run here, on the main thread, so the step that reverses it is registered
    /// while the undo manager is undoing (it then goes to Redo, and the other way). The files are small and the store
    /// waits at most `lockWait` for another writer.
    private func applyContainerUndo(_ step: ContainerUndoStep, action: String, tree: String?, on undo: UndoManager) {
        guard tree == containerTree?.path else {
            containerEditError = "That change was made in another archive, so it was not undone."
            announce(containerEditError ?? "")
            return
        }
        let redoing = undo.isRedoing
        let result = step.apply()
        registerContainerUndo(result.inverse, action: action, on: undo)
        let verb = redoing ? "redone" : "undone"
        if result.failures.isEmpty {
            containerEditError = nil
            statusMessage = "\(action) \(verb)."
            announce(statusMessage)
        } else {
            let failed = result.failures.count
            let names = result.failures.map { "“\($0.folder.lastPathComponent)”" }.joined(separator: ", ")
            let start = result.inverse.restores.isEmpty
                ? "\(action) was not \(verb)."
                : "\(action) was \(verb) except in \(failed) folder\(failed == 1 ? "" : "s") (\(names))."
            let failure = start + " " + containerUndoMessage(result.failures[0].error)
            containerEditError = failure
            announce(failure)
        }
        containerEditSaving = true
        refreshContainers(force: true)
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
    /// What it wrote is registered with `undo` as `action`.
    private func runContainerEdit(done: String, action: String, undo: UndoManager?,
                                  _ work: @escaping @Sendable () throws -> ContainerUndoStep?) {
        guard !containerEditSaving else {
            containerEditError = "The last change is still being saved. Try again in a moment."
            return
        }
        containerEditSaving = true
        containerEditError = nil
        let treePath = containerTree?.path
        Task { [weak self] in
            let outcome: Result<ContainerUndoStep?, ContainerEditFailure> = await Task.detached(priority: .userInitiated) {
                do { return .success(try work()) } catch { return .failure(ContainerEditFailure(error)) }
            }.value
            guard let self else { return }
            guard treePath == self.containerTree?.path else { self.containerEditSaving = false; return }
            var failure: String?
            switch outcome {
            case .success(let step): if let step { self.registerContainerUndo(step, action: action, on: undo) }
            case .failure(let error): failure = error.message
            }
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
    /// stamp. A document this build would not overwrite is refused before `change` runs. Returns what undoes it.
    @discardableResult
    nonisolated static func editContainerFile(at directory: URL,
                                              _ change: (ContainerFile) -> ContainerFile?) throws
        -> ContainerDocumentRestore? {
        try prepareContainerEdit(at: directory, change)?.commit()
    }

    /// The read and the change of `editContainerFile`, without the write; nil when nothing would change.
    nonisolated static func prepareContainerEdit(at directory: URL,
                                                 _ change: (ContainerFile) -> ContainerFile?) throws
        -> PreparedContainerEdit? {
        let file: ContainerFile
        let stamp: ContainerFileStamp?
        switch ContainerFileStore.load(directory: directory) {
        case .missing: (file, stamp) = (ContainerFile(), nil)
        case let .loaded(doc, s) where !s.droppedOnReading: (file, stamp) = (doc, s)
        default: throw ContainerWriteError.refusedExisting(ContainerFile.fileName)
        }
        guard var edited = change(file), edited != file else { return nil }
        edited.updatedAt = Date()
        return PreparedContainerEdit(directory: directory, before: file, stamp: stamp, edited: edited)
    }
}

/// A container file read and edited, not yet written.
struct PreparedContainerEdit: Sendable {
    let directory: URL
    /// What the file held (an empty document where there was none).
    let before: ContainerFile
    let stamp: ContainerFileStamp?
    let edited: ContainerFile

    /// Writes it with the read's stamp; what undoes it.
    func commit() throws -> ContainerDocumentRestore {
        let wrote = try ContainerFileStore.write(edited, directory: directory, expecting: stamp)
        return ContainerDocumentRestore(folder: directory, restore: .containers(before), expecting: wrote)
    }
}

/// One file a container edit wrote: the document to put back, and the stamp of the one the edit wrote.
struct ContainerDocumentRestore: Sendable {
    enum Document: Sendable {
        /// `<folder>/.archivesuite/containers.json`.
        case containers(ContainerFile)
        /// `<folder>/.archivesuite/container-names.json`.
        case names(ContainerNames)
    }
    let folder: URL
    let restore: Document
    let expecting: ContainerFileStamp
}

/// What one Undo or Redo of a container edit puts back: every file of one edit, a set for selection's folders
/// included.
struct ContainerUndoStep: Sendable {
    var restores: [ContainerDocumentRestore]

    /// Puts each file back where it is still the document the edit wrote, read fresh and written with that read's
    /// stamp; any other is left alone. `inverse` is what takes the restored files forward again.
    func apply() -> (inverse: ContainerUndoStep, failures: [(folder: URL, error: Error)]) {
        var inverse: [ContainerDocumentRestore] = []
        var failures: [(folder: URL, error: Error)] = []
        for r in restores {
            do {
                switch r.restore {
                case .containers(let doc):
                    let current = try Self.current(ContainerFileStore.load(directory: r.folder), r.expecting)
                    let wrote = try ContainerFileStore.write(doc, directory: r.folder, expecting: r.expecting)
                    inverse.append(.init(folder: r.folder, restore: .containers(current), expecting: wrote))
                case .names(let doc):
                    let current = try Self.current(ContainerFileStore.loadNames(root: r.folder), r.expecting)
                    let wrote = try ContainerFileStore.writeNames(doc, root: r.folder, expecting: r.expecting)
                    inverse.append(.init(folder: r.folder, restore: .names(current), expecting: wrote))
                }
            } catch {
                failures.append((r.folder, error))
            }
        }
        return (ContainerUndoStep(restores: inverse), failures)
    }

    /// The document on disk, when it is still the one with `expected`'s stamp.
    private static func current<D>(_ load: ContainerLoad<D>, _ expected: ContainerFileStamp) throws -> D {
        guard case let .loaded(doc, stamp) = load, stamp == expected else {
            throw ContainerWriteError.changedSinceRead
        }
        return doc
    }
}

/// "Set for selection" wrote `written` of `total` folders before a write failed, then put them back; `notRestored`
/// are the folders that could not be put back.
struct ContainerSelectionRolledBack: Error {
    let written: Int
    let total: Int
    let notRestored: [(folder: URL, error: Error)]
    let underlying: Error
}

/// An edit's error, as the Inspector words it (carried off the detached task as text).
struct ContainerEditFailure: Error {
    let message: String
    init(_ error: Error) { message = containerEditWriteMessage(error) }
}

/// Why an undo or redo left a folder alone.
func containerUndoMessage(_ error: Error) -> String {
    if (error as? ContainerWriteError) == .changedSinceRead {
        return "Its container file changed after the edit (another app, or another change), so it was left as it is."
    }
    return containerEditWriteMessage(error)
}

/// Why a container edit was refused, for the Inspector.
func containerEditWriteMessage(_ error: Error) -> String {
    if let partial = error as? ContainerSelectionRolledBack {
        let reason = containerEditWriteMessage(partial.underlying)
        guard !partial.notRestored.isEmpty else {
            return "Nothing was saved: \(partial.written) of \(partial.total) folders were written and then put back. "
                + reason
        }
        let names = partial.notRestored.map { "“\($0.folder.lastPathComponent)”" }.joined(separator: ", ")
        return "Not every folder could be saved, and \(names) could not be put back as it was. "
            + containerUndoMessage(partial.notRestored[0].error) + " " + reason
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
