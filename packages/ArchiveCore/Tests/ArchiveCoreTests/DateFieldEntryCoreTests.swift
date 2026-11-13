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

    // MARK: archiveDate (W40.processor-date-field)

    private func date(_ text: String) -> ArchiveDate? {
        if case .date(let d, _) = DateFieldEntry.archiveDate(text) { return d }
        return nil
    }

    func testArchiveDateReadsEachPrecision() {
        XCTAssertEqual(date("1968")?.wireValue, "1968")
        XCTAssertEqual(date("1960s")?.wireValue, "1960s")
        XCTAssertEqual(date("1960's")?.precision, .decade)
        XCTAssertEqual(date("March 1968")?.wireValue, "1968-03")
        XCTAssertEqual(date("1968-3")?.wireValue, "1968-03")
        XCTAssertEqual(date("12 March 1968")?.wireValue, "1968-03-12")
        XCTAssertEqual(date("March 12th, 1968")?.wireValue, "1968-03-12")
        XCTAssertEqual(date("1968/03/12")?.wireValue, "1968-03-12")
        XCTAssertEqual(date("29 Feb 1968")?.wireValue, "1968-02-29")
    }

    /// The stored wire value is the seed text, and reads back to the same date.
    func testWireValueRoundTrips() {
        for wire in ["1958", "1950s", "1958-03", "1958-03-12", "1000-01-01", "9999-12-31", "100"] {
            XCTAssertEqual(date(wire)?.wireValue, wire, wire)
        }
    }

    func testImpossibleDayIsCoarsenedWithANote() {
        guard case .date(let d, let note) = DateFieldEntry.archiveDate("31 February 1968") else {
            return XCTFail("a month with an impossible day is still a month")
        }
        XCTAssertEqual(d.wireValue, "1968-02")
        XCTAssertEqual(note, "February 1968 has 29 days — the day is ignored.")
        guard case .date(_, let none) = DateFieldEntry.archiveDate("1968-02-29") else { return XCTFail() }
        XCTAssertNil(none)
    }

    func testEmptyAndUnreadable() {
        XCTAssertEqual(DateFieldEntry.archiveDate("  "), .empty)
        for text in ["68", "12/3/1968", "Smarch 1968", "1968-13", "99", "10000", "0 1968", "1968-03-00"] {
            guard case .unreadable(let why) = DateFieldEntry.archiveDate(text) else {
                return XCTFail("\(text) must not be written")
            }
            XCTAssertFalse(why.isEmpty, text)
        }
        guard case .unreadable(let why) = DateFieldEntry.archiveDate("12345") else { return XCTFail() }
        XCTAssertEqual(why, "Write a year from 100 to 9999.")
    }
}
