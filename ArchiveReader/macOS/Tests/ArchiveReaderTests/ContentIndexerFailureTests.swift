import XCTest
@testable import ArchiveReader
@testable import ArchiveCore

/// W23.m9 (failure mode 1) — the indexing driver must not report a clean finish over an index it
/// could not open or could not fully write.
///
/// Before this fix `launch()` did `try? await idx.open()` and every batch write was `try?` too: a
/// dead index produced a pass that extracted every PDF in the library, threw all of it away, cleared
/// `progress` and left an idle status bar. Search then returned `[]` — which in the UI is
/// indistinguishable from "no matches" — and the format-health count read 0, i.e. "nothing needs
/// attention". The driver now carries a typed `Failure` the status bar shows.
///
/// All scratch: a garbage `sqlite3` file under the test bundle's temp dir, and `ArchiveFile`s whose
/// paths need not exist (an unreadable file is a legitimate row: `readable = false`). No corpus.
@MainActor
final class ContentIndexerFailureTests: XCTestCase {

    private func scratchURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cix-\(UUID().uuidString).sqlite3")
    }

    private func removeDB(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// 1 KiB of non-header bytes: SQLite opens the file, then fails on the first statement.
    private func writeGarbage(to url: URL) throws {
        try Data(repeating: 0x5A, count: 1024).write(to: url)
    }

    private func file(_ path: String) -> ArchiveFile {
        let url = URL(fileURLWithPath: path)
        return ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                           tags: DocumentTags.parse(raw: [], labelNumber: nil),
                           contentModified: Date(timeIntervalSince1970: 1))
    }

    /// Poll a main-actor condition — the pass runs detached, so its completion is observed, not awaited.
    private func wait(_ label: String, timeout: TimeInterval = 5,
                      until condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }

    // MARK: - Queries

    /// A query over an unopenable index must record `unavailable` rather than quietly answering "none".
    func testQueryOnUnopenableIndexReportsUnavailable() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        try writeGarbage(to: url)
        let indexer = ContentIndexer(url: url)

        let hits = await indexer.search("chafee")
        XCTAssertTrue(hits.isEmpty)
        guard case .unavailable = indexer.failure else {
            return XCTFail("expected .unavailable, got \(String(describing: indexer.failure))")
        }
        XCTAssertFalse(indexer.failure?.message.isEmpty ?? true, "the status bar needs a line to show")
    }

    /// Format health goes through the same seam: a 0 count over a dead index would read as
    /// "nothing needs attention".
    func testFormatHealthOnUnopenableIndexReportsUnavailable() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        try writeGarbage(to: url)
        let indexer = ContentIndexer(url: url)

        let statuses = await indexer.formatStatuses(for: ["/corpus/a.pdf"])
        let count = await indexer.needsAttentionCount(among: ["/corpus/a.pdf"])
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(count, 0)
        guard case .unavailable = indexer.failure else {
            return XCTFail("expected .unavailable, got \(String(describing: indexer.failure))")
        }
    }

    /// A healthy index must stay healthy-looking — no false alarm in the status bar.
    func testHealthyQueryLeavesNoFailure() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        let indexer = ContentIndexer(url: url)
        let hits = await indexer.search("chafee")
        XCTAssertTrue(hits.isEmpty)          // empty index, genuinely no matches
        XCTAssertNil(indexer.failure)
    }

    // MARK: - Passes

    /// An indexing pass over an unopenable index must end in `unavailable`, not in a clean idle.
    func testPassOnUnopenableIndexReportsUnavailable() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        try writeGarbage(to: url)
        let indexer = ContentIndexer(url: url)

        indexer.startIndexing([file("/corpus/a.pdf"), file("/corpus/b.pdf")])
        await wait("the pass to report a failure") { indexer.failure != nil }
        guard case .unavailable = indexer.failure else {
            return XCTFail("expected .unavailable, got \(String(describing: indexer.failure))")
        }
        XCTAssertNil(indexer.progress, "a failed pass must still settle the progress indicator")
    }

    /// The recovery arc end to end: a dead index reports unavailable; once the file is replaced a
    /// pass succeeds, writes its rows, and clears the failure. (Both halves matter — a flag that
    /// never clears would put a permanent warning in the status bar.)
    func testSuccessfulPassAfterRecoveryClearsTheFailure() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        try writeGarbage(to: url)
        let indexer = ContentIndexer(url: url)

        _ = await indexer.search("chafee")
        XCTAssertNotNil(indexer.failure, "precondition: the corrupt file is reported")

        // Replace the bad file (truncating to empty is a valid empty DB — no delete API needed).
        try Data().write(to: url)
        indexer.startIndexing([file("/corpus/a.pdf")])
        await wait("the pass to clear the failure") { indexer.failure == nil && indexer.progress == nil }

        // And it really wrote: the row is there, flagged unreadable (the path doesn't exist).
        let statuses = await indexer.formatStatuses(for: ["/corpus/a.pdf"])
        XCTAssertEqual(statuses["/corpus/a.pdf"], .unreadable)
        XCTAssertNil(indexer.failure)
    }

    /// The outcome → published-state mapping, checked directly. There is no portable way to make
    /// SQLite fail a *write* on demand (short of corrupting an open file, which is undefined
    /// behaviour), so the `.rowsDropped` count from the two flush sites is verified here rather than
    /// through a forced mid-pass failure.
    func testOutcomeMapsToTheStateTheStatusBarShows() {
        XCTAssertNil(ContentIndexer.Outcome.ok.failure, "a clean pass must clear an earlier failure")
        XCTAssertEqual(ContentIndexer.Outcome.rowsDropped(500).failure, .incomplete(rows: 500))
        XCTAssertEqual(ContentIndexer.Outcome.couldNotOpen("file is not a database").failure,
                       .unavailable(detail: "file is not a database"))
    }

    /// `Failure` messages are what the status bar renders — they must be non-empty and singular/plural
    /// correct, since a "1 files missing" line is the kind of thing nobody re-reads.
    func testFailureMessagesReadCorrectly() {
        XCTAssertTrue(ContentIndexer.Failure.incomplete(rows: 1).message.contains("1 file missing"))
        XCTAssertTrue(ContentIndexer.Failure.incomplete(rows: 7).message.contains("7 files missing"))
        XCTAssertFalse(ContentIndexer.Failure.unavailable(detail: "file is not a database").message.isEmpty)
        XCTAssertTrue(ContentIndexer.Failure.unavailable(detail: "file is not a database")
            .detail.contains("file is not a database"), "the SQLite reason belongs in the tooltip")
    }
}
