import XCTest
@testable import ArchiveReader
import ArchiveCore

/// W40.reader-advanced-search: the rule tree, its in-memory test, and the text rules through a real FTS5 index.
final class AdvancedSearchTests: XCTestCase {

    private func file(_ path: String, _ tags: [String], label: Int? = nil) -> ArchiveFile {
        let url = URL(fileURLWithPath: path)
        return ArchiveFile(url: url, name: url.lastPathComponent, fileType: "PDF",
                           tags: DocumentTags.parse(raw: tags, labelNumber: label), contentModified: nil)
    }

    private func rule(_ field: RuleField, _ op: RuleOperator? = nil, _ edit: (inout SearchRule) -> Void = { _ in })
        -> SearchRule {
        var r = SearchRule(field: field, op: op); edit(&r); return r
    }

    private func search(_ combine: RuleCombine, _ rules: SearchRule...) -> AdvancedSearch {
        AdvancedSearch(combine: combine, rules: rules)
    }

    // MARK: In-memory rules

    func testStarterRowsMatchEverythingUntilFilledIn() {
        let s = AdvancedSearch.starter
        XCTAssertFalse(s.isActive)
        XCTAssertEqual(s.rules.map(\.field), [.ocrText, .tags, .date])
        XCTAssertTrue(s.matches(file("/c/a.pdf", ["Unread"]), RuleContext()))
        var any = s; any.combine = .any
        XCTAssertTrue(any.matches(file("/c/a.pdf", ["Unread"]), RuleContext()))
    }

    func testTagsAllAnyAndNoneByTagIdentity() {
        let both = file("/c/both.pdf", ["Treasury", "Press"])
        let treasury = file("/c/t.pdf", ["treasury"])
        let neither = file("/c/n.pdf", ["Budget"])
        let all = search(.all, rule(.tags, .hasAll) { $0.tags = ["Treasury", "Press"] })
        let any = search(.all, rule(.tags, .hasAny) { $0.tags = ["Treasury", "Press"] })
        let none = search(.all, rule(.tags, .hasNone) { $0.tags = ["press"] })
        XCTAssertEqual([both, treasury, neither].map { all.matches($0, RuleContext()) }, [true, false, false])
        XCTAssertEqual([both, treasury, neither].map { any.matches($0, RuleContext()) }, [true, true, false])
        XCTAssertEqual([both, treasury, neither].map { none.matches($0, RuleContext()) }, [false, true, true])
    }

    func testAllVersusAnyAtTheTop() {
        let unreadQ3 = file("/c/a.pdf", ["Unread", "Q3"])
        let readQ1 = file("/c/b.pdf", ["Read", "Q1"])
        let unreadQ1 = file("/c/c.pdf", ["Unread", "Q1"])
        let unread = rule(.readState) { $0.read = .unread }
        let q3 = rule(.quality) { $0.qualities = [3] }
        let all = search(.all, unread, q3), any = search(.any, unread, q3)
        XCTAssertEqual([unreadQ3, readQ1, unreadQ1].map { all.matches($0, RuleContext()) }, [true, false, false])
        XCTAssertEqual([unreadQ3, readQ1, unreadQ1].map { any.matches($0, RuleContext()) }, [true, false, true])
    }

    func testQualityNoneAndIsNot() {
        let q2 = file("/c/a.pdf", ["Q2"]), unrated = file("/c/b.pdf", ["Unread"])
        let noQuality = search(.all, rule(.quality) { $0.qualities = [0] })
        XCTAssertFalse(noQuality.matches(q2, RuleContext()))
        XCTAssertTrue(noQuality.matches(unrated, RuleContext()))
        let notTwo = search(.all, rule(.quality, .isNot) { $0.qualities = [2] })
        XCTAssertFalse(notTwo.matches(q2, RuleContext()))
        XCTAssertTrue(notTwo.matches(unrated, RuleContext()))
    }

