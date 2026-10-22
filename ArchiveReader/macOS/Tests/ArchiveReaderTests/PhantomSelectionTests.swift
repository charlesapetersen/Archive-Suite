import XCTest
@testable import ArchiveReader

/// `W40.fix-reader-phantom-selection`: the selection is never wider than the list. A row the filter
/// hides leaves the selection, the "N selected" count is what the actions act on, and no
/// selection-wide action writes a tag to a file the list does not show. Before the fix the selection
/// resolved against the whole library, so with every row filtered away the status bar still said
/// "2 selected" and Mark Read tagged both files unseen. Scratch `mktemp` fixtures only.
@MainActor
final class PhantomSelectionTests: XCTestCase {

    private var savedLedgerURL: URL!
    private var ledgerDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        // `mark` writes an audit line; keep it out of the real ledger.
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PhantomSelectionTests-\(UUID().uuidString)", isDirectory: true)
        AuditLedger.shared.fileURL = ledgerDir.appendingPathComponent("audit-ledger.jsonl")
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerDir)
        try await super.tearDown()
    }

    private func makeRoot(files names: [String]) throws -> (root: URL, files: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PhantomSelectionTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let files = try names.map { name -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(["Unread", "Smith"], forKey: .tagNamesKey)
            return url
        }
        return (root, files)
    }

    /// Read from disk through a fresh `URL`, so a cached resource value cannot answer for the file.
    private func tagsOnDisk(_ url: URL) throws -> Set<String> {
        Set(try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [])
    }

    private func selectAll(in model: NavigationModel) {
        model.selection = Set(model.displayed.map(\.id))
    }

    func testAFilterThatHidesEverySelectedRowEmptiesTheSelectionAndMarkWritesNothing() throws {
        let fixture = try makeRoot(files: ["alpha.pdf", "beta.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        selectAll(in: model)
        XCTAssertEqual(model.selectedFiles.count, 2, "precondition: both rows are selected")

        model.filter.searchText = "matches-no-file"
        model.recompute()
        XCTAssertTrue(model.displayed.isEmpty, "precondition: the filter hides every row")
        XCTAssertTrue(model.selection.isEmpty, "a hidden row leaves the selection")
        XCTAssertTrue(model.selectedFiles.isEmpty, "so the status bar counts nothing")

        model.mark(.read)
        for url in fixture.files {
            XCTAssertEqual(try tagsOnDisk(url), ["Unread", "Smith"], "\(url.lastPathComponent) was not visible, so it is not touched")
        }

        model.filter.searchText = ""
        model.recompute()
        XCTAssertEqual(model.displayed.count, 2)
        XCTAssertTrue(model.selection.isEmpty, "clearing the filter does not bring back a selection nobody could see")
    }

    func testAFilterThatHidesPartOfTheSelectionLeavesOnlyTheVisibleRowAsTheTarget() throws {
        let fixture = try makeRoot(files: ["alpha.pdf", "beta.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        selectAll(in: model)

        model.filter.searchText = "alpha"
        model.recompute()
        XCTAssertEqual(model.displayed.map(\.url.lastPathComponent), ["alpha.pdf"], "precondition")
        XCTAssertEqual(model.selectedFiles.map(\.url.lastPathComponent), ["alpha.pdf"])
        XCTAssertEqual(model.selection.count, 1, "the count and the target agree")

        model.mark(.read)
        XCTAssertEqual(try tagsOnDisk(fixture.files[0]), ["Read", "Smith"], "the visible row is marked")
        XCTAssertEqual(try tagsOnDisk(fixture.files[1]), ["Unread", "Smith"], "the hidden row is not")
    }

    /// An edit in the open tag editor can move its targets out of the filter ("Remove X" under a tag-X
    /// filter). The sheet keeps acting on them until it closes; then they leave the selection.
    func testTheOpenTagEditorKeepsItsTargetsUntilItCloses() throws {
        let fixture = try makeRoot(files: ["alpha.pdf", "beta.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        model.filter.searchText = "alpha"
        model.recompute()
        selectAll(in: model)
        model.showingEditor = true

        model.filter.searchText = "matches-no-file"   // stands in for an edit that unfilters the rows
        model.recompute()
        XCTAssertEqual(model.selectedFiles.map(\.url.lastPathComponent), ["alpha.pdf"],
                       "the open editor still has the file it was opened on")

        model.showingEditor = false
        XCTAssertTrue(model.selection.isEmpty, "closed, the hidden row leaves the selection")
        XCTAssertTrue(model.selectedFiles.isEmpty)
    }

    /// Opening the editor never widens the selection to a row that was already hidden.
    func testOpeningTheTagEditorDoesNotPickUpAHiddenID() throws {
        let fixture = try makeRoot(files: ["alpha.pdf", "beta.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        let beta = try XCTUnwrap(model.displayed.first { $0.url.lastPathComponent == "beta.pdf" })
        model.filter.searchText = "alpha"
        model.recompute()
        model.selection = [beta.id]
        model.showingEditor = true
        XCTAssertTrue(model.selectedFiles.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }

    /// A selection set from outside the table (a resumed session, a link reveal) can name a row the
    /// list does not show; until the next recompute prunes it, the actions still see only visible rows.
    func testAHiddenIDSetDirectlyIsNeverAnActionTarget() throws {
        let fixture = try makeRoot(files: ["alpha.pdf", "beta.pdf"])
        let model = fixtureNavigationModel(pinnedTo: fixture.root)
        let beta = try XCTUnwrap(model.displayed.first { $0.url.lastPathComponent == "beta.pdf" })
        model.filter.searchText = "alpha"
        model.recompute()

        model.selection = [beta.id]
        XCTAssertTrue(model.selectedFiles.isEmpty, "a row the list does not show is not a target")
        model.mark(.read)
        XCTAssertEqual(try tagsOnDisk(fixture.files[1]), ["Unread", "Smith"])
    }
}
