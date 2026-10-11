import XCTest
@testable import ArchiveCore

/// W24.cal1-core — display-calendar profiles. Anchors are published dates; the Hebrew, Islamic and Julian
/// arithmetic is also checked day by day against ICU (`Foundation.Calendar`), which is an independent
/// implementation — used here only as a test oracle, never in the module.
final class DisplayCalendarTests: XCTestCase {

    private typealias A = CalendarArithmetic

    private func day(_ y: Int, _ m: Int, _ d: Int) -> CalendarDay { CalendarDay(year: y, month: m, day: d) }

    private func display(_ cal: DisplayCalendar, _ y: Int, _ m: Int, _ d: Int) -> CalendarDay? {
        cal.display(stored: day(y, m, d))
    }

    /// The corpus begins 1789; run to a few years past today.
    private let corpusRange = A.fixedFromGregorian(1789, 1, 1)...A.fixedFromGregorian(2030, 12, 31)

    // MARK: Epochs (Reingold & Dershowitz's published RD values)

    func testFrenchClosedFormMatchesCountingYearByYear() {
        var start = A.frenchEpoch
        for y in 1...8_300 {
            XCTAssertEqual(A.frenchNewYear(y), start, "An \(y)")
            start += A.isFrenchLeap(y) ? 366 : 365
        }
    }

    func testEpochsMatchPublishedValues() {
        XCTAssertEqual(A.fixedFromGregorian(1, 1, 1), 1)
        XCTAssertEqual(A.julianEpoch, A.fixedFromGregorian(0, 12, 30))
        XCTAssertEqual(A.hebrewEpoch, -1_373_427)
        XCTAssertEqual(A.islamicEpoch, 227_015)
        XCTAssertEqual(A.frenchEpoch, 654_415)
        XCTAssertEqual(A.fixedFromGregorian(1945, 11, 12), 710_347)   // the book's worked example
    }

    // MARK: Round trips over the corpus range, every day, every calendar

    func testEveryCorpusDayRoundTripsThroughEveryCalendar() {
        for cal in DisplayCalendar.allCases {
            var previous: CalendarDay?
            for f in corpusRange {
                let (y, m, d) = A.gregorianFromFixed(f)
                let stored = day(y, m, d)
                XCTAssertEqual(A.fixedFromGregorian(y, m, d), f)
                guard let shown = cal.display(stored: stored) else {
                    // Only the French Republican calendar starts inside the range.
                    XCTAssertEqual(cal, .frenchRepublican, "\(cal) \(stored)")
                    XCTAssertLessThan(f, A.frenchEpoch)
                    continue
                }
                XCTAssertTrue(cal.isValid(shown), "\(cal) \(stored) → \(shown)")
                XCTAssertEqual(cal.stored(from: shown), stored, "\(cal) \(stored) → \(shown)")
                XCTAssertNotNil(cal.format(shown))
                if let previous { XCTAssertNotEqual(previous, shown, "two days shown alike in \(cal)") }
                previous = shown
            }
        }
    }

    func testSampledRoundTripsAcrossTheWholeStoredRange() {
        let first = A.fixedFromGregorian(1, 1, 1), last = A.fixedFromGregorian(9999, 12, 31)
        for cal in DisplayCalendar.allCases {
            for f in stride(from: first, through: last, by: 97) {
                let (y, m, d) = A.gregorianFromFixed(f)
                guard let shown = cal.display(stored: day(y, m, d)) else { continue }
                XCTAssertEqual(cal.stored(from: shown), day(y, m, d), "\(cal) \(y)-\(m)-\(d)")
            }
        }
    }

    // MARK: England, September 1752

