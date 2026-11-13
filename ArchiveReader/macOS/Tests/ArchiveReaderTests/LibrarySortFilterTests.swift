import XCTest
@testable import ArchiveReader
import ArchiveCore

final class LibrarySortFilterTests: XCTestCase {

    private func file(_ name: String, _ tags: [String], label: Int? = nil, type: String = "PDF") -> ArchiveFile {
        ArchiveFile(url: URL(fileURLWithPath: "/corpus/\(name)"), name: name, fileType: type,
                    tags: DocumentTags.parse(raw: tags, labelNumber: label), contentModified: nil)
    }

    // MARK: Filtering

    func testReadFilterTriState() {
        let unread = file("a", ["Unread", "1980"])
        let read = file("b", ["Read", "1980"])
        let marker = file("c", ["Red"], label: 6)   // no read-state token

        XCTAssertTrue(LibraryFilter(read: .unread).matches(unread))
        XCTAssertFalse(LibraryFilter(read: .unread).matches(read))
        XCTAssertTrue(LibraryFilter(read: .read).matches(read))
        XCTAssertTrue(LibraryFilter(read: .noReadState).matches(marker))
        XCTAssertFalse(LibraryFilter(read: .noReadState).matches(unread))
        XCTAssertTrue(LibraryFilter(read: .all).matches(marker))
    }

    func testQualityFilterExcludesUnrated() {
        let q3 = file("a", ["Unread", "Q3", "1980"])
        let q2 = file("b", ["Unread", "Q2", "1980"])
        let none = file("c", ["Unread", "1980"])
        let f = LibraryFilter(qualities: [3])
        XCTAssertTrue(f.matches(q3))
        XCTAssertFalse(f.matches(q2))
        XCTAssertFalse(f.matches(none))
    }

    func testPathPrefixMatchesOnComponentBoundary() {
        let inFolder = file("Brown/00001.pdf", ["Unread"])        // /corpus/Brown/00001.pdf
        let sibling  = file("Brown2/00002.pdf", ["Unread"])       // /corpus/Brown2/… — must NOT match
        let deeper   = file("Brown/sub/00003.pdf", ["Unread"])    // nested — matches
        var f = LibraryFilter(); f.pathPrefix = "/corpus/Brown"
        XCTAssertTrue(f.matches(inFolder))
        XCTAssertTrue(f.matches(deeper))
        XCTAssertFalse(f.matches(sibling))          // boundary: "Brown" is not a prefix of "Brown2"
        XCTAssertTrue(f.isActive)
        f.pathPrefix = nil
        XCTAssertTrue(f.matches(sibling))           // nil = whole root
        XCTAssertFalse(f.isActive)
        f.pathPrefix = "/corpus/Brown/"             // trailing slash tolerated
        XCTAssertTrue(f.matches(inFolder))
        XCTAssertFalse(f.matches(sibling))
    }

    /// The bar's tags all match; matching any of them is an Advanced Search rule (W40.reader-tag-any-drop), which
    /// finds what the bar's old Any did.
    func testTagFilterMatchesAllAndTheAnyRuleMatchesAny() {
        let both = file("a", ["Jerry Brown", "Economics", "1980", "Unread"])
        let one = file("b", ["Jerry Brown", "1980", "Unread"])
        let neither = file("c", ["Reagan", "1980", "Unread"])
        let and = LibraryFilter(subjects: ["Jerry Brown", "Economics"])
        XCTAssertTrue(and.matches(both));  XCTAssertFalse(and.matches(one))
        var r = SearchRule(field: .tags, op: .hasAny); r.tags = ["Jerry Brown", "Economics"]
        let or = AdvancedSearch(combine: .all, rules: [r])
        XCTAssertEqual([both, one, neither].map { or.matches($0, RuleContext()) }, [true, true, false])
    }

    /// Tags that differ only in case are one tag (W40.fix-tags-case-insensitive).
    func testTagFilterMatchesEveryCaseOfATag() {
        let upper = file("a", ["Lincoln", "Grant", "1862"])
        let lower = file("b", ["lincoln", "1862"])
        let neither = file("c", ["Lincolnshire", "1862"])
        let and = LibraryFilter(subjects: ["LINCOLN", "grant"])
        XCTAssertTrue(and.matches(upper)); XCTAssertFalse(and.matches(lower)); XCTAssertFalse(and.matches(neither))
        var r = SearchRule(field: .tags, op: .hasAny); r.tags = ["LINCOLN", "grant"]
        let or = AdvancedSearch(combine: .all, rules: [r])
        XCTAssertEqual([upper, lower, neither].map { or.matches($0, RuleContext()) }, [true, true, false])

        var f = LibraryFilter(subjects: ["lincoln"])
        XCTAssertTrue(f.hasSubject("Lincoln"))
        f.insertSubject("LINCOLN")
        XCTAssertEqual(f.subjects, ["lincoln"], "a case variant is the tag already in the filter")
        f.subjects.insert("Lincoln")
        f.removeSubject("Lincoln")
        XCTAssertTrue(f.subjects.isEmpty, "removing a tag takes every case of it")
    }