    func testDatesByPrecisionRoleAndUndated() {
        let june81 = file("/c/a.pdf", ["1981", "06 June", "Day 30"])
        let y83 = file("/c/b.pdf", ["1983"])
        let sent82 = file("/c/c.pdf", ["1975", "Sent With 1982-02"])
        let undated = file("/c/d.pdf", ["Unread"])
        let files = [june81, y83, sent82, undated]
        func hits(_ r: SearchRule) -> [Bool] { files.map { search(.all, r).matches($0, RuleContext()) } }

        XCTAssertEqual(hits(rule(.date, .between) { $0.text = "1981"; $0.text2 = "1982" }), [true, false, true, false])
        XCTAssertEqual(hits(rule(.date, .between) { $0.text = "1981-07"; $0.text2 = "1983" }),
                       [false, true, true, false])
        XCTAssertEqual(hits(rule(.date, .before) { $0.text = "1981-6-30" }), [true, false, true, false])
        XCTAssertEqual(hits(rule(.date, .after) { $0.text = "1982" }), [false, true, true, false])
        XCTAssertEqual(hits(rule(.date, .after) { $0.text = "1982"; $0.dateRole = .own }), [false, true, false, false])
        XCTAssertEqual(hits(rule(.date, .between) { $0.text = "1980s"; $0.dateRole = .sentWith }),
                       [false, false, true, false])
        XCTAssertEqual(hits(rule(.date, .undated)), [false, false, false, true])
        XCTAssertEqual(hits(rule(.date, .undated) { $0.dateRole = .sentWith }), [true, true, false, true])
        // An unreadable date leaves the rule inactive, matching everything rather than nothing.
        XCTAssertFalse(rule(.date, .between) { $0.text = "June" }.isActive)
        XCTAssertEqual(hits(rule(.date, .between) { $0.text = "1982-13" }), [true, true, true, true])
    }

    func testFolderRuleIsOnAComponentBoundary() {
        let inBox = file("/c/Box 12/a.pdf", []), sibling = file("/c/Box 123/b.pdf", [])
        let inside = search(.all, rule(.folder) { $0.text = "/c/Box 12" })
        XCTAssertTrue(inside.matches(inBox, RuleContext()))
        XCTAssertFalse(inside.matches(sibling, RuleContext()))
        let notInside = search(.all, rule(.folder, .isNot) { $0.text = "/c/Box 12/" })
        XCTAssertFalse(notInside.matches(inBox, RuleContext()))
        XCTAssertTrue(notInside.matches(sibling, RuleContext()))
    }

    func testFileNameOperators() {
        let f = file("/c/Budget Memo 1981.pdf", [])
        func hit(_ op: RuleOperator, _ t: String) -> Bool { search(.all, rule(.fileName, op) { $0.text = t }).matches(f, RuleContext()) }
        XCTAssertTrue(hit(.contains, "memo"))
        XCTAssertFalse(hit(.doesNotContain, "memo"))
        XCTAssertTrue(hit(.beginsWith, "budget"))
        XCTAssertFalse(hit(.beginsWith, "memo"))
        XCTAssertTrue(hit(.endsWith, "1981.PDF"))
    }

    func testContextRulesAndGroups() {
        let a = file("/c/a.pdf", ["Unread"]), b = file("/c/b.pdf", ["Read"])
        let ctx = RuleContext(needsAttention: ["/c/a.pdf"], flagged: ["/c/b.pdf"])
        XCTAssertTrue(search(.all, rule(.needsAttention)).matches(a, ctx))
        XCTAssertFalse(search(.all, rule(.needsAttention)).matches(b, ctx))
        XCTAssertTrue(search(.all, rule(.flagged, .isNot)).matches(a, ctx))
        // read AND (flagged OR needs attention)
        let g = search(.all, rule(.readState) { $0.read = .read },
                       .group(.any, [rule(.flagged), rule(.needsAttention)]))
        XCTAssertFalse(g.matches(a, ctx))
        XCTAssertTrue(g.matches(b, ctx))
        XCTAssertFalse(SearchRule.group(.any, [rule(.tags)]).isActive)
    }

