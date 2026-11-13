import XCTest
import SQLite3
import ArchiveCore
@testable import ArchiveReader

/// W44.reocr-reader-freshness: the content index's freshness key is the date, inode and size, so a
/// replacement that keeps the date is extracted again and a tag edit is not. Scratch files only.
@MainActor
final class ContentIndexFreshnessTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentIndexFreshnessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testSameDateReplacementIsExtractedAgain() async throws {
        let file = scratch.appendingPathComponent("letter.pdf")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("old words", to: file, date: date)
        let (driver, index, probe) = makeDriver()

        driver.startIndexing([try discover(file)])
        try await waitForPasses(driver, 1)
        XCTAssertEqual(probe.count, 1)

        // Replace the file as a publication does: a new file renamed over it, the date put back,
        // the size unchanged, so only the inode tells the two apart.
        let staged = scratch.appendingPathComponent("staged.tmp")
        try write("new words", to: staged, date: date)
        XCTAssertEqual(rename(staged.path, file.path), 0)
        let replaced = try discover(file)
        XCTAssertEqual(replaced.contentModified, date, "the replacement kept the date")

        driver.startIndexing([replaced])
        try await waitForPasses(driver, 2)
        XCTAssertEqual(probe.count, 2, "a same-date replacement is extracted again")
        try await index.open()
        let oldHits = await index.search("old")
        let newHits = await index.search("new")
        XCTAssertEqual(oldHits, [])
        XCTAssertEqual(newHits, [file.path])
        await index.close()
        await driver.closeForTesting()
    }

    func testSameDateSameInodeRewriteOfAnotherSizeIsExtractedAgain() async throws {
        let file = scratch.appendingPathComponent("letter.pdf")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try write("old words", to: file, date: date)
        let (driver, _, probe) = makeDriver()
        driver.startIndexing([try discover(file)])
        try await waitForPasses(driver, 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("longer new words".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)

        driver.startIndexing([try discover(file)])
        try await waitForPasses(driver, 2)
        XCTAssertEqual(probe.count, 2, "a rewrite in place that changed the size is extracted again")
        await driver.closeForTesting()
    }

    func testTagEditIsNotExtractedAgain() async throws {
        let file = scratch.appendingPathComponent("letter.pdf")
        try write("some words", to: file, date: Date(timeIntervalSince1970: 1_700_000_000))
        let (driver, _, probe) = makeDriver()
        let before = try discover(file)
        driver.startIndexing([before])
        try await waitForPasses(driver, 1)

        try (URL(fileURLWithPath: file.path) as NSURL).setResourceValue(["Read", "1957"], forKey: .tagNamesKey)
        let after = try discover(file)
        XCTAssertNotEqual(after.tags, before.tags, "the tag write landed")
        XCTAssertEqual(after.contentModified, before.contentModified)
        XCTAssertEqual(after.contentIdentity, before.contentIdentity)

        driver.startIndexing([after])
        try await waitForPasses(driver, 2)
        XCTAssertEqual(probe.count, 1, "a tag edit does not re-extract the text")
        await driver.closeForTesting()
    }

    /// The warm-start cache row and the disk row of one unchanged file carry the same stamp, so a
    /// launch from the cache followed by the walk's refresh extracts nothing twice.
    func testCacheAndDiskRowsOfOneFileCarryTheSameIdentity() throws {
        let file = scratch.appendingPathComponent("letter.pdf")
        try write("words", to: file, date: Date(timeIntervalSince1970: 1_700_000_000))
        guard case let .tracked(entry) = CorpusWalker.inspect(file, predicate: { _ in true }),
              let fingerprint = entry.fingerprint else { return XCTFail("not tracked") }
        let row = ArchiveLibrary.row(entry, tagNames: entry.tagNames, labelNumber: entry.labelNumber)
        XCTAssertEqual(row.contentIdentity, ContentIdentity(fingerprint))
        XCTAssertEqual(row.contentIdentity?.size, 5)
    }

    /// An index written before the key gained inode and size is dropped and rebuilt, not read with
    /// its old rows taken as current.
    func testOldSchemaIsDroppedAndRebuilt() async throws {
        let url = scratch.appendingPathComponent("content.sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        for sql in ["CREATE TABLE files(path TEXT PRIMARY KEY, mtime REAL, page_count INTEGER, has_text INTEGER, readable INTEGER);",
                    "CREATE VIRTUAL TABLE fts USING fts5(body, classification, name, path UNINDEXED);",
                    "INSERT INTO files(path, mtime, page_count, has_text, readable) VALUES('/a.pdf', 1, 1, 1, 1);",
                    "INSERT INTO fts(rowid, body, classification, name, path) VALUES(1, 'stale', NULL, 'a', '/a.pdf');"] {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql)
        }
        sqlite3_close(db)

        let index = ContentIndex(url: url)
        try await index.open()
        let stamps = await index.existingStamps()
        let hits = await index.search("stale")
        XCTAssertTrue(stamps.isEmpty)
        XCTAssertEqual(hits, [])
        let identity = ContentIdentity(inode: 42, size: 7)
        try await index.upsert(path: "/a.pdf", mtime: 1, identity: identity, name: "a",
                               classification: nil, body: "fresh")
        let stored = await index.existingStamps()
        XCTAssertEqual(stored["/a.pdf"], ContentStamp(mtime: 1, identity: identity))
        let sameStamp = await index.needsIndex(path: "/a.pdf", mtime: 1, identity: identity)
        let otherInode = await index.needsIndex(path: "/a.pdf", mtime: 1,
                                                identity: ContentIdentity(inode: 43, size: 7))
        let noIdentity = await index.needsIndex(path: "/a.pdf", mtime: 1)
        XCTAssertFalse(sameStamp)
        XCTAssertTrue(otherInode)
        XCTAssertTrue(noIdentity)
        await index.close()
    }

    // MARK: - Helpers

    private func write(_ text: String, to url: URL, date: Date) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// The row discovery builds, through the same `stat(2)` and resource read as the walk.
    private func discover(_ url: URL) throws -> ArchiveFile {
        guard case let .tracked(entry) = CorpusWalker.inspect(url, predicate: { _ in true }) else {
            throw XCTSkip("scratch file was not tracked")
        }
        return ArchiveLibrary.row(entry, tagNames: entry.tagNames, labelNumber: entry.labelNumber)
    }

    /// A driver whose extractor reads the scratch file's bytes as its text and counts the opens.
    private func makeDriver() -> (ContentIndexer, ContentIndex, ExtractionCounter) {
        let url = scratch.appendingPathComponent("content.sqlite3")
        let counter = ExtractionCounter()
        let driver = ContentIndexer(url: url, extractPDFForTesting: { file in
            counter.increment()
            let body = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return ExtractedContent(fullBody: body, strippedBody: body, classification: nil, pageCount: 1)
        })
        return (driver, ContentIndex(url: url), counter)
    }

    private func waitForPasses(_ driver: ContentIndexer, _ passes: Int) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, driver.completedPassesForTesting < passes {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(driver.completedPassesForTesting, passes)
    }
}

private final class ExtractionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
