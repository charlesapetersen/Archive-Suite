import AppKit
import ArchiveCore
import UniformTypeIdentifiers

/// File ▸ New Library… and Open Library… — make or open the `.archivenotes` library Notes keeps its notes in
/// (W40.fix-notes-choose-store; a package since W49.notes-store-format, owner 2026-11-20, call 24).
///
/// A library is a folder with the `.archivenotes` extension, which Notes declares as a package
/// (`com.archivenotes.library` in `Info.plist`): Finder shows it as one object that opens in Notes, and the
/// Reader, Processor and ArchiveCore walks skip package contents. Inside it is the store as before:
/// `.archive-suite-root.json`, `items/`, `organization.json`, `Trash/`. A library copied from another computer
/// is opened where it lies, nothing copied or moved. A new one is made only by New Library… (the Save panel);
/// an ordinary folder never becomes a store, and neither does a library holding other files, because the
/// next launch writes a Notes marker and saves notes there.
///
/// The switch happens at the next launch (`RootFolderStore.rememberRootAtQuit`), so after the user confirms,
/// the app quits through its normal path, which saves every open editor first (`NotesAppDelegate`), and
/// starts itself again in the chosen library (Restart and Switch; owner, notes-2 row 1).
///
/// The panels, the confirmation, the outcome alert and the quit are seams, as in `ReaderRootChooser`:
/// an `NSOpenPanel` or `NSAlert` shown from a unit-test host blocks the bundle with nobody to dismiss it.
@MainActor
final class StoreFolderChooser {

    nonisolated static let libraryExtension = "archivenotes"
    nonisolated static let libraryType = UTType(exportedAs: "com.archivenotes.library", conformingTo: .package)

    /// What a picked library is, as a candidate store.
    enum FolderCheck: Equatable, Sendable {
        /// Holds a Notes store: a `.notes` marker.
        case store
        /// Holds nothing but hidden files: a new store starts there (a library New Library… just made).
        case empty
        case refused(Refusal)
    }

    enum Refusal: Equatable, Sendable {
        /// Could not be read as a folder.
        case unreadable
        /// Its marker exists but could not be read, so what it belongs to is unknown.
        case markerUnreadable
        /// Another app's root, e.g. the archive Archive Reader uses.
        case otherRootKind(RootKind)
        /// Inside a Reader archive or another store: notes saved there would be written into it.
        case insideAnotherRoot
        /// Not an `.archivenotes` library.
        case notALibrary
        /// A library with contents but no Notes store.
        case notAStore
        /// New Library… named something that already exists and is not a library.
        case alreadyExists
        /// macOS would not let Notes remember the library.
        case cannotRemember

        var message: String {
            switch self {
            case .unreadable:
                "Archive Notes can't read it."
            case .markerUnreadable:
                "Its Archive Suite marker can't be read, so Archive Notes can't tell what it holds."
            case .otherRootKind(.reader):
                "That folder is an archive for Archive Reader, not a notes library. "
                    + "To preview its documents from Notes, use File ▸ Choose Archive Folder… instead."
            case .otherRootKind:
                "It belongs to another Archive Suite app, not to Archive Notes."
            case .insideAnotherRoot:
                "It is inside an archive or another notes library. "
                    + "Choose a place outside it, so notes are never saved into the archive."
            case .notALibrary:
                "Archive Notes keeps notes in a library whose name ends in .archivenotes. "
                    + "Choose one, or make a new one with File ▸ New Library…."
            case .notAStore:
                "That library holds other files but no notes."
            case .alreadyExists:
                "Something with that name is already there. Choose another name."
            case .cannotRemember:
                "macOS wouldn't let Archive Notes remember it, so the library was not changed."
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        case cancelled
        /// The picked library is the one already in use.
        case alreadyCurrent(URL)
        case refused(URL, Refusal)
        /// Remembered; the app is quitting so the next launch uses it.
        case switching(URL)
        /// Confirmed, but the quit was called off, so nothing was remembered.
        case quitCancelled(URL)
        /// Asked whether the place is inside an archive, the user chose to grant the archive first.
        case chooseArchiveFirst(URL)
    }

    /// What the folders above a place say about it.
    enum Enclosing: Equatable, Sendable {
        /// No parent carries a marker, and every parent could be looked at.
        case none
        /// A parent carries an `.archive-suite-root.json`.
        case marker
        /// No marker was seen, but some parent could not be looked at, so one may be there.
        case cannotLook
    }

    /// The answer to "is it inside an archive?" (asked only for `Enclosing.cannotLook`).
    enum ArchiveAnswer: Sendable { case notInArchive, chooseArchive, cancel }

    /// Look for a marker in every parent of `path`. `stat(2)`, not a listing: the sandbox refuses to list an
    /// ungranted parent but lets its metadata be read, so a marker there is seen (measured 2026-11-20 with the
    /// production entitlements: `stat` found an ungranted archive's marker, on the Desktop too, where listing
    /// failed). `ENOENT` is "no marker"; any other failure is "cannot look" (W49.notes-store-format).
    nonisolated static func enclosingMarker(of path: String) -> Enclosing {
        var result = Enclosing.none
        var parent = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            var info = stat()
            if stat(parent.appendingPathComponent(RootMarker.filename).path, &info) == 0 { return .marker }
            if errno != ENOENT && errno != ENOTDIR { result = .cannotLook }
            parent = parent.deletingLastPathComponent()
        }
        return result
    }

