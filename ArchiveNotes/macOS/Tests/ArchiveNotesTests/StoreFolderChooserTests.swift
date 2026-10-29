import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveNotes

/// W40.fix-notes-choose-store — File ▸ Choose Store Folder…: which folders may become the store, that the
/// pick survives a relaunch and the notes are then read from it, and that one store's index is never
/// another's. Every store and bookmark here is scratch: a temp folder and a throwaway defaults suite,
/// never `notesStoreRootBookmark` in the app's own defaults or its real default store.
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

    /// A store as another computer leaves it: marker, `items/` and one note.
    private func makeStore(_ name: String, noteTitle: String) async throws -> URL {
        let root = try folder(name)
        _ = try RootMarker.ensure(at: root, kind: .notes, name: name)
        let item = Item(id: UUID(), kind: .note, title: noteTitle, authors: [], date: nil,
                        datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                        roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                        unknownFrontMatter: [], trailingBodyRaw: nil)
        _ = try await NoteStore(root: root).create(item)
        return root
    }

    private func launchStore() -> RootFolderStore {
        RootFolderStore(defaults: defaults, defaultRoot: scratch.appendingPathComponent("default-store"),
                        notificationCenter: center)
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

    private func path(_ url: URL?) -> String? { url?.resolvingSymlinksInPath().standardizedFileURL.path }

    // MARK: Which folders qualify

    func testCheckClassifiesFolders() async throws {
        let marked = try await makeStore("marked", noteTitle: "A")
        XCTAssertEqual(StoreFolderChooser.check(marked), .store)

        let legacy = try folder("legacy")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("items"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(StoreFolderChooser.check(legacy), .store, "an items/ folder without a marker is a store")

        let empty = try folder("empty")
        try Data().write(to: empty.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(StoreFolderChooser.check(empty), .empty, "hidden files alone leave a folder empty")

        let reader = try folder("reader")
        _ = try RootMarker.ensure(at: reader, kind: .reader, name: "reader")
        XCTAssertEqual(StoreFolderChooser.check(reader), .refused(.otherRootKind(.reader)))

        let documents = try folder("documents")
        try Data("x".utf8).write(to: documents.appendingPathComponent("letter.pdf"))
        XCTAssertEqual(StoreFolderChooser.check(documents), .refused(.notAStore))

        let broken = try folder("broken")
        try Data("{not json".utf8).write(to: broken.appendingPathComponent(RootMarker.filename))
        XCTAssertEqual(StoreFolderChooser.check(broken), .refused(.markerUnreadable))
    }

    // MARK: The pick, then a relaunch

    /// The test the item asked for: pick a folder holding a store, relaunch, and the notes read from it.
    func testPickedStoreIsOpenedAtNextLaunchAndItsNotesRead() async throws {
        let copied = try await makeStore("copied-from-another-mac", noteTitle: "Adopted note")
        let markerBefore = try Data(contentsOf: copied.appendingPathComponent(RootMarker.filename))

        let first = launchStore()
        XCTAssertEqual(path(first.root), path(scratch.appendingPathComponent("default-store")),
                       "with nothing chosen the default store opens")

        let chooser = StoreFolderChooser(rootStore: first)
        var quits = 0, confirmed: StoreFolderChooser.FolderCheck?
        chooser.pickFolder = { copied }
        chooser.confirm = { _, check in confirmed = check; return true }
        chooser.report = { XCTFail("a successful pick shows no alert, got \($0)") }
        chooser.quit = { quits += 1; self.terminate() }

        XCTAssertEqual(chooser.choose(), .switching(copied))
        XCTAssertEqual(confirmed, .store)
        XCTAssertEqual(quits, 1, "the app quits so the next launch opens the new store")
        XCTAssertEqual(path(first.root), path(scratch.appendingPathComponent("default-store")),
                       "the running app keeps its store until it quits")

        // Relaunch.
        let second = launchStore()
        XCTAssertEqual(path(second.root), path(copied), "the pick is remembered across a relaunch")
        XCTAssertFalse(second.savedRootUnavailable)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent(RootMarker.filename)), markerBefore,
                       "the store is adopted where it lies: its marker is not rewritten")
        let notes = await NoteStore(root: try XCTUnwrap(second.root)).allItemSummaries()
        XCTAssertEqual(notes.map(\.title), ["Adopted note"])
    }

    func testEmptyFolderBecomesANewStoreAtNextLaunch() throws {
        let empty = try folder("new-store")
        let chooser = StoreFolderChooser(rootStore: launchStore())
        var confirmed: StoreFolderChooser.FolderCheck?
        chooser.pickFolder = { empty }
        chooser.confirm = { _, check in confirmed = check; return true }
        chooser.quit = { self.terminate() }
        XCTAssertEqual(chooser.choose(), .switching(empty))
        XCTAssertEqual(confirmed, .empty)

        let relaunched = launchStore()
        XCTAssertEqual(path(relaunched.root), path(empty))
        XCTAssertEqual(relaunched.marker?.kind, .notes, "the next launch marks the new store")
    }

    // MARK: Refusals and cancels write nothing

    func testRefusedFolderIsNeverRememberedOrMarked() throws {
        let reader = try folder("reader")
        _ = try RootMarker.ensure(at: reader, kind: .reader, name: "reader")
        let documents = try folder("documents")
        try Data("x".utf8).write(to: documents.appendingPathComponent("letter.pdf"))

        for (picked, refusal) in [(reader, StoreFolderChooser.Refusal.otherRootKind(.reader)),
                                  (documents, .notAStore)] {
            let chooser = StoreFolderChooser(rootStore: launchStore())
            var reported: StoreFolderChooser.Outcome?
            chooser.pickFolder = { picked }
            chooser.confirm = { _, _ in XCTFail("a refused folder is not offered"); return true }
            chooser.report = { reported = $0 }
            chooser.quit = { XCTFail("a refused folder must not quit the app") }
            XCTAssertEqual(chooser.choose(), .refused(picked, refusal))
            XCTAssertEqual(reported, .refused(picked, refusal), "a refusal is said")
        }
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: documents.path), ["letter.pdf"],
                       "nothing is written into a refused folder")
        XCTAssertEqual(try RootMarker.read(at: reader)?.kind, .reader)
    }

    func testDecliningTheConfirmationChangesNothing() async throws {
        let copied = try await makeStore("other", noteTitle: "B")
        let chooser = StoreFolderChooser(rootStore: launchStore())
        chooser.pickFolder = { copied }
        chooser.confirm = { _, _ in false }
        chooser.report = { XCTFail("a cancel says nothing, got \($0)") }
        chooser.quit = { XCTFail("a cancel must not quit") }
        XCTAssertEqual(chooser.choose(), .cancelled)
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
    }

    func testPickingTheOpenStoreIsSaidAndChangesNothing() throws {
        let store = launchStore()
        let current = try XCTUnwrap(store.root)
        let chooser = StoreFolderChooser(rootStore: store)
        var reported: StoreFolderChooser.Outcome?
        chooser.pickFolder = { current }
        chooser.confirm = { _, _ in XCTFail("nothing to confirm"); return true }
        chooser.report = { reported = $0 }
        chooser.quit = { XCTFail("must not quit") }
        XCTAssertEqual(chooser.choose(), .alreadyCurrent(current))
        XCTAssertEqual(reported, .alreadyCurrent(current))
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
    }

    // MARK: A chosen store that is gone

    /// The default store is not opened in place of a chosen one that no longer opens: new notes would
    /// land in a store the user did not pick.
    func testUnavailableChosenStoreDoesNotFallBackToTheDefault() async throws {
        let gone = try await makeStore("gone", noteTitle: "C")
        try remember(gone)
        try FileManager.default.removeItem(at: gone)

        let unusedDefault = scratch.appendingPathComponent("never-created-default", isDirectory: true)
        let relaunched = RootFolderStore(defaults: defaults, defaultRoot: unusedDefault)
        XCTAssertNil(relaunched.root)
        XCTAssertTrue(relaunched.savedRootUnavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unusedDefault.path),
                       "the default store is not created in its place")
    }

    // MARK: One index per store

    func testEachStoreGetsItsOwnIndexFile() throws {
        let defaultRoot = scratch.appendingPathComponent("default-store", isDirectory: true)
        let a = try folder("a"), b = try folder("b")
        let guid = UUID()
        func name(_ root: URL?, _ id: UUID? = nil) -> String {
            NotesModel.indexFileName(storeRoot: root, storeGUID: id ?? guid, defaultRoot: defaultRoot)
        }
        XCTAssertEqual(name(defaultRoot), "notes-index-v1.sqlite3", "the default store keeps its index")
        XCTAssertEqual(name(nil), "notes-index-v1.sqlite3")
        let nameA = name(a), nameB = name(b)
        XCTAssertNotEqual(nameA, "notes-index-v1.sqlite3")
        XCTAssertNotEqual(nameA, nameB, "two stores never share an index")
        XCTAssertNotEqual(name(a, UUID()), nameA,
                          "a different store later put at the same path does not inherit the old index")
        XCTAssertEqual(name(a.appendingPathComponent(".")), nameA, "the same store always maps to the same index")
        XCTAssertTrue(nameA.hasPrefix("notes-index-v1-") && nameA.hasSuffix(".sqlite3"))
    }
    // MARK: Review findings (Tier-2)

    /// An empty folder inside a Reader archive has no marker of its own; taking it would put notes in the archive.
    func testFolderInsideAnArchiveIsRefused() throws {
        let archive = try folder("archive")
        _ = try RootMarker.ensure(at: archive, kind: .reader, name: "archive")
        let emptyBox = try folder("archive/Box 12")
        XCTAssertEqual(StoreFolderChooser.check(emptyBox), .refused(.insideAnotherRoot),
                       "a parent's marker refuses the folder")

        // The sandbox usually cannot read the parents, so a granted archive folder refuses too.
        let unmarked = try folder("granted-archive")
        let box = try folder("granted-archive/Box 3")
        XCTAssertEqual(StoreFolderChooser.check(box, readerRoots: [unmarked]), .refused(.insideAnotherRoot))
        XCTAssertEqual(StoreFolderChooser.check(unmarked, readerRoots: [unmarked]), .refused(.otherRootKind(.reader)))
        XCTAssertEqual(StoreFolderChooser.check(try folder("granted-archive-2"), readerRoots: [unmarked]), .empty,
                       "a sibling whose name starts the same is not inside it")

        let chooser = StoreFolderChooser(rootStore: launchStore())
        chooser.pickFolder = { box }
        chooser.confirm = { _, _ in XCTFail("refused before asking"); return true }
        chooser.report = { _ in }
        chooser.quit = { XCTFail("must not quit") }
        XCTAssertEqual(chooser.choose(readerRoots: [unmarked]), .refused(box, .insideAnotherRoot))
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: box.path).isEmpty)

        let store = try folder("store")
        _ = try RootMarker.ensure(at: store, kind: .notes, name: "store")
        XCTAssertEqual(StoreFolderChooser.check(try folder("store/nested")), .refused(.insideAnotherRoot),
                       "nor is a store made inside another store")
    }

    func testLinkedItemsFolderIsNotAStore() throws {
        let elsewhere = try folder("elsewhere")
        let linked = try folder("linked")
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("items"),
                                                   withDestinationURL: elsewhere)
        XCTAssertEqual(StoreFolderChooser.check(linked), .refused(.notAStore))
    }

    /// A quit called off (a failed save the user would not quit over) drops the pick: it must not switch
    /// stores at some later quit.
    func testCancelledQuitRemembersNothing() async throws {
        let copied = try await makeStore("other", noteTitle: "B")
        let store = launchStore()
        let chooser = StoreFolderChooser(rootStore: store)
        var reported: StoreFolderChooser.Outcome?
        chooser.pickFolder = { copied }
        chooser.confirm = { _, _ in true }
        chooser.report = { reported = $0 }
        chooser.quit = {}   // terminate returned: the quit was called off
        XCTAssertEqual(chooser.choose(), .quitCancelled(copied))
        XCTAssertEqual(reported, .quitCancelled(copied), "the user is told the store did not change")
        terminate()   // a later, ordinary quit
        XCTAssertNil(defaults.data(forKey: "notesStoreRootBookmark"))
        XCTAssertEqual(path(launchStore().root), path(scratch.appendingPathComponent("default-store")))
    }

    /// The next launch checks the remembered folder again: one that has since become a Reader archive is
    /// not opened, and nothing is written into it.
    func testRememberedFolderThatBecameAnArchiveIsNotOpened() throws {
        let picked = try folder("picked-empty")
        try remember(picked)
        _ = try RootMarker.ensure(at: picked, kind: .reader, name: "picked-empty")
        let markerBefore = try Data(contentsOf: picked.appendingPathComponent(RootMarker.filename))

        let relaunched = RootFolderStore(defaults: defaults,
                                         defaultRoot: scratch.appendingPathComponent("unused-default"),
                                         notificationCenter: center)
        XCTAssertNil(relaunched.root)
        XCTAssertTrue(relaunched.savedRootUnavailable)
        XCTAssertEqual(try Data(contentsOf: picked.appendingPathComponent(RootMarker.filename)), markerBefore)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: picked.path), [RootMarker.filename])
    }

    /// Likewise a remembered store that turns out to sit inside an archive granted to Notes since.
    func testRememberedFolderInsideAGrantedArchiveIsNotOpened() throws {
        let archive = try folder("archive-granted-later")
        let picked = try folder("archive-granted-later/Box 1")
        try remember(picked)
        let relaunched = RootFolderStore(defaults: defaults,
                                         defaultRoot: scratch.appendingPathComponent("unused-default"),
                                         notificationCenter: center,
                                         readerRoots: [URL(fileURLWithPath: archive.path.uppercased())])
        XCTAssertNil(relaunched.root, "matched however the archive's path is capitalised")
        XCTAssertTrue(relaunched.savedRootUnavailable)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: picked.path).isEmpty,
                      "no marker is written into it")
    }
}
