import Foundation
import ArchiveCore

// MARK: - The container editor (W47.ct-reader-edit, Tier-2; `SPEC/containers.md`)
//
// The Reader's one write class outside Finder tags: `<directory>/.archivesuite/containers.json` and the tree's
// `container-names.json`, new files or whole-document replacements inside `.archivesuite` only, through
// `ContainerFileStore` (no link followed, `flock`, the stamp of the read checked before the rename). Every edit reads
// the document fresh off the main thread, works the change out on it (`ContainerEdits`) and writes it with that read's
// stamp, so another app's change in between is refused, never overwritten. A document this build cannot read, of a
// newer version or holding values it drops is left alone and the Inspector says so; one the SPEC lets the user set
// aside is offered for it (`NavigationModel+ContainerSetAside`). No document is touched.
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

/// One window's container and item-field undo steps, newest last, kept beside its undo manager's own stacks so the
/// menu can name the next one and say when it was made (W49.reader-undo-menu-names).
struct ContainerHistory {
    struct Step: Equatable {
        let action: String
        /// When the step was made, or last moved between Undo and Redo, as a rotation's is.
        let date: Date
    }
    weak var manager: UndoManager?
    var undos: [Step] = []
    var redos: [Step] = []
}

extension NavigationModel {
    /// Edits `field` where `path`'s value lives (`ContainerEdits.target`): every file the run covers follows.
    func editContainerField(_ field: ContainerField, _ edit: ContainerFieldEdit, forPath path: String,
                            undo: UndoManager? = nil) {
        guard let (tree, dir, name) = containerEditLocation(path) else { return }
        folderDatingOffer = nil   // W47.ct-folder-date-reader: an offer made before this edit no longer stands
        let now = Date()
        let action = switch edit {
        case .set: "Container Change"
        case .noneHere: "None Here"
        case .remove: "Remove Your Value"
        }
        // W47.ct-folder-date-reader: a folder date typed or confirmed may date the run's undated documents; any edit of
        // it, a clearing included, updates the dates it gave (W49.reader-folder-date-undo).
        var onSaved: (@MainActor () -> Void)?
        let before = FolderDateBefore()
        if field == .date {
            let window = undo.map { ObjectIdentifier($0) }
            onSaved = { [weak self] in self?.offerFolderDating(at: path, window: window, datedBefore: before.dated) }
        }
        runContainerEdit(done: "Container saved.", action: action, undo: undo, {
            let directory = try Self.containerDirectoryURL(tree, dir)
            return try Self.editContainerFile(at: directory) { file in
                if field == .date { before.dated = ContainerFolderDate.confirmed(at: name, in: file.runs)?.inherited != nil }
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
        }, onSaved: onSaved)
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
    nonisolated static func commitAll(_ prepared: [any PreparedDocumentEdit]) throws -> ContainerUndoStep? {
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
            try Self.setStandardName(standard, for: written, field: field,
                                     root: try Self.nearestNamesRoot(tree, dir), at: now)
        }
    }

    /// The standard-names edit on `root`'s `container-names.json`: read fresh, changed, written with the read's stamp.
    /// An unreadable file is set aside only with the user's consent (W49.reader-ct-set-aside).
    nonisolated static func setStandardName(_ standard: String, for written: String, field: ContainerField,
                                            root: URL, at now: Date) throws -> ContainerUndoStep? {
        let names: ContainerNames
        let stamp: ContainerFileStamp?
        var settingAside = false
        switch ContainerFileStore.loadNames(root: root) {
        case .missing: (names, stamp) = (ContainerNames(), nil)
        case let .loaded(doc, s) where !s.droppedOnReading: (names, stamp) = (doc, s)
        case .unreadable(let why):
            // W49.reader-ct-set-aside: the names are strict, so a file this build drops from reads as unreadable.
            guard ContainerSetAsideConsent.given(root, ContainerNames.fileName) else {
                throw ContainerSetAsideNeeded(directory: root, fileName: ContainerNames.fileName,
                                              reason: .unreadable(why))
            }
            (names, stamp, settingAside) = (ContainerNames(), nil, true)
        default: throw ContainerWriteError.refusedExisting(ContainerNames.fileName)
        }
        let edited = ContainerEdits.setStandardName(standard, for: written, field: field, in: names, at: now)
        guard edited.names != names.names else { return nil }
        guard settingAside else {
            let wrote = try ContainerFileStore.writeNames(edited, root: root, expecting: stamp)
            return ContainerUndoStep(restores: [ContainerDocumentRestore(folder: root, restore: .names(names),
                                                                         expecting: wrote, written: .names(edited))])
        }
        let wrote = try ContainerFileStore.writeNamesSettingAside(edited, root: root, expecting: stamp)
        let restore: ContainerDocumentRestore.Document = wrote.setAsideName.map {
            .putBack(file: ContainerNames.fileName, aside: $0)
        } ?? .names(names)
        return ContainerUndoStep(restores: [ContainerDocumentRestore(folder: root, restore: restore,
                                                                     expecting: wrote.stamp,
                                                                     written: .names(edited))])
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
        recordContainerHistory(action, on: undo)
    }

    /// Adds the step just registered on `undo` to its window's history: an undo's reverse goes to Redo, a redo's or a
    /// new edit's to Undo, and a new edit ends what Redo held, as the undo manager does.
    private func recordContainerHistory(_ action: String, on undo: UndoManager) {
        let step = ContainerHistory.Step(action: action, date: Date())
        var entry = containerHistory.first { $0.manager === undo } ?? ContainerHistory(manager: undo)
        if undo.isUndoing {
            entry.redos.append(step)
        } else {
            entry.undos.append(step)
            if !undo.isRedoing { entry.redos.removeAll() }
        }
        containerHistory = containerHistory.filter { $0.manager != nil && $0.manager !== undo } + [entry]
    }

    /// The window's next container undo (or redo): its action's name and when it was made; nil unless the undo
    /// manager's next step is that one (typing in a field, say, sits above it until that is undone).
    func containerUndo(on undo: UndoManager?, redo: Bool = false) -> ContainerHistory.Step? {
        guard let undo, let entry = containerHistory.first(where: { $0.manager === undo }),
              let step = redo ? entry.redos.last : entry.undos.last,
              redo ? undo.canRedo : undo.canUndo,
              (redo ? undo.redoActionName : undo.undoActionName) == step.action else { return nil }
        return step
    }

    /// Undo or Redo of a container edit. Run here, on the main thread, so the step that reverses it is registered
    /// while the undo manager is undoing (it then goes to Redo, and the other way). The files are small and the store
    /// waits at most `lockWait` for another writer.
    private func applyContainerUndo(_ step: ContainerUndoStep, action: String, tree: String?, on undo: UndoManager) {
        let document = step.document
        let redoing = undo.isRedoing
        // The undo manager has taken this step off its stack; the history follows (`recordContainerHistory`).
        if let index = containerHistory.firstIndex(where: { $0.manager === undo }) {
            _ = redoing ? containerHistory[index].redos.popLast() : containerHistory[index].undos.popLast()
        }
        guard tree == containerTree?.path else {
            if document == .itemFields { itemFieldEditPath = nil }
            setEditError("That change was made in another archive, so it was not undone.", document)
            announce(editError(document) ?? "")
            return
        }
        if document == .containers { folderDatingOffer = nil }   // the folder date it offered may be the one undone
        if document == .itemFields { itemFieldEditPath = nil }   // an undo's error is shown whatever is selected
        let result = step.apply()
        registerContainerUndo(result.inverse, action: action, on: undo)
        let verb = redoing ? "redone" : "undone"
        if result.failures.isEmpty {
            setEditError(nil, document)
            statusMessage = "\(action) \(verb)."
            announce(statusMessage)
        } else {
            let failed = result.failures.count
            let names = result.failures.map { "“\($0.folder.lastPathComponent)”" }.joined(separator: ", ")
            let start = result.inverse.restores.isEmpty
                ? "\(action) was not \(verb)."
                : "\(action) was \(verb) except in \(failed) folder\(failed == 1 ? "" : "s") (\(names))."
            let failure = start + " " + containerUndoMessage(result.failures[0].error, document)
            setEditError(failure, document)
            announce(failure)
        }
        finishEdit(document)
    }

    /// After an edit, undo or redo: the Checks read the user's values again; a container edit keeps the editor off
    /// until the catalog read after it is published, so a menu still offering the old value cannot write it back. An
    /// item-field edit changes nothing the catalog reads, and each one reads its file fresh, so it waits for nothing.
    private func finishEdit(_ document: EditedDocument) {
        itemFieldRevision &+= 1
        syncItemFieldsToIndex()
        switch document {
        case .containers:
            containerEditSaving = true
            refreshContainers(force: true)
        case .itemFields:
            containerEditSaving = false
        }
    }

    /// Where an edit's error is shown: the Container section or the Checks section.
    func setEditError(_ message: String?, _ document: EditedDocument) {
        switch document {
        case .containers: containerEditError = message
        case .itemFields: itemFieldEditError = message
        }
    }

    private func editError(_ document: EditedDocument) -> String? {
        document == .containers ? containerEditError : itemFieldEditError
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

    /// A warning's Show in the Library health list (W49.reader-ct-warnings-all): the file it starts at is selected
    /// where the list is; one in another folder or hidden by a filter is shown in All Files, as Show in All Files does.
    func showContainerWarning(_ row: ContainerWarningRow) {
        if displayed.contains(where: { $0.path == row.startPath }) { return selectContainerWarning(row) }
        let files = library.files.filter { $0.path == row.startPath }
        guard !files.isEmpty else {
            statusMessage = "“\(row.start)” is no longer in the library."
            announce(statusMessage)
            return
        }
        showInAllFiles(ids: Set(files.map(\.id)), files: files)
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
    /// What it wrote is registered with `undo` as `action`; `onSaved` runs on the main thread after a save that worked.
    /// `consent`: the documents the user has said may be set aside (W49.reader-ct-set-aside); a refusal that one could
    /// lift is offered as `containerSetAsideOffer`, whose acceptance runs the same edit again with it added.
    func runContainerEdit(done: String, action: String, undo: UndoManager?, document: EditedDocument = .containers,
                          consent: Set<String> = [],
                          _ work: @escaping @Sendable () throws -> ContainerUndoStep?,
                          onSaved: (@MainActor () -> Void)? = nil) {
        guard !containerEditSaving else {
            setEditError("The last change is still being saved. Try again in a moment.", document)
            return
        }
        containerEditSaving = true
        containerSetAsideOffer = nil
        setEditError(nil, document)
        let treePath = containerTree?.path
        Task { [weak self] in
            let outcome: Result<ContainerUndoStep?, ContainerEditFailure> = await Task.detached(priority: .userInitiated) {
                do { return .success(try ContainerSetAsideConsent.$paths.withValue(consent) { try work() }) }
                catch { return .failure(ContainerEditFailure(error, document)) }
            }.value
            guard let self else { return }
            guard treePath == self.containerTree?.path else { self.containerEditSaving = false; return }
            var failure: String?
            switch outcome {
            case .success(let step): if let step { self.registerContainerUndo(step, action: action, on: undo) }
            case .failure(let error):
                failure = error.message
                if let needed = error.setAside {
                    self.containerSetAsideOffer = ContainerSetAsideOffer(
                        needed: needed, treePath: treePath, window: undo.map { ObjectIdentifier($0) },
                        retry: { [weak self] consent in
                            self?.runContainerEdit(done: done, action: action, undo: undo, document: document,
                                                   consent: consent, work, onSaved: onSaved)
                        }, consent: consent)
                }
            }
            if let failure {
                self.setEditError(failure, document)
                self.announce(failure)
            } else {
                self.statusMessage = done
                self.announce(done)
            }
            let saved = failure == nil
            // The editor stays disabled until the catalog read after this edit is published, so a menu still
            // offering the old value cannot write it back over the one just saved (`refreshContainers` clears it).
            self.finishEdit(document)
            if saved { onSaved?() }
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
        var settingAside = false
        let consented = ContainerSetAsideConsent.given(directory, ContainerFile.fileName)
        switch ContainerFileStore.load(directory: directory) {
        case .missing: (file, stamp) = (ContainerFile(), nil)
        case let .loaded(doc, s) where !s.droppedOnReading: (file, stamp) = (doc, s)
        case let .loaded(doc, s):
            // W49.reader-ct-set-aside: what reads is edited and kept; the file itself only on the user's say-so.
            guard consented else {
                let values = doc.directory.values.count + doc.runs.reduce(0) { $0 + $1.fields.values.count }
                throw ContainerSetAsideNeeded(directory: directory, fileName: ContainerFile.fileName,
                                              reason: .drops(runs: doc.runs.count, values: values))
            }
            (file, stamp, settingAside) = (doc, s, true)
        case .unreadable(let why):
            guard consented else {
                throw ContainerSetAsideNeeded(directory: directory, fileName: ContainerFile.fileName,
                                              reason: .unreadable(why))
            }
            (file, stamp, settingAside) = (ContainerFile(), nil, true)
        case .newer: throw ContainerWriteError.refusedExisting(ContainerFile.fileName)
        }
        guard var edited = change(file), edited != file else { return nil }
        edited.updatedAt = Date()
        return PreparedContainerEdit(directory: directory, before: file, stamp: stamp, edited: edited,
                                     settingAside: settingAside)
    }
}

/// A container file read and edited, not yet written.
/// A folder's edit in `.archivesuite`, read and changed, that `commitAll` writes with the others or not at all.
protocol PreparedDocumentEdit: Sendable {
    func commit() throws -> ContainerDocumentRestore
}

struct PreparedContainerEdit: PreparedDocumentEdit {
    let directory: URL
    /// What the file held (an empty document where there was none).
    let before: ContainerFile
    let stamp: ContainerFileStamp?
    let edited: ContainerFile
    /// The user said the file on disk may be set aside (W49.reader-ct-set-aside).
    var settingAside = false

    /// Writes it with the read's stamp; what undoes it. A set-aside file is put back by the undo, not overwritten.
    func commit() throws -> ContainerDocumentRestore {
        guard settingAside else {
            let wrote = try ContainerFileStore.write(edited, directory: directory, expecting: stamp)
            return ContainerDocumentRestore(folder: directory, restore: .containers(before), expecting: wrote,
                                            written: .containers(edited))
        }
        let wrote = try ContainerFileStore.writeSettingAside(edited, directory: directory, expecting: stamp)
        let restore: ContainerDocumentRestore.Document = wrote.setAsideName.map {
            .putBack(file: ContainerFile.fileName, aside: $0)
        } ?? .containers(before)
        return ContainerDocumentRestore(folder: directory, restore: restore, expecting: wrote.stamp,
                                        written: .containers(edited))
    }
}

/// One file a container edit wrote: the document to put back, and the stamp and content of the one the edit wrote.
struct ContainerDocumentRestore: Sendable {
    enum Document: Sendable, Equatable {
        /// `<folder>/.archivesuite/containers.json`.
        case containers(ContainerFile)
        /// `<folder>/.archivesuite/container-names.json`.
        case names(ContainerNames)
        /// `<folder>/.archivesuite/item-fields.json` (W40.reader-item-field-edit).
        case itemFields(UserItemFields)
        /// The document set aside as `aside` goes back to being `file` (W49.reader-ct-set-aside): the two are
        /// swapped, so the one written takes the set-aside name and nothing is deleted. As `written`, the file is
        /// matched by its stamp alone.
        case putBack(file: String, aside: String)
    }
    let folder: URL
    let restore: Document
    let expecting: ContainerFileStamp
    /// What the edit wrote, as it reads back. An undo of a later edit in the same folder rewrites the file with the
    /// content this edit wrote but a new stamp; that file is still this edit's, so its own undo goes ahead
    /// (`ContainerUndoStep.apply`).
    let written: Document

    init(folder: URL, restore: Document, expecting: ContainerFileStamp, written: Document) {
        self.folder = folder
        self.restore = restore
        self.expecting = expecting
        self.written = written.asStored
    }
}

extension ContainerDocumentRestore.Document {
    /// The document with its dates in whole seconds, as a read of the file gives it.
    var asStored: Self {
        switch self {
        case .containers(let d): return .containers(ContainerFileStore.asStored(d) ?? d)
        case .names(let d): return .names(ContainerFileStore.asStored(d) ?? d)
        case .itemFields(let d): return .itemFields(ContainerFileStore.asStored(d) ?? d)
        case .putBack: return self
        }
    }
}

/// What one Undo or Redo of a container edit puts back: every file of one edit, a set for selection's folders
/// included.
struct ContainerUndoStep: Sendable {
    var restores: [ContainerDocumentRestore]

    /// Which document an edit wrote, so its errors are shown where it was made.
    var document: EditedDocument {
        restores.allSatisfy { if case .itemFields = $0.restore { true } else { false } } && !restores.isEmpty
            ? .itemFields : .containers
    }

    /// Puts each file back where it is still the document the edit wrote, read fresh and written with that read's
    /// stamp; any other is left alone. `inverse` is what takes the restored files forward again.
    func apply() -> (inverse: ContainerUndoStep, failures: [(folder: URL, error: Error)]) {
        var inverse: [ContainerDocumentRestore] = []
        var failures: [(folder: URL, error: Error)] = []
        for r in restores {
            do {
                switch r.restore {
                case .containers(let doc):
                    let (current, stamp) = try Self.current(ContainerFileStore.load(directory: r.folder), r) {
                        .containers($0)
                    }
                    let wrote = try ContainerFileStore.write(doc, directory: r.folder, expecting: stamp)
                    inverse.append(.init(folder: r.folder, restore: .containers(current), expecting: wrote,
                                         written: r.restore))
                case .names(let doc):
                    let (current, stamp) = try Self.current(ContainerFileStore.loadNames(root: r.folder), r) {
                        .names($0)
                    }
                    let wrote = try ContainerFileStore.writeNames(doc, root: r.folder, expecting: stamp)
                    inverse.append(.init(folder: r.folder, restore: .names(current), expecting: wrote,
                                         written: r.restore))
                case .itemFields(let doc):
                    let (current, stamp) = try Self.current(ContainerFileStore.loadItemFields(directory: r.folder), r) {
                        .itemFields($0)
                    }
                    let wrote = try ContainerFileStore.writeItemFields(doc, directory: r.folder, expecting: stamp)
                    inverse.append(.init(folder: r.folder, restore: .itemFields(current), expecting: wrote,
                                         written: r.restore))
                case let .putBack(file, aside):
                    let back = try ContainerFileStore.putBackSetAside(aside, as: file, in: r.folder,
                                                                      expecting: try Self.putBackStamp(r))
                    inverse.append(.init(folder: r.folder, restore: r.restore, expecting: back, written: r.restore))
                }
            } catch {
                failures.append((r.folder, error))
            }
        }
        return (ContainerUndoStep(restores: inverse), failures)
    }

    /// The stamp a put-back checks the file against: the one written, or (after an undo of a later edit in the folder
    /// rewrote it) that of the same content read now. A put-back's own redo has only the stamp.
    private static func putBackStamp(_ r: ContainerDocumentRestore) throws -> ContainerFileStamp {
        switch r.written {
        case .containers: return try current(ContainerFileStore.load(directory: r.folder), r) { .containers($0) }.1
        case .names: return try current(ContainerFileStore.loadNames(root: r.folder), r) { .names($0) }.1
        case .itemFields, .putBack: return r.expecting
        }
    }

    /// The document on disk and its stamp, when it is still the one `restore`'s edit wrote: the same stamp, or (after
    /// an undo or redo of a later edit in the folder put it back) the same content, `updatedAt` included, so another
    /// writer's change is never taken for it. The write that follows uses this read's stamp.
    private static func current<D>(_ load: ContainerLoad<D>, _ restore: ContainerDocumentRestore,
                                   _ wrap: (D) -> ContainerDocumentRestore.Document) throws
        -> (D, ContainerFileStamp) {
        guard case let .loaded(doc, stamp) = load,
              stamp == restore.expecting || (!stamp.droppedOnReading && wrap(doc) == restore.written) else {
            throw ContainerWriteError.changedSinceRead
        }
        return (doc, stamp)
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
    /// The file the user could set aside to save the edit (W49.reader-ct-set-aside).
    let setAside: ContainerSetAsideNeeded?
    init(_ error: Error, _ document: EditedDocument = .containers) {
        message = document == .containers ? containerEditWriteMessage(error) : itemFieldEditWriteMessage(error)
        setAside = error as? ContainerSetAsideNeeded
    }
}

/// The document an edit in `.archivesuite` writes: the container files, or the user's item-field values.
enum EditedDocument: Sendable { case containers, itemFields }

/// Why an undo or redo left a folder alone.
func containerUndoMessage(_ error: Error, _ document: EditedDocument = .containers) -> String {
    if (error as? ContainerWriteError) == .changedSinceRead {
        let file = document == .containers ? "container file" : "item-field file"
        return "Its \(file) changed after the edit (another app, or another change), so it was left as it is."
    }
    return document == .containers ? containerEditWriteMessage(error) : itemFieldEditWriteMessage(error)
}

/// Why an item-field edit was refused, for the Inspector's Checks (W40.reader-item-field-edit).
func itemFieldEditWriteMessage(_ error: Error) -> String {
    // W49.reader-item-fields-follow: a selection's edit across folders is put back as a container one is.
    if let partial = error as? ContainerSelectionRolledBack { return rolledBackMessage(partial, .itemFields) }
    switch error as? ContainerWriteError {
    case .changedSinceRead?: return "Another app changed this folder's item fields just now. Look again and redo the change."
    case .busy?: return "Another app is writing this folder's item fields. Try again in a moment."
    case .refusedExisting?: return "This folder's item-field file (“.archivesuite/\(UserItemFields.fileName)”) was written "
        + "by a newer version, or is not one this version can read, so it is left as it is and nothing was changed."
    case .notOrdinary?: return "This folder's “.archivesuite” is a link or not a folder, so nothing was written."
    case .tooBig?: return "This folder's item-field file would pass its 1 MB limit, so nothing was written."
    default: return "The change could not be saved: \(error.localizedDescription)"
    }
}

/// Why a "set for selection" across folders saved nothing, or which folders it could not put back.
func rolledBackMessage(_ partial: ContainerSelectionRolledBack, _ document: EditedDocument) -> String {
    let reason = document == .containers ? containerEditWriteMessage(partial.underlying)
                                         : itemFieldEditWriteMessage(partial.underlying)
    guard !partial.notRestored.isEmpty else {
        return "Nothing was saved: \(partial.written) of \(partial.total) folders were written and then put back. "
            + reason
    }
    let names = partial.notRestored.map { "“\($0.folder.lastPathComponent)”" }.joined(separator: ", ")
    return "Not every folder could be saved, and \(names) could not be put back as it was. "
        + containerUndoMessage(partial.notRestored[0].error, document) + " " + reason
}

/// Why a container edit was refused, for the Inspector.
func containerEditWriteMessage(_ error: Error) -> String {
    if let partial = error as? ContainerSelectionRolledBack { return rolledBackMessage(partial, .containers) }
    if let needed = error as? ContainerSetAsideNeeded { return needed.refusal }
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
