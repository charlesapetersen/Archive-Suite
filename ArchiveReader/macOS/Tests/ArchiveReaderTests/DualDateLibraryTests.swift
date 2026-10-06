import XCTest
@testable import ArchiveReader
import ArchiveCore

/// W37.dual-date in the Reader: own date sorts (sent-with fallback), a year filter matches either
/// date — the same value meeting both bounds — and the Date column labels each role.
final class DualDateLibraryTests: XCTestCase {

    private func file(_ name: String, _ tags: [String]) -> ArchiveFile {
        ArchiveFile(url: URL(fileURLWithPath: "/corpus/\(name)"), name: name, fileType: "PDF",
                    tags: DocumentTags.parse(raw: tags, labelNumber: nil), contentModified: nil)
    }

    private let enclosure = ["1957", "11 November", "Day 3", "Sent With 1958-03-12", "Report"]

    func testSortUsesOwnDateThenSentWithFallback() {
        let enc = file("enc.pdf", enclosure)                     // own 1957-11-03, sent 1958-03-12
        let sentOnly = file("sent.pdf", ["Sent With 1957-06"])   // no own date → sorts 1957-06
        let letter = file("letter.pdf", ["1958", "03 March", "Day 12"])
        let undated = file("undated.pdf", ["Report"])
        let order = LibrarySort.sorted([undated, letter, enc, sentOnly], by: LibrarySort.default).map(\.name)
        XCTAssertEqual(order, ["sent.pdf", "enc.pdf", "letter.pdf", "undated.pdf"])
    }

    func testSortIsStableUnderASentDateEditWhenOwnDateExists() {
        let a = file("a.pdf", ["1957", "Sent With 1990"])
        let b = file("b.pdf", ["1957", "Sent With 1900"])
        let c = file("c.pdf", ["1956"])
        XCTAssertEqual(LibrarySort.sorted([a, b, c], by: LibrarySort.default).map(\.name), ["c.pdf", "a.pdf", "b.pdf"])
    }

    func testYearFilterMatchesEitherRoleOnce() {
        let enc = file("enc.pdf", enclosure)
        XCTAssertTrue(LibraryFilter(dateFromYear: 1957, dateToYear: 1957).matches(enc))
        XCTAssertTrue(LibraryFilter(dateFromYear: 1958, dateToYear: 1958).matches(enc))
        XCTAssertFalse(LibraryFilter(dateFromYear: 1959, dateToYear: nil).matches(enc))
        XCTAssertTrue(LibraryFilter(dateFromYear: nil, dateToYear: 1957).matches(enc))
        let files = [enc, file("other.pdf", ["1958"])]
        XCTAssertEqual(files.filter(LibraryFilter(dateFromYear: 1950, dateToYear: 1960).matches).count, 2,
                       "a file matching on both roles is still one row")
    }

    func testRangeCannotPairOneDatePerBound() {
        let split = file("split.pdf", ["1950", "Sent With 1970"])
        XCTAssertFalse(LibraryFilter(dateFromYear: 1960, dateToYear: 1965).matches(split))
    }

    func testUndatedNeverMatchesAnActiveRangeAndInactiveMatchesAll() {
        let undated = file("u.pdf", ["Report"])
        XCTAssertFalse(LibraryFilter(dateFromYear: 1900, dateToYear: nil).matches(undated))
        XCTAssertTrue(LibraryFilter().matches(undated))
        XCTAssertFalse(LibraryFilter().isActive)
        XCTAssertTrue(LibraryFilter(dateFromYear: 1900).isActive)
    }

    func testEffectiveFilterAndCodable() throws {
        let base = LibraryFilter(dateFromYear: 1950, dateToYear: 1960)
        XCTAssertEqual(LibraryFilter.effective(base: base, user: LibraryFilter()).dateToYear, 1960)
        let user = LibraryFilter(dateFromYear: 1970)
        let eff = LibraryFilter.effective(base: base, user: user)
        XCTAssertEqual(eff.dateFromYear, 1970); XCTAssertNil(eff.dateToYear)
        let back = try JSONDecoder().decode(LibraryFilter.self, from: JSONEncoder().encode(base))
        XCTAssertEqual(back, base)
        XCTAssertEqual(base.dateYearsSummary, "1950\u{2013}1960")
    }

    func testDateCellLabelsEachRole() {
        XCTAssertEqual(file("e", enclosure).dateCellText, "Nov 3, 1957 \u{b7} sent Mar 12, 1958")
        XCTAssertEqual(file("s", ["Sent With 1958"]).dateCellText, "Sent with 1958")
        XCTAssertEqual(file("o", ["1957"]).dateCellText, "1957")
        XCTAssertEqual(file("n", []).dateCellText, "\u{2014}")
        XCTAssertTrue(file("s", ["Sent With 1958", "Sent With Date Uncertain"]).dateCellIsSpeculative)
        XCTAssertFalse(file("e", enclosure + ["Sent With Date Uncertain"]).dateCellIsSpeculative,
                       "the own date sorts the row, and it is certain")
    }
}
