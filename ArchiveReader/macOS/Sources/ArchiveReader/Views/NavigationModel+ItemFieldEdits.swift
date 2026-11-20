import Foundation
import ArchiveCore

// MARK: - Correcting a page-2 item field (W40.reader-item-field-edit, Tier-2; SPEC/tag-format.md §"Field checks")
//
// The page-2 header is the Processor's output-time snapshot and the Reader never rewrites a PDF, so the user's value is
// kept in the file's folder, `<folder>/.archivesuite/item-fields.json` (`UserItemFields`), through the same
// `ContainerFileStore` writer as the container editor: read fresh off the main thread, changed, written with the read's
// stamp, so another app's change in between is refused, never overwritten. Nothing outside `.archivesuite` is touched.
// Undo and Redo are the container editor's (`ContainerUndoStep`).

/// What the user did to one item field of one file.
enum ItemFieldEdit: Equatable, Sendable {
    /// Typed a value, shown in place of page 2's.
    case set(String)
    /// "None": the file has no such field, whatever page 2 reads.
    case none
    /// Takes the user's value away, so page 2's shows again.
    case remove
}

extension ItemFieldEdit {
    /// The value `UserItemFields.set` takes: the trimmed text, "" for none, nil to remove; nil for blank text, which
    /// is no edit at all.
    var stored: String?? {
        switch self {
        case .set(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .some(trimmed)
        case .none: return .some("")
        case .remove: return .some(nil)
        }
    }

    func action(_ field: CheckableField) -> String {
        switch self {
        case .set: return "\(field.label) Change"
        case .none: return "\(field.label) None"
        case .remove: return "Remove Your \(field.label)"
        }
    }
}

extension NavigationModel {
    /// Where item fields can be corrected: the folder the Reader was given, the boundary every Reader tag write keeps
    /// (W49.reader-item-fields-follow; before it, only the archive's main folder, the container tree, was offered).
    /// The correction goes beside the file whatever its folder, so nothing ties it to the container tree.
    var itemFieldRoot: (url: URL, path: String)? {
        guard let granted = rootStore.root, let prefix = rootStore.discoveredPathPrefix else { return nil }
        return (granted, prefix)
    }

    /// Whether the file at `path` is where a correction can be saved for it.
    func canEditItemFields(_ path: String) -> Bool {
        itemFieldRoot.map { ContainerCatalog.split(path, under: $0.path) != nil } ?? false
    }

    /// Edits `field` of the file at `path`, under the folder the Reader was given.
    func editItemField(_ field: CheckableField, _ edit: ItemFieldEdit, forPath path: String,
                       undo: UndoManager? = nil) {
        guard CheckableField.correctable.contains(field), let value = edit.stored else { return }
        itemFieldEditPath = path
        guard let root = itemFieldRoot, let (dir, name) = ContainerCatalog.split(path, under: root.path) else {
            itemFieldEditError = "This file is outside the archive folder the Reader was given, so a correction "
                + "cannot be saved for it."
            return
        }
        runContainerEdit(done: "\(field.label) saved.", action: edit.action(field), undo: undo,
                         document: .itemFields) {
            let directory = try Self.containerDirectoryURL(root.url, dir)
            return try Self.editItemFields(at: directory) { fields in
                var fields = fields
                fields.set(field, to: value, for: name)
                return fields
            }.map { ContainerUndoStep(restores: [$0]) }
        }
    }

    /// W49.reader-item-fields-follow: the same edit of `field` for every file at `paths`, all or nothing across their
    /// folders, as the container editor's "set for selection" (`setForSelection`): every folder's file is read and
    /// edited first, one refusal writes nothing, and a write that still fails puts back the folders already written.
    /// One Undo takes the whole edit back. A file outside the folder the Reader was given refuses the whole edit.
    func editItemFieldForSelection(_ field: CheckableField, _ edit: ItemFieldEdit, paths: [String],
                                   undo: UndoManager? = nil) {
        guard CheckableField.correctable.contains(field), let value = edit.stored, !paths.isEmpty else { return }
        itemFieldEditPath = nil   // shown for a selection, whatever is selected when it lands
        itemFieldEditForSelection = true
        guard let root = itemFieldRoot else { return }
        var byDirectory: [[String]: Set<String>] = [:]
        for path in paths {
            guard let (dir, name) = ContainerCatalog.split(path, under: root.path) else {
                itemFieldEditError = "Some of these files are outside the archive folder the Reader was given, so "
                    + "nothing was saved."
                return
            }
            byDirectory[dir, default: []].insert(name)
        }
        let count = paths.count
        let directories = byDirectory.sorted { $0.key.joined(separator: "/") < $1.key.joined(separator: "/") }
        runContainerEdit(done: "\(field.label) saved for \(count) file\(count == 1 ? "" : "s").",
                         action: edit.action(field) + " for Selection", undo: undo, document: .itemFields) {
            let prepared = try directories.compactMap { dir, names in
                try Self.prepareItemFieldEdit(at: try Self.containerDirectoryURL(root.url, dir)) { fields in
                    var fields = fields
                    for name in names { fields.set(field, to: value, for: name) }
                    return fields
                }
            }
            return try Self.commitAll(prepared)
        }
    }

