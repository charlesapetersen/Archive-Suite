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

extension NavigationModel {
    /// Edits `field` of the file at `path`, under the archive's main folder.
    func editItemField(_ field: CheckableField, _ edit: ItemFieldEdit, forPath path: String,
                       undo: UndoManager? = nil) {
        guard CheckableField.itemFields.contains(field) else { return }
        guard let tree = containerTree, let (dir, name) = ContainerCatalog.split(path, under: tree.path) else {
            itemFieldEditError = "This file is outside the archive's main folder, so a correction cannot be saved for it."
            return
        }
        let value: String?
        let action: String
        switch edit {
        case .set(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            (value, action) = (trimmed, "\(field.label) Change")
        case .none: (value, action) = ("", "\(field.label) None")
        case .remove: (value, action) = (nil, "Remove Your \(field.label)")
        }
        runContainerEdit(done: "\(field.label) saved.", action: action, undo: undo, document: .itemFields) {
            let directory = try Self.containerDirectoryURL(tree.url, dir)
            return try Self.editItemFields(at: directory) { fields in
                var fields = fields
                fields.set(field, to: value, for: name)
                return fields
            }.map { ContainerUndoStep(restores: [$0]) }
        }
    }

    /// Reads `directory`'s item-field file, applies `change` and writes it with the read's stamp; nil when nothing
    /// changed. A document this build cannot read, or of a newer version, is refused before `change` runs.
    nonisolated static func editItemFields(at directory: URL, _ change: (UserItemFields) -> UserItemFields) throws
        -> ContainerDocumentRestore? {
        let fields: UserItemFields
        let stamp: ContainerFileStamp?
        switch ContainerFileStore.loadItemFields(directory: directory) {
        case .missing: (fields, stamp) = (UserItemFields(), nil)
        case let .loaded(doc, s) where !s.droppedOnReading: (fields, stamp) = (doc, s)
        default: throw ContainerWriteError.refusedExisting(UserItemFields.fileName)
        }
        var edited = change(fields)
        guard edited.files != fields.files else { return nil }
        edited.updatedAt = Date()
        let wrote = try ContainerFileStore.writeItemFields(edited, directory: directory, expecting: stamp)
        return ContainerDocumentRestore(folder: directory, restore: .itemFields(fields), expecting: wrote)
    }
}
