import XCTest
@testable import ArchiveNotes

final class NotesFilterTests: XCTestCase {

    // MARK: - Defaults

    func testDefaultFilterIsEmpty() {
        let filter = NotesFilter()
        XCTAssertTrue(filter.isEmpty)
        XCTAssertEqual(filter.searchText, "")
        XCTAssertEqual(filter.tags, [])
        XCTAssertEqual(filter.tagCombine, .all)
        XCTAssertEqual(filter.kind, .both)
        XCTAssertTrue(filter.qualities.isEmpty)
        XCTAssertNil(filter.dateFrom)
        XCTAssertNil(filter.dateTo)
        XCTAssertNil(filter.folderId)
    }

    func testNonEmptySearchText() {
        var filter = NotesFilter()
        filter.searchText = "hello"
        XCTAssertFalse(filter.isEmpty)
    }

    func testNonEmptyTags() {
        var filter = NotesFilter()
        filter.tags = ["History"]
        XCTAssertFalse(filter.isEmpty)
    }

    func testKindFilterNotBoth() {
        var filter = NotesFilter()
        filter.kind = .notes
        XCTAssertFalse(filter.isEmpty)
    }

    func testNonEmptyQualities() {
        var filter = NotesFilter()
        filter.qualities = [2, 3]
        XCTAssertFalse(filter.isEmpty)
    }

    func testDateFromMakesNonEmpty() {
        var filter = NotesFilter()
        filter.dateFrom = 19680000
        XCTAssertFalse(filter.isEmpty)
    }

    func testFolderIdMakesNonEmpty() {
        var filter = NotesFilter()
        filter.folderId = UUID()
        XCTAssertFalse(filter.isEmpty)
    }

    // MARK: - Equatable

    func testEqualFilters() {
        let a = NotesFilter()
        let b = NotesFilter()
        XCTAssertEqual(a, b)
    }

    func testUnequalFilters() {
        var a = NotesFilter()
        a.searchText = "test"
        let b = NotesFilter()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let folderId = UUID()
        var filter = NotesFilter()
        filter.searchText = "silicon valley"
        filter.tags = ["History", "Tech"]
        filter.tagCombine = .any
        filter.kind = .notes
        filter.qualities = [1, 2, 3]
        filter.dateFrom = 19600000
        filter.dateTo = 19691231
        filter.folderId = folderId

        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: data)