    func testATextRuleWaitsForItsHits() {
        let r = rule(.text) { $0.text = "budget" }
        let s = search(.all, r, rule(.readState) { $0.read = .unread })
        let f = file("/c/a.pdf", ["Unread"])
        XCTAssertTrue(s.matches(f, RuleContext()))                                  // not yet answered: skipped
        XCTAssertFalse(s.matches(f, RuleContext(textHits: [r.id: []])))
        XCTAssertTrue(s.matches(f, RuleContext(textHits: [r.id: ["/c/a.pdf"]])))
        let none = rule(.text, .noWords) { $0.text = "draft" }
        XCTAssertFalse(search(.all, none).matches(f, RuleContext(textHits: [none.id: ["/c/a.pdf"]])))
        XCTAssertTrue(search(.all, none).matches(f, RuleContext(textHits: [none.id: []])))
    }

    // MARK: From the filter bar

    func testFilterBarStateBecomesEquivalentRules() {
        var f = LibraryFilter(subjects: ["Press", "Treasury"], subjectCombine: .any, qualities: [2, 3], read: .unread)
        f.pathPrefix = "/c/Box 12"; f.dateFromYear = 1981; f.searchText = "memo"; f.ambiguousDatesOnly = true
        let s = AdvancedSearch(filter: f, fullTextQuery: "  balanced budget ")
        XCTAssertEqual(s.combine, .all)
        XCTAssertEqual(s.rules.map(\.field), [.text, .folder, .tags, .quality, .readState, .date, .fileName, .ambiguousDate])
        XCTAssertEqual(s.rules[0].text, "balanced budget*")   // the Find box's prefix last word
        XCTAssertEqual(s.rules[2].op, .hasAny)
        XCTAssertEqual(s.rules[5].dateBounds, DateRangeFilter(lower: 19_810_000, upper: nil))

        let files = [file("/c/Box 12/memo.pdf", ["Unread", "Q2", "Press", "1982"]),
                     file("/c/Box 12/memo2.pdf", ["Unread", "Q4", "Press", "1982"]),
                     file("/c/Box 13/memo.pdf", ["Unread", "Q2", "Press", "1982"])]
        var plain = f; plain.ambiguousDatesOnly = false
        let rules = AdvancedSearch(filter: plain, fullTextQuery: "")
        XCTAssertEqual(files.map { rules.matches($0, RuleContext()) }, files.map(plain.matches))
    }

    func testNarrowingKeepsAnAnySearchWhole() {
        let base = search(.any, rule(.flagged), rule(.needsAttention))
        let user = search(.all, rule(.readState) { $0.read = .unread })
        let n = base.narrowed(by: user)
        XCTAssertEqual(n.combine, .all)
        XCTAssertEqual(n.rules.map(\.field), [.group, .readState])
        XCTAssertEqual(n.rules[0].combine, .any)
        XCTAssertEqual(base.narrowed(by: AdvancedSearch()), base)
        XCTAssertEqual(AdvancedSearch.starter.narrowed(by: user), user)
    }

    func testFoldersOutsideTheRootAreDropped() {
        let s = search(.all, rule(.folder) { $0.text = "/old/Box" },
                       .group(.any, [rule(.folder) { $0.text = "/root/Box" }, rule(.folder) { $0.text = "/elsewhere" }]))
        let (clean, dropped) = s.droppingFolders(outside: "/root")
        XCTAssertTrue(dropped)
        XCTAssertEqual(clean.rules.count, 1)
        XCTAssertEqual(clean.rules[0].children.map(\.text), ["/root/Box"])
        XCTAssertFalse(search(.all, rule(.folder) { $0.text = "/root/x" }).droppingFolders(outside: "/root").dropped)
    }

