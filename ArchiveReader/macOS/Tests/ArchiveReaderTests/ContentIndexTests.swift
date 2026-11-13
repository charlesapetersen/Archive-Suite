import XCTest
@testable import ArchiveReader
@testable import ArchiveCore

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
        let odd = await idx.search("\"unbalanced ( quote * AND")
        XCTAssertEqual(odd, [], "none of the query's terms are in the index")
        let hello = await idx.search("hello")
        XCTAssertEqual(hello, ["/a.pdf"], "the index still answers after the malformed query")
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

    func testExistingStamps() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let empty = await idx.existingStamps()
        XCTAssertTrue(empty.isEmpty)
        try await idx.upsert(path: "/a.pdf", mtime: 100, name: "a", classification: nil, body: "hello")
        try await idx.upsert(path: "/b.pdf", mtime: 200, name: "b", classification: nil, body: "world")
        let stamps = await idx.existingStamps()
        XCTAssertEqual(stamps.count, 2)
        XCTAssertEqual(stamps["/a.pdf"], ContentStamp(mtime: 100, identity: nil))
        XCTAssertEqual(stamps["/b.pdf"], ContentStamp(mtime: 200, identity: nil))
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

    /// The "Search OCR text" box matches the OCR text only (W40.fix-reader-ocr-search-names, owner's Reader
    /// session 2 row 22): a word only in the file name or the classification is not a hit, through either
    /// `search` or `searchRanked`, and Advanced Search's "Any text" (an unqualified expression) still finds both.
    func testOCRTextSearchSkipsNameAndClassification() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/body.pdf", mtime: 1, name: "report",
                             classification: nil, body: "a letter to David Riesman about the seminar")
        try await idx.upsert(path: "/Riesman to Petersen.pdf", mtime: 1, name: "Riesman to Petersen",
                             classification: nil, body: "a routine document")
        try await idx.upsert(path: "/class.pdf", mtime: 1, name: "memo",
                             classification: "Riesman papers", body: "a routine document")
        let plain = await idx.search("Riesman")
        XCTAssertEqual(plain, ["/body.pdf"])
        let ranked = await idx.searchRanked("riesm")
        XCTAssertEqual(ranked.paths, ["/body.pdf"], "the prefix term is limited to the OCR text too")
        XCTAssertNotNil(ranked.snippets["/body.pdf"])
        XCTAssertEqual(idx.ocrTextMatchExpression("cold war"), "body : (\"cold\" \"war\"*)")
        XCTAssertEqual(idx.ocrTextMatchExpression("  "), "")
        let anyText = await idx.search(expression: "\"riesman\"")
        XCTAssertEqual(Set(anyText), ["/body.pdf", "/Riesman to Petersen.pdf", "/class.pdf"])
        await idx.close()
    }

    // bm25 relevance ranking for an expression over every column (Advanced Search's "Any text"): a term in
    // name (weight 10) outranks classification (5) outranks body (1).
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
        let results = await idx.search(expression: "\"budget\"")
        XCTAssertEqual(results.count, 3)
        // bm25 with weights (body=1, class=5, name=10): name hit first, body-only hit last.
        XCTAssertEqual(results.first, "/name.pdf", "name hit (weight 10) should rank first")
        XCTAssertEqual(results.last, "/body.pdf", "body-only hit (weight 1) should rank last")
        await idx.close()
    }

    // MARK: - Prefix matching

    func testFtsMatchExpressionPrefixWildcard() {
        let idx = ContentIndex(url: URL(fileURLWithPath: "/dev/null"))
        // Multi-word: last token gets wildcard (>2 chars)
        XCTAssertEqual(idx.ftsMatchExpression("cold war bud"), "\"cold\" \"war\" \"bud\"*")
        // Single long token: gets wildcard
        XCTAssertEqual(idx.ftsMatchExpression("news"), "\"news\"*")
        // Short last token (≤2 chars): no wildcard
        XCTAssertEqual(idx.ftsMatchExpression("cold an"), "\"cold\" \"an\"")
        // Single short token: no wildcard
        XCTAssertEqual(idx.ftsMatchExpression("ab"), "\"ab\"")
        // Empty: empty
        XCTAssertEqual(idx.ftsMatchExpression(""), "")
    }

    func testPrefixMatchSearch() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil,
                             body: "the newspaper reported on the budget")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b", classification: nil,
                             body: "a newsletter was distributed")
        try await idx.upsert(path: "/c.pdf", mtime: 1, name: "c", classification: nil,
                             body: "unrelated document about taxes")
        // "news" (>2 chars) prefix-matches "newspaper" and "newsletter"
        let hits = await idx.search("news")
        XCTAssertEqual(Set(hits), ["/a.pdf", "/b.pdf"], "prefix should find both")
        // Full word still works
        let exact = await idx.search("newspaper")
        XCTAssertEqual(exact, ["/a.pdf"])
        await idx.close()
    }

    func testPrefixMatchShortTokenSkipsWildcard() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        // "an" is only in doc A as a standalone token; doc B has "analysis" but NOT "an"
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil,
                             body: "an idea was proposed")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b", classification: nil,
                             body: "analysis of the data")
        // Short token (≤2 chars): no wildcard, so "an" matches only exact token
        let hits = await idx.search("an")
        XCTAssertEqual(hits, ["/a.pdf"], "short token should not prefix-expand to 'analysis'")
        await idx.close()
    }

    // MARK: - Ranked search + keyword-in-context snippets

    /// searchRanked returns the same complete bm25-ordered paths as `search`, plus a KWIC body snippet
    /// per hit with the matched term wrapped in SearchSnippet marks.
    func testSearchRankedSnippetsHighlightMatch() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil,
                             body: "The Senate debated the defense budget for many hours that evening.")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b", classification: nil,
                             body: "A letter about the harvest and the weather.")
        let ranked = await idx.searchRanked("budget")
        let plain = await idx.search("budget")
        XCTAssertEqual(ranked.paths, ["/a.pdf"])                     // same as search()
        XCTAssertEqual(ranked.paths, plain)
        let snip = try XCTUnwrap(ranked.snippets["/a.pdf"])
        // The matched term is wrapped for the UI to emphasise; the surrounding OCR text is present.
        XCTAssertTrue(snip.contains("\(SearchSnippet.openMark)budget\(SearchSnippet.closeMark)"),
                      "matched term should be marked; got: \(snip.debugDescription)")
        let segs = SearchSnippet.segments(from: snip)
        XCTAssertTrue(SearchSnippet.hasMatch(segs))
        XCTAssertEqual(segs.first(where: { $0.isMatch })?.text.lowercased(), "budget")
        await idx.close()
    }

    /// No match → empty paths AND empty snippets (no crash).
    func testSearchRankedNoMatch() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "hello world")
        let ranked = await idx.searchRanked("nonexistentterm")
        XCTAssertTrue(ranked.paths.isEmpty)
        XCTAssertTrue(ranked.snippets.isEmpty)
        await idx.close()
    }

    /// An image-only doc (empty body) that matches on name/classification yields a path but NO snippet
    /// entry under Advanced Search's "Any text" (empty snippets are dropped, so the UI shows the row without
    /// a preview line), and is no hit at all for the OCR-text box (W40.fix-reader-ocr-search-names).
    func testSearchRankedEmptyBodyHasNoSnippet() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/scan.pdf", mtime: 1, name: "budget scan", classification: nil,
                             body: "", pageCount: 3, hasText: false, readable: true)
        let ranked = await idx.searchRanked(expression: "\"budget\"")
        XCTAssertEqual(ranked.paths, ["/scan.pdf"])          // matches on the name column
        XCTAssertNil(ranked.snippets["/scan.pdf"])           // empty body → no KWIC preview
        let ocrBox = await idx.searchRanked("budget")
        XCTAssertTrue(ocrBox.paths.isEmpty)
        await idx.close()
    }

    /// paths is complete (every match, uncapped) while snippets are bounded to snippetLimit — a broad
    /// query must not drop matches from filtering, but must not compute a fragment for every row.
    func testSearchRankedSnippetsAreBoundedButPathsAreComplete() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        let n = 50
        for i in 0..<n {
            try await idx.upsert(path: "/f\(i).pdf", mtime: 1, name: "f\(i)", classification: nil,
                                 body: "the shared commonterm appears in document number \(i)")
        }
        let ranked = await idx.searchRanked("commonterm", snippetLimit: 10)
        XCTAssertEqual(ranked.paths.count, n)                 // every match — filtering must be complete
        XCTAssertEqual(ranked.snippets.count, 10)             // snippets bounded to the top 10
        // Every path that HAS a snippet is one of the returned matches, and its snippet marks the term.
        for (path, snip) in ranked.snippets {
            XCTAssertTrue(ranked.paths.contains(path))
            XCTAssertTrue(snip.contains(SearchSnippet.openMark))
        }
        await idx.close()
    }

    /// W40.fix-reader-fts-snippet-stall: the snippet expression drops stop words but keeps the rest of
    /// the query, wildcard included, and keeps everything when nothing else is left.
    func testSnippetMatchExpressionDropsStopWordsOnly() {
        let idx = ContentIndex(url: URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(idx.ftsMatchExpression("Bureau of the Budget"), "\"Bureau\" \"of\" \"the\" \"Budget\"*")
        XCTAssertEqual(idx.snippetMatchExpression("Bureau of the Budget"), "\"Bureau\" \"Budget\"*")
        XCTAssertEqual(idx.snippetMatchExpression("Secretary OF THE, Treasury"), "\"Secretary\" \"Treasury\"*")
        XCTAssertEqual(idx.snippetMatchExpression("budget of the"), "\"budget\"")
        XCTAssertEqual(idx.snippetMatchExpression("of the"), "\"of\" \"the\"*")
        XCTAssertEqual(idx.snippetMatchExpression("  "), "")
    }

    /// The dropped words are not highlighted, the kept ones are, and the hit set is the full query's.
    func testSearchRankedSnippetHighlightsTheDistinctiveTerms() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil,
                             body: "A memorandum from the Bureau of the Budget to the Secretary.")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b", classification: nil,
                             body: "The Bureau reviewed a budget.")          // no "of"
        let ranked = await idx.searchRanked("Bureau of the Budget")
        XCTAssertEqual(ranked.paths, ["/a.pdf"])
        let snip = try XCTUnwrap(ranked.snippets["/a.pdf"])
        let marked = SearchSnippet.segments(from: snip).filter { $0.isMatch }.map { $0.text }
        XCTAssertEqual(marked, ["Bureau", "Budget"], "got: \(snip.debugDescription)")
        await idx.close()
    }

    /// Out of snippet time, every hit is still returned; only the previews are missing.
    func testSearchRankedSnippetBudgetKeepsEveryPath() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        for i in 0..<5 {
            try await idx.upsert(path: "/f\(i).pdf", mtime: 1, name: "f\(i)", classification: nil,
                                 body: "commonterm in document \(i)")
        }
        let ranked = await idx.searchRanked("commonterm", snippetBudget: 0)
        XCTAssertEqual(ranked.paths.count, 5)
        XCTAssertTrue(ranked.snippets.isEmpty)
        await idx.close()
    }

    /// W40.fix-reader-fts-snippets: the hits the search left without a preview get one afterwards, by path.
    /// A path with no body text or no row is answered (counted as attempted) with no snippet, so the list
    /// does not ask for it again; out of time, nothing is attempted and the caller asks again later.
    func testSnippetsForPathsFillWhatTheSearchLeftOut() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        for i in 0..<5 {
            try await idx.upsert(path: "/f\(i).pdf", mtime: 1, name: "f\(i)", classification: nil,
                                 body: "commonterm in document \(i)")
        }
        try await idx.upsert(path: "/commonterm-empty.pdf", mtime: 1, name: "commonterm empty",
                             classification: nil, body: "")   // the word in its name only, no body to quote
        let ranked = await idx.searchRanked("commonterm", snippetBudget: 0)
        XCTAssertEqual(ranked.paths.count, 5, "a name-only match is no OCR-text hit")
        XCTAssertTrue(ranked.snippets.isEmpty, "precondition: the search gave no previews")

        let asked = ranked.paths + ["/commonterm-empty.pdf", "/not-indexed.pdf"]
        let filled = await idx.snippets("commonterm", for: asked)
        XCTAssertEqual(filled.attempted, asked.count)
        XCTAssertEqual(Set(filled.snippets.keys), Set((0..<5).map { "/f\($0).pdf" }))
        for snip in filled.snippets.values {
            XCTAssertTrue(SearchSnippet.hasMatch(SearchSnippet.segments(from: snip)), snip)
        }
        // A query of stop words alone is quoted by scanning the body, not by `snippet()`.
        try await idx.upsert(path: "/memo.pdf", mtime: 1, name: "memo", classification: nil,
                             body: "Notes on the meeting of the Board, held at the Treasury.")
        let stop = await idx.snippets("of the", for: ["/memo.pdf"])
        XCTAssertEqual(stop.attempted, 1)
        let marked = try XCTUnwrap(stop.snippets["/memo.pdf"])
        XCTAssertEqual(SearchSnippet.segments(from: marked).filter { $0.isMatch }.map { $0.text },
                       ["the", "of", "the", "the"], marked.debugDescription)

        let outOfTime = await idx.snippets("commonterm", for: asked, budget: 0)
        XCTAssertEqual(outOfTime.attempted, 0)
        XCTAssertTrue(outOfTime.snippets.isEmpty)
        await idx.close()
    }

    func testReOCRHeaderThroughReaderExtractorKeepsFullSearchText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderReOCR-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = "Extracted text.\nKind: filename.jpg\nAtlas · Qwen fp8 · 7 November 2026\nClassification: Document Start\nKind: forms\nDocument date: 1957\nSent with: 1958\n\nReport from the harbour."
        XCTAssertTrue(TestPDFBuilder.write(pages: ["Scan text layer", header], to: url))
        let before = try Data(contentsOf: url)
        let content = try XCTUnwrap(PDFTextExtractor.extract(url))
        XCTAssertEqual(content.textPages.first?.header?.kind, .forms)
        XCTAssertEqual(content.textPages.first?.header?.provenance?.provider, "Atlas")
        XCTAssertEqual(content.textPages.first?.header?.documentDate, "1957")
        XCTAssertEqual(content.classification, "Document Start")
        XCTAssertEqual(content.strippedBody, "Report from the harbour.")
        XCTAssertTrue(content.fullBody.contains("Scan text layer"))
        XCTAssertTrue(content.fullBody.contains("Kind: forms"))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// W44.reocr-header-longname: a filename read back as several lines still shows its provider.
    func testLongFilenameOverSeveralLinesKeepsTheProviderInTheReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderLongName-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let name = "Herrnstein_Papers_Box_12_\nFolder_3_Correspondence_\nwith_the_Dean_1952_\nIMG_0042.jpg"
        let header = "Extracted text.\n\(name)\nAtlas · Qwen fp8 · 7 November 2026\nKind: typewritten\n\nDear Dean,"
        XCTAssertTrue(TestPDFBuilder.write(pages: ["Scan text layer", header], to: url))
        let content = try XCTUnwrap(PDFTextExtractor.extract(url))
        let parsed = try XCTUnwrap(content.textPages.first?.header)
        XCTAssertEqual(parsed.provenance?.provider, "Atlas")
        XCTAssertEqual(parsed.kind, .typewritten)
        XCTAssertEqual(parsed.originalFilename?.replacingOccurrences(of: "\n", with: ""),
                       name.replacingOccurrences(of: "\n", with: ""))
        XCTAssertEqual(content.strippedBody, "Dear Dean,")
    }

    func testClassificationParsing() {
        let page2 = "Extracted text.\n00023 IMG — Brown.jpg\nGemini · Gemini 2.5 · 19 June 2026\nClassification: Document Start\nINTRODUCTION"
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page2), "Document Start")
        // Only the app-format header carries it (W40.fix-core-classification-from-body).
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "Classification: Box"))
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "no classification line here"))
    }

    // MARK: - Pruning (deletePaths + allPaths)

    /// deletePaths removes the target rows and leaves others intact; counts + search reflect it.
    func testDeletePathsRemovesTargetOnly() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/root/a.pdf", mtime: 1, name: "a", classification: nil, body: "alpha text")
        try await idx.upsert(path: "/root/b.pdf", mtime: 1, name: "b", classification: nil, body: "bravo text")
        try await idx.upsert(path: "/root/c.pdf", mtime: 1, name: "c", classification: nil, body: "charlie text")
        try await idx.deletePaths(["/root/c.pdf"])
        let count = await idx.indexedCount()
        XCTAssertEqual(count, 2)
        let alpha = await idx.search("alpha")
        XCTAssertEqual(alpha, ["/root/a.pdf"])
        let charlie = await idx.search("charlie")
        XCTAssertTrue(charlie.isEmpty, "deleted path must not appear in search")
        await idx.close()
    }

    /// deletePaths with an empty array is a no-op (no crash, no deletion).
    func testDeletePathsEmptyIsNoop() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "hello")
        try await idx.deletePaths([])
        let count = await idx.indexedCount()
        XCTAssertEqual(count, 1)
        await idx.close()
    }

    /// allPaths returns the full set of indexed paths.
    func testAllPaths() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "hello")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b", classification: nil, body: "world")
        let paths = await idx.allPaths()
        XCTAssertEqual(paths, ["/a.pdf", "/b.pdf"])
        await idx.close()
    }

    /// deletePaths on a nonexistent path is a silent no-op (no crash, count unchanged).
    func testDeletePathsNonexistentIsSilent() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "a", classification: nil, body: "hello")
        try await idx.deletePaths(["/nonexistent.pdf"])
        let count = await idx.indexedCount()
        XCTAssertEqual(count, 1)
        await idx.close()
    }

    /// After pruning, needsAttentionCount drops to the live set (stale rows gone).
    func testPruneDropsCorpusWideCount() async throws {
        let (idx, url) = makeIndex(); defer { try? FileManager.default.removeItem(at: url) }
        try await idx.open()
        try await idx.upsert(path: "/root/good.pdf", mtime: 1, name: "good", classification: nil,
                             body: "ok", pageCount: 2, hasText: true, readable: true)
        try await idx.upsert(path: "/root/stale.pdf", mtime: 1, name: "stale", classification: nil,
                             body: "", pageCount: 0, hasText: false, readable: false)
        let before = await idx.needsAttentionCount()
        XCTAssertEqual(before, 1)
        try await idx.deletePaths(["/root/stale.pdf"])
        let after = await idx.needsAttentionCount()
        XCTAssertEqual(after, 0, "corpus-wide count should drop after pruning the stale row")
        await idx.close()
    }
}
