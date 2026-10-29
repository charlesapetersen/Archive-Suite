import AppKit
import ArchiveCore

/// File ▸ Choose Store Folder… — pick the folder Notes keeps its store in (W40.fix-notes-choose-store).
///
/// A store copied from another computer is adopted where it lies: its `.archive-suite-root.json`,
/// `items/` and `organization.json` are read as they are, nothing is copied or moved. An empty folder
/// becomes a new store. Anything else is refused, because the next launch writes a Notes marker into
/// the folder and saves notes there: a Reader archive or an ordinary folder of documents must never
/// turn into a notes store by a mis-click.
///
/// The switch happens at the next launch (`RootFolderStore.rememberRoot`), so after the user confirms,
/// the app quits through its normal path, which saves every open editor first (`NotesAppDelegate`).
///
/// The panel, the confirmation, the outcome alert and the quit are seams, as in `ReaderRootChooser`:
/// an `NSOpenPanel` or `NSAlert` opened from a unit-test host blocks the bundle with nobody to dismiss it.
@MainActor
final class StoreFolderChooser {

    /// What a picked folder is, as a candidate store.
    enum FolderCheck: Equatable, Sendable {
        /// Holds a Notes store: a `.notes` marker, or (a store made before markers) an `items/` folder.
        case store
        /// Holds nothing but hidden files: a new store starts there.
        case empty
        case refused(Refusal)
    }

    enum Refusal: Equatable, Sendable {
        /// Could not be opened as a folder.
        case unreadable
        /// Its marker exists but could not be read, so what it belongs to is unknown.
        case markerUnreadable
        /// Another app's root, e.g. the archive Archive Reader opens.
        case otherRootKind(RootKind)
        /// Inside a Reader archive or another store: notes saved there would be written into it.
        case insideAnotherRoot
        /// Has contents but no Notes store.
        case notAStore
        /// macOS would not let Notes remember the folder.
        case cannotRemember

