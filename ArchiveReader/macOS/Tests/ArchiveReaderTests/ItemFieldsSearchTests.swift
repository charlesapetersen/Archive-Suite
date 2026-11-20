import XCTest
import AppKit
import SQLite3
import ArchiveCore
@testable import ArchiveReader

/// W49.reader-item-fields-search: a corrected item field reaches search and the Item fields column. Scratch folders
/// and a scratch content index only.
@MainActor
final class ItemFieldsSearchTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ItemFieldsSearch-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var database: URL { root.appendingPathComponent("content.sqlite3") }

    private func row(_ path: String, body: String, header: [CheckableField: String] = [:],
                     user: [CheckableField: String] = [:]) -> IndexRow {
        IndexRow(path: path, mtime: 1, name: (path as NSString).lastPathComponent, classification: nil, body: body,
                 pageCount: 2, hasText: true, readable: true, headerFields: header, userFields: user)
    }

    func testTheOCRSearchFindsACorrectionAndForgetsItWhenRemoved() async throws {
        let index = ContentIndex(url: database)
        try await index.open()
        try await index.upsertBatch([
            row("/a.pdf", body: "Title: Harbor Reprot\nThe harbour.", header: [.title: "Harbor Reprot"],
                user: [.title: "Harbour Report of 1958"]),
            row("/b.pdf", body: "Nothing here."),
        ])
        let corrected = await index.search("1958")
        XCTAssertEqual(corrected, ["/a.pdf"], "the corrected title is searched with the text")
        let original = await index.search("Reprot")
        XCTAssertEqual(original, ["/a.pdf"], "page 2's own line is still in the text")
        let fields = await index.itemFields(for: ["/a.pdf", "/b.pdf"])
        XCTAssertEqual(fields["/a.pdf"]?.shown.title, "Harbour Report of 1958")
        XCTAssertEqual(fields["/a.pdf"]?.header.title, "Harbor Reprot")
        XCTAssertNil(fields["/b.pdf"], "a file with no item fields has no entry")

        try await index.setUserFields(["/a.pdf": [:], "/b.pdf": [.byline: "Mary Jones"], "/c.pdf": [.title: "X"]])
        let gone = await index.search("1958")
        XCTAssertEqual(gone, [], "a removed correction is no longer found")
        let added = await index.search("Jones")
        XCTAssertEqual(added, ["/b.pdf"], "Add Item Field is found too")
        let stored = await index.storedUserFields()
        XCTAssertEqual(stored, ["/b.pdf": [.byline: "Mary Jones"]], "a path not indexed is not added")
        let after = await index.itemFields(for: ["/a.pdf"])
        XCTAssertEqual(after["/a.pdf"]?.shown.title, "Harbor Reprot", "page 2's value shows again")
        await index.close()
    }

    func testAnAdvancedSearchOCRTextRuleReachesCorrections() async throws {
        var rule = SearchRule(field: .ocrText)
        rule.op = .allWords
        rule.text = "Harbour"
        XCTAssertEqual(rule.ftsExpression, #"{body fields} : ("Harbour")"#)
        let index = ContentIndex(url: database)
        try await index.open()
        try await index.upsertBatch([row("/a.pdf", body: "Text.", user: [.title: "Harbour Report"])])
        let hits = await index.search(expression: try XCTUnwrap(rule.ftsExpression))
        XCTAssertEqual(hits, ["/a.pdf"])
        await index.close()
    }

    /// An index written before the item-field columns is dropped and rebuilt by the next pass: it is a cache.
    func testAnOlderIndexIsRebuilt() async throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        for sql in ["CREATE TABLE files(path TEXT PRIMARY KEY, mtime REAL, inode INTEGER, size INTEGER, page_count INTEGER, has_text INTEGER, readable INTEGER);",
                    "CREATE VIRTUAL TABLE fts USING fts5(body, classification, name, path UNINDEXED);",
                    "INSERT INTO files(path, mtime) VALUES('/old.pdf', 1);",
                    "INSERT INTO fts(rowid, body, classification, name, path) VALUES(1, 'old text', '', 'old.pdf', '/old.pdf');"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)
        let index = ContentIndex(url: database)
        try await index.open()
        let stamps = await index.existingStamps()
        XCTAssertTrue(stamps.isEmpty, "the old rows are gone, so every file is extracted again")
        try await index.upsertBatch([row("/a.pdf", body: "Text.", user: [.title: "Harbour"])])
        let hits = await index.search("Harbour")
        XCTAssertEqual(hits, ["/a.pdf"])
        await index.close()
    }

    private func file(_ url: URL, modified: TimeInterval = 20) -> ArchiveFile {
        ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                    tags: DocumentTags.parse(raw: ["Unread"], labelNumber: nil),
                    contentModified: Date(timeIntervalSince1970: modified))
    }

    private func waitForPasses(_ driver: ContentIndexer, _ n: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, driver.completedPassesForTesting < n { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(driver.completedPassesForTesting, n)
    }

    private func setTitle(_ value: String?, _ name: String, in dir: URL) throws {
        _ = try NavigationModel.editItemFields(at: dir) { f in
            var f = f
            f.set(.title, to: value, for: name)
            return f
        }
    }

    /// A pass reads the corrections beside the files: a new file takes them with its text, and a file whose text is
    /// current takes a later one without being extracted again; `syncUserFields` does the same after an edit.
    func testAPassAndAnEditKeepTheIndexOnTheCorrections() async throws {
        let dir = root.appendingPathComponent("Box 3", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        for u in [a, b] { try Data("scratch fixture".utf8).write(to: u) }
        try setTitle("Harbour Report", "a.pdf", in: dir)
        let files = [file(a), file(b)]
        let probe = ExtractionCounter()
        let driver = ContentIndexer(url: database, extractPDFForTesting: { _ in
            probe.bump()
            return ExtractedContent(fullBody: "plain text", strippedBody: "plain text", classification: nil,
                                    pageCount: 2)
        })
        driver.startIndexing(files)
        try await waitForPasses(driver, 1)
        var hits = await driver.search("Harbour")
        XCTAssertEqual(hits, [a.path], "a new file takes its correction with its text")

        try setTitle("Lighthouse Survey", "b.pdf", in: dir)
        try setTitle(nil, "a.pdf", in: dir)
        driver.startIndexing(files)
        try await waitForPasses(driver, 2)
        XCTAssertEqual(probe.count, 2, "neither file was extracted again")
        hits = await driver.search("Lighthouse")
        XCTAssertEqual(hits, [b.path])
        hits = await driver.search("Harbour")
        XCTAssertEqual(hits, [], "a removed correction is dropped by the next pass")

        try setTitle("Pier Ledger", "a.pdf", in: dir)
        let changed = await driver.syncUserFields(files)
        XCTAssertTrue(changed)
        let again = await driver.syncUserFields(files)
        XCTAssertFalse(again, "nothing changed since")
        hits = await driver.search("Ledger")
        XCTAssertEqual(hits, [a.path])
        let shown = await driver.itemFields(for: [a.path, b.path])
        XCTAssertEqual(shown[a.path]?.columnText, "Pier Ledger")
        XCTAssertEqual(shown[b.path]?.columnText, "Lighthouse Survey")
        await driver.closeForTesting()
    }

    /// The model end to end: a correction written beside a listed file reaches the Item fields column once the
    /// model asks the index to read the corrections again, as it does after each edit, undo or redo.
    func testACorrectionReachesTheColumnAfterTheEdit() async throws {
        let fileURL = root.appendingPathComponent("fixture.pdf")
        try Data("scratch fixture".utf8).write(to: fileURL)
        try (fileURL as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        let indexer = ContentIndexer(url: database, extractPDFForTesting: { _ in
            ExtractedContent(fullBody: "body", strippedBody: "body", classification: nil, pageCount: 2)
        })
        do {
            let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: root), indexer: indexer)
            let path = try XCTUnwrap(model.library.files.first?.url.path, "precondition: one nav row")
            try await waitForPasses(indexer, 1)
            XCTAssertFalse(model.isColumnAvailable(AppKitTableView.itemFieldsColumnID), "no file has an item field yet")

            try setTitle("Harbour Report", "fixture.pdf", in: fileURL.deletingLastPathComponent().resolvingSymlinksInPath())
            model.syncItemFieldsToIndex()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, model.itemFields(for: path) == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(model.itemFields(for: path)?.columnText, "Harbour Report")
            XCTAssertTrue(model.isColumnAvailable(AppKitTableView.itemFieldsColumnID))
            XCTAssertFalse(model.effectiveHiddenColumns.contains(AppKitTableView.itemFieldsColumnID))
            let hits = await indexer.search("Harbour")
            XCTAssertEqual(hits, [path])
        }
        await indexer.closeForTesting()
    }

    func testTheItemFieldsCellRendersToPixels() throws {
        let field = NSTextField(labelWithString: "")
        AppKitTableView.Coordinator.configureItemFieldsTextField(
            field, fields: IndexedItemFields(user: [.title: "Harbour Report", .byline: "Mary Jones"]))
        XCTAssertEqual(field.stringValue, "Harbour Report · Mary Jones")
        let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: field, size: CGSize(width: 220, height: 28)))
        writeRenderArtifact(data, named: "w49-item-fields-column.png")
        _ = try XCTUnwrap(assertRendersNonBlank(try XCTUnwrap(RenderProbe.cgImage(fromPNG: data)), "Item fields cell"))
    }

    func testTheColumnShowsWhatTheInspectorShows() throws {
        let header = PDFHeaderParser.parse("Extracted text.\nscan_002.jpg\nAnthropic \u{00B7} Claude \u{00B7} 6 October 2026\n"
            + "Kind: typewritten\nDocument kind: letter\nTitle: Re: the budjet\nRecipient place: Boston, MA\nDear Sir,").header
        let fields = IndexedItemFields(header: IndexedItemFields.header(of: [nil, header]),
                                       user: [.title: "Re: the budget", .recipientPlace: ""])
        XCTAssertEqual(fields.columnText, "Re: the budget · letter", "title first; \"none\" hides page 2's value")
        XCTAssertEqual(fields.columnToolTip, "Title: Re: the budget (your value)\nKind: letter")
        XCTAssertNil(IndexedItemFields(user: [.title: ""]).columnText)
        XCTAssertEqual(IndexedItemFields.decode(IndexedItemFields.encode([.byline: "A; B", .title: ""])),
                       [.byline: "A; B", .title: ""])
        XCTAssertEqual(IndexedItemFields.searchText([.byline: "A; B", .title: ""]), "A; B")
    }
}

private final class ExtractionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
