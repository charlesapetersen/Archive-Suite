import SwiftUI
import AppKit
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
        if navigation.library.usesCatalogue {
            navigation.markCatalogue(state, paths: paths) { _ in viewer.tagStatus = navigation.statusMessage }
        } else {
            navigation.mark(state, paths: paths)
            viewer.tagStatus = navigation.statusMessage
        }
    }

    /// Marks the open file Read, then moves this window on to the next file it holds that is still Unread.
    /// The list's version moves the list's selection; here the window's own files are the run being read.
    func markReadAndNextUnread() {
        guard let navigation, let paths else { return }
        if navigation.library.usesCatalogue {
            let original = viewer.currentFilePath
            navigation.markCatalogue(.read, paths: paths) { verified in
                guard viewer.currentFilePath == original else { return }
                if !verified.isEmpty { advance(using: navigation) }
                else { viewer.tagStatus = navigation.statusMessage }
            }
            return
        }
        navigation.mark(.read, paths: paths)
        // Moves on only once the open file reads Read; a refused or failed mark keeps it in front with the reason.
        guard navigation.libraryFiles(atPaths: paths).first?.readState == .read else {
            viewer.tagStatus = navigation.statusMessage
            return
        }
        advance(using: navigation)
    }

    private func advance(using navigation: NavigationModel) {
        let status = navigation.statusMessage
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
        // In Catalogue Mode the flag is a companion save, whose result arrives once it has been written.
        guard navigation.toggleFlag(paths: paths, completed: { _ in viewer.tagStatus = navigation.statusMessage }) else {
            viewer.tagStatus = navigation.statusMessage
            return
        }
        if !navigation.library.usesCatalogue {
            viewer.tagStatus = paths.allSatisfy(navigation.flags.isFlagged) ? "Flagged." : "Flag removed."
        }
    }

    /// W44.reocr-reader: the Tags menu's poor-OCR toggle and Improve OCR… for the open file.
    var poorOCRTitle: String { navigation?.poorOCRCommandTitle(paths: paths) ?? ReaderCommand.togglePoorOCR.title }

    func togglePoorOCR() {
        guard let navigation, let paths else { return }
        if navigation.library.usesCatalogue {
            if !navigation.togglePoorOCR(paths: paths, completed: { _ in viewer.tagStatus = navigation.statusMessage }) {
                viewer.tagStatus = navigation.statusMessage
            }
            return
        }
        let flag = !navigation.poorOCRWouldClear(paths: paths)
        let targets = navigation.libraryFiles(atPaths: paths)
        guard !targets.isEmpty else { navigation.togglePoorOCR(paths: paths); viewer.tagStatus = navigation.statusMessage; return }
        guard navigation.connectImproveOCRFolderIfNeeded() else { viewer.tagStatus = navigation.statusMessage; return }
        Task {
            await navigation.setPoorOCR(flag, on: targets)
            viewer.tagStatus = navigation.statusMessage
        }
    }

    func improveOCR() {
        guard let navigation, let paths else { return }
        navigation.improveOCR(paths: paths)
        viewer.tagStatus = navigation.statusMessage
    }

    // MARK: Selection menu (W49.reader-doc-window-parity)
    //
    // Selection's file commands act on the open file, as the Tags menu does. Reveal in Finder and Copy Link(s) need
    // only the file; the archive link and Zotero need its library row, so the navigation window's model.

    var canActOnFile: Bool { viewer.currentURL != nil }

    /// Read-only: Finder is pointed at the file, which is never moved or changed.
    func revealInFinder() {
        guard let url = viewer.currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInDefaultApp() { viewer.openInDefaultApp() }

    func copyLinks() {
        guard let url = viewer.currentURL else { return }
        viewer.tagStatus = NavigationModel.copyLinks([url])
    }

    func copyArchiveLinks() {
        guard let navigation, let paths = libraryPaths(navigation) else { return }
        navigation.copyArchiveLinks(paths: paths)
        viewer.tagStatus = navigation.statusMessage
    }

    func exportToZotero() {
        guard let navigation, let paths = libraryPaths(navigation) else { return }
        navigation.exportToZotero(paths: paths) { viewer.tagStatus = $0 }
    }

    func addToZotero() {
        guard let navigation, let paths = libraryPaths(navigation) else { return }
        navigation.addToZotero(paths: paths) { viewer.tagStatus = $0 }
    }

    /// The open file's path when the library holds it; otherwise the status line says why nothing happens.
    private func libraryPaths(_ navigation: NavigationModel) -> [String]? {
        guard let paths, !navigation.libraryFiles(atPaths: paths).isEmpty else {
            viewer.tagStatus = "This file is not in the archive's library, so it has no archive link or Zotero entry here."
            return nil
        }
        return paths
    }

    func undo() {
        guard let navigation, canUndo else { return }
        // A large undo runs off the main actor; the status is set again once it has reported.
        navigation.undoLast { viewer.tagStatus = navigation.statusMessage }
        viewer.tagStatus = navigation.statusMessage
    }

    func redo() {
        guard let navigation, canRedo else { return }
        navigation.redoLast { viewer.tagStatus = navigation.statusMessage }
        viewer.tagStatus = navigation.statusMessage
    }
}

struct DocumentTagActionsKey: FocusedValueKey { typealias Value = DocumentTagActions }
extension FocusedValues {
    var documentTagActions: DocumentTagActions? {
        get { self[DocumentTagActionsKey.self] }
        set { self[DocumentTagActionsKey.self] = newValue }
    }
}
