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

    private func either(_ from: Int?, _ to: Int?) -> LibraryFilter {
        var f = LibraryFilter(dateFromYear: from, dateToYear: to)
        f.dateRangeRoles = .either
        return f
    }

    func testYearFilterMatchesEitherRoleOnceWhenAsked() {
        let enc = file("enc.pdf", enclosure)
        XCTAssertTrue(either(1957, 1957).matches(enc))
        XCTAssertTrue(either(1958, 1958).matches(enc))
        XCTAssertFalse(either(1959, nil).matches(enc))
        XCTAssertTrue(either(nil, 1957).matches(enc))
        let files = [enc, file("other.pdf", ["1958"])]
        XCTAssertEqual(files.filter(either(1950, 1960).matches).count, 2,
                       "a file matching on both roles is still one row")
    }

    /// W40.suite-date-design: the year range tests the own date unless asked; the sent-with date alone works too.
    func testYearFilterTestsTheOwnDateByDefault() {
        let enc = file("enc.pdf", enclosure)                     // own 1957, sent 1958
        let sentOnly = file("sent.pdf", ["Sent With 1958-03"])
        XCTAssertEqual(LibraryFilter().dateRangeRoles, .own)
        XCTAssertTrue(LibraryFilter(dateFromYear: 1957, dateToYear: 1957).matches(enc))
        XCTAssertFalse(LibraryFilter(dateFromYear: 1958, dateToYear: 1958).matches(enc))
        XCTAssertFalse(LibraryFilter(dateFromYear: 1958, dateToYear: 1958).matches(sentOnly),
                       "a sent-with date alone is not the item's date")
        var sent = LibraryFilter(dateFromYear: 1958, dateToYear: 1958)
        sent.dateRangeRoles = .sentWith
        XCTAssertTrue(sent.matches(enc))
        XCTAssertTrue(sent.matches(sentOnly))
        XCTAssertFalse(LibraryFilter(dateFromYear: 1957, dateToYear: 1957, dateRangeRole: .sentWith).matches(enc))
        XCTAssertEqual(AdvancedSearch(filter: sent, fullTextQuery: "").rules.first { $0.field == .date }?.dateRole, .sentWith)
        XCTAssertEqual(AdvancedSearch(filter: LibraryFilter(dateFromYear: 1958), fullTextQuery: "").rules.first { $0.field == .date }?.dateRole, .own)
        XCTAssertEqual(SearchRule(field: .date).dateRole, .own, "a new Advanced Search date row tests the own date")
    }

    /// A filter saved before the role existed tested either date; it decodes to that, so a smart folder keeps
    /// what it meant.
    func testAFilterSavedWithoutTheRoleKeepsEither() throws {
        let old = #"{"subjects":[],"subjectCombine":"all","qualities":[],"read":"all","searchText":"","needsAttentionOnly":false,"dateFromYear":1958,"dateToYear":1958}"#
        let f = try JSONDecoder().decode(LibraryFilter.self, from: Data(old.utf8))
        XCTAssertEqual(f.dateRangeRoles, .either)
        XCTAssertTrue(f.matches(file("enc.pdf", enclosure)))
        let rule = try JSONDecoder().decode(SearchRule.self, from: Data(#"{"field":"date","op":"between","text":"1958"}"#.utf8))
        XCTAssertEqual(rule.dateRole, .either, "a date row saved without its role keeps either")
    }

    func testRangeCannotPairOneDatePerBound() {
        let split = file("split.pdf", ["1950", "Sent With 1970"])
        XCTAssertFalse(either(1960, 1965).matches(split))
    }

    func testUndatedNeverMatchesAnActiveRangeAndInactiveMatchesAll() {
        let undated = file("u.pdf", ["Report"])
        XCTAssertFalse(LibraryFilter(dateFromYear: 1900, dateToYear: nil).matches(undated))
        XCTAssertTrue(LibraryFilter().matches(undated))
        XCTAssertFalse(LibraryFilter().isActive)
        XCTAssertTrue(LibraryFilter(dateFromYear: 1900).isActive)
    }

    func testDateFilterCodable() throws {
        let base = LibraryFilter(dateFromYear: 1950, dateToYear: 1960)
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