    func testCombinedFilterMatchesWorkflowExample() {
        // "Cold War" + Unread + Q3 — the canonical triage query.
        let hit = file("a", ["Cold War", "Unread", "Q3", "1962"])
        let wrongQuality = file("b", ["Cold War", "Unread", "Q2", "1962"])
        let alreadyRead = file("c", ["Cold War", "Read", "Q3", "1962"])
        let f = LibraryFilter(subjects: ["Cold War"], qualities: [3], read: .unread)
        XCTAssertTrue(f.matches(hit))
        XCTAssertFalse(f.matches(wrongQuality))
        XCTAssertFalse(f.matches(alreadyRead))
    }

    func testFilenameSearch() {
        let f = LibraryFilter(searchText: "brown")
        XCTAssertTrue(f.matches(file("00001 IMG — Brown.pdf", ["Unread"])))
        XCTAssertFalse(f.matches(file("00002 IMG — Smith.pdf", ["Unread"])))
    }

    // MARK: Sorting

    func testDefaultSortIsChronologicalThenNameWithUndatedLast() {
        let files = [
            file("z-1980", ["1980"]),
            file("marker", ["Red"], label: 6),         // undated → last
            file("a-1975", ["1975"]),
            file("b-1980", ["1980"]),
        ]
        let sorted = LibrarySort.sorted(files, by: LibrarySort.default).map(\.name)
        XCTAssertEqual(sorted, ["a-1975", "b-1980", "z-1980", "marker"])  // 1975 < 1980; name tiebreak; undated last
    }

    func testDescendingDateKeepsUndatedLast() {
        let files = [
            file("old", ["1975"]),
            file("undated", ["Red"], label: 6),
            file("new", ["1985"]),
        ]
        let desc = [ARSortDescriptor(field: .date, ascending: false)]
        let sorted = LibrarySort.sorted(files, by: desc).map(\.name)
        XCTAssertEqual(sorted, ["new", "old", "undated"])  // newest first, undated STILL last
    }

    func testMonthAndDayRefineChronology() {
        let files = [
            file("mar", ["1980", "03 March"]),
            file("jan", ["1980", "01 January"]),
            file("jan25", ["1980", "01 January", "Day 25"]),
        ]
        let sorted = LibrarySort.sorted(files, by: LibrarySort.default).map(\.name)
        XCTAssertEqual(sorted, ["jan", "jan25", "mar"])  // Jan(0) < Jan-25 < March
    }

    // W40.suite-month-tag-zero: Month tags are written without the zero, so as text `3 March` would sort after
    // `10 October`; the list orders them by the month's number, and the older `03 March` sorts the same.
    func testUnpaddedMonthsSortByNumber() {
        let files = [
            file("oct", ["1980", "10 October"]),
            file("mar", ["1980", "3 March"]),
            file("feb", ["1980", "02 February"]),
        ]
        XCTAssertEqual(LibrarySort.sorted(files, by: LibrarySort.default).map(\.name), ["feb", "mar", "oct"])
    }

    func testQualitySortNilLast() {
        let files = [
            file("q2", ["Q2", "1980"]),
            file("none", ["1980"]),
            file("q3", ["Q3", "1980"]),
        ]
        let sorted = LibrarySort.sorted(files, by: [ARSortDescriptor(field: .quality, ascending: true)]).map(\.name)
        XCTAssertEqual(sorted, ["q2", "q3", "none"])  // Q2<Q3 ascending; unrated last
    }

    // W40.fix-reader-date-ambiguity (R-47): failed before it — nothing flagged two Years, and no filter found them.
    func testTwoYearsAreFlaggedAndTheAmbiguousDatesFilterFindsThem() {
        let twoYears = file("a", ["Unread", "1980", "Cold War", "1984"])
        let oneYear = file("b", ["Unread", "1980", "Cold War"])
        XCTAssertTrue(twoYears.dateIsAmbiguous)
        XCTAssertEqual(twoYears.dateAmbiguityText, "Two Year tags: 1984 is used, 1980 was set aside.")
        XCTAssertEqual(twoYears.sortDate, 1984_00_00, "the last-wins rule is unchanged")
        XCTAssertFalse(oneYear.dateIsAmbiguous)
        XCTAssertNil(oneYear.dateAmbiguityText)

        var f = LibraryFilter(); f.ambiguousDatesOnly = true
        XCTAssertTrue(f.isActive)
        XCTAssertEqual([twoYears, oneYear].filter(f.matches).map(\.name), ["a"])
    }
}
