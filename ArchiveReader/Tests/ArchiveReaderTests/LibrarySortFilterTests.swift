import XCTest
@testable import ArchiveReader

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

    func testPriorityFilterExcludesUnprioritized() {
        let p10 = file("a", ["Unread", "P10", "1980"])
        let p9 = file("b", ["Unread", "P9", "1980"])
        let none = file("c", ["Unread", "1980"])
        let f = LibraryFilter(priorities: [10])
        XCTAssertTrue(f.matches(p10))
        XCTAssertFalse(f.matches(p9))
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

    func testSubjectCombineAndVsOr() {
        let both = file("a", ["Jerry Brown", "Economics", "1980", "Unread"])
        let one = file("b", ["Jerry Brown", "1980", "Unread"])
        let and = LibraryFilter(subjects: ["Jerry Brown", "Economics"], subjectCombine: .all)
        let or = LibraryFilter(subjects: ["Jerry Brown", "Economics"], subjectCombine: .any)
        XCTAssertTrue(and.matches(both));  XCTAssertFalse(and.matches(one))
        XCTAssertTrue(or.matches(both));   XCTAssertTrue(or.matches(one))
    }

    func testCombinedFilterMatchesWorkflowExample() {
        // "Cold War" + Unread + P10 — the canonical triage query.
        let hit = file("a", ["Cold War", "Unread", "P10", "1962"])
        let wrongPriority = file("b", ["Cold War", "Unread", "P9", "1962"])
        let alreadyRead = file("c", ["Cold War", "Read", "P10", "1962"])
        let f = LibraryFilter(subjects: ["Cold War"], priorities: [10], read: .unread)
        XCTAssertTrue(f.matches(hit))
        XCTAssertFalse(f.matches(wrongPriority))
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

    func testPrioritySortNilLast() {
        let files = [
            file("p9", ["P9", "1980"]),
            file("none", ["1980"]),
            file("p10", ["P10", "1980"]),
        ]
        let sorted = LibrarySort.sorted(files, by: [ARSortDescriptor(field: .priority, ascending: true)]).map(\.name)
        XCTAssertEqual(sorted, ["p9", "p10", "none"])  // 9<10 ascending; unprioritized last
    }
}
