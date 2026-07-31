import XCTest
@testable import ArchiveNotes

/// W23.l4 — the calendar the date input seams validate against.
///
/// Notes used to check month (`1…12`) and day (`1…31`) independently, so `2026-02-31` was a legal
/// day-precision date. These tests pin the arithmetic that replaces that pair of range checks, and
/// each impossible-day case also **re-runs the pre-fix predicate** (`(1...31).contains(day)`) and
/// asserts it said yes — so a pass here can never be vacuous.
final class GregorianDayTests: XCTestCase {

    /// The exact predicate the seams used before this item, kept here as the contrast baseline.
    private func preFixAccepted(month: Int, day: Int) -> Bool {
        (1...12).contains(month) && (1...31).contains(day)
    }

    // MARK: - Month lengths

    func testThirtyOneDayMonths() {
        for m in [1, 3, 5, 7, 8, 10, 12] {
            XCTAssertEqual(GregorianDay.daysInMonth(year: 1968, month: m), 31, "month \(m)")
            XCTAssertTrue(GregorianDay.isValidDay(year: 1968, month: m, day: 31))
        }
    }

    func testThirtyDayMonths() {
        for m in [4, 6, 9, 11] {
            XCTAssertEqual(GregorianDay.daysInMonth(year: 1968, month: m), 30, "month \(m)")
            XCTAssertTrue(GregorianDay.isValidDay(year: 1968, month: m, day: 30))
            XCTAssertFalse(GregorianDay.isValidDay(year: 1968, month: m, day: 31))
            XCTAssertTrue(preFixAccepted(month: m, day: 31), "baseline: month \(m) day 31 used to pass")
        }
    }

    func testFebruaryCommonAndLeapYear() {
        XCTAssertEqual(GregorianDay.daysInMonth(year: 2026, month: 2), 28)
        XCTAssertEqual(GregorianDay.daysInMonth(year: 2024, month: 2), 29)
        XCTAssertTrue(GregorianDay.isValidDay(year: 2024, month: 2, day: 29))
        XCTAssertFalse(GregorianDay.isValidDay(year: 2026, month: 2, day: 29))
    }

    // MARK: - The reported case

    func testTheReportedImpossibleDate() {
        // W23.l4's example, verbatim.
        XCTAssertFalse(GregorianDay.isValidDay(year: 2026, month: 2, day: 31))
        XCTAssertTrue(preFixAccepted(month: 2, day: 31),
                      "baseline: the independent range checks accepted 2026-02-31")
    }

    func testEveryImpossibleFebruaryDayIsRejected() {
        for d in 29...31 {
            XCTAssertFalse(GregorianDay.isValidDay(year: 2026, month: 2, day: d), "2026-02-\(d)")
            XCTAssertTrue(preFixAccepted(month: 2, day: d), "baseline: 2026-02-\(d) used to pass")
        }
        for d in 30...31 {
            XCTAssertFalse(GregorianDay.isValidDay(year: 2024, month: 2, day: d), "2024-02-\(d)")
        }
    }

    // MARK: - Out-of-range components

    func testDayZeroAndOverflowRejected() {
        for d in [-1, 0, 32, 99] {
            XCTAssertFalse(GregorianDay.isValidDay(year: 1968, month: 3, day: d), "day \(d)")
        }
    }

    func testImpossibleMonthRejected() {
        for m in [-1, 0, 13, 99] {
            XCTAssertNil(GregorianDay.daysInMonth(year: 1968, month: m), "month \(m)")
            XCTAssertFalse(GregorianDay.isValidDay(year: 1968, month: m, day: 1), "month \(m)")
        }
    }

    func testNonPositiveYearRejected() {
        for y in [-1, 0] {
            XCTAssertNil(GregorianDay.daysInMonth(year: y, month: 3))
            XCTAssertFalse(GregorianDay.isValidDay(year: y, month: 3, day: 1))
            XCTAssertFalse(GregorianDay.isLeapYear(y))
        }
    }

    // MARK: - Leap rules

    func testGregorianCenturyRule() {
        XCTAssertFalse(GregorianDay.isLeapYear(1900))          // ÷100, not ÷400
        XCTAssertFalse(GregorianDay.isLeapYear(2100))
        XCTAssertTrue(GregorianDay.isLeapYear(2000))           // ÷400
        XCTAssertTrue(GregorianDay.isLeapYear(1600))           // ÷400, and post-cutover
        XCTAssertTrue(GregorianDay.isLeapYear(2024))
        XCTAssertFalse(GregorianDay.isLeapYear(2023))
        XCTAssertFalse(GregorianDay.isValidDay(year: 1900, month: 2, day: 29))
        XCTAssertTrue(GregorianDay.isValidDay(year: 2000, month: 2, day: 29))
    }

    /// A day transcribed off a pre-1582 document was reckoned in the Julian calendar, where every
    /// 4th year is a leap year — `1500-02-29` is a real day and coarsening it would lose the day
    /// the operator read. See `GregorianDay.daysInMonth`'s note on the 1582 boundary.
    func testPreCutoverCenturyLeapYearAccepted() {
        XCTAssertTrue(GregorianDay.isLeapYear(1500))
        XCTAssertTrue(GregorianDay.isValidDay(year: 1500, month: 2, day: 29))
        XCTAssertTrue(GregorianDay.isValidDay(year: 1300, month: 2, day: 29))
        XCTAssertFalse(GregorianDay.isValidDay(year: 1501, month: 2, day: 29))   // not ÷4 either way
    }

    /// The ten days ICU deletes at the 1582 cutover exist for us: they are on real documents, and
    /// `DateComponents.isValidDate(in:)` calls every one of them invalid.
    func testCutoverGapDaysAccepted() {
        for d in 5...14 {
            XCTAssertTrue(GregorianDay.isValidDay(year: 1582, month: 10, day: d), "1582-10-\(d)")
        }
    }

    // MARK: - Equivalence with Foundation over the range where Foundation is trustworthy

    /// Well after the cutover, our arithmetic must agree with `Calendar` exactly — that is the range
    /// nearly every note lives in, and the cheapest proof the rules are not hand-rolled wrong.
    /// (Before 1582 the two deliberately diverge; see the two tests above.)
    func testAgreesWithFoundationForModernDates() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var years = Array(1899...1905) + Array(1996...2005) + Array(2020...2030) + Array(2098...2102)
        years += stride(from: 1600, through: 2400, by: 100)
        for y in years {
            for m in 1...12 {
                for d in 1...32 {
                    var dc = DateComponents()
                    dc.year = y; dc.month = m; dc.day = d
                    XCTAssertEqual(GregorianDay.isValidDay(year: y, month: m, day: d),
                                   dc.isValidDate(in: cal),
                                   "\(y)-\(m)-\(d)")
                }
            }
        }
    }

    /// February across the whole post-cutover span, against Foundation, so the century/400 rules are
    /// checked everywhere they matter rather than at a few sampled years.
    func testFebruaryTwentyNineAgreesWithFoundationPostCutover() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        for y in 1583...2400 {
            var dc = DateComponents()
            dc.year = y; dc.month = 2; dc.day = 29
            XCTAssertEqual(GregorianDay.isValidDay(year: y, month: 2, day: 29),
                           dc.isValidDate(in: cal), "\(y)-02-29")
        }
    }
}
