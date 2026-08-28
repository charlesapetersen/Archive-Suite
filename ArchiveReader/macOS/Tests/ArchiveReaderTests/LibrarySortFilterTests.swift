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

    func testSubjectCombineAndVsOr() {
        let both = file("a", ["Jerry Brown", "Economics", "1980", "Unread"])
        let one = file("b", ["Jerry Brown", "1980", "Unread"])
        let and = LibraryFilter(subjects: ["Jerry Brown", "Economics"], subjectCombine: .all)
        let or = LibraryFilter(subjects: ["Jerry Brown", "Economics"], subjectCombine: .any)
        XCTAssertTrue(and.matches(both));  XCTAssertFalse(and.matches(one))
        XCTAssertTrue(or.matches(both));   XCTAssertTrue(or.matches(one))
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

    func testQualitySortNilLast() {
        let files = [
            file("q2", ["Q2", "1980"]),
            file("none", ["1980"]),
            file("q3", ["Q3", "1980"]),
        ]
        let sorted = LibrarySort.sorted(files, by: [ARSortDescriptor(field: .quality, ascending: true)]).map(\.name)
        XCTAssertEqual(sorted, ["q2", "q3", "none"])  // Q2<Q3 ascending; unrated last
    }

    // MARK: - LibraryFilter.effective (base-scope merge)

    func testEffectiveUserWinsRead() {
        let base = LibraryFilter(read: .unread)
        let user = LibraryFilter(read: .read)
        XCTAssertEqual(LibraryFilter.effective(base: base, user: user).read, .read)
    }

    func testEffectiveInheritsBaseWhenUserNeutral() {
        let base = LibraryFilter(qualities: [3], read: .unread, searchText: "memo")
        let user = LibraryFilter()   // neutral
        let eff = LibraryFilter.effective(base: base, user: user)
        XCTAssertEqual(eff.read, .unread)
        XCTAssertEqual(eff.qualities, [3])
        XCTAssertEqual(eff.searchText, "memo")
    }

    func testEffectiveSubjectsUnion() {
        let base = LibraryFilter(subjects: ["A", "B"])
        let user = LibraryFilter(subjects: ["B", "C"])
        XCTAssertEqual(LibraryFilter.effective(base: base, user: user).subjects, ["A", "B", "C"])
    }

    func testEffectiveSubjectCombineUserWins() {
        let base = LibraryFilter(subjects: ["A"], subjectCombine: .all)
        let user = LibraryFilter(subjects: ["B"], subjectCombine: .any)
        XCTAssertEqual(LibraryFilter.effective(base: base, user: user).subjectCombine, .any)
    }

    func testEffectiveSubjectCombineInheritsBaseWhenUserEmpty() {
        let base = LibraryFilter(subjects: ["A"], subjectCombine: .any)
        let user = LibraryFilter()
        XCTAssertEqual(LibraryFilter.effective(base: base, user: user).subjectCombine, .any)
    }

    func testEffectivePathPrefixUserWins() {
        let base = LibraryFilter(pathPrefix: "/corpus/Brown")
        let user = LibraryFilter(pathPrefix: "/corpus/Smith")
        XCTAssertEqual(LibraryFilter.effective(base: base, user: user).pathPrefix, "/corpus/Smith")
    }

    func testEffectivePathPrefixInheritsBase() {
        let base = LibraryFilter(pathPrefix: "/corpus/Brown")
        let user = LibraryFilter()
        XCTAssertEqual(LibraryFilter.effective(base: base, user: user).pathPrefix, "/corpus/Brown")
    }

    func testEffectiveNeedsAttentionOR() {
        let base = LibraryFilter(needsAttentionOnly: true)
        let user = LibraryFilter()
        XCTAssertTrue(LibraryFilter.effective(base: base, user: user).needsAttentionOnly)
        let user2 = LibraryFilter(needsAttentionOnly: true)
        let base2 = LibraryFilter()
        XCTAssertTrue(LibraryFilter.effective(base: base2, user: user2).needsAttentionOnly)
    }

    func testEffectiveNeutralBothReturnsNeutral() {
        let eff = LibraryFilter.effective(base: LibraryFilter(), user: LibraryFilter())
        XCTAssertFalse(eff.isActive)
    }
}
