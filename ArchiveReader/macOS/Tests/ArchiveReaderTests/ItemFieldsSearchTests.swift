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

// MARK: - W49.reader-sidecar-names-index: the JSON sidecar's names reach search and the column

@MainActor
final class SidecarNamesIndexTests: XCTestCase {
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("SidecarNamesIndex-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var database: URL { root.appendingPathComponent("content.sqlite3") }

    /// The sidecar's names are searched with the text; the user's correction replaces them, and "none" hides them.
    func testTheIndexSearchesTheNamesUnderTheUsersCorrection() async throws {
        let index = ContentIndex(url: database)
        try await index.open()
        try await index.upsertBatch([
            IndexRow(path: "/a.pdf", mtime: 1, name: "a.pdf", classification: nil, body: "Dear Sir,", pageCount: 2,
                     hasText: true, readable: true,
                     sidecarNames: [.sender: "Eleanor Vance", .recipient: "John Doe; Mary Roe", .sendingPlace: "Boston"]),
            IndexRow(path: "/b.pdf", mtime: 1, name: "b.pdf", classification: nil, body: "Nothing.", pageCount: 2,
                     hasText: true, readable: true),
        ])
        var hits = await index.search("Vance")
        XCTAssertEqual(hits, ["/a.pdf"], "the sender is found though the text does not name her")
        hits = await index.search("Roe")
        XCTAssertEqual(hits, ["/a.pdf"], "each of several recipients is found")
        var fields = await index.itemFields(for: ["/a.pdf", "/b.pdf"])
        XCTAssertEqual(fields["/a.pdf"]?.shownNames[.sendingPlace], "Boston")
        XCTAssertNil(fields["/b.pdf"], "a file with no names and no item fields has no entry")

        try await index.setUserFields(["/a.pdf": [.sender: "Eleanor Vane", .sendingPlace: ""]])
        hits = await index.search("Vance")
        XCTAssertEqual(hits, [], "a corrected sender replaces the sidecar's")
        hits = await index.search("Vane")
        XCTAssertEqual(hits, ["/a.pdf"])
        hits = await index.search("Boston")
        XCTAssertEqual(hits, [], "\"none\" hides the sidecar's sending place")
        hits = await index.search("Doe")
        XCTAssertEqual(hits, ["/a.pdf"], "a name the user did not correct is still found")
        fields = await index.itemFields(for: ["/a.pdf"])
        XCTAssertEqual(fields["/a.pdf"]?.shownNames, [.sender: "Eleanor Vane", .recipient: "John Doe; Mary Roe"])

        try await index.setUserFields(["/a.pdf": [:]])
        hits = await index.search("Boston")
        XCTAssertEqual(hits, ["/a.pdf"], "removing the correction brings the sidecar's name back")
        await index.close()
    }

    /// An index written before `sidecar_stamp` is dropped and rebuilt, so every file's names are read with a stamp.
    func testAnIndexWithoutTheSidecarStampColumnIsRebuilt() async throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        for sql in ["CREATE TABLE files(path TEXT PRIMARY KEY, mtime REAL, inode INTEGER, size INTEGER, page_count INTEGER, has_text INTEGER, readable INTEGER, header_fields TEXT, user_fields TEXT, sidecar_names TEXT);",
                    "CREATE VIRTUAL TABLE fts USING fts5(body, classification, name, fields, path UNINDEXED);",
                    "INSERT INTO files(path, mtime) VALUES('/old.pdf', 1);"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)
        let index = ContentIndex(url: database)
        try await index.open()
        let stamps = await index.existingStamps()
        XCTAssertTrue(stamps.isEmpty, "the old rows are gone, so every file is extracted again")
        await index.close()
    }