    /// A library was opened from Finder in this process. A first launch by double-click then switches to it
    /// and does not also offer the first-launch Save panel.
    static var libraryArrivedFromFinder = false

    nonisolated static func isLibraryName(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == libraryExtension
    }

    /// The checks that need only the place, not its contents: not a granted archive, not inside one, not
    /// inside anything a parent's marker claims. Run for a new library too, before anything is made.
    nonisolated static func placeCheck(_ folder: URL, readerRoots: [URL]) -> Refusal? {
        func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        let path = canonical(folder)
        // Case folded: APFS is usually case-insensitive, and refusing one folder too many is safe.
        let folded = path.lowercased()
        for root in readerRoots.map({ canonical($0).lowercased() }) {
            if folded == root { return .otherRootKind(.reader) }
            if folded.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return .insideAnotherRoot }
        }
        return enclosingMarker(of: path) == .marker ? .insideAnotherRoot : nil
    }

    /// Classify a library. Reads only: nothing is written until the next launch adopts it, and that launch
    /// runs the same check again (`RootFolderStore.resolveSaved`).
    ///
    /// A library inside another root is refused even when it is empty: taking it would put notes inside the
    /// archive. Two signs are used: a marker in any parent (`enclosingMarker`), and `readerRoots`, the archive
    /// folders Notes has been granted (Choose Archive Folder…). An archive whose top carries no marker (one no
    /// Archive Suite app has used) cannot be recognised (`ArchiveNotes/KNOWN_ISSUES.md`).
    nonisolated static func check(_ folder: URL, readerRoots: [URL] = []) -> FolderCheck {
        if let refusal = placeCheck(folder, readerRoots: readerRoots) { return .refused(refusal) }
        let marker: RootMarker?
        do {
            marker = try RootMarker.read(at: folder)
        } catch {
            return .refused(.markerUnreadable)
        }
        if let marker {
            guard marker.kind == .notes else { return .refused(.otherRootKind(marker.kind)) }
            return isLibraryName(folder) ? .store : .refused(.notALibrary)
        }
        guard isLibraryName(folder) else { return .refused(.notALibrary) }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return .refused(.unreadable)
        }
        return names.allSatisfy { $0.hasPrefix(".") } ? .empty : .refused(.notAStore)
    }

    private let rootStore: RootFolderStore

    /// Seams (see the type comment).
    var pickFolder: @MainActor () -> URL? = { StoreFolderChooser.runOpenPanel() }
    var pickNewLibrary: @MainActor (_ firstLaunch: Bool) -> URL? = { StoreFolderChooser.runSavePanel(firstLaunch: $0) }
    var confirm: @MainActor (_ folder: URL, _ check: FolderCheck) -> Bool = {
        StoreFolderChooser.runConfirmation(folder: $0, check: $1)
    }
    var askInsideArchive: @MainActor (_ folder: URL) -> ArchiveAnswer = {
        StoreFolderChooser.runInsideArchiveQuestion(folder: $0)
    }
    var report: @MainActor (Outcome) -> Void = { StoreFolderChooser.presentAlert(for: $0) }
    var quit: @MainActor () -> Void = { NSApp.terminate(nil) }
    /// Run as the app terminates, after the pick is written.
    var relaunch: @MainActor () -> Void = { StoreFolderChooser.relaunchApp() }

    init(rootStore: RootFolderStore) {
        self.rootStore = rootStore
    }

    /// File ▸ Open Library….
    /// - Parameter readerRoots: the archive folders Notes has been granted; none of them, nor anything
    ///   inside one, may become the store.
    @discardableResult
    func choose(readerRoots: [URL] = []) -> Outcome {
        guard let picked = pickFolder() else { return .cancelled }
        return use(picked, readerRoots: readerRoots)
    }

    /// A library given to Notes from outside: a double-click in Finder, or one dropped on the Dock icon. The
    /// same checks and confirmation as Open Library….
    @discardableResult
    func use(_ picked: URL, readerRoots: [URL] = []) -> Outcome {
        // A bookmark cannot resolve a symbolic link, so remember the folder it points at (as
        // `ReaderRootStore.grantRoot` does).
        guard let target = CorpusWalker.canonicalRoot(picked) else {
            return finish(.refused(picked, .unreadable))
        }
        if let current = rootStore.root, Self.samePath(current, target) {
            return finish(.alreadyCurrent(picked))
        }
        let check = Self.check(target, readerRoots: readerRoots)
        if case let .refused(refusal) = check { return finish(.refused(picked, refusal)) }
        return askThenSwitch(picked: picked, target: target, check: check)
    }

    /// File ▸ New Library…, and the first launch, which has no library (`RootFolderStore.needsLibrary`). The
    /// Save panel names the library and its place; the package is made empty, and the next launch writes its
    /// marker. Never replaces anything: a name already in use is a library to switch to, or refused.
    @discardableResult
    func newLibrary(readerRoots: [URL] = [], firstLaunch: Bool = false) -> Outcome {
        guard var picked = pickNewLibrary(firstLaunch) else { return .cancelled }
        if !Self.isLibraryName(picked) { picked.appendPathExtension(Self.libraryExtension) }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDirectory) {
            // The Save panel's Replace must never delete a library: one already there (holding notes, or
            // still empty from a switch called off) is used as it is.
            let existing = isDirectory.boolValue ? Self.check(picked, readerRoots: readerRoots) : nil
            guard existing == .store || existing == .empty else {
                return finish(.refused(picked, .alreadyExists))
            }
            return use(picked, readerRoots: readerRoots)
        }
        if let refusal = Self.placeCheck(picked, readerRoots: readerRoots) {
            return finish(.refused(picked, refusal))
        }
        switch askIfInsideArchive(picked) {
        case .notInArchive: break
        case .chooseArchive: return finish(.chooseArchiveFirst(picked))
        case .cancel: return .cancelled
        }
        // Asked before anything is made, so a cancel leaves nothing behind.
        guard confirm(picked, .empty) else { return .cancelled }
        do {
            try FileManager.default.createDirectory(at: picked, withIntermediateDirectories: false)
        } catch {
            NSLog("StoreFolderChooser: could not make \(picked.path): \(error)")
            return finish(.refused(picked, .unreadable))
        }
        let outcome = remember(picked: picked, target: picked)
        if outcome != .switching(picked) {
            // The switch did not happen, so the package just made goes again. `rmdir` removes only an
            // empty folder: if anything has been put in it since, it stays.
            rmdir(picked.path)
        }
        return outcome
    }

    private func askThenSwitch(picked: URL, target: URL, check: FolderCheck) -> Outcome {
        switch askIfInsideArchive(target) {
        case .notInArchive: break
        case .chooseArchive: return finish(.chooseArchiveFirst(picked))
        case .cancel: return .cancelled
        }
        return switchTo(picked: picked, target: target, check: check)
    }

    /// The owner's question (call 24): when a parent could not be looked at, ask before using the place.
    private func askIfInsideArchive(_ folder: URL) -> ArchiveAnswer {
        Self.enclosingMarker(of: folder.resolvingSymlinksInPath().standardizedFileURL.path) == .cannotLook
            ? askInsideArchive(folder) : .notInArchive
    }

    private func switchTo(picked: URL, target: URL, check: FolderCheck) -> Outcome {
        guard confirm(picked, check) else { return .cancelled }
        return remember(picked: picked, target: target)
    }

    private func remember(picked: URL, target: URL) -> Outcome {
        do {
            try rootStore.rememberRootAtQuit(target, then: relaunch)
        } catch {
            NSLog("StoreFolderChooser: could not bookmark \(target.path): \(error)")
            return finish(.refused(picked, .cannotRemember))
        }
        // The pick is written, and the relaunch started, only once the quit is really happening
        // (`willTerminate`). A successful quit never returns here; a return means the quit was called off
        // (a failed save the user chose not to quit over), so the pick is dropped with it rather than
        // switching at some later quit.
        quit()
        if rootStore.committedPendingRoot { return .switching(picked) }
        rootStore.discardPendingRoot()
        return finish(.quitCancelled(picked))
    }

    /// Runs `body` from the main run loop in its default mode, not as a main-queue job. A pick that is not a
    /// menu or button action (a library from Finder, the first launch's Save panel) must start this way, since it
    /// may end in Restart and Switch: the quit waits in `applicationShouldTerminate` for the editors' flush, which
    /// needs the main queue, and a nested run loop started inside a main-queue job (a `Task` on the main actor,
    /// `DispatchQueue.main.async`) never drains it, so the app hung instead of quitting (measured with the
    /// Release build in the VM, W49.notes-finder-open-check). Default mode only, so it waits out an open alert.
    static func onMainRunLoop(_ body: @escaping @MainActor () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { MainActor.assumeIsolated(body) }
        CFRunLoopWakeUp(loop)
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        report(outcome)
        return outcome
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - The real panels and alerts

    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        // A library is a package: the panel shows it as one file to choose, not a folder to enter.
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [libraryType]
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Library"
        panel.message = "Choose an Archive Notes library (its name ends in .archivenotes)."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The user's own Documents folder, not the sandbox container's: the Save panel may propose it, and the
    /// grant comes from the panel.
    static var documentsFolder: URL? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    static func runSavePanel(firstLaunch: Bool) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [libraryType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Archive Notes"
        panel.directoryURL = documentsFolder
        panel.prompt = "Make Library"
        panel.message = firstLaunch
            ? "Archive Notes keeps your notes in a library you can see, back up and move as one item. "
                + "Choose where to make it. To use a library you already have, cancel and choose File ▸ Open Library…."
            : "Name the new library and choose where to keep it."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func runInsideArchiveQuestion(folder: URL) -> ArchiveAnswer {
        let alert = NSAlert()
        alert.messageText = "Is “\(folder.lastPathComponent)” inside an archive?"
        alert.informativeText = "Archive Notes can't look at the folders around it. If it is inside an archive "
            + "folder, notes saved there would be written into the archive. Choose the archive's top folder "
            + "with Choose Archive Folder… first, so Archive Notes can tell."
        alert.addButton(withTitle: "Not in an Archive")
        alert.addButton(withTitle: "Choose Archive Folder…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .notInArchive
        case .alertSecondButtonReturn: return .chooseArchive
        default: return .cancel
        }
    }

    static func runConfirmation(folder: URL, check: FolderCheck) -> Bool {
        let alert = NSAlert()
        let name = folder.deletingPathExtension().lastPathComponent
        alert.messageText = check == .empty
            ? "Start the new library “\(name)”?"
            : "Switch to the library “\(name)”?"
        alert.informativeText = "Archive Notes will save your notes and restart in the chosen library. "
            + "The notes in the current library stay where they are."
        alert.addButton(withTitle: "Restart and Switch")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Start a new instance of Notes as this one terminates. It is asked for while this process still runs (the
    /// old one is past saving, and the two never open the same store), so the launch is waited for briefly:
    /// returning from `willTerminate` ends the process, and with it a request not yet delivered. A sandboxed
    /// relaunch is given no arguments (the configuration's are dropped), so a UITest's are handed over through
    /// the app's defaults instead, and its relaunch uses its scratch store, never the owner's.
    static func relaunchApp() {
        guard !ArchiveTestHost.isUnitTestHost else { return }
#if DEBUG
        UITestRelaunchArguments.saveForRelaunch()
#endif
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let launched = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { NSLog("StoreFolderChooser: could not restart Archive Notes: \(error)") }
            launched.signal()
        }
        _ = launched.wait(timeout: .now() + 5)
    }

    static func presentAlert(for outcome: Outcome) {
        let alert = NSAlert()
        switch outcome {
        case .cancelled, .switching, .chooseArchiveFirst:
            return
        case let .quitCancelled(folder):
            alert.messageText = "The library was not changed."
            alert.informativeText = "Archive Notes did not quit, so it is still using the current library. "
                + "Choose “\(folder.lastPathComponent)” again when you are ready to switch."
        case let .alreadyCurrent(folder):
            alert.messageText = "“\(folder.lastPathComponent)” is already the library Archive Notes is using."
        case let .refused(folder, refusal):
            alert.alertStyle = .warning
            alert.messageText = "“\(folder.lastPathComponent)” can't be used as the notes library."
            alert.informativeText = refusal.message
        }
        alert.runModal()
    }
}