        var message: String {
            switch self {
            case .unreadable:
                "Archive Notes can't open that folder."
            case .markerUnreadable:
                "The folder's Archive Suite marker can't be read, so Archive Notes can't tell what it holds."
            case .otherRootKind(.reader):
                "That folder is an archive for Archive Reader, not a notes store. "
                    + "To preview its documents from Notes, use File ▸ Choose Archive Folder… instead."
            case .otherRootKind:
                "That folder belongs to another Archive Suite app, not to Archive Notes."
            case .insideAnotherRoot:
                "That folder is inside an archive or another notes store. "
                    + "Choose a folder outside it, so notes are never saved into the archive."
            case .notAStore:
                "That folder already holds other files but no notes store. "
                    + "Choose a folder that holds a store, or an empty folder for a new one."
            case .cannotRemember:
                "macOS wouldn't let Archive Notes remember that folder, so the store was not changed."
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case cancelled
        /// The picked folder is the store already open.
        case alreadyCurrent(URL)
        case refused(URL, Refusal)
        /// Remembered; the app is quitting so the next launch opens it.
        case switching(URL)
        /// Confirmed, but the quit was called off, so nothing was remembered.
        case quitCancelled(URL)
    }

    /// Classify a folder. Reads only: nothing is written until the next launch adopts it, and that launch
    /// runs the same check again (`RootFolderStore.resolveSaved`).
    ///
    /// A folder inside another root is refused even when it is empty: an empty box folder in the corpus
    /// has no marker of its own, and taking it would put notes inside the archive. Two signs are used,
    /// because the sandbox usually cannot read a picked folder's parents: a marker in any parent that can
    /// be read, and `readerRoots`, the archive folders Notes has been granted (Choose Archive Folder…).
    /// Both are best-effort: in the sandboxed app the parents are normally unreadable, so an empty folder
    /// inside an archive never granted to Notes is accepted (`ArchiveNotes/KNOWN_ISSUES.md`). Nothing
    /// already in the archive is touched then; the store's own files are added beside it.
    nonisolated static func check(_ folder: URL, readerRoots: [URL] = []) -> FolderCheck {
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let path = canonical(folder)
        // Case folded: APFS is usually case-insensitive, and refusing one folder too many is safe.
        let folded = path.lowercased()
        for root in readerRoots.map({ canonical($0).lowercased() }) {
            if folded == root { return .refused(.otherRootKind(.reader)) }
            if folded.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return .refused(.insideAnotherRoot) }
        }
        var parent = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent(RootMarker.filename).path) {
                return .refused(.insideAnotherRoot)
            }
            parent = parent.deletingLastPathComponent()
        }
        let marker: RootMarker?
        do {
            marker = try RootMarker.read(at: folder)
        } catch {
            return .refused(.markerUnreadable)
        }
        if let marker {
            return marker.kind == .notes ? .store : .refused(.otherRootKind(marker.kind))
        }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else {
            return .refused(.unreadable)
        }
        // A real directory, not a link: a linked `items` would send every save somewhere else.
        let items = try? fm.attributesOfItem(atPath: folder.appendingPathComponent("items").path)
        if items?[.type] as? FileAttributeType == .typeDirectory {
            return .store
        }
        return names.allSatisfy { $0.hasPrefix(".") } ? .empty : .refused(.notAStore)
    }

    private let rootStore: RootFolderStore

    /// Seams (see the type comment).
    var pickFolder: @MainActor () -> URL? = { StoreFolderChooser.runOpenPanel() }
    var confirm: @MainActor (_ folder: URL, _ check: FolderCheck) -> Bool = {
        StoreFolderChooser.runConfirmation(folder: $0, check: $1)
    }
    var report: @MainActor (Outcome) -> Void = { StoreFolderChooser.presentAlert(for: $0) }
    var quit: @MainActor () -> Void = { NSApp.terminate(nil) }

    init(rootStore: RootFolderStore) {
        self.rootStore = rootStore
    }

    /// - Parameter readerRoots: the archive folders Notes has been granted; none of them, nor anything
    ///   inside one, may become the store.
    @discardableResult
    func choose(readerRoots: [URL] = []) -> Outcome {
        guard let picked = pickFolder() else { return .cancelled }
        // A bookmark cannot open a symbolic link, so remember the folder it points at (as
        // `ReaderRootStore.grantRoot` does).
        guard let target = CorpusWalker.canonicalRoot(picked) else {
            return finish(.refused(picked, .unreadable))
        }
        if let current = rootStore.root, Self.samePath(current, target) {
            return finish(.alreadyCurrent(picked))
        }
        let check = Self.check(target, readerRoots: readerRoots)
        if case let .refused(refusal) = check { return finish(.refused(picked, refusal)) }
        guard confirm(picked, check) else { return .cancelled }
        do {
            try rootStore.rememberRootAtQuit(target)
        } catch {
            NSLog("StoreFolderChooser: could not bookmark \(target.path): \(error)")
            return finish(.refused(picked, .cannotRemember))
        }
        // The pick is written only once the quit is really happening (`willTerminate`). A successful quit
        // never returns here; a return means the quit was called off (a failed save the user chose not
        // to quit over), so the pick is dropped with it rather than switching at some later quit.
        quit()
        if rootStore.committedPendingRoot { return .switching(picked) }
        rootStore.discardPendingRoot()
        return finish(.quitCancelled(picked))
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        report(outcome)
        return outcome
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - The real panel and alerts

    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Store Folder"
        panel.message = "Choose a folder that holds an Archive Notes store, or an empty folder for a new store."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func runConfirmation(folder: URL, check: FolderCheck) -> Bool {
        let alert = NSAlert()
        let name = folder.lastPathComponent
        alert.messageText = check == .empty
            ? "Start a new store in “\(name)”?"
            : "Switch to the store in “\(name)”?"
        alert.informativeText = "Archive Notes will save your open notes and quit. "
            + "Open it again to work in the chosen store. The notes in the current store stay where they are."
        alert.addButton(withTitle: "Quit and Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func presentAlert(for outcome: Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .cancelled, .switching:
            return
        case let .quitCancelled(folder):
            alert.messageText = "The store was not changed."
            alert.informativeText = "Archive Notes did not quit, so it is still using the current store. "
                + "Choose “\(folder.lastPathComponent)” again when you are ready to switch."
        case let .alreadyCurrent(folder):
            alert.messageText = "“\(folder.lastPathComponent)” is already the store Archive Notes is using."
        case let .refused(folder, refusal):
            alert.alertStyle = .warning
            alert.messageText = "“\(folder.lastPathComponent)” can't be used as the notes store."
            alert.informativeText = refusal.message
        }
        alert.runModal()
    }
}