    /// W49.reader-item-fields-search: after an edit, undo or redo, the content index reads the corrections beside the
    /// listed files again, so search and the Item fields column follow at once rather than at the next pass.
    /// One sync at a time, and at most one more after it (W49.reader-item-fields-follow): two overlapping reads could
    /// land out of order and put an older read of the corrections into the index.
    func syncItemFieldsToIndex() {
        guard !itemFieldSyncRunning else { itemFieldSyncQueued = true; return }
        itemFieldSyncRunning = true
        let files = library.files
        Task { [weak self] in
            guard let self else { return }
            let changed = await self.indexer.syncUserFields(files)
            self.itemFieldSyncRunning = false
            if changed {
                self.refreshFormatStatuses()
                self.refreshFullTextSearchIfActive()
            }
            if self.itemFieldSyncQueued {
                self.itemFieldSyncQueued = false
                self.syncItemFieldsToIndex()
            }
        }
    }

    /// W49.reader-sidecar-names-refresh: after the watcher saw a `.json` written, the content index reads the sidecar
    /// names of the files in those folders again where a sidecar changed, so search and the Item fields column follow
    /// at once rather than at the next pass. One sync at a time; folders announced while it runs are taken after it.
    func syncSidecarNamesToIndex() {
        guard !sidecarSyncRunning else { return }
        let folders = library.takeTouchedSidecarFolders()
        guard !folders.isEmpty else { return }
        sidecarSyncRunning = true
        let files = Self.files(library.files, under: folders)
        Task { [weak self] in
            guard let self else { return }
            let changed = await self.indexer.syncSidecarNames(files)
            self.sidecarSyncRunning = false
            if changed {
                self.refreshFormatStatuses()
                self.refreshFullTextSearchIfActive()
            }
            self.syncSidecarNamesToIndex()   // folders announced meanwhile
        }
    }

    /// The files of `files` inside any of `folders`, at any depth.
    nonisolated static func files(_ files: [ArchiveFile], under folders: Set<String>) -> [ArchiveFile] {
        files.filter { file in
            var folder = (file.path as NSString).deletingLastPathComponent
            while folder.count > 1 {
                if folders.contains(folder) { return true }
                folder = (folder as NSString).deletingLastPathComponent
            }
            return folders.contains(folder)
        }
    }

    /// Reads `directory`'s item-field file, applies `change` and writes it with the read's stamp; nil when nothing
    /// changed. A document this build cannot read, or of a newer version, is refused before `change` runs.
    nonisolated static func editItemFields(at directory: URL, _ change: (UserItemFields) -> UserItemFields) throws
        -> ContainerDocumentRestore? {
        try prepareItemFieldEdit(at: directory, change)?.commit()
    }

    /// `editItemFields` without the write: the read, checked and changed, for a caller that writes several folders
    /// all or nothing (`commitAll`).
    nonisolated static func prepareItemFieldEdit(at directory: URL, _ change: (UserItemFields) -> UserItemFields)
        throws -> PreparedItemFieldEdit? {
        let fields: UserItemFields
        let stamp: ContainerFileStamp?
        switch ContainerFileStore.loadItemFields(directory: directory) {
        case .missing: (fields, stamp) = (UserItemFields(), nil)
        case let .loaded(doc, s) where !s.droppedOnReading: (fields, stamp) = (doc, s)
        default: throw ContainerWriteError.refusedExisting(UserItemFields.fileName)
        }
        var edited = change(fields)
        guard edited.files != fields.files || edited.dates != fields.dates else { return nil }
        edited.updatedAt = Date()
        try ContainerFileStore.checkSize(edited)
        return PreparedItemFieldEdit(directory: directory, before: fields, stamp: stamp, edited: edited)
    }
}

/// One folder's item-field edit, read and changed but not yet written.
struct PreparedItemFieldEdit: PreparedDocumentEdit {
    let directory: URL
    let before: UserItemFields
    let stamp: ContainerFileStamp?
    let edited: UserItemFields

    /// Writes it with the read's stamp; what undoes it.
    func commit() throws -> ContainerDocumentRestore {
        let wrote = try ContainerFileStore.writeItemFields(edited, directory: directory, expecting: stamp)
        return ContainerDocumentRestore(folder: directory, restore: .itemFields(before), expecting: wrote,
                                        written: .itemFields(edited))
    }
}
