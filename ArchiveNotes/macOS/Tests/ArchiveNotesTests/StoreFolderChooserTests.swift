import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveNotes

/// W40.fix-notes-choose-store and W49.notes-store-format — File ▸ New Library… and Open Library…: which
/// places may become the `.archivenotes` library, that the pick survives a relaunch and the notes are then
/// read from it, that a first launch opens no hidden default, that New Library… never replaces anything,
/// and that one store's index is never another's. Every library and bookmark here is scratch: a temp folder
/// and a throwaway defaults suite, never `notesStoreRootBookmark` in the app's own defaults.
@MainActor
final class StoreFolderChooserTests: XCTestCase {

    private var scratch: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Stands in for the app's centre, so "the app terminates" is a notification this test posts.
    private let center = NotificationCenter()

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreFolderChooserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        suiteName = "com.archivenotes.tests.store-folder.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: Helpers

    private func folder(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A library as another computer leaves it: marker, `items/` and one note.
    private func makeStore(_ name: String, noteTitle: String) async throws -> URL {
        let root = try folder(name)
        _ = try RootMarker.ensure(at: root, kind: .notes, name: name)
        let item = Item(id: UUID(), kind: .note, title: noteTitle, date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await NoteStore(root: root).create(item)
        return root
    }

    private func launchStore(readerRoots: [URL] = []) -> RootFolderStore {
        RootFolderStore(defaults: defaults, notificationCenter: center, readerRoots: readerRoots)
    }

    /// The quit going ahead: AppKit posts `willTerminate` and the process exits.
    private func terminate() {
        center.post(name: NSApplication.willTerminateNotification, object: nil)
    }

    private func remember(_ folder: URL) throws {
        let running = launchStore()   // the app's store lives until the process exits
        try running.rememberRootAtQuit(folder)
        terminate()
        XCTAssertTrue(running.committedPendingRoot)
    }

    /// A chooser whose every seam fails the test unless the test sets it.
    private func chooser(_ store: RootFolderStore) -> StoreFolderChooser {
        let chooser = StoreFolderChooser(rootStore: store)
        chooser.pickFolder = { XCTFail("no Open panel expected"); return nil }
        chooser.pickNewLibrary = { _ in XCTFail("no Save panel expected"); return nil }
        chooser.askInsideArchive = { _ in XCTFail("every parent can be looked at here"); return .cancel }
        chooser.confirm = { _, _ in XCTFail("nothing to confirm"); return false }
        chooser.report = { XCTFail("no alert expected, got \($0)") }
        chooser.quit = { XCTFail("must not quit") }
        chooser.relaunch = {}
        return chooser
    }

    private func path(_ url: URL?) -> String? { url?.resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: Which places qualify

    func testCheckClassifiesLibraries() async throws {
        let marked = try await makeStore("marked.archivenotes", noteTitle: "A")
        XCTAssertEqual(StoreFolderChooser.check(marked), .store)
        let capitalised = try await makeStore("Capitalised.ArchiveNotes", noteTitle: "A")
        XCTAssertEqual(StoreFolderChooser.check(capitalised), .store, "the extension is matched in any case")

        let plainStore = try await makeStore("plain-folder-store", noteTitle: "A")
        XCTAssertEqual(StoreFolderChooser.check(plainStore), .refused(.notALibrary),
                       "a store that is not an .archivenotes library is not adopted (nothing to migrate)")

        let legacy = try folder("legacy.archivenotes")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("items"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(StoreFolderChooser.check(legacy), .refused(.notAStore),
                       "an items/ folder without a marker is no longer adopted")

        let empty = try folder("empty.archivenotes")
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(StoreFolderChooser.check(empty), .empty, "hidden files alone leave a library empty")
        XCTAssertEqual(StoreFolderChooser.check(try folder("empty-plain")), .refused(.notALibrary),
                       "an empty ordinary folder never becomes a store")

        let reader = try folder("reader")
        _ = try RootMarker.ensure(at: reader, kind: .reader, name: "reader")
        XCTAssertEqual(StoreFolderChooser.check(reader), .refused(.otherRootKind(.reader)))

        let documents = try folder("documents.archivenotes")
        try Data("x".utf8).write(to: documents.appendingPathComponent("letter.pdf"))
        XCTAssertEqual(StoreFolderChooser.check(documents), .refused(.notAStore))

        let broken = try folder("broken.archivenotes")
        try Data("{not json".utf8).write(to: broken.appendingPathComponent(RootMarker.filename))
        XCTAssertEqual(StoreFolderChooser.check(broken), .refused(.markerUnreadable))
    }

    // MARK: The first launch

    /// There is no hidden default store (owner, 2026-11-20, call 24): with nothing chosen, no store opens and
    /// nothing is made; the app asks for a library.
    func testFirstLaunchOpensNoStoreAndMakesNothing() throws {
        let store = launchStore()
        XCTAssertNil(store.root)
        XCTAssertTrue(store.needsLibrary)
        XCTAssertFalse(store.savedRootUnavailable)
        XCTAssertNil(RootFolderStore.savedStoreFolder(defaults: defaults))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    // MARK: Open Library…, then a relaunch

    /// Open a library holding notes, relaunch, and the notes are read from it.
    func testOpenedLibraryIsUsedAtNextLaunchAndItsNotesRead() async throws {
        let copied = try await makeStore("copied-from-another-mac.archivenotes", noteTitle: "Adopted note")
        let markerBefore = try Data(contentsOf: copied.appendingPathComponent(RootMarker.filename))

        let first = launchStore()
        let chooser = chooser(first)
        var quits = 0, relaunches = 0, confirmed: StoreFolderChooser.FolderCheck?
        var pickWrittenAtRelaunch = false
        chooser.pickFolder = { copied }
        chooser.confirm = { _, check in confirmed = check; return true }
        chooser.quit = { quits += 1; self.terminate() }
        chooser.relaunch = {
            relaunches += 1
            pickWrittenAtRelaunch = self.defaults.data(forKey: "notesStoreRootBookmark") != nil
        }

        XCTAssertEqual(chooser.choose(), .switching(copied))
        XCTAssertEqual(confirmed, .store)
        XCTAssertEqual(quits, 1, "the app quits so the next launch uses the new library")
        // Restart and Switch (owner, notes-2 row 1): the app starts itself again, once the pick is written.
        XCTAssertEqual(relaunches, 1, "the app restarts into the new library")
        XCTAssertTrue(pickWrittenAtRelaunch, "the relaunch starts only after the pick is written")
        XCTAssertNil(first.root, "the running app keeps what it had until it quits")

        // Relaunch.
        let second = launchStore()
        XCTAssertEqual(path(second.root), path(copied), "the pick is remembered across a relaunch")
        XCTAssertFalse(second.savedRootUnavailable)
        XCTAssertFalse(second.needsLibrary)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent(RootMarker.filename)), markerBefore,
                       "the library is adopted where it lies: its marker is not rewritten")
        let notes = await NoteStore(root: try XCTUnwrap(second.root)).allItemSummaries()
        XCTAssertEqual(notes.map(\.title), ["Adopted note"])
    }

    /// A library double-clicked in Finder goes through the same checks and confirmation.
    func testLibraryFromFinderIsCheckedAndConfirmed() async throws {
        let library = try await makeStore("From Finder.archivenotes", noteTitle: "F")
        let chooser = chooser(launchStore())
        var confirmed: StoreFolderChooser.FolderCheck?
        chooser.confirm = { _, check in confirmed = check; return true }
        chooser.quit = { self.terminate() }
        XCTAssertEqual(chooser.use(library), .switching(library))
        XCTAssertEqual(confirmed, .store)
        XCTAssertEqual(path(launchStore().root), path(library))
    }

    // MARK: New Library…

    func testNewLibraryIsMadeEmptyAndMarkedAtNextLaunch() throws {
        let chooser = chooser(launchStore())
        var confirmed: StoreFolderChooser.FolderCheck?, askedFirstLaunch: Bool?
        chooser.pickNewLibrary = { first in askedFirstLaunch = first; return self.scratch.appendingPathComponent("Research") }
        chooser.confirm = { _, check in confirmed = check; return true }
        chooser.quit = { self.terminate() }
        let made = scratch.appendingPathComponent("Research.archivenotes")
        XCTAssertEqual(chooser.newLibrary(firstLaunch: true), .switching(made),
                       "the extension is added when the name lacks it")
        XCTAssertEqual(askedFirstLaunch, true)
        XCTAssertEqual(confirmed, .empty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: made.path).isEmpty,
                      "the package is made empty; nothing is written into it before the next launch")

        let relaunched = launchStore()
        XCTAssertEqual(path(relaunched.root), path(made))
        XCTAssertEqual(relaunched.marker?.kind, .notes, "the next launch marks the new library")
    }

    /// The Save panel's Replace must never delete anything: a library already there is switched to as it is,
    /// and anything else with the name is refused and left alone.
    func testNewLibraryNeverReplacesWhatIsThere() async throws {
        let existing = try await makeStore("Existing.archivenotes", noteTitle: "Kept")
        let file = scratch.appendingPathComponent("A File.archivenotes")
        try Data("x".utf8).write(to: file)
        let other = try folder("Other.archivenotes")
        try Data("x".utf8).write(to: other.appendingPathComponent("letter.pdf"))

        for (picked, refusal) in [(file, StoreFolderChooser.Refusal.alreadyExists), (other, .alreadyExists)] {
            let chooser = chooser(launchStore())
            var reported: StoreFolderChooser.Outcome?
            chooser.pickNewLibrary = { _ in picked }
            chooser.report = { reported = $0 }
            XCTAssertEqual(chooser.newLibrary(), .refused(picked, refusal))
            XCTAssertEqual(reported, .refused(picked, refusal), "a refusal is said")
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: other.path), ["letter.pdf"])

        let chooser = chooser(launchStore())
        var confirmed: StoreFolderChooser.FolderCheck?
        chooser.pickNewLibrary = { _ in existing }
        chooser.confirm = { _, check in confirmed = check; return true }
        chooser.quit = { self.terminate() }
        XCTAssertEqual(chooser.newLibrary(), .switching(existing))
        XCTAssertEqual(confirmed, .store, "an existing library is switched to, not made again")
        let notes = await NoteStore(root: existing).allItemSummaries()
        XCTAssertEqual(notes.map(\.title), ["Kept"])
    }

    /// A new library inside an archive is refused before anything is made.
    func testNewLibraryInsideAnArchiveMakesNothing() throws {
        let archive = try folder("archive")
        _ = try RootMarker.ensure(at: archive, kind: .reader, name: "archive")
        let picked = archive.appendingPathComponent("Box 4/Notes.archivenotes", isDirectory: true)
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        let chooser = chooser(launchStore())
        chooser.pickNewLibrary = { _ in picked }
        chooser.report = { _ in }
        XCTAssertEqual(chooser.newLibrary(), .refused(picked, .insideAnotherRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path))

        let granted = try folder("granted")
        let inGranted = granted.appendingPathComponent("Notes.archivenotes", isDirectory: true)
        chooser.pickNewLibrary = { _ in inGranted }
        XCTAssertEqual(chooser.newLibrary(readerRoots: [granted]), .refused(inGranted, .insideAnotherRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inGranted.path))
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
    }

    // MARK: "Is it inside an archive?" (owner, call 24)

    /// `stat` sees a parent's marker; a parent that cannot be looked at at all is "cannot look", and only then
    /// is the question asked. The place is made unsearchable here with permissions, as an unreadable volume
    /// would be.
    func testUnreadableParentAsksInsideArchiveAndMakesNothingUnlessAnswered() throws {
        let archive = try folder("marked")
        _ = try RootMarker.ensure(at: archive, kind: .reader, name: "marked")
        XCTAssertEqual(StoreFolderChooser.enclosingMarker(of: archive.appendingPathComponent("a/b").path), .marker)
        XCTAssertEqual(StoreFolderChooser.enclosingMarker(of: try folder("plain/a").path), .none)

        let locked = try folder("locked")
        let picked = locked.appendingPathComponent("inner/Notes.archivenotes", isDirectory: true)
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(StoreFolderChooser.enclosingMarker(of: picked.path), .cannotLook)

        let chooser = chooser(launchStore())
        chooser.pickNewLibrary = { _ in picked }
        var asked = 0
        chooser.askInsideArchive = { _ in asked += 1; return .chooseArchive }
        chooser.report = { _ in }
        XCTAssertEqual(chooser.newLibrary(), .chooseArchiveFirst(picked),
                       "Choose Archive Folder… is offered first; the commands run it")
        chooser.askInsideArchive = { _ in asked += 1; return .cancel }
        XCTAssertEqual(chooser.newLibrary(), .cancelled)
        XCTAssertEqual(asked, 2)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: picked.path), "nothing is made unless answered")
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
    }

    // MARK: Refusals and cancels write nothing

    func testRefusedFolderIsNeverRememberedOrMarked() throws {
        let reader = try folder("reader")
        _ = try RootMarker.ensure(at: reader, kind: .reader, name: "reader")
        let documents = try folder("documents.archivenotes")
        try Data("x".utf8).write(to: documents.appendingPathComponent("letter.pdf"))
        let ordinary = try folder("ordinary")

        for (picked, refusal) in [(reader, StoreFolderChooser.Refusal.otherRootKind(.reader)),
                                  (documents, .notAStore), (ordinary, .notALibrary)] {
            let chooser = chooser(launchStore())
            var reported: StoreFolderChooser.Outcome?
            chooser.pickFolder = { picked }
            chooser.report = { reported = $0 }
            XCTAssertEqual(chooser.choose(), .refused(picked, refusal))
            XCTAssertEqual(reported, .refused(picked, refusal), "a refusal is said")
        }
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: documents.path), ["letter.pdf"],
                       "nothing is written into a refused folder")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ordinary.path).isEmpty)
        XCTAssertEqual(try RootMarker.read(at: reader)?.kind, .reader)
    }

    func testDecliningTheConfirmationChangesNothing() async throws {
        let copied = try await makeStore("other.archivenotes", noteTitle: "B")
        let chooser = chooser(launchStore())
        chooser.pickFolder = { copied }
        chooser.confirm = { _, _ in false }
        XCTAssertEqual(chooser.choose(), .cancelled)
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))

        let fresh = scratch.appendingPathComponent("Declined.archivenotes", isDirectory: true)
        chooser.pickNewLibrary = { _ in fresh }
        XCTAssertEqual(chooser.newLibrary(), .cancelled)
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "asked before anything is made")
    }

    /// A new library whose quit is called off is removed again (it is still empty), and an empty library left
    /// from before is used rather than refused as taken.
    func testNewLibraryWhoseQuitIsCalledOffLeavesNothing() throws {
        let fresh = scratch.appendingPathComponent("Called Off.archivenotes")
        let chooser = chooser(launchStore())
        chooser.pickNewLibrary = { _ in fresh }
        chooser.confirm = { _, _ in true }
        chooser.report = { _ in }
        chooser.quit = {}   // terminate returned: the quit was called off
        XCTAssertEqual(chooser.newLibrary(), .quitCancelled(fresh))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "the empty package goes again")

        let leftover = try folder("Left Over.archivenotes")
        var confirmed: StoreFolderChooser.FolderCheck?
        chooser.pickNewLibrary = { _ in leftover }
        chooser.confirm = { _, check in confirmed = check; return true }
        chooser.quit = { self.terminate() }
        XCTAssertEqual(chooser.newLibrary(), .switching(leftover))
        XCTAssertEqual(confirmed, .empty)
        XCTAssertEqual(path(launchStore().root), path(leftover))
    }

    func testPickingTheLibraryInUseIsSaidAndChangesNothing() async throws {
        let library = try await makeStore("current.archivenotes", noteTitle: "C")
        try remember(library)
        let store = launchStore()
        let current = try XCTUnwrap(store.root)
        let bookmark = defaults.data(forKey: "notesStoreRootBookmark")
        let chooser = chooser(store)
        var reported: StoreFolderChooser.Outcome?
        chooser.pickFolder = { current }
        chooser.report = { reported = $0 }
        XCTAssertEqual(chooser.choose(), .alreadyCurrent(current))
        XCTAssertEqual(reported, .alreadyCurrent(current))
        XCTAssertEqual(defaults.data(forKey: "notesStoreRootBookmark"), bookmark)
    }

    // MARK: A chosen library that is gone

    /// Nothing is opened or made in place of a chosen library that no longer opens: new notes would land in
    /// a store the user did not pick.
    func testUnavailableChosenLibraryOpensNothing() async throws {
        let gone = try await makeStore("gone.archivenotes", noteTitle: "C")
        try remember(gone)
        try FileManager.default.removeItem(at: gone)

        let relaunched = launchStore()
        XCTAssertNil(relaunched.root)
        XCTAssertTrue(relaunched.savedRootUnavailable)
        XCTAssertFalse(relaunched.needsLibrary, "the app asks for that library again, not for a new one")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    // MARK: One index per store

    func testEachStoreGetsItsOwnIndexFile() throws {
        let a = try folder("a.archivenotes"), b = try folder("b.archivenotes")
        let guid = UUID()
        func name(_ root: URL?, _ id: UUID? = nil) -> String {
            NotesModel.indexFileName(storeRoot: root, storeGUID: id ?? guid)
        }
        XCTAssertEqual(name(nil), "notes-index-v1-no-library.sqlite3",
                       "a launch with no library never opens the old container store's index")
        let nameA = name(a), nameB = name(b)
        XCTAssertNotEqual(nameA, "notes-index-v1.sqlite3")
        XCTAssertNotEqual(nameA, nameB, "two stores never share an index")
        XCTAssertNotEqual(name(a, UUID()), nameA,
                          "a different store later put at the same path does not inherit the old index")
        XCTAssertEqual(name(a.appendingPathComponent(".")), nameA, "the same store always maps to the same index")
        XCTAssertTrue(nameA.hasPrefix("notes-index-v1-") && nameA.hasSuffix(".sqlite3"))
    }

    // MARK: Review findings (Tier-2)

    /// An empty library inside a Reader archive has no marker of its own; taking it would put notes in the archive.
    func testLibraryInsideAnArchiveIsRefused() throws {
        let archive = try folder("archive")
        _ = try RootMarker.ensure(at: archive, kind: .reader, name: "archive")
        let emptyBox = try folder("archive/Box 12/Notes.archivenotes")
        XCTAssertEqual(StoreFolderChooser.check(emptyBox), .refused(.insideAnotherRoot),
                       "a parent's marker refuses the library")

        let unmarked = try folder("granted-archive")
        let box = try folder("granted-archive/Box 3.archivenotes")
        XCTAssertEqual(StoreFolderChooser.check(box, readerRoots: [unmarked]), .refused(.insideAnotherRoot))
        XCTAssertEqual(StoreFolderChooser.check(unmarked, readerRoots: [unmarked]), .refused(.otherRootKind(.reader)))
        XCTAssertEqual(StoreFolderChooser.check(try folder("granted-archive-2.archivenotes"), readerRoots: [unmarked]),
                       .empty, "a sibling whose name starts the same is not inside it")

        let chooser = chooser(launchStore())
        chooser.pickFolder = { box }
        chooser.report = { _ in }
        XCTAssertEqual(chooser.choose(readerRoots: [unmarked]), .refused(box, .insideAnotherRoot))
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: box.path).isEmpty)

        let store = try folder("store.archivenotes")
        _ = try RootMarker.ensure(at: store, kind: .notes, name: "store")
        XCTAssertEqual(StoreFolderChooser.check(try folder("store.archivenotes/nested.archivenotes")),
                       .refused(.insideAnotherRoot), "nor is a library made inside another library")
    }

    /// A quit called off (a failed save the user would not quit over) drops the pick: it must not switch
    /// libraries at some later quit.
    func testCancelledQuitRemembersNothing() async throws {
        let copied = try await makeStore("other.archivenotes", noteTitle: "B")
        let store = launchStore()
        let chooser = chooser(store)
        var reported: StoreFolderChooser.Outcome?
        chooser.pickFolder = { copied }
        chooser.confirm = { _, _ in true }
        chooser.report = { reported = $0 }
        chooser.quit = {}   // terminate returned: the quit was called off
        chooser.relaunch = { XCTFail("a quit called off must not restart the app, nor a later ordinary quit") }
        XCTAssertEqual(chooser.choose(), .quitCancelled(copied))
        XCTAssertEqual(reported, .quitCancelled(copied), "the user is told the library did not change")
        terminate()   // a later, ordinary quit
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
        XCTAssertNil(launchStore().root)
    }

    /// The next launch checks the remembered library again: one that has since become a Reader archive is
    /// not opened, and nothing is written into it.
    func testRememberedLibraryThatBecameAnArchiveIsNotOpened() throws {
        let picked = try folder("picked-empty.archivenotes")
        try remember(picked)
        _ = try RootMarker.ensure(at: picked, kind: .reader, name: "picked-empty")
        let markerBefore = try Data(contentsOf: picked.appendingPathComponent(RootMarker.filename))

        let relaunched = launchStore()
        XCTAssertNil(relaunched.root)
        XCTAssertTrue(relaunched.savedRootUnavailable)
        XCTAssertEqual(try Data(contentsOf: picked.appendingPathComponent(RootMarker.filename)), markerBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: picked.path), [RootMarker.filename])
    }

    /// Likewise a remembered library that turns out to sit inside an archive granted to Notes since.
    func testRememberedLibraryInsideAGrantedArchiveIsNotOpened() throws {
        let archive = try folder("archive-granted-later")
        let picked = try folder("archive-granted-later/Box 1.archivenotes")
        try remember(picked)
        let relaunched = launchStore(readerRoots: [URL(fileURLWithPath: archive.path.uppercased())])
        XCTAssertNil(relaunched.root, "matched however the archive's path is capitalised")
        XCTAssertTrue(relaunched.savedRootUnavailable)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: picked.path).isEmpty,
                      "no marker is written into it")
    }
}
