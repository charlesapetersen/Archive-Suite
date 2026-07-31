import XCTest
@testable import ArchiveReader

/// W23.m9 — `ContentIndex.open()` must be all-or-nothing.
///
/// `sqlite3_open_v2` is lazy: it hands back a live handle for a file it has not read yet, so a
/// corrupt/foreign cache file opens *successfully* and then fails on the first PRAGMA with
/// "file is not a database". Before this fix `open()` threw with `db` still non-nil, and since
/// `open()` short-circuits on `db != nil`, every later `open()` returned "success" without ever
/// completing setup — the index was poisoned until the process restarted, and because the corrupt
/// file is still there next launch, permanently.
///
/// All scratch: a `sqlite3` file under the test bundle's temp dir. No corpus, no app, no network.
final class ContentIndexRecoveryTests: XCTestCase {

    /// A scratch DB URL plus a cleanup closure covering the -wal/-shm sidecars.
    private func scratchURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ci-recovery-\(UUID().uuidString).sqlite3")
    }

    private func removeDB(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    /// 1 KiB of non-header bytes — enough that SQLite's header check fails outright (an *empty*
    /// file is a valid empty database, so it would not reproduce anything).
    private func writeGarbage(to url: URL) throws {
        try Data(repeating: 0x5A, count: 1024).write(to: url)
    }

    // MARK: - The half-open handle

    /// A setup failure must throw AND leave nothing behind, so the retry after the bad file is
    /// replaced actually opens. Pre-fix the second `open()` returned immediately (handle non-nil)
    /// and the `upsert` then failed with "file is not a database" — RED on the write below.
    func testSetupFailureLeavesNoHalfOpenHandle() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        try writeGarbage(to: url)
        let idx = ContentIndex(url: url)

        do {
            try await idx.open()
            XCTFail("open() must throw on a file that is not a database")
        } catch {
            // Expected: the first statement inside open() fails.
        }

        // The cache is disposable, so recovery in the real app is "replace the file and reopen".
        // Truncating to empty is a valid empty DB and needs no delete API.
        try Data().write(to: url)
        try await idx.open()                     // pre-fix: a no-op that "succeeds" on the dead handle
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a.pdf",
                             classification: "Document Start", body: "Chafee budget memorandum")
        let hits = await idx.search("memorandum")
        XCTAssertEqual(hits, ["/a.pdf"], "a reopened index must be writable and searchable")
        await idx.close()
    }

    /// The narrower invariant on its own: after a failed `open()` the actor must behave as *closed*,
    /// not as open-but-broken. Reading through the public surface (a query that would need a handle)
    /// keeps this a behaviour check rather than a peek at a private field.
    func testFailedOpenLeavesTheIndexClosedNotPoisoned() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        try writeGarbage(to: url)
        let idx = ContentIndex(url: url)

        for attempt in 1...3 {
            do {
                try await idx.open()
                XCTFail("open() attempt \(attempt) must keep throwing while the file is corrupt")
            } catch {}
        }
        // Still corrupt, so every read degrades to empty — but it degrades *while reporting the
        // failure*, which is what the indexer's `Failure` state is built on.
        let count = await idx.indexedCount()
        XCTAssertEqual(count, 0)

        try Data().write(to: url)
        try await idx.open()
        try await idx.upsert(path: "/b.pdf", mtime: 2, name: "b.pdf", classification: nil, body: "recovered")
        let after = await idx.indexedCount()
        XCTAssertEqual(after, 1, "the third failed open must not have blocked recovery")
        await idx.close()
    }

    /// `close()` must also be re-entrant safe, and reopening after an explicit close must work —
    /// the same `discardHandle()` path the failure branch uses.
    func testCloseIsIdempotentAndReopenWorks() async throws {
        let url = scratchURL(); defer { removeDB(url) }
        let idx = ContentIndex(url: url)
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a.pdf", classification: nil, body: "kept across a close")
        await idx.close()
        await idx.close()                        // second close must not touch a freed handle
        try await idx.open()
        let hits = await idx.search("kept")
        XCTAssertEqual(hits, ["/a.pdf"])
        await idx.close()
    }
}
