import Testing
import Foundation
@testable import ArchiveNotes

// W23.l4 — the calendar Notes' date input seams validate against.
//
// Those seams used to check month (`1…12`) and day (`1…31`) independently, so `2026-02-31` was a
// legal day-precision date. These tests pin the arithmetic that replaces that pair of range checks.
// Every impossible-day case also re-runs the pre-fix predicate and asserts it said YES, so a pass
// here can never be vacuous. Two sweeps check the rules against Foundation over the post-1582 range
// where Foundation is trustworthy; the two deliberate divergences below say why that range stops there.

@Suite("GregorianDay — does this (year, month, day) name a real day?")
struct GregorianDayTests {

    /// The exact predicate the seams used before this item, kept as the contrast baseline.
    private func preFixAccepted(month: Int, day: Int) -> Bool {
        (1...12).contains(month) && (1...31).contains(day)
    }

    // MARK: - Month lengths

    @Test("31-day months are 31 days", arguments: [1, 3, 5, 7, 8, 10, 12])
    func longMonths(_ m: Int) {
        #expect(GregorianDay.daysInMonth(year: 1968, month: m) == 31)
        #expect(GregorianDay.isValidDay(year: 1968, month: m, day: 31))
    }

    @Test("30-day months reject a 31st the old range check waved through", arguments: [4, 6, 9, 11])
    func shortMonths(_ m: Int) {
        #expect(GregorianDay.daysInMonth(year: 1968, month: m) == 30)
        #expect(GregorianDay.isValidDay(year: 1968, month: m, day: 30))
        #expect(!GregorianDay.isValidDay(year: 1968, month: m, day: 31))
        #expect(preFixAccepted(month: m, day: 31))          // baseline: used to pass
    }

    @Test("February is 28 days, 29 in a leap year")
    func february() {
        #expect(GregorianDay.daysInMonth(year: 2026, month: 2) == 28)
        #expect(GregorianDay.daysInMonth(year: 2024, month: 2) == 29)
        #expect(GregorianDay.isValidDay(year: 2024, month: 2, day: 29))
        #expect(!GregorianDay.isValidDay(year: 2026, month: 2, day: 29))
    }

    // MARK: - The reported case

    @Test("2026-02-31 — W23.l4's example, verbatim")
    func reportedImpossibleDate() {
        #expect(!GregorianDay.isValidDay(year: 2026, month: 2, day: 31))
        #expect(preFixAccepted(month: 2, day: 31))           // baseline: the independent checks accepted it
    }

    @Test("every impossible February day is rejected", arguments: 29...31)
    func impossibleFebruaryDays(_ d: Int) {
        #expect(!GregorianDay.isValidDay(year: 2026, month: 2, day: d))
        #expect(preFixAccepted(month: 2, day: d))            // baseline: used to pass
        if d >= 30 { #expect(!GregorianDay.isValidDay(year: 2024, month: 2, day: d)) }
    }

    // MARK: - Out-of-range components

    @Test("day 0 / overflow rejected", arguments: [-1, 0, 32, 99])
    func badDay(_ d: Int) {
        #expect(!GregorianDay.isValidDay(year: 1968, month: 3, day: d))
    }

    @Test("impossible month rejected", arguments: [-1, 0, 13, 99])
    func badMonth(_ m: Int) {
        #expect(GregorianDay.daysInMonth(year: 1968, month: m) == nil)
        #expect(!GregorianDay.isValidDay(year: 1968, month: m, day: 1))
    }

    @Test("non-positive year rejected", arguments: [-1, 0])
    func badYear(_ y: Int) {
        #expect(GregorianDay.daysInMonth(year: y, month: 3) == nil)
        #expect(!GregorianDay.isValidDay(year: y, month: 3, day: 1))
        #expect(!GregorianDay.isLeapYear(y))
    }

    // MARK: - Leap rules

    @Test("Gregorian century rule: ÷100 is not a leap year unless ÷400")
    func centuryRule() {
        #expect(!GregorianDay.isLeapYear(1900))
        #expect(!GregorianDay.isLeapYear(2100))
        #expect(GregorianDay.isLeapYear(2000))
        #expect(GregorianDay.isLeapYear(1600))
        #expect(GregorianDay.isLeapYear(2024))
        #expect(!GregorianDay.isLeapYear(2023))
        #expect(!GregorianDay.isValidDay(year: 1900, month: 2, day: 29))
        #expect(GregorianDay.isValidDay(year: 2000, month: 2, day: 29))
    }

    /// A day transcribed off a pre-1582 document was reckoned in the Julian calendar, where every 4th
    /// year is a leap year — `1500-02-29` is a real day, and coarsening it would throw away the day
    /// the operator read. See `GregorianDay.daysInMonth` on the 1582 boundary.
    @Test("pre-cutover century leap years are real (1500-02-29 kept)")
    func preCutoverCenturyLeapYear() {
        #expect(GregorianDay.isLeapYear(1500))
        #expect(GregorianDay.isValidDay(year: 1500, month: 2, day: 29))
        #expect(GregorianDay.isValidDay(year: 1300, month: 2, day: 29))
        #expect(!GregorianDay.isValidDay(year: 1501, month: 2, day: 29))     // not ÷4 either way
    }

    /// The ten days ICU deletes at the 1582 cutover exist for us: they are on real documents, and
    /// `DateComponents.isValidDate(in:)` calls every one of them invalid.
    @Test("the 1582 cutover gap days exist", arguments: 5...14)
    func cutoverGapDay(_ d: Int) {
        #expect(GregorianDay.isValidDay(year: 1582, month: 10, day: d))
    }

    // MARK: - Equivalence with Foundation, where Foundation is trustworthy

    private static var utcGregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private static func foundationSaysValid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d
        return dc.isValidDate(in: utcGregorian)
    }

    /// Well after the cutover our arithmetic must agree with `Calendar` exactly — that is the range
    /// nearly every note lives in, and the cheapest proof these rules are not hand-rolled wrong.
    /// (Before 1582 the two deliberately diverge; see the two tests above.)
    @Test("agrees with Foundation for every day of every month, sampled 1600–2400")
    func agreesWithFoundationModern() {
        var years = Array(1899...1905) + Array(1996...2005) + Array(2020...2030) + Array(2098...2102)
        years += stride(from: 1600, through: 2400, by: 100)
        for y in years {
            for m in 1...12 {
                for d in 1...32 {
                    #expect(GregorianDay.isValidDay(year: y, month: m, day: d)
                            == Self.foundationSaysValid(y, m, d), "\(y)-\(m)-\(d)")
                }
            }
        }
    }

    /// February across the whole post-cutover span, so the century/400 rules are checked everywhere
    /// they matter rather than at a few sampled years.
    @Test("agrees with Foundation on every February 29 from 1583 to 2400")
    func agreesWithFoundationOnLeapDays() {
        for y in 1583...2400 {
            #expect(GregorianDay.isValidDay(year: y, month: 2, day: 29)
                    == Self.foundationSaysValid(y, 2, 29), "\(y)-02-29")
        }
    }
}