    func testCodableRoundTripAndLenientDecode() throws {
        let s = search(.any, rule(.tags, .hasNone) { $0.tags = ["Press"] },
                       .group(.all, [rule(.date, .before) { $0.text = "1981"; $0.dateRole = .own }]))
        let back = try JSONDecoder().decode(AdvancedSearch.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let bare = try JSONDecoder().decode(SearchRule.self, from: Data(#"{"field":"quality"}"#.utf8))
        XCTAssertEqual(bare.op, .is)
        XCTAssertTrue(bare.qualities.isEmpty)
    }

    // MARK: Text rules through FTS5

    func testFTSExpressionsAreQuotedAndShaped() {
        XCTAssertEqual(AdvancedSearch.ftsExpression(op: .allWords, text: "budget  deficit", column: nil),
                       #"("budget" "deficit")"#)
        XCTAssertEqual(AdvancedSearch.ftsExpression(op: .phrase, text: "\"balanced budget\"", column: nil),
                       #""balanced budget""#)
        XCTAssertEqual(AdvancedSearch.ftsExpression(op: .anyWords, text: "Stockman Darman", column: "body"),
                       #"body : ("Stockman" OR "Darman")"#)
        XCTAssertEqual(AdvancedSearch.ftsExpression(op: .allWords, text: "news* a\"b", column: nil),
                       #"("news"* "a""b")"#)
        XCTAssertEqual(AdvancedSearch.ftsExpression(op: .allWords, text: "NOT", column: nil), #""NOT""#)
        XCTAssertNil(AdvancedSearch.ftsExpression(op: .allWords, text: " \" * ", column: nil))
    }

    func testTextRulesAgainstARealIndex() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("as-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let idx = ContentIndex(url: url)
        try await idx.open()
        try await idx.upsert(path: "/a.pdf", mtime: 1, name: "budget.pdf", classification: nil,
                             body: "A balanced budget was proposed by Stockman.")
        try await idx.upsert(path: "/b.pdf", mtime: 1, name: "b.pdf", classification: nil,
                             body: "The budget is not balanced; Darman draft.")
        try await idx.upsert(path: "/c.pdf", mtime: 1, name: "c.pdf", classification: nil,
                             body: "Newspaper clippings about taxes.")
        func hits(_ op: RuleOperator, _ text: String, ocrOnly: Bool = false) async -> Set<String> {
            let r = rule(ocrOnly ? .ocrText : .text, op) { $0.text = text }
            return Set(await idx.search(expression: r.ftsExpression!))
        }
        let phrase = await hits(.phrase, "balanced budget")
        XCTAssertEqual(phrase, ["/a.pdf"])
        let all = await hits(.allWords, "budget balanced")
        XCTAssertEqual(all, ["/a.pdf", "/b.pdf"])
        let any = await hits(.anyWords, "Stockman taxes")
        XCTAssertEqual(any, ["/a.pdf", "/c.pdf"])
        let draft = await hits(.noWords, "draft OR")   // the files a "none of" rule leaves out
        XCTAssertEqual(draft, ["/b.pdf"])
        let prefix = await hits(.allWords, "news*")
        XCTAssertEqual(prefix, ["/c.pdf"])
        let nameEverywhere = await hits(.allWords, "budget")
        XCTAssertEqual(nameEverywhere, ["/a.pdf", "/b.pdf"])
        let ocrOnly = await hits(.allWords, "pdf", ocrOnly: true)   // "pdf" is only in the names
        XCTAssertEqual(ocrOnly, [])
        let named = await hits(.allWords, "pdf")
        XCTAssertEqual(named, ["/a.pdf", "/b.pdf", "/c.pdf"])

        // The whole search: OCR text has "budget", none of "draft" → only a.
        let budget = rule(.ocrText) { $0.text = "budget" }, noDraft = rule(.text, .noWords) { $0.text = "draft" }
        let s = search(.all, budget, noDraft)
        var ctx = RuleContext()
        for r in s.textRules { ctx.textHits[r.id] = Set(await idx.search(expression: r.ftsExpression!)) }
        let files = ["/a.pdf", "/b.pdf", "/c.pdf"].map { file($0, []) }
        XCTAssertEqual(files.filter { s.matches($0, ctx) }.map(\.path), ["/a.pdf"])
        let ranked = await idx.searchRanked(expression: s.rankingExpression!)
        XCTAssertEqual(Set(ranked.paths), ["/a.pdf", "/b.pdf"])
        XCTAssertNotNil(ranked.snippets["/a.pdf"])
        await idx.close()
    }
}
