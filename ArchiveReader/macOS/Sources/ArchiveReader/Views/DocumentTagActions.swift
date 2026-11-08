import SwiftUI
import ArchiveCore

/// The Tags menu with a document window in front (W40.fix-reader-menus-follow-window; owner session reader-1,
/// row 20). The menu acted only on the list's selection, so every item was disabled while reading. Here it acts
/// on the file the window shows, through the navigation window's `NavigationModel`: the same `TagWriter`
/// writes, the same main-archive and cache-row checks, and the same undo ledger as the list. No new write path.
///
/// The model is reached through `DeepLinkRouter.nav` (weak), read at the moment of each action, so a closed
/// navigation window disables the menu rather than leaving it writing through a dead model.
@MainActor
struct DocumentTagActions {
    let router: DeepLinkRouter
    let viewer: DocumentViewerModel

    var navigation: NavigationModel? { router.nav }
    private var paths: [String]? { viewer.currentFilePath.map { [$0] } }

    /// A file is open and there is a library to write through.
    var canTag: Bool { navigation != nil && viewer.currentFilePath != nil }
    /// Off while Find has the keyboard; TextUndoGuard gives inspector fields their own typing undo.
    var canUndo: Bool {
        (navigation?.undoDepth ?? 0) > 0 && !viewer.findFieldFocused
    }
    /// Off in the same places as `canUndo`, so ⇧⌘Z there never redoes a tag change.
    var canRedo: Bool {
        (navigation?.redoDepth ?? 0) > 0 && !viewer.findFieldFocused
    }

    func mark(_ state: ReadState) {
        guard let navigation, let paths else { return }
        navigation.mark(state, paths: paths)
        viewer.tagStatus = navigation.statusMessage
    }

    /// Marks the open file Read, then moves this window on to the next file it holds that is still Unread.
    /// The list's version moves the list's selection; here the window's own files are the run being read.
    func markReadAndNextUnread() {
        guard let navigation, let paths else { return }
        navigation.mark(.read, paths: paths)
        let status = navigation.statusMessage
        // Moves on only once the open file reads Read; a refused or failed mark keeps it in front with the reason.
        guard navigation.libraryFiles(atPaths: paths).first?.readState == .read else {
            viewer.tagStatus = status
            return
        }
        let later = viewer.urls.indices.filter { $0 > viewer.index }
        let unread = Set(navigation.libraryFiles(atPaths: later.map { viewer.urls[$0].path })
            .filter { $0.readState == .unread }.map(\.path))
        if let next = later.first(where: { unread.contains(viewer.urls[$0].path) }) {
            viewer.index = next   // loads it, which clears the status line, so the status is set after
            viewer.tagStatus = status
        } else {
            viewer.tagStatus = status + " No further unread documents in this window."
        }
    }

    func editTags() {
        guard canTag else { return }
        viewer.showingTagEditor.toggle()
    }

    func toggleFlag() {
        guard let navigation, let paths else { return }
        guard navigation.toggleFlag(paths: paths) else { viewer.tagStatus = navigation.statusMessage; return }
        viewer.tagStatus = paths.allSatisfy(navigation.flags.isFlagged) ? "Flagged." : "Flag removed."
    }

    func undo() {
        guard let navigation, canUndo else { return }
        // The ledger is shared with the list, so the newest change may be on another file: name it.
        let names = navigation.nextUndoFileNames()
        navigation.undoLast()
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        viewer.tagStatus = navigation.statusMessage + (names.isEmpty ? "" : " (\(shown))")
    }

    func redo() {
        guard let navigation, canRedo else { return }
        let names = navigation.nextRedoFileNames()
        navigation.redoLast()
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        viewer.tagStatus = navigation.statusMessage + (names.isEmpty ? "" : " (\(shown))")
    }
}

struct DocumentTagActionsKey: FocusedValueKey { typealias Value = DocumentTagActions }
extension FocusedValues {
    var documentTagActions: DocumentTagActions? {
        get { self[DocumentTagActionsKey.self] }
        set { self[DocumentTagActionsKey.self] = newValue }
    }
}
