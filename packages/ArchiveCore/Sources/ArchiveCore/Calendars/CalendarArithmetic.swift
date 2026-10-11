import Foundation

/// Fixed-day arithmetic behind `DisplayCalendar` (W24.cal1-core). Every calendar converts to and from one
/// integer day count — the *Rata Die* of Reingold & Dershowitz, *Calendrical Calculations* (RD 1 =
/// Monday 0001-01-01 proleptic Gregorian) — so any two calendars convert through it. Pure integer
/// arithmetic, deliberately not `Foundation.Calendar`: ICU's Gregorian is a Julian→Gregorian hybrid that
/// deletes the ten 1582 cutover days, and `Calendar.current` follows the user's locale (see the Notes
/// `GregorianDay` header, which measured both).
enum CalendarArithmetic {

    /// Floor division and modulo — Swift's `/` and `%` truncate toward zero, which is wrong for the
    /// negative day counts before RD 1.
    static func fdiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
    static func fmod(_ a: Int, _ b: Int) -> Int { a - b * fdiv(a, b) }

    // MARK: Gregorian (proleptic)

    static func isGregorianLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }

    static func gregorianMonthLength(year y: Int, month m: Int) -> Int {
        switch m {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isGregorianLeap(y) ? 29 : 28
        }
    }

    static func fixedFromGregorian(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let p = y - 1
        return 365 * p + fdiv(p, 4) - fdiv(p, 100) + fdiv(p, 400) + fdiv(367 * m - 362, 12)
            + (m <= 2 ? 0 : (isGregorianLeap(y) ? -1 : -2)) + d
    }

    static func gregorianYearFromFixed(_ date: Int) -> Int {
        let d0 = date - 1
        let n400 = fdiv(d0, 146_097), d1 = fmod(d0, 146_097)
        let n100 = fdiv(d1, 36_524), d2 = fmod(d1, 36_524)
        let n4 = fdiv(d2, 1_461), d3 = fmod(d2, 1_461)
        let n1 = fdiv(d3, 365)
        let year = 400 * n400 + 100 * n100 + 4 * n4 + n1
        return (n100 == 4 || n1 == 4) ? year : year + 1
    }

    static func gregorianFromFixed(_ date: Int) -> (Int, Int, Int) {
        let y = gregorianYearFromFixed(date)
        let priorDays = date - fixedFromGregorian(y, 1, 1)
        let correction = date < fixedFromGregorian(y, 3, 1) ? 0 : (isGregorianLeap(y) ? 1 : 2)
        let m = fdiv(12 * (priorDays + correction) + 373, 367)
        return (y, m, date - fixedFromGregorian(y, m, 1) + 1)
    }

    // MARK: Julian (proleptic, astronomical year numbering — only years ≥ 1 ever reach the public API)

    static func isJulianLeap(_ y: Int) -> Bool { fmod(y, 4) == 0 }

    static func julianMonthLength(year y: Int, month m: Int) -> Int {
        m == 2 ? (isJulianLeap(y) ? 29 : 28) : gregorianMonthLength(year: 2001, month: m)
    }

    /// RD of Julian 0001-01-01 (= Gregorian 0000-12-30).
    static let julianEpoch = -1

    static func fixedFromJulian(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let p = y - 1
        return julianEpoch - 1 + 365 * p + fdiv(p, 4) + fdiv(367 * m - 362, 12)
            + (m <= 2 ? 0 : (isJulianLeap(y) ? -1 : -2)) + d
    }

    static func julianFromFixed(_ date: Int) -> (Int, Int, Int) {
        let y = fdiv(4 * (date - julianEpoch) + 1_464, 1_461)
        let priorDays = date - fixedFromJulian(y, 1, 1)
        let correction = date < fixedFromJulian(y, 3, 1) ? 0 : (isJulianLeap(y) ? 1 : 2)
        let m = fdiv(12 * (priorDays + correction) + 373, 367)
        return (y, m, date - fixedFromJulian(y, m, 1) + 1)
    }

    // MARK: Islamic (tabular / arithmetic, civil "Friday" epoch)

    /// RD of 1 Muharram AH 1 = Julian 622-07-16.
    static let islamicEpoch = fixedFromJulian(622, 7, 16)

    /// The 30-year cycle's leap years 2, 5, 7, 10, 13, 16, 18, 21, 24, 26, 29 — the rule ICU calls
    /// `islamic-civil`.
    static func isIslamicLeap(_ y: Int) -> Bool { fmod(14 + 11 * y, 30) < 11 }

    static func islamicMonthLength(year y: Int, month m: Int) -> Int {
        m % 2 == 1 ? 30 : (m == 12 && isIslamicLeap(y) ? 30 : 29)
    }

    static func fixedFromIslamic(_ y: Int, _ m: Int, _ d: Int) -> Int {
        d + 29 * (m - 1) + fdiv(6 * m - 1, 11) + (y - 1) * 354 + fdiv(3 + 11 * y, 30) + islamicEpoch - 1
    }

    static func islamicFromFixed(_ date: Int) -> (Int, Int, Int) {
        let y = fdiv(30 * (date - islamicEpoch) + 10_646, 10_631)
        let priorDays = date - fixedFromIslamic(y, 1, 1)
        let m = fdiv(11 * priorDays + 330, 325)
        return (y, m, date - fixedFromIslamic(y, m, 1) + 1)
    }

    // MARK: Hebrew (arithmetic; months numbered from Nisan = 1, Tishri = 7, Adar II = 13)

    /// RD of 1 Tishri AM 1 = Julian 3761 BCE October 7 (astronomical year -3760); RD -1,373,427.
    static let hebrewEpoch = fixedFromJulian(-3_760, 10, 7)

    static func isHebrewLeap(_ y: Int) -> Bool { fmod(7 * y + 1, 19) < 7 }

    static func hebrewLastMonth(_ y: Int) -> Int { isHebrewLeap(y) ? 13 : 12 }

    static func hebrewElapsedDays(_ y: Int) -> Int {
        let monthsElapsed = fdiv(235 * y - 234, 19)
        let partsElapsed = 12_084 + 13_753 * monthsElapsed
        let days = 29 * monthsElapsed + fdiv(partsElapsed, 25_920)
        return fmod(3 * (days + 1), 7) < 3 ? days + 1 : days
    }

    static func hebrewYearLengthCorrection(_ y: Int) -> Int {
        let ny0 = hebrewElapsedDays(y - 1), ny1 = hebrewElapsedDays(y), ny2 = hebrewElapsedDays(y + 1)
        if ny2 - ny1 == 356 { return 2 }
        if ny1 - ny0 == 382 { return 1 }
        return 0
    }

    static func hebrewNewYear(_ y: Int) -> Int {
        hebrewEpoch + hebrewElapsedDays(y) + hebrewYearLengthCorrection(y)
    }

    static func hebrewDaysInYear(_ y: Int) -> Int { hebrewNewYear(y + 1) - hebrewNewYear(y) }

    static func hebrewMonthLength(year y: Int, month m: Int) -> Int {
        let length = hebrewDaysInYear(y)
        if [2, 4, 6, 10, 13].contains(m) { return 29 }
        if m == 12 && !isHebrewLeap(y) { return 29 }
        if m == 8 && !(length == 355 || length == 385) { return 29 }   // Heshvan is long only in a complete year
        if m == 9 && (length == 353 || length == 383) { return 29 }    // Kislev is short in a deficient year
        return 30
    }

    static func fixedFromHebrew(_ y: Int, _ m: Int, _ d: Int) -> Int {
        var days = hebrewNewYear(y) + d - 1
        if m < 7 {
            for mm in 7...hebrewLastMonth(y) { days += hebrewMonthLength(year: y, month: mm) }
            for mm in stride(from: 1, to: m, by: 1) { days += hebrewMonthLength(year: y, month: mm) }
        } else {
            for mm in stride(from: 7, to: m, by: 1) { days += hebrewMonthLength(year: y, month: mm) }
        }
        return days
    }

    static func hebrewFromFixed(_ date: Int) -> (Int, Int, Int) {
        // Mean year length 35975351/98496 days gives a guess at most one year low.
        var y = Int((Double(date - hebrewEpoch) * 98_496 / 35_975_351).rounded(.down))
        while hebrewNewYear(y + 1) <= date { y += 1 }
        var m = date < fixedFromHebrew(y, 1, 1) ? 7 : 1
        while date > fixedFromHebrew(y, m, hebrewMonthLength(year: y, month: m)) { m += 1 }
        return (y, m, date - fixedFromHebrew(y, m, 1) + 1)
    }

    // MARK: French Republican

    /// RD of 1 Vendémiaire An I = Gregorian 1792-09-22.
    static let frenchEpoch = fixedFromGregorian(1792, 9, 22)

    /// Years III, VII, XI and XV were the sextile years actually decreed (equinox-based); from An XX on,
    /// Romme's proposed rule (÷4, except ÷100 unless ÷400, except ÷4000). The calendar was abolished
    /// after 10 Nivôse An XIV (1805-12-31); later years are the conventional proleptic continuation.
    static func isFrenchLeap(_ y: Int) -> Bool {
        if y < 20 { return [3, 7, 11, 15].contains(y) }
        return y % 4 == 0 && ![100, 200, 300].contains(y % 400) && y % 4_000 != 0
    }

    /// Months 1–12 have 30 days; month 13 is the jours complémentaires (5, or 6 in a sextile year).
    static func frenchMonthLength(year y: Int, month m: Int) -> Int {
        m < 13 ? 30 : (isFrenchLeap(y) ? 6 : 5)
    }

    /// Sextile years among An I…An n. The decreed four (III–XV) are exactly Romme's count up to An XIX, so
    /// one closed form serves from An XIX on.
    static func frenchLeapYears(through n: Int) -> Int {
        n < 19 ? (n + 1) / 4 : n / 4 - n / 100 + n / 400 - n / 4_000
    }

    static func frenchNewYear(_ y: Int) -> Int {
        frenchEpoch + 365 * (y - 1) + frenchLeapYears(through: y - 1)
    }

    static func fixedFromFrench(_ y: Int, _ m: Int, _ d: Int) -> Int {
        frenchNewYear(y) + 30 * (m - 1) + d - 1
    }

    /// `date` must be on or after `frenchEpoch`.
    static func frenchFromFixed(_ date: Int) -> (Int, Int, Int) {
        var y = max(1, (date - frenchEpoch) * 10_000 / 3_652_422)   // a guess at most a year off
        while y > 1 && frenchNewYear(y) > date { y -= 1 }
        while frenchNewYear(y + 1) <= date { y += 1 }
        let dayOfYear = date - frenchNewYear(y)
        return (y, dayOfYear / 30 + 1, dayOfYear % 30 + 1)
    }
}
