import Foundation

/// The one Undo and Redo of a window: the newest change of the tag ledger, the viewer's turns, the window's container
/// edits and the catalogue's saves (`ReaderUndoSource`), named for it. Edit ▸ Undo/Redo and the navigation window's
/// toolbar Undo both read it, so the button is enabled, named and acts as the menu item does
/// (W49.reader-toolbar-undo; it called the tag ledger alone, so it stayed off after a container or catalogue edit,
/// or took back an older tag change under it).
@MainActor
struct ReaderUndoRoute {
    /// The navigation window's model, when it is in front.
    let nav: NavigationModel?
    /// The viewer in front: a document window's, or the preview sheet's.
    let doc: DocumentViewerModel?
    /// A document window's file, when no navigation window is in front.
    let docTags: DocumentTagActions?
    /// The window's undo manager, which its container edits are registered on.
    let windowUndo: UndoManager?

    /// The tag ledger's undo is open to the window in front (the list's, or the document window's file).
    var tagCanUndo: Bool { nav != nil ? (nav?.undoDepth ?? 0) > 0 : (docTags?.canUndo ?? false) }
    var tagCanRedo: Bool { nav != nil ? (nav?.redoDepth ?? 0) > 0 : (docTags?.canRedo ?? false) }
    var tagModel: NavigationModel? { nav ?? docTags?.navigation }
    /// The container and item-field edits made in the window in front (`ContainerHistory`).
    var containerUndoStep: ContainerHistory.Step? { tagModel?.containerUndo(on: windowUndo) }
    var containerRedoStep: ContainerHistory.Step? { tagModel?.containerUndo(on: windowUndo, redo: true) }
    /// A catalogue save, or a bulk tag change running off the main actor (W49.reader-batch-writes-async): Undo
    /// and Redo wait for it rather than reversing an older step of another kind under it.
    var catalogueChangeInProgress: Bool {
        guard let model = tagModel else { return false }
        return model.tagBatch != nil || (model.library.usesCatalogue && model.catalogueEditSaving)
    }
    var catalogueUndoStep: CatalogueEditJournal.Step? { catalogueHistory?.undo }
    var catalogueRedoStep: CatalogueEditJournal.Step? { catalogueHistory?.redo }
    private var catalogueHistory: CatalogueEditJournal.Heads? {
        guard let model = tagModel, model.library.usesCatalogue, !model.catalogueEditSaving,
              doc?.findFieldFocused != true else { return nil }
        return model.catalogueHistory
    }

    /// The title reads the history last read; the action reads the ledger fresh. A tag change whose time is not read
    /// yet still counts, as the oldest.
    func nextUndo(tag: Date?) -> ReaderUndoSource? {
        ReaderUndoSource.newest(tag: tagCanUndo ? tag ?? .distantPast : nil, rotation: doc?.nextRotationUndoDate,
                                container: containerUndoStep?.date, catalogue: catalogueUndoStep?.date)
    }
    func nextRedo(tag: Date?) -> ReaderUndoSource? {
        ReaderUndoSource.newest(tag: tagCanRedo ? tag ?? .distantPast : nil, rotation: doc?.nextRotationRedoDate,
                                container: containerRedoStep?.date, catalogue: catalogueRedoStep?.date)
    }

    var canUndo: Bool {
        !catalogueChangeInProgress && (tagCanUndo || (doc?.canUndoRotation ?? false)
                                       || containerUndoStep != nil || catalogueUndoStep != nil)
    }
    var canRedo: Bool {
        !catalogueChangeInProgress && (tagCanRedo || (doc?.canRedoRotation ?? false)
                                       || containerRedoStep != nil || catalogueRedoStep != nil)
    }

    var undoTitle: String {
        switch nextUndo(tag: tagModel?.knownUndoDate) {
        case .tag: return ReaderCommand.undoTagChange.title
        case .rotation: return "Undo Rotation"
        case .catalogue: return "Undo \(catalogueUndoStep?.title ?? "Catalogue Change")"
        case .container: return "Undo \(containerUndoStep?.action ?? "")"
        case nil: return "Undo"
        }
    }

    var redoTitle: String {
        switch nextRedo(tag: tagModel?.knownRedoDate) {
        case .tag: return ReaderCommand.redoTagChange.title
        case .rotation: return "Redo Rotation"
        case .catalogue: return "Redo \(catalogueRedoStep?.title ?? "Catalogue Change")"
        case .container: return "Redo \(containerRedoStep?.action ?? "")"
        case nil: return "Redo"
        }
    }

    func undo() {
        guard !catalogueChangeInProgress else { return }
        switch nextUndo(tag: tagCanUndo ? tagModel?.nextUndoDate() : nil) {
        case .rotation: doc?.undoRotation()
        case .catalogue: tagModel?.reverseCatalogueEdit(redo: false)
        case .container: windowUndo?.undo()
        case .tag: if let nav { nav.undoLast() } else { docTags?.undo() }
        case nil: break
        }
    }

    func redo() {
        guard !catalogueChangeInProgress else { return }
        switch nextRedo(tag: tagCanRedo ? tagModel?.nextRedoDate() : nil) {
        case .rotation: doc?.redoRotation()
        case .catalogue: tagModel?.reverseCatalogueEdit(redo: true)
        case .container: windowUndo?.redo()
        case .tag: if let nav { nav.redoLast() } else { docTags?.redo() }
        case nil: break
        }
    }
}