    func testEnglishCutoverAnchors() {
        // Wednesday 2 September (O.S.) was followed by Thursday 14 September (N.S.).
        XCTAssertEqual(display(.julianEnglish1752, 1752, 9, 13), day(1752, 9, 2))
        XCTAssertEqual(display(.julianEnglish1752, 1752, 9, 14), day(1752, 9, 14))
        XCTAssertEqual(display(.standard, 1752, 9, 14), day(1752, 9, 14))
        XCTAssertEqual(display(.julian, 1752, 9, 13), day(1752, 9, 2))
        XCTAssertEqual(display(.julian, 1752, 9, 14), day(1752, 9, 3))
        XCTAssertEqual(A.fmod(A.fixedFromGregorian(1752, 9, 13), 7), 3, "RD mod 7: 3 = Wednesday")
        XCTAssertEqual(A.fmod(A.fixedFromGregorian(1752, 9, 14), 7), 4, "Thursday")

        let cal = DisplayCalendar.julianEnglish1752
        for missing in 3...13 { XCTAssertFalse(cal.isValid(day(1752, 9, missing)), "\(missing) Sep 1752") }
        XCTAssertEqual(cal.daysInMonth(year: 1752, month: 9), 19)
        XCTAssertEqual(cal.lastDayOfMonth(year: 1752, month: 9), 30)
        XCTAssertEqual(cal.format(day(1752, 9, 2)), "2 September 1752")
    }

    func testEnglishLeapDay1700IsJulianOnly() {
        XCTAssertTrue(DisplayCalendar.julianEnglish1752.isValid(day(1700, 2, 29)))
        XCTAssertTrue(DisplayCalendar.julian.isValid(day(1700, 2, 29)))
        XCTAssertFalse(DisplayCalendar.standard.isValid(day(1700, 2, 29)))
        XCTAssertEqual(DisplayCalendar.julianEnglish1752.daysInMonth(year: 1700, month: 2), 29)
        XCTAssertEqual(DisplayCalendar.standard.daysInMonth(year: 1700, month: 2), 28)
        XCTAssertEqual(DisplayCalendar.julianEnglish1752.stored(from: day(1700, 2, 29)), day(1700, 3, 11))
        // After the cutover the English calendar is plain Gregorian.
        XCTAssertFalse(DisplayCalendar.julianEnglish1752.isValid(day(1800, 2, 29)))
    }

    // MARK: The stored pre-1582 Julian leap day

    func testStoredJulianLeapDayIsReadAsJulianNotRejected() {
        let stored = day(1500, 2, 29)
        XCTAssertEqual(DisplayCalendar.standard.display(stored: stored), stored, "shown as stored")
        XCTAssertEqual(DisplayCalendar.standard.stored(from: stored), stored, "never rewritten")
        XCTAssertEqual(DisplayCalendar.julian.display(stored: stored), stored)
        XCTAssertEqual(DisplayCalendar.julianEnglish1752.display(stored: stored), stored)
        for cal in DisplayCalendar.allCases where cal != .frenchRepublican {
            XCTAssertNotNil(cal.display(stored: stored), "\(cal)")
        }
        XCTAssertNil(DisplayCalendar.frenchRepublican.display(stored: stored), "before An I")
        // The same day, reached from the Julian side, comes back as its proleptic Gregorian name.
        XCTAssertEqual(DisplayCalendar.julian.stored(from: stored), day(1500, 3, 10))
        XCTAssertEqual(DisplayCalendar.hebrew.display(stored: stored),
                       DisplayCalendar.hebrew.display(stored: day(1500, 3, 10)))
    }

    func testStoredValuesTheGregorianDayRuleRejectsHaveNoDisplay() {
        for bad in [day(1900, 2, 29), day(2026, 2, 31), day(1968, 4, 31), day(2026, 13, 1), day(2026, 0, 1),
                    day(2026, 1, 0), day(0, 1, 1), day(10_000, 1, 1), day(1582, 2, 29), day(1501, 2, 29)] {
            for cal in DisplayCalendar.allCases { XCTAssertNil(cal.display(stored: bad), "\(cal) \(bad)") }
        }
    }

    // MARK: Julian

    func testJulianAnchors() {
        XCTAssertEqual(display(.julian, 1582, 10, 15), day(1582, 10, 5))
        XCTAssertEqual(display(.julian, 1789, 7, 14), day(1789, 7, 3))
        XCTAssertEqual(display(.julian, 1918, 2, 14), day(1918, 2, 1))   // Russia's switch
        XCTAssertEqual(display(.julian, 2026, 10, 11), day(2026, 9, 28))
    }

    /// ICU's Gregorian calendar is Julian before 15 October 1582, so it checks the Julian arithmetic there.
    func testJulianMatchesICUBeforeIts1582Cutover() {
        var icu = Calendar(identifier: .gregorian)
        icu.timeZone = TimeZone(identifier: "UTC")!
        for f in stride(from: A.fixedFromGregorian(1000, 1, 1), to: A.fixedFromGregorian(1582, 10, 15), by: 7) {
            let c = icu.dateComponents([.year, .month, .day], from: date(fixed: f))
            let (y, m, d) = A.julianFromFixed(f)
            XCTAssertEqual([y, m, d], [c.year!, c.month!, c.day!], "RD \(f)")
        }
    }

