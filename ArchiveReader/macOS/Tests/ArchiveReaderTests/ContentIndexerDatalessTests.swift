import XCTest
import Darwin
import ArchiveCore
@testable import ArchiveReader

/// W26.idx cloud-placeholder guard. Scratch content cache only; no cloud provider and no corpus.
@MainActor
final class ContentIndexerDatalessTests: XCTestCase {
    func testDatalessFileIsNeverOpenedAndItsDisposableContentRowIsRemoved() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContentIndexerDatalessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let database = scratch.appendingPathComponent("content.sqlite3")
        let placeholder = scratch.appendingPathComponent("not-present-placeholder.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: placeholder.path))

        // Seed stale searchable content. If the driver tried to open this absent path, extraction
        // would create a fresh `.unreadable` row; the required behaviour is no open and no row.
        let directIndex = ContentIndex(url: database)
        try await directIndex.open()
        try await directIndex.upsertBatch([
            IndexRow(path: placeholder.path, mtime: 10, name: placeholder.lastPathComponent,
                     classification: "Document Start", body: "stale searchable text",
                     pageCount: 1, hasText: true, readable: true),
        ])
        let seededHits = await directIndex.search("stale")
        XCTAssertEqual(seededHits, [placeholder.path])

        let file = ArchiveFile(url: placeholder, name: placeholder.lastPathComponent,
                               fileType: "PDF",
                               tags: DocumentTags.parse(raw: ["Unread"], labelNumber: nil),
                               contentModified: Date(timeIntervalSince1970: 10),
                               isDataless: true)
        let extraction = ExtractionProbe()
        let driver = ContentIndexer(url: database, extractPDFForTesting: { url in
            extraction.record(url: url, policy: getiopolicy_np(
                IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD
            ))
            return ExtractedContent(fullBody: "opened", strippedBody: "opened",
                                    classification: nil, pageCount: 1)
        })
        driver.startIndexing([file])

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if driver.completedPassesForTesting == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(driver.completedPassesForTesting, 1,
                       "assert only after deletion and the whole async pass have finished")
        XCTAssertEqual(extraction.count, 0,
                       "an initially dataless row must never reach the PDF-open boundary")

        let finalHits = await directIndex.search("stale")
        let finalFlags = await directIndex.formatFlags(for: [placeholder.path])
        XCTAssertTrue(finalHits.isEmpty,
                      "stale text for a newly-dataless file must not remain searchable")
        XCTAssertNil(finalFlags[placeholder.path],
                     "the placeholder is skipped rather than reinserted as an unreadable PDF")
    }

    func testRacePathPDFOpenRunsInsideNoMaterialisationPolicy() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ContentIndexerPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let fileURL = scratch.appendingPathComponent("local.pdf")
        try Data("scratch fixture".utf8).write(to: fileURL)
        let file = ArchiveFile(url: fileURL, name: fileURL.lastPathComponent, fileType: "PDF",
                               tags: DocumentTags.parse(raw: ["Unread"], labelNumber: nil),
                               contentModified: Date(timeIntervalSince1970: 20))
        let extraction = ExtractionProbe()
        let driver = ContentIndexer(
            url: scratch.appendingPathComponent("content.sqlite3"),
            extractPDFForTesting: { url in
                extraction.record(url: url, policy: getiopolicy_np(
                    IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD
                ))
                return ExtractedContent(fullBody: "body", strippedBody: "body",
                                        classification: "Document Start", pageCount: 1)
            }
        )

        driver.startIndexing([file])
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, driver.completedPassesForTesting == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(driver.completedPassesForTesting, 1)
        XCTAssertEqual(extraction.count, 1)
        XCTAssertEqual(extraction.urls, [fileURL])
        XCTAssertEqual(extraction.policies, [IOPOL_MATERIALIZE_DATALESS_FILES_OFF],
                       "a file becoming dataless after discovery must still not auto-download")
    }
}

private final class ExtractionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []
    private var recordedPolicies: [Int32] = []

    func record(url: URL, policy: Int32) {
        lock.lock()
        recordedURLs.append(url)
        recordedPolicies.append(policy)
        lock.unlock()
    }

    var count: Int { lock.withLock { recordedURLs.count } }
    var urls: [URL] { lock.withLock { recordedURLs } }
    var policies: [Int32] { lock.withLock { recordedPolicies } }
}
