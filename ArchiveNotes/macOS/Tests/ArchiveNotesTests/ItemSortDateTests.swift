import XCTest
@testable import ArchiveNotes

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
}