    // MARK: French Republican

    func testFrenchRepublicanAnchors() {
        let fr = DisplayCalendar.frenchRepublican
        XCTAssertEqual(display(fr, 1792, 9, 22), day(1, 1, 1))
        XCTAssertNil(display(fr, 1792, 9, 21))
        XCTAssertNil(display(fr, 1789, 7, 14))
        XCTAssertEqual(display(fr, 1794, 7, 27), day(2, 11, 9))     // 9 Thermidor An II
        XCTAssertEqual(display(fr, 1795, 9, 22), day(3, 13, 6))     // jour de la Révolution, An III (sextile)
        XCTAssertEqual(display(fr, 1795, 9, 23), day(4, 1, 1))
        XCTAssertEqual(display(fr, 1799, 11, 9), day(8, 2, 18))     // 18 Brumaire An VIII
        XCTAssertEqual(display(fr, 1803, 9, 24), day(12, 1, 1))     // 1 Vendémiaire An XII
        XCTAssertEqual(display(fr, 1804, 12, 2), day(13, 3, 11))    // the coronation, 11 Frimaire An XIII
        XCTAssertEqual(display(fr, 1805, 12, 31), day(14, 4, 10))   // last day in use
        XCTAssertEqual(fr.format(day(12, 1, 1)), "1 Vendémiaire An XII")
        XCTAssertEqual(fr.daysInMonth(year: 3, month: 13), 6)
        XCTAssertEqual(fr.daysInMonth(year: 4, month: 13), 5)
        XCTAssertEqual(fr.daysInMonth(year: 4, month: 1), 30)
        XCTAssertFalse(fr.isValid(day(4, 13, 6)))
        XCTAssertNil(fr.daysInMonth(year: 4, month: 14))
    }

    // MARK: Hebrew

    func testHebrewAnchors() {
        XCTAssertEqual(display(.hebrew, 2024, 10, 3), day(5785, 7, 1))    // Rosh Hashanah 5785
        XCTAssertEqual(display(.hebrew, 2023, 9, 16), day(5784, 7, 1))
        XCTAssertEqual(DisplayCalendar.hebrew.format(day(5785, 7, 1)), "1 Tishri AM 5785")
        XCTAssertEqual(DisplayCalendar.hebrew.monthsInYear(5784), 13)
        XCTAssertEqual(DisplayCalendar.hebrew.monthName(12, year: 5784), "Adar I")
        XCTAssertEqual(DisplayCalendar.hebrew.monthName(12, year: 5785), "Adar")
        XCTAssertNil(DisplayCalendar.hebrew.monthName(13, year: 5785))
        XCTAssertFalse(DisplayCalendar.hebrew.isValid(day(5785, 13, 1)), "no Adar II in a common year")
        XCTAssertEqual(DisplayCalendar.hebrew.daysInMonth(year: 5785, month: 7), 30)   // Tishri
        XCTAssertEqual(DisplayCalendar.hebrew.daysInMonth(year: 5785, month: 10), 29)  // Tevet
    }

    /// ICU numbers months from Tishri = 1, with Adar I = 6 present only in leap years.
    private func icuHebrewMonth(_ m: Int, year: Int) -> Int {
        switch m {
        case 7...11: return m - 6
        case 12: return A.isHebrewLeap(year) ? 6 : 7
        case 13: return 7
        default: return m + 7
        }
    }

    func testHebrewMatchesICUEveryCorpusDay() {
        var icu = Calendar(identifier: .hebrew)
        icu.timeZone = TimeZone(identifier: "UTC")!
        for f in corpusRange {
            let c = icu.dateComponents([.year, .month, .day], from: date(fixed: f))
            let (y, m, d) = A.hebrewFromFixed(f)
            XCTAssertEqual([y, icuHebrewMonth(m, year: y), d], [c.year!, c.month!, c.day!], "RD \(f)")
            if c.year != y { return }   // one failure is enough to read
        }
    }

