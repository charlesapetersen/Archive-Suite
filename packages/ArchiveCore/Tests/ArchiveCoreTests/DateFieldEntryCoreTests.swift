import XCTest
import ArchiveCore

/// W40.suite-date-design — the suite's one typed date field lives in Core, so every app types a date by the same
/// rules. Not `@testable`: this checks the public surface another app sees. The full rules are tested in Archive
/// Notes (`DateFieldEntryTests`, `DateFieldTypedEntryTests`, `DateFieldCalendarEntryTests`).
final class DateFieldEntryCoreTests: XCTestCase {

    private func written(_ text: String) -> (DateFieldEntry.Commit, ArchiveDate.Precision?) {
        let (typed, calendar) = DateFieldEntry.resolve(text, calendar: .standard)
        return DateFieldEntry.commit(typed: typed, calendar: calendar, storedDate: nil)
    }

    /// The commit is year-month-day numbers, unpadded; each app pads it as it stores it (Notes: `Item.normalizedDate`).
    func testEachPrecisionWritesItsNumbers() {
        XCTAssertEqual(written("1968").0, .write("1968"))
        XCTAssertEqual(written("1968").1, .year)
        XCTAssertEqual(written("March 1968").0, .write("1968-3"))
        XCTAssertEqual(written("March 1968").1, .month)
        XCTAssertEqual(written("12 March 1968").0, .write("1968-3-12"))
        XCTAssertEqual(written("1968-03-12").1, .day)
        XCTAssertEqual(written("1960s").1, .decade)
    }

    func testEmptyClearsAndUnreadableKeeps() {
        XCTAssertEqual(written("").0, .write(nil))
        XCTAssertEqual(written("68").0, .keep, "a two-digit year is not guessed")
        // W40.fix-reader-date-fields review: a month written as 0 was read as no month, dropping a typed day.
        for text in ["1968-00", "1968-00-12", "0/1968"] { XCTAssertEqual(written(text).0, .keep, text) }
        XCTAssertEqual(written("1968-1-12").0, .write("1968-1-12"))
        XCTAssertNotNil(GregorianDay.daysInMonth(year: 1968, month: 2))
        XCTAssertFalse(GregorianDay.isValidDay(year: 2026, month: 2, day: 31))
    }

    func testSeedTextRoundTrips() {
        let seed = DateFieldEntry.seedText(storedDate: "1968-03-12", precision: .day, active: nil)
        XCTAssertEqual(written(seed.text).0, .write("1968-3-12"))
    }
}