    private func waitForPasses(_ driver: ContentIndexer, _ n: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, driver.completedPassesForTesting < n { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(driver.completedPassesForTesting, n)
    }

    /// A pass reads each extracted file's sidecar, beside it or in its folder's `JSON Output`, as the Inspector does.
    func testAPassReadsTheSidecarBesideTheFileAndInJSONOutput() async throws {
        let dir = root.appendingPathComponent("Box 4", isDirectory: true)
        let output = dir.appendingPathComponent(ZoteroSidecar.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        let c = dir.appendingPathComponent("c.pdf")
        for u in [a, b, c] { try Data("scratch fixture".utf8).write(to: u) }
        try Data(#"{"author_name": "Eleanor Vance", "recipient_name": ["John Doe"]}"#.utf8)
            .write(to: dir.appendingPathComponent("a.json"))
        try Data((#"{"entities": {"status": "extracted", "sender": [{"name": "Harold Pike", "evidence": "inferred"}], "#
                  + #""sending_place": [{"name": "Salem", "evidence": "inferred"}]}}"#).utf8)
            .write(to: output.appendingPathComponent("b.json"))
        let files = [a, b, c].map {
            ArchiveFile(url: $0, name: $0.lastPathComponent, fileType: "PDF",
                        tags: DocumentTags.parse(raw: ["Unread"], labelNumber: nil),
                        contentModified: Date(timeIntervalSince1970: 20))
        }
        let driver = ContentIndexer(url: database, extractPDFForTesting: { _ in
            ExtractedContent(fullBody: "plain text", strippedBody: "plain text", classification: nil, pageCount: 2)
        })
        driver.startIndexing(files)
        try await waitForPasses(driver, 1)
        var hits = await driver.search("Vance")
        XCTAssertEqual(hits, [a.path])
        hits = await driver.search("Pike")
        XCTAssertEqual(hits, [b.path], "the JSON Output folder's sidecar is read")
        hits = await driver.search("Salem")
        XCTAssertEqual(hits, [], "an inferred sending place is not one the sidecar keeps")
        let shown = await driver.itemFields(for: [a.path, b.path, c.path])
        XCTAssertEqual(shown[a.path]?.columnText, "Eleanor Vance · John Doe")
        XCTAssertEqual(shown[b.path]?.columnText, "Harold Pike")
        XCTAssertNil(shown[c.path], "a file with no sidecar has no entry")
        await driver.closeForTesting()
    }

    private func pdfFile(_ url: URL) -> ArchiveFile {
        ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                    tags: DocumentTags.parse(raw: ["Unread"], labelNumber: nil),
                    contentModified: Date(timeIntervalSince1970: 20))
    }

    /// W49.reader-sidecar-names-refresh: a sidecar written, rewritten or removed after its PDF was indexed is read again
    /// by the next pass or a sync, and the PDF's text is not extracted again.
    func testASidecarChangedWithoutItsPDFIsReadAgainWithoutReextracting() async throws {
        let dir = root.appendingPathComponent("Box 5", isDirectory: true)
        let output = dir.appendingPathComponent(ZoteroSidecar.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        for u in [a, b] { try Data("scratch fixture".utf8).write(to: u) }
        let files = [pdfFile(a), pdfFile(b)]
        let probe = ExtractionCounter()
        let driver = ContentIndexer(url: database, extractPDFForTesting: { _ in
            probe.bump()
            return ExtractedContent(fullBody: "plain text", strippedBody: "plain text", classification: nil, pageCount: 2)
        })
        driver.startIndexing(files)
        try await waitForPasses(driver, 1)
        var hits = await driver.search("Vance")
        XCTAssertEqual(hits, [])

        // The Processor writes the sidecar after the PDF.
        try Data(#"{"author_name": "Eleanor Vance"}"#.utf8).write(to: dir.appendingPathComponent("a.json"))
        driver.startIndexing(files)
        try await waitForPasses(driver, 2)
        XCTAssertEqual(probe.count, 2, "neither file was extracted again")
        hits = await driver.search("Vance")
        XCTAssertEqual(hits, [a.path], "the next pass reads a sidecar written after the PDF")
        var shown = await driver.itemFields(for: [a.path])
        XCTAssertEqual(shown[a.path]?.columnText, "Eleanor Vance")

        // A tagging re-run rewrites only the sidecar (a new file, as an atomic write makes); a sync reads it.
        try Data(#"{"author_name": "Harold Pike", "recipient_name": "John Doe"}"#.utf8)
            .write(to: dir.appendingPathComponent("a.json"), options: .atomic)
        var changed = await driver.syncSidecarNames(files)
        XCTAssertTrue(changed)
        changed = await driver.syncSidecarNames(files)
        XCTAssertFalse(changed, "nothing changed since")
        hits = await driver.search("Vance")
        XCTAssertEqual(hits, [], "the old name is gone")
        hits = await driver.search("Doe")
        XCTAssertEqual(hits, [a.path])

        // A sidecar that moves into `JSON Output` is followed there; a removed one takes its names with it.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("a.json"),
                                         to: output.appendingPathComponent("b.json"))
        changed = await driver.syncSidecarNames(files)
        XCTAssertTrue(changed)
        hits = await driver.search("Pike")
        XCTAssertEqual(hits, [b.path], "a's sidecar is gone and b's is in JSON Output")
        shown = await driver.itemFields(for: [a.path, b.path])
        XCTAssertNil(shown[a.path])

        // The user's correction still wins over a sidecar read again.
        _ = try NavigationModel.editItemFields(at: dir) { f in
            var f = f
            f.set(.sender, to: "Harold Pyke", for: "b.pdf")
            return f
        }
        _ = await driver.syncUserFields(files)
        try Data(#"{"author_name": "Harold Pikeman"}"#.utf8).write(to: output.appendingPathComponent("b.json"),
                                                                   options: .atomic)
        driver.startIndexing(files)
        try await waitForPasses(driver, 3)
        XCTAssertEqual(probe.count, 2)
        hits = await driver.search("Pikeman")
        XCTAssertEqual(hits, [], "the corrected sender is the one searched")
        hits = await driver.search("Pyke")
        XCTAssertEqual(hits, [b.path])
        await driver.closeForTesting()
    }

    /// A file whose PDF cannot be read still has its sidecar's names indexed.
    func testAnUnreadablePDFStillHasItsSidecarNames() async throws {
        let dir = root.appendingPathComponent("Box 6", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.pdf")
        try Data("not a pdf".utf8).write(to: a)
        try Data(#"{"author_name": "Eleanor Vance"}"#.utf8).write(to: dir.appendingPathComponent("a.json"))
        let driver = ContentIndexer(url: database, extractPDFForTesting: { _ in nil })
        driver.startIndexing([pdfFile(a)])
        try await waitForPasses(driver, 1)
        let hits = await driver.search("Vance")
        XCTAssertEqual(hits, [a.path])
        await driver.closeForTesting()
    }

    /// The stamp follows `ZoteroSidecar.locate`: beside the PDF first, then `JSON Output`; a directory is no sidecar.
    func testTheSidecarStampFollowsWhereTheSidecarIs() throws {
        let dir = root.appendingPathComponent("Box 7", isDirectory: true)
        let output = dir.appendingPathComponent(ZoteroSidecar.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        let c = dir.appendingPathComponent("c.pdf")
        for u in [a, b, c] { try Data("x".utf8).write(to: u) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("a.json"))
        try Data("{}".utf8).write(to: output.appendingPathComponent("a.json"))
        try Data("{}".utf8).write(to: output.appendingPathComponent("b.json"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("c.json"), withIntermediateDirectories: true)
        let stamps = SidecarStamp.stamps(of: [a, b, c].map(pdfFile))
        XCTAssertEqual(stamps[a.path]?.first, "b", "beside the PDF comes first")
        XCTAssertEqual(stamps[b.path]?.first, "j")
        XCTAssertNil(stamps[c.path], "a directory named c.json is no sidecar")
    }

    /// The watcher names the PDFs' folder for a `.json` beside them or in `JSON Output`, never for the item-field file.
    func testTheWatcherNamesTheFoldersOfAChangedSidecar() {
        var request = CorpusWatchRequest()
        request.paths.insert("/r/Box 1/a.json")
        request.paths.insert("/r/Box 2/JSON Output/b.JSON")
        request.paths.insert("/r/Box 3/" + ContainerFile.folderName + "/" + UserItemFields.fileName)
        request.paths.insert("/r/Box 4/c.pdf")
        request.subtrees.insert("/r/Box 5")
        XCTAssertEqual(ArchiveLibrary.sidecarFolders(request), ["/r/Box 1", "/r/Box 2", "/r/Box 5"])
        let files = ["/r/Box 1/a.pdf", "/r/Box 10/a.pdf", "/r/Box 5/Sub/x.pdf", "/r/Box 2/b.pdf"].map {
            pdfFile(URL(fileURLWithPath: $0))
        }
        XCTAssertEqual(NavigationModel.files(files, under: ["/r/Box 1", "/r/Box 5"]).map(\.path),
                       ["/r/Box 1/a.pdf", "/r/Box 5/Sub/x.pdf"])
    }

    /// The cost of the per-pass sidecar check (W49.reader-sidecar-names-refresh), measured here in the app-hosted bundle
    /// rather than in a daemon session, whose timings are clamped: one `stat` a file, one more where `JSON Output`
    /// exists and the file has none beside it.
    func testMeasureTheSidecarStampCost() throws {
        var files: [ArchiveFile] = []
        for folder in 0..<40 {
            let dir = root.appendingPathComponent("Folder \(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let output = dir.appendingPathComponent(ZoteroSidecar.folderName, isDirectory: true)
            if folder % 4 == 0 { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            for n in 0..<100 {
                let pdf = dir.appendingPathComponent(String(format: "%06d Item.pdf", n))
                FileManager.default.createFile(atPath: pdf.path, contents: nil)
                if n % 10 == 0 {
                    let side = folder % 4 == 0 ? output : dir
                    FileManager.default.createFile(atPath: side.appendingPathComponent(String(format: "%06d Item.json", n)).path,
                                                   contents: Data("{}".utf8))
                }
                files.append(pdfFile(pdf))
            }
        }
        _ = SidecarStamp.stamps(of: files)   // warm, as a pass after discovery finds the metadata cached
        // Interleaved with a baseline of one bare `stat` of each PDF, so the figure reads against the machine's load.
        let rounds = 5
        let missing = files.map { $0.path + ".json" }
        var found = 0, stampNs: UInt64 = 0, baseNs: UInt64 = 0, missNs: UInt64 = 0, userNs: UInt64 = 0
        for _ in 0..<rounds {
            var t = DispatchTime.now().uptimeNanoseconds
            found = SidecarStamp.stamps(of: files).count
            stampNs += DispatchTime.now().uptimeNanoseconds - t
            t = DispatchTime.now().uptimeNanoseconds
            var st = stat()
            for f in files { _ = stat(f.path, &st) }
            baseNs += DispatchTime.now().uptimeNanoseconds - t
            t = DispatchTime.now().uptimeNanoseconds
            for m in missing { _ = stat(m, &st) }
            missNs += DispatchTime.now().uptimeNanoseconds - t
            t = DispatchTime.now().uptimeNanoseconds
            _ = ContentIndexer.userFields(of: files)
            userNs += DispatchTime.now().uptimeNanoseconds - t
        }
        let perFile = Double(stampNs) / Double(rounds * files.count) / 1000
        let basePerFile = Double(baseNs) / Double(rounds * files.count) / 1000
        let missPerFile = Double(missNs) / Double(rounds * files.count) / 1000
        let userPerFile = Double(userNs) / Double(rounds * files.count) / 1000
        print("W49.reader-sidecar-names-refresh: SidecarStamp.stamps \(String(format: "%.2f", perFile)) µs a file over "
              + "\(files.count) files (one bare stat: \(String(format: "%.2f", basePerFile)) µs of a file, "
              + "\(String(format: "%.2f", missPerFile)) µs of a missing name; the pass's existing per-file read of the corrections \(String(format: "%.2f", userPerFile)) µs; ratio to the first "
              + "\(String(format: "%.1f", perFile / basePerFile))); at 102,000 files \(String(format: "%.0f", perFile * 102)) ms a pass")
        XCTAssertEqual(found, 400)
    }

    func testTheColumnGivesTheNamesAfterTheItemFields() {
        let fields = IndexedItemFields(header: PDFItemFields(documentKind: "letter"),
                                       user: [.recipient: "Mary Roe", .sendingPlace: ""],
                                       names: [.sender: "Eleanor Vance", .recipient: "John Doe",
                                               .sendingPlace: "Boston"])
        XCTAssertEqual(fields.columnText, "letter · Eleanor Vance · Mary Roe", "the user's over the sidecar's")
        XCTAssertEqual(fields.columnToolTip, "Kind: letter\nSender: Eleanor Vance\nRecipient: Mary Roe (your value)")
        XCTAssertEqual(IndexedItemFields.searchText(fields.user, names: fields.names), "Eleanor Vance\nMary Roe")
        XCTAssertNil(IndexedItemFields(user: [.sender: ""], names: [.sender: "X"]).columnText)
    }
}

private final class ExtractionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