        XCTAssertEqual(decoded, filter)
        XCTAssertEqual(decoded.searchText, "silicon valley")
        XCTAssertEqual(decoded.tags, ["History", "Tech"])
        XCTAssertEqual(decoded.tagCombine, .any)
        XCTAssertEqual(decoded.kind, .notes)
        XCTAssertEqual(decoded.qualities, [1, 2, 3])
        XCTAssertEqual(decoded.dateFrom, 19600000)
        XCTAssertEqual(decoded.dateTo, 19691231)
        XCTAssertEqual(decoded.folderId, folderId)
    }

    func testDefaultFilterCodableRoundTrip() throws {
        let filter = NotesFilter()
        let data = try JSONEncoder().encode(filter)
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: data)
        XCTAssertEqual(decoded, filter)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - TagCombine / KindFilter raw values

    func testTagCombineRawValues() {
        XCTAssertEqual(TagCombine.all.rawValue, "all")
        XCTAssertEqual(TagCombine.any.rawValue, "any")
    }

    func testKindFilterRawValues() {
        XCTAssertEqual(KindFilter.notes.rawValue, "notes")
        XCTAssertEqual(KindFilter.extracts.rawValue, "extracts")
        XCTAssertEqual(KindFilter.both.rawValue, "both")
    }

    // MARK: - matches(_:folderItemIDs:)

    private func item(_ title: String = "Untitled", kind: Item.Kind = .note, sortDate: Int? = nil,
                      quality: Int? = nil, tags: [String] = [], id: UUID = UUID()) -> ItemSummary {
        let t = Date(timeIntervalSince1970: 0)
        return ItemSummary(id: id, title: title, kind: kind, date: nil, datePrecision: nil,
                           dateUncertain: false, authors: [], sortDate: sortDate, quality: quality,
                           created: t, modified: t, mtime: 0, managedTags: tags)
    }

    func testEmptyFilterMatchesEverything() {
        let f = NotesFilter()
        XCTAssertTrue(f.matches(item("a", kind: .note), folderItemIDs: nil))
        XCTAssertTrue(f.matches(item("b", kind: .extract, sortDate: nil, quality: nil), folderItemIDs: nil))
    }

    func testKindMatch() {
        var f = NotesFilter(); f.kind = .notes
        XCTAssertTrue(f.matches(item(kind: .note), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item(kind: .extract), folderItemIDs: nil))
        f.kind = .extracts
        XCTAssertFalse(f.matches(item(kind: .note), folderItemIDs: nil))
        XCTAssertTrue(f.matches(item(kind: .extract), folderItemIDs: nil))
    }

    func testQualityMatch() {
        var f = NotesFilter(); f.qualities = [2, 3]
        XCTAssertTrue(f.matches(item(quality: 3), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item(quality: 1), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item(quality: nil), folderItemIDs: nil))   // undated quality excluded
    }

    func testDateRangeMatch() {
        var f = NotesFilter(); f.dateFrom = 19700000; f.dateTo = 19801231
        XCTAssertTrue(f.matches(item(sortDate: 19700000), folderItemIDs: nil))   // lower bound, year-only
        XCTAssertTrue(f.matches(item(sortDate: 19750615), folderItemIDs: nil))
        XCTAssertTrue(f.matches(item(sortDate: 19801231), folderItemIDs: nil))   // upper bound, inclusive
        XCTAssertFalse(f.matches(item(sortDate: 19691231), folderItemIDs: nil))  // before
        XCTAssertFalse(f.matches(item(sortDate: 19810101), folderItemIDs: nil))  // after
        XCTAssertFalse(f.matches(item(sortDate: nil), folderItemIDs: nil))       // undated excluded
    }

    func testDateRangeOpenEnded() {
        var f = NotesFilter(); f.dateFrom = 19700000   // "from 1970 onward"
        XCTAssertTrue(f.matches(item(sortDate: 20000000), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item(sortDate: 19600000), folderItemIDs: nil))
    }

    func testTagsAllVsAny() {
        var f = NotesFilter(); f.tags = ["History", "Tech"]; f.tagCombine = .all
        XCTAssertTrue(f.matches(item(tags: ["History", "Tech", "Misc"]), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item(tags: ["History"]), folderItemIDs: nil))
        f.tagCombine = .any
        XCTAssertTrue(f.matches(item(tags: ["History"]), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item(tags: ["Misc"]), folderItemIDs: nil))
    }

    func testTitleSubstringCaseInsensitive() {
        var f = NotesFilter(); f.searchText = "brown"
        XCTAssertTrue(f.matches(item("Jerry Brown papers"), folderItemIDs: nil))
        XCTAssertTrue(f.matches(item("BROWN v Board"), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item("Reagan memo"), folderItemIDs: nil))
    }

    func testFolderMembershipScope() {
        let inScope = UUID(), outOfScope = UUID()
        var f = NotesFilter(); f.folderId = UUID()
        let set: Set<UUID> = [inScope]
        XCTAssertTrue(f.matches(item(id: inScope), folderItemIDs: set))
        XCTAssertFalse(f.matches(item(id: outOfScope), folderItemIDs: set))
        // folderId set but no resolved membership set → nothing matches (defensive).
        XCTAssertFalse(f.matches(item(id: inScope), folderItemIDs: nil))
    }

    func testFacetsCombineWithAND() {
        var f = NotesFilter(); f.kind = .notes; f.qualities = [3]; f.searchText = "war"
        XCTAssertTrue(f.matches(item("The war years", kind: .note, quality: 3), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item("The war years", kind: .extract, quality: 3), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item("The war years", kind: .note, quality: 2), folderItemIDs: nil))
        XCTAssertFalse(f.matches(item("Peace times", kind: .note, quality: 3), folderItemIDs: nil))
    }

    // MARK: - effective(base:user:)

    func testEffectiveUserWinsElseBase() {
        var base = NotesFilter(); base.kind = .extracts; base.qualities = [3]; base.searchText = "base"
        base.dateFrom = 19000000; base.folderId = UUID()
        var user = NotesFilter(); user.kind = .both; user.searchText = ""   // both/blank → inherit base
        var eff = NotesFilter.effective(base: base, user: user)
        XCTAssertEqual(eff.kind, .extracts)
        XCTAssertEqual(eff.qualities, [3])
        XCTAssertEqual(eff.searchText, "base")
        XCTAssertEqual(eff.dateFrom, 19000000)
        XCTAssertEqual(eff.folderId, base.folderId)

        user.kind = .notes; user.qualities = [1]; user.searchText = "user"; user.dateFrom = 20000000
        eff = NotesFilter.effective(base: base, user: user)
        XCTAssertEqual(eff.kind, .notes)            // user wins
        XCTAssertEqual(eff.qualities, [1])
        XCTAssertEqual(eff.searchText, "user")
        XCTAssertEqual(eff.dateFrom, 20000000)
    }

    func testEffectiveTagsUnion() {
        var base = NotesFilter(); base.tags = ["A", "B"]
        var user = NotesFilter(); user.tags = ["B", "C"]
        let eff = NotesFilter.effective(base: base, user: user)
        XCTAssertEqual(Set(eff.tags), ["A", "B", "C"])
    }

    // MARK: - Tolerant decode (older/partial smart-folder JSON)

    func testTolerantDecodePartialJSON() throws {
        // A smart folder persisted before some fields existed — only `tags` present.
        let json = #"{"tags":["History"]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: json)
        XCTAssertEqual(decoded.tags, ["History"])
        XCTAssertEqual(decoded.kind, .both)         // defaulted
        XCTAssertEqual(decoded.tagCombine, .all)    // defaulted
        XCTAssertEqual(decoded.searchText, "")
        XCTAssertNil(decoded.dateFrom)
    }

    func testTolerantDecodeEmptyObject() throws {
        let decoded = try JSONDecoder().decode(NotesFilter.self, from: "{}".data(using: .utf8)!)
        XCTAssertTrue(decoded.isEmpty)
    }
}