    func testHebrewMonthLengthsMatchICU() {
        var icu = Calendar(identifier: .hebrew)
        icu.timeZone = TimeZone(identifier: "UTC")!
        for y in 5549...5791 {
            for m in 1...A.hebrewLastMonth(y) {
                let f = A.fixedFromHebrew(y, m, 1)
                let icuLength = icu.range(of: .day, in: .month, for: date(fixed: f))!.count
                XCTAssertEqual(DisplayCalendar.hebrew.daysInMonth(year: y, month: m), icuLength, "\(y)-\(m)")
            }
        }
    }

    // MARK: Islamic

    func testIslamicAnchors() {
        // 1 Muharram AH 1 = Friday 16 July 622 (Julian) = 19 July 622 (Gregorian).
        XCTAssertEqual(display(.islamic, 622, 7, 19), day(1, 1, 1))
        XCTAssertNil(display(.islamic, 622, 7, 18))
        XCTAssertEqual(A.fmod(A.islamicEpoch, 7), 5, "RD mod 7: 5 = Friday")
        XCTAssertEqual(DisplayCalendar.islamic.format(day(1446, 1, 1)), "1 Muharram AH 1446")
        XCTAssertEqual(DisplayCalendar.islamic.daysInMonth(year: 1445, month: 12), 30)  // a leap year
        XCTAssertEqual(DisplayCalendar.islamic.daysInMonth(year: 1446, month: 12), 29)
        XCTAssertEqual(DisplayCalendar.islamic.daysInMonth(year: 1446, month: 9), 30)   // Ramadan
    }

    func testIslamicMatchesICUCivilEveryCorpusDay() {
        var icu = Calendar(identifier: .islamicCivil)
        icu.timeZone = TimeZone(identifier: "UTC")!
        for f in corpusRange {
            let c = icu.dateComponents([.year, .month, .day], from: date(fixed: f))
            let (y, m, d) = A.islamicFromFixed(f)
            XCTAssertEqual([y, m, d], [c.year!, c.month!, c.day!], "RD \(f)")
            if c.year != y { return }
        }
    }

    // MARK: Standard (today's rule) and the API's edges

    func testStandardIsTheGregorianDayRule() {
        let s = DisplayCalendar.standard
        for (y, m, d, valid) in [(2026, 2, 28, true), (2026, 2, 29, false), (2000, 2, 29, true),
                                 (1900, 2, 29, false), (1500, 2, 29, true), (1582, 10, 10, true),
                                 (1968, 4, 31, false), (2026, 2, 31, false)] {
            XCTAssertEqual(s.isValid(day(y, m, d)), valid, "\(y)-\(m)-\(d)")
            XCTAssertEqual(s.display(stored: day(y, m, d)) != nil, valid, "\(y)-\(m)-\(d)")
        }
        XCTAssertEqual(s.format(day(1958, 3, 12)), "12 March 1958")
    }

    func testRawValuesAreStable() {
        // These strings will be persisted (W24.cal1-toggle) — changing one orphans every saved choice.
        XCTAssertEqual(DisplayCalendar.allCases.map(\.rawValue),
                       ["standard", "julian", "julian-1752", "french-republican", "hebrew", "islamic"])
    }

    func testNothingOutsideACalendarIsCoerced() {
        for cal in DisplayCalendar.allCases {
            XCTAssertFalse(cal.isValid(day(0, 1, 1)), "\(cal)")
            XCTAssertFalse(cal.isValid(day(2000, 0, 1)), "\(cal)")
            XCTAssertFalse(cal.isValid(day(2000, 1, 0)), "\(cal)")
            XCTAssertFalse(cal.isValid(day(2000, 14, 1)), "\(cal)")
            XCTAssertNil(cal.daysInMonth(year: 2000, month: 14), "\(cal)")
            XCTAssertNil(cal.format(day(2000, 1, 40)), "\(cal)")
        }
        XCTAssertNil(DisplayCalendar.julian.stored(from: day(1, 1, 1)), "lands in Gregorian year 0")
        XCTAssertEqual(DisplayCalendar.roman(14), "XIV")
        XCTAssertEqual(DisplayCalendar.roman(1999), "MCMXCIX")
    }

    private func date(fixed f: Int) -> Date {
        Date(timeIntervalSince1970: Double(f - A.fixedFromGregorian(1970, 1, 1)) * 86_400 + 43_200)
    }
}
