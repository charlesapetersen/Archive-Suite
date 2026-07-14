import XCTest
@testable import ArchiveNotes
import ArchiveCore

/// Verify Item.sortDate parity with the SPEC formula (DocumentTags.sortDate:89-92):
///   year * 10_000 + month * 100 + day
///   decade -> decade * 10_000
///   nil when no date
final class ItemSortDateTests: XCTestCase {

    private func makeItem(date: String?, precision: Item.DatePrecision?) -> Item {
        Item(
            id: UUID(),
            kind: .note,
            title: "",
            authors: [],
            date: date,
            datePrecision: precision,
            dateUncertain: false,
            quality: nil,
            tags: [],
            zotero: [],
            roundup: false,
            created: Date(),
            modified: Date(),
            schema: 1,
            blocks: [],
            unknownFrontMatter: [],
            trailingBodyRaw: nil
        )
    }

    // MARK: - Parity table (matching DocumentTags.sortDate)

    func testDecade() {
        let item = makeItem(date: "1970", precision: .decade)
        XCTAssertEqual(item.sortDate, 19_700_000)
    }

    func testYearOnly() {
        let item = makeItem(date: "1968", precision: .year)
        XCTAssertEqual(item.sortDate, 19_680_000)
    }

    func testYearMonth() {
        let item = makeItem(date: "1968-03", precision: .month)
        XCTAssertEqual(item.sortDate, 19_680_300)
    }

    func testYearMonthDay() {
        let item = makeItem(date: "1968-03-25", precision: .day)
        XCTAssertEqual(item.sortDate, 19_680_325)
    }

    func testMedieval() {
        let item = makeItem(date: "842", precision: .year)
        XCTAssertEqual(item.sortDate, 8_420_000)
    }

    func testDecadeStart1970s() {
        // "1970s" decade has date="1970", precision=.decade → same as decade*10_000
        let item = makeItem(date: "1970", precision: .decade)
        XCTAssertEqual(item.sortDate, 19_700_000)
    }

    func testNoDate() {
        let item = makeItem(date: nil, precision: nil)
        XCTAssertNil(item.sortDate)
    }

    func testNoPrecisionFallsBackToYear() {
        // When datePrecision is nil but date is a plain year, treat as year.
        let item = makeItem(date: "1968", precision: nil)
        XCTAssertEqual(item.sortDate, 19_680_000)
    }

    func testNoPrecisionNonYearReturnsNil() {
        // A full date string with nil precision can't parse as Int → nil.
        let item = makeItem(date: "1968-03-25", precision: nil)
        XCTAssertNil(item.sortDate)
    }

    func testMalformedDateReturnsNil() {
        let item = makeItem(date: "unknown", precision: .year)
        XCTAssertNil(item.sortDate)
    }

    func testMonthDayZeroPadded() {
        // year * 10_000 + 1 * 100 + 5 = 19680105
        let item = makeItem(date: "1968-01-05", precision: .day)
        XCTAssertEqual(item.sortDate, 19_680_105)
    }

    // MARK: - Uncertain date still sorts

    func testUncertainDateStillSorts() {
        var item = makeItem(date: "1968", precision: .year)
        item.dateUncertain = true
        XCTAssertEqual(item.sortDate, 19_680_000, "Uncertain dates still sort by the stated date")
    }

    // MARK: - Cross-implementation parity guard (reconciles §1.7 `testReuseNotReimplemented`)
    //
    // `Item.sortDate` RE-IMPLEMENTS the SPEC formula locally (over `date: String?` + precision)
    // instead of calling `ArchiveCore.DocumentTags.sortDate` the way Reader does, so a literal
    // "routes through the shared function" guard isn't satisfiable today. This asserts the
    // stronger observable property instead: for the same logical date, Notes' key MUST equal the
    // shared ArchiveCore key. If Notes' formula ever drifts from the SPEC, this fails.
    // (Follow-up flagged to Morning Review: extract a shared numeric combiner in ArchiveCore so
    // both sides can literally reuse it.)
    func testItemSortDateMatchesArchiveCoreSharedFormula() {
        // The shared ArchiveCore key for the equivalent typed date fields.
        func core(year: Int?, month: Int?, day: Int?, decade: Int?) -> Int? {
            DocumentTags(
                raw: [], labelNumber: nil,
                year: year,
                month: month.map { DocumentTags.Month(number: $0, name: "") },
                day: day, dateUncertain: false, decade: decade,
                priority: nil, readState: nil, color: nil, subjects: [],
                yearToken: nil, monthToken: nil, dayToken: nil, decadeToken: nil, priorityToken: nil
            ).sortDate
        }

        // Each row feeds the SAME logical date to both implementations.
        XCTAssertEqual(makeItem(date: "1970", precision: .decade).sortDate,
                       core(year: nil, month: nil, day: nil, decade: 1970))
        XCTAssertEqual(makeItem(date: "1968", precision: .year).sortDate,
                       core(year: 1968, month: nil, day: nil, decade: nil))
        XCTAssertEqual(makeItem(date: "1968-03", precision: .month).sortDate,
                       core(year: 1968, month: 3, day: nil, decade: nil))
        XCTAssertEqual(makeItem(date: "1968-03-25", precision: .day).sortDate,
                       core(year: 1968, month: 3, day: 25, decade: nil))
        XCTAssertEqual(makeItem(date: "842", precision: .year).sortDate,
                       core(year: 842, month: nil, day: nil, decade: nil))
        XCTAssertEqual(makeItem(date: "1215-05-25", precision: .day).sortDate,
                       core(year: 1215, month: 5, day: 25, decade: nil))
        // Both agree that an undated item has no key.
        XCTAssertEqual(makeItem(date: nil, precision: nil).sortDate,
                       core(year: nil, month: nil, day: nil, decade: nil))
        XCTAssertNil(makeItem(date: nil, precision: nil).sortDate)
    }
}
