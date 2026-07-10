import XCTest
@testable import ArchiveReader

final class ContentIndexTests: XCTestCase {

    private func makeIndex() -> (ContentIndex, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ci-\(UUID().uuidString).sqlite3")
        return (ContentIndex(url: url), url)
    }

    func testUpsertAndSearch() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a.pdf",
                             classification: "Document Start", body: "Senator Chafee discussed the Cold War budget.")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b.pdf",
                             classification: "Continuation", body: "Economic policy and taxes in California.")
        let cold = await idx.search("Cold War")
        XCTAssertEqual(cold, ["/a.pdf"])
        let taxes = await idx.search("taxes")
        XCTAssertEqual(taxes, ["/b.pdf"])
        let none = await idx.search("nonexistentterm")
        XCTAssertTrue(none.isEmpty)
        await idx.close()
    }

    func testNeedsIndexIncremental() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let unindexed = await idx.needsIndex(path: "/a.pdf", mtime: 100)
        XCTAssertTrue(unindexed)
        try await idx.upsert(path: "/a.pdf", mtime: 100, name: "a", classification: nil, body: "hello world")
        let same = await idx.needsIndex(path: "/a.pdf", mtime: 100)
        XCTAssertFalse(same)
        let changed = await idx.needsIndex(path: "/a.pdf", mtime: 200)
        XCTAssertTrue(changed)
        await idx.close()
    }

    func testReindexReplacesOldBody() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "apples")
        try await idx.upsert(path: "/a.pdf", mtime: 2, name: "a", classification: nil, body: "oranges")
        let apples = await idx.search("apples")
        XCTAssertTrue(apples.isEmpty)                      // old body gone
        let oranges = await idx.search("oranges")
        XCTAssertEqual(oranges, ["/a.pdf"])
        let count = await idx.indexedCount()
        XCTAssertEqual(count, 1)                            // still a single file
        await idx.close()
    }

    func testMultiTermSearchIsAnd() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "cold war budget")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b", classification: nil, body: "cold weather report")
        let both = await idx.search("cold war")
        XCTAssertEqual(both, ["/a.pdf"])                                    // AND of terms
        let cold = await idx.search("cold")
        XCTAssertEqual(Set(cold), ["/a.pdf", "/b.pdf"])
        await idx.close()
    }

    func testArbitraryQueryDoesNotCrashFTS() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "hello")
        // Punctuation that would be invalid raw FTS5 syntax must be handled safely.
        _ = await idx.search("\"unbalanced ( quote * AND")
        await idx.close()
    }

    func testFormatFlagsAndNeedsAttentionCount() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        // Standard (readable + text), no-text-layer (readable, empty body), unreadable (open failed).
        try await idx.upsert(path: "/std.pdf", mtime: 1, name: "std", classification: "Document Start",
                             body: "real ocr text", pageCount: 2, hasText: true, readable: true)
        try await idx.upsert(path: "/notext.pdf", mtime: 1, name: "notext", classification: nil,
                             body: "", pageCount: 7, hasText: false, readable: true)
        try await idx.upsert(path: "/bad.pdf", mtime: 1, name: "bad", classification: nil,
                             body: "", pageCount: 0, hasText: false, readable: false)
        let flags = await idx.formatFlags(for: ["/std.pdf", "/notext.pdf", "/bad.pdf", "/missing.pdf"])
        XCTAssertEqual(flags["/std.pdf"], .standard)
        XCTAssertEqual(flags["/notext.pdf"], .noTextLayer)   // >2 pages is NOT a defect — no-text is
        XCTAssertEqual(flags["/bad.pdf"], .unreadable)
        XCTAssertNil(flags["/missing.pdf"])                  // unindexed → absent
        let count = await idx.needsAttentionCount()
        XCTAssertEqual(count, 2)                              // notext + bad, never std
        await idx.close()
    }

    // R-2: search is used only for set-membership AND-ing, so it must return EVERY match — no silent
    // row cap. A common term over a large corpus previously truncated at 5000 (by rowid), dropping
    // real matches. Index >5000 files carrying a shared term and assert all come back.
    func testSearchReturnsAllMatchesBeyond5000() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let n = 6000
        for i in 0..<n {
            try await idx.upsert(path: "/f\(i).pdf", mtime: 1, name: "f\(i)", classification: nil,
                                 body: "commonterm body \(i)")
        }
        let hits = await idx.search("commonterm")
        XCTAssertEqual(hits.count, n)                          // all matches, not a 5000 cap
        XCTAssertEqual(Set(hits).count, n)                     // distinct paths
        // A deliberate bound still applies when a caller asks for one.
        let capped = await idx.search("commonterm", limit: 10)
        XCTAssertEqual(capped.count, 10)
        await idx.close()
    }

    // R-5: the badge count must be scoped to the CURRENT library's paths — the shared index is never
    // pruned, so a corpus-wide count over-reports rows from other roots / removed files after a switch.
    func testNeedsAttentionCountScopedToPaths() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        // "Current root" files: one needs attention (no text).
        try await idx.upsert(path: "/root/std.pdf", mtime: 1, name: "std", classification: "Document Start",
                             body: "real ocr text", pageCount: 2, hasText: true, readable: true)
        try await idx.upsert(path: "/root/notext.pdf", mtime: 1, name: "notext", classification: nil,
                             body: "", pageCount: 7, hasText: false, readable: true)
        // Stale rows from a DIFFERENT root that must NOT be counted.
        try await idx.upsert(path: "/other/bad1.pdf", mtime: 1, name: "bad1", classification: nil,
                             body: "", pageCount: 0, hasText: false, readable: false)
        try await idx.upsert(path: "/other/bad2.pdf", mtime: 1, name: "bad2", classification: nil,
                             body: "", pageCount: 0, hasText: false, readable: false)
        let corpusWide = await idx.needsAttentionCount()
        XCTAssertEqual(corpusWide, 3)                          // corpus-wide over-reports (notext + 2 bad)
        // Scoped to the current library: only /root/notext.pdf counts.
        let scoped = await idx.needsAttentionCount(among: ["/root/std.pdf", "/root/notext.pdf"])
        XCTAssertEqual(scoped, 1)
        let emptyScope = await idx.needsAttentionCount(among: [])
        XCTAssertEqual(emptyScope, 0)                          // empty scope → 0
        let missingScope = await idx.needsAttentionCount(among: ["/missing.pdf"])
        XCTAssertEqual(missingScope, 0)                        // unindexed ignored
        await idx.close()
    }

    func testReindexClearsUnreadableFlag() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil,
                             body: "", pageCount: 0, hasText: false, readable: false)
        let before = await idx.needsAttentionCount()
        XCTAssertEqual(before, 1)
        // A later, successful re-extraction flips it back to standard (no stale attention flag).
        try await idx.upsert(path: "/a.pdf", mtime: 2, name: "a", classification: "Document Start",
                             body: "recovered text", pageCount: 2, hasText: true, readable: true)
        let after = await idx.needsAttentionCount()
        XCTAssertEqual(after, 0)
        let flags = await idx.formatFlags(for: ["/a.pdf"])
        XCTAssertEqual(flags["/a.pdf"], .standard)
        await idx.close()
    }

    // --- upsertBatch parity: batch insert is searchable, count correct, reindex within batch replaces.
    func testUpsertBatchParity() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let rows: [IndexRow] = [
            IndexRow(path: "/a.pdf", mtime: 1, name: "a", classification: "Document Start",
                     body: "Senator Cold War budget", pageCount: 2, hasText: true, readable: true),
            IndexRow(path: "/b.pdf", mtime: 1, name: "b", classification: nil,
                     body: "Economic policy taxes", pageCount: 2, hasText: true, readable: true),
        ]
        try await idx.upsertBatch(rows)
        let cold = await idx.search("Cold War")
        XCTAssertEqual(cold, ["/a.pdf"])
        let taxes = await idx.search("taxes")
        XCTAssertEqual(taxes, ["/b.pdf"])
        let count = await idx.indexedCount()
        XCTAssertEqual(count, 2)
        // Reindex within a second batch replaces old body.
        let updated = [IndexRow(path: "/a.pdf", mtime: 2, name: "a", classification: nil,
                                body: "oranges", pageCount: 1, hasText: true, readable: true)]
        try await idx.upsertBatch(updated)
        let coldGone = await idx.search("Cold War")
        XCTAssertTrue(coldGone.isEmpty)
        let oranges = await idx.search("oranges")
        XCTAssertEqual(oranges, ["/a.pdf"])
        let finalCount = await idx.indexedCount()
        XCTAssertEqual(finalCount, 2) // still 2 files
        await idx.close()
    }

    func testExistingMTimes() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let empty = await idx.existingMTimes()
        XCTAssertTrue(empty.isEmpty)
        try await idx.upsert(path: "/a.pdf", mtime: 100, name: "a", classification: nil, body: "hello")
        try await idx.upsert(path: "/b.pdf", mtime: 200, name: "b", classification: nil, body: "world")
        let mtimes = await idx.existingMTimes()
        XCTAssertEqual(mtimes.count, 2)
        XCTAssertEqual(mtimes["/a.pdf"], 100)
        XCTAssertEqual(mtimes["/b.pdf"], 200)
        await idx.close()
    }

    func testPerformMaintenanceSearchable() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let rows = (0..<10).map { i in
            IndexRow(path: "/f\(i).pdf", mtime: 1, name: "f\(i)", classification: nil,
                     body: "maintenance test body \(i)", pageCount: 1, hasText: true, readable: true)
        }
        try await idx.upsertBatch(rows)
        await idx.performMaintenance(rowsIndexed: 10)  // incremental merge path
        // Index must still be fully searchable after maintenance.
        let hits = await idx.search("maintenance")
        XCTAssertEqual(hits.count, 10)
        // Zero-row pass should be a no-op (no crash).
        await idx.performMaintenance(rowsIndexed: 0)
        await idx.close()
    }

    // bm25 relevance ranking: a term in name (weight 10) outranks classification (5) outranks body (1).
    func testBm25RankedSearch() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        // "budget" in body only (weight 1.0 → ranks last)
        try await idx.upsert(path: "/body.pdf", mtime: 1, name: "report",
                             classification: nil, body: "budget allocation for defense spending")
        // "budget" in classification (weight 5.0 → ranks middle)
        try await idx.upsert(path: "/class.pdf", mtime: 1, name: "memo",
                             classification: "Budget Review", body: "a routine document")
        // "budget" in name (weight 10.0 → ranks first)
        try await idx.upsert(path: "/name.pdf", mtime: 1, name: "budget",
                             classification: nil, body: "a routine document")
        let results = await idx.search("budget")
        XCTAssertEqual(results.count, 3)
        // bm25 with weights (body=1, class=5, name=10): name hit first, body-only hit last.
        XCTAssertEqual(results.first, "/name.pdf", "name hit (weight 10) should rank first")
        XCTAssertEqual(results.last, "/body.pdf", "body-only hit (weight 1) should rank last")
        await idx.close()
    }

    func testClassificationParsing() {
        let page2 = "Extracted text.\n00023 IMG — Brown.jpg\nGemini · Gemini 2.5 · 19 June 2026\nClassification: Document Start\nINTRODUCTION"
        XCTAssertEqual(PDFTextExtractor.parseClassification(from: page2), "Document Start")
        XCTAssertEqual(PDFTextExtractor.parseClassification(from: "Classification: Box"), "Box")
        XCTAssertNil(PDFTextExtractor.parseClassification(from: "no classification line here"))
    }
}
