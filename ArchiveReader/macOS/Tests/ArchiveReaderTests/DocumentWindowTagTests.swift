import XCTest
@testable import ArchiveReader

/// `W40.fix-reader-menus-follow-window`: with a document window in front, the Tags menu acts on the file that
/// window shows, through the navigation model's own `TagWriter` actions and undo ledger, never on the list's
/// selection. Scratch `mktemp` fixtures only; the audit ledger is redirected away from the real one.
/// (Toggle Flag is not exercised here: `FlagStore` writes the host app's standard defaults.)
@MainActor
final class DocumentWindowTagTests: XCTestCase {

    private var savedLedgerURL: URL!
    private var ledgerDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DocumentWindowTagTests-\(UUID().uuidString)", isDirectory: true)
        AuditLedger.shared.fileURL = ledgerDir.appendingPathComponent("audit-ledger.jsonl")
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerDir)
        try await super.tearDown()
    }

    private func makeRoot(_ files: [(name: String, tags: [String])]) throws -> (root: URL, files: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DocumentWindowTagTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let urls = try files.map { file -> URL in
            let url = box.appendingPathComponent(file.name)
            try Data("scratch PDF \(file.name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(file.tags, forKey: .tagNamesKey)
            return url
        }
        return (root, urls)
    }

    private func tagsOnDisk(_ url: URL) throws -> Set<String> {
        Set(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    /// The model's paths are the library's own spelling of each file, as the list hands to a document window.
    private func libraryPath(_ model: NavigationModel, _ url: URL) throws -> String {
        try XCTUnwrap(model.library.files.first { $0.url.lastPathComponent == url.lastPathComponent }?.path)
    }

    private func documentWindow(_ model: NavigationModel, paths: [String]) -> DocumentTagActions {
        let router = DeepLinkRouter()
        router.nav = model
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: paths))
        return DocumentTagActions(router: router, viewer: viewer)
    }

    func testMarkReadActsOnTheOpenFileNotTheListSelection() throws {
        let fixture = try makeRoot([("alpha.pdf", ["Unread", "Smith"]), ("beta.pdf", ["Unread", "Smith"])])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        model.selection = [try XCTUnwrap(model.displayed.first { $0.url.lastPathComponent == "alpha.pdf" }).id]
        let doc = documentWindow(model, paths: [try libraryPath(model, fixture.files[1])])
        XCTAssertTrue(doc.canTag)

        doc.mark(.read)
        XCTAssertEqual(try tagsOnDisk(fixture.files[1]), ["Read", "Smith"], "the open file is marked")
        XCTAssertEqual(try tagsOnDisk(fixture.files[0]), ["Unread", "Smith"], "the list's selection is not")
        XCTAssertEqual(doc.viewer.tagStatus, "Marked 1 Read.")

        // The same undo ledger as the list: one step, and undoing it from the document window restores the file.
        XCTAssertEqual(model.undoDepth, 1)
        XCTAssertTrue(doc.canUndo)
        doc.undo()
        XCTAssertEqual(try tagsOnDisk(fixture.files[1]), ["Unread", "Smith"])
        XCTAssertEqual(model.undoDepth, 0)
        XCTAssertEqual(doc.viewer.tagStatus, "Undid 1 change. (beta.pdf)", "the status names the file it reverted")
    }

    func testUndoIsOffWhileTheFindFieldOrTheTagEditorHasTheKeyboard() throws {
        let fixture = try makeRoot([("alpha.pdf", ["Unread"])])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        let doc = documentWindow(model, paths: [try libraryPath(model, fixture.files[0])])
        doc.mark(.read)
        XCTAssertTrue(doc.canUndo)

        doc.viewer.findFieldFocused = true
        XCTAssertFalse(doc.canUndo, "⌘Z in the find field undoes the typing, not a tag change")
        doc.undo()
        XCTAssertEqual(try tagsOnDisk(fixture.files[0]), ["Read"], "so nothing was undone")

        doc.viewer.findFieldFocused = false
        doc.editTags()
        XCTAssertTrue(doc.viewer.showingTagEditor)
        XCTAssertEqual(doc.viewer.tagEditorPath, doc.viewer.currentFilePath, "the sheet is pinned to the open file")
        XCTAssertFalse(doc.canUndo, "nor in the tag editor's fields")
    }

    func testTheTagEditorsEditGoesToTheOpenFileOnly() throws {
        let fixture = try makeRoot([("alpha.pdf", ["Unread", "Smith"]), ("beta.pdf", ["Unread", "Smith"])])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        model.selection = Set(model.displayed.map(\.id))
        model.applyEdit(.addSubject("Jones"), paths: [try libraryPath(model, fixture.files[0])])
        XCTAssertEqual(try tagsOnDisk(fixture.files[0]), ["Unread", "Smith", "Jones"])
        XCTAssertEqual(try tagsOnDisk(fixture.files[1]), ["Unread", "Smith"], "the rest of the list's selection is untouched")
        XCTAssertEqual(model.undoDepth, 1, "one undo step, on the shared ledger")
    }

    func testMarkReadAndNextUnreadMovesTheWindowToItsNextUnreadFile() throws {
        let fixture = try makeRoot([("a.pdf", ["Unread"]), ("b.pdf", ["Read"]), ("c.pdf", ["Unread"])])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        let doc = documentWindow(model, paths: try fixture.files.map { try libraryPath(model, $0) })
        XCTAssertEqual(doc.viewer.index, 0)

        doc.markReadAndNextUnread()
        XCTAssertEqual(try tagsOnDisk(fixture.files[0]), ["Read"])
        XCTAssertEqual(doc.viewer.index, 2, "b is already Read, so the window skips to c")
        XCTAssertEqual(doc.viewer.tagStatus, "Marked 1 Read.", "the status survives the move")

        doc.markReadAndNextUnread()
        XCTAssertEqual(try tagsOnDisk(fixture.files[2]), ["Read"])
        XCTAssertEqual(doc.viewer.index, 2, "nothing unread is left, so the window stays")
        XCTAssertEqual(doc.viewer.tagStatus, "Marked 1 Read. No further unread documents in this window.")
    }

    func testAFileOutsideTheLibraryIsNeverWritten() throws {
        let fixture = try makeRoot([("alpha.pdf", ["Unread"])])
        let outside = try makeRoot([("stray.pdf", ["Unread"])])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        let doc = documentWindow(model, paths: [outside.files[0].path])

        doc.mark(.read)
        XCTAssertEqual(try tagsOnDisk(outside.files[0]), ["Unread"], "a file the library does not hold is not tagged")
        XCTAssertEqual(doc.viewer.tagStatus,
                       "This file is not in the archive's library, so its tags cannot be changed here.")
        XCTAssertEqual(model.undoDepth, 0)

        // A refused mark keeps the file in front rather than moving on as if it had been read.
        let run = documentWindow(model, paths: [outside.files[0].path, try libraryPath(model, fixture.files[0])])
        run.markReadAndNextUnread()
        XCTAssertEqual(run.viewer.index, 0)
        XCTAssertEqual(try tagsOnDisk(fixture.files[0]), ["Unread"])
    }

    func testNoNavigationWindowMeansNoTagging() throws {
        let viewer = DocumentViewerModel(persists: false, thumbnailer: nil)
        viewer.load(DocumentSelection(filePaths: ["/nonexistent/a.pdf"]))
        let doc = DocumentTagActions(router: DeepLinkRouter(), viewer: viewer)
        XCTAssertFalse(doc.canTag, "a closed navigation window disables the menu")
        XCTAssertFalse(doc.canUndo)
        doc.mark(.read)
        XCTAssertNil(viewer.tagStatus)
    }
}
