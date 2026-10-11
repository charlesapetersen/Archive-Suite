import Foundation

/// A year-month-day triple in some calendar. What the numbers mean depends on the `DisplayCalendar` it is
/// paired with; on its own it is just three integers (no validation at construction).
public struct CalendarDay: Sendable, Hashable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// The calendar a stored day is **shown** in (W24.cal1-core). Display and validation only: a stored date
/// is always the proleptic ISO 8601 day the apps already write, and nothing here changes how it is stored.
///
/// A *stored* day means a triple the Notes `GregorianDay` rule accepts — proleptic Gregorian, plus, before
/// 1582, the Julian leap day 29 February (so `1500-02-29` can be on disk). Such a pre-1582 leap day is not a
/// proleptic Gregorian day; it is read as the Julian date it names and converted from that, never rejected
/// or rewritten. Converting *back* from another calendar always yields the canonical proleptic Gregorian
/// day (Julian `1500-02-29` comes back as `1500-03-10`); only `.standard` hands a stored triple back
/// unchanged.
///
/// Pure arithmetic (`CalendarArithmetic`); no locale, no `Foundation.Calendar`. A conversion that has no
/// answer — a day before the calendar's epoch, a triple that does not exist — is `nil`, never a coerced value.
public enum DisplayCalendar: String, CaseIterable, Sendable, Codable {
    /// Today's rule, shown as stored: Gregorian, with Julian leap years accepted before 1582.
    case standard
    /// Proleptic Julian ("Old Style") throughout.
    case julian
    /// Julian until Wednesday 2 September 1752, Gregorian from Thursday 14 September 1752 — Britain and its
    /// colonies. Only the day changes; the old 25 March start of the legal year is not modelled.
    case julianEnglish1752 = "julian-1752"
    /// The French Republican calendar, from 1 Vendémiaire An I (1792-09-22). Month 13 is the jours
    /// complémentaires.
    case frenchRepublican = "french-republican"
    /// The arithmetic Hebrew calendar. Months are numbered from Nisan = 1, so the year begins at Tishri = 7;
    /// in a leap year month 12 is Adar I and 13 is Adar II.
    case hebrew
    /// The tabular Islamic calendar (civil epoch, 30-year cycle). Observational calendars can differ by a
    /// day or two.
    case islamic

    /// The stored years this module converts. `ArchiveDate` and the Notes date fields stay inside it.
    public static let storedYearRange = 1...9999

    public var displayName: String {
        switch self {
        case .standard: return "Gregorian (as stored)"
        case .julian: return "Julian"
        case .julianEnglish1752: return "Julian, English 1752 cutover"
        case .frenchRepublican: return "French Republican"
        case .hebrew: return "Hebrew"
        case .islamic: return "Islamic (tabular)"
        }
    }

    // MARK: Stored ↔ display

    /// The stored ISO day shown in this calendar, or nil when the stored triple is not a day the
    /// `GregorianDay` rule accepts, or the day falls before this calendar's epoch.
    public func display(stored: CalendarDay) -> CalendarDay? {
        guard let fixed = Self.fixedDay(stored: stored) else { return nil }
        if self == .standard { return stored }
        return day(fromFixed: fixed)
    }

    /// The ISO day to store for a day entered in this calendar, or nil when it does not exist in this
    /// calendar or lands outside `storedYearRange`.
    public func stored(from display: CalendarDay) -> CalendarDay? {
        guard let fixed = fixed(from: display) else { return nil }
        if self == .standard { return display }
        let (y, m, d) = CalendarArithmetic.gregorianFromFixed(fixed)
        guard Self.storedYearRange.contains(y) else { return nil }
        return CalendarDay(year: y, month: m, day: d)
    }

    /// The day count of a stored triple: proleptic Gregorian when it is one, else a pre-1582 Julian leap
    /// day read as Julian. Nil for anything the `GregorianDay` rule rejects.
    static func fixedDay(stored s: CalendarDay) -> Int? {
        guard storedYearRange.contains(s.year), (1...12).contains(s.month), s.day >= 1 else { return nil }
        if s.day <= CalendarArithmetic.gregorianMonthLength(year: s.year, month: s.month) {
            return CalendarArithmetic.fixedFromGregorian(s.year, s.month, s.day)
        }
        if s.year < 1582, s.month == 2, s.day == 29, CalendarArithmetic.isJulianLeap(s.year) {
            return CalendarArithmetic.fixedFromJulian(s.year, s.month, s.day)
        }
        return nil
    }

    // MARK: Validation

    /// True when the triple names a day that exists in this calendar (year 1 or later).
    public func isValid(_ day: CalendarDay) -> Bool { fixed(from: day) != nil }

    /// Months in `year` (13 in a Hebrew leap year and in every French Republican year), nil before year 1.
    public func monthsInYear(_ year: Int) -> Int? {
        guard year >= 1 else { return nil }
        switch self {
        case .standard, .julian, .julianEnglish1752, .islamic: return 12
        case .frenchRepublican: return 13
        case .hebrew: return CalendarArithmetic.hebrewLastMonth(year)
        }
    }

    /// How many days of `month` exist, or nil when the year-month does not. Usually the last day's
    /// number — except September 1752 under `.julianEnglish1752`, which has 19 (1–2, then 14–30); ask
    /// `isValid` for a particular day.
    public func daysInMonth(year: Int, month: Int) -> Int? {
        guard let last = lastDayOfMonth(year: year, month: month) else { return nil }
        return (1...last).filter { isValid(CalendarDay(year: year, month: month, day: $0)) }.count
    }

    /// The number of the month's last day, or nil when the year-month does not exist.
    public func lastDayOfMonth(year: Int, month: Int) -> Int? {
        guard let months = monthsInYear(year), (1...months).contains(month) else { return nil }
        typealias A = CalendarArithmetic
        switch self {
        case .standard:
            return month == 2 && year < 1582 && A.isJulianLeap(year)
                ? 29 : A.gregorianMonthLength(year: year, month: month)
        case .julian: return A.julianMonthLength(year: year, month: month)
        case .julianEnglish1752:
            return year < 1752 || (year == 1752 && month <= 9)
                ? A.julianMonthLength(year: year, month: month) : A.gregorianMonthLength(year: year, month: month)
        case .frenchRepublican: return A.frenchMonthLength(year: year, month: month)
        case .hebrew: return A.hebrewMonthLength(year: year, month: month)
        case .islamic: return A.islamicMonthLength(year: year, month: month)
        }
    }

    // MARK: Names

    public func monthName(_ month: Int, year: Int) -> String? {
        guard let months = monthsInYear(year), (1...months).contains(month) else { return nil }
        switch self {
        case .standard, .julian, .julianEnglish1752: return Self.westernMonths[month - 1]
        case .frenchRepublican: return Self.frenchMonths[month - 1]
        case .islamic: return Self.islamicMonths[month - 1]
        case .hebrew:
            if month == 12 && CalendarArithmetic.isHebrewLeap(year) { return "Adar I" }
            return Self.hebrewMonths[month - 1]
        }
    }

    /// "2 September 1752", "13 Vendémiaire An XII", "1 Tishri AM 5785", "1 Muharram AH 1446"; nil when
    /// the day does not exist in this calendar.
    public func format(_ day: CalendarDay) -> String? {
        guard isValid(day), let name = monthName(day.month, year: day.year) else { return nil }
        switch self {
        case .standard, .julian, .julianEnglish1752: return "\(day.day) \(name) \(day.year)"
        case .frenchRepublican: return "\(day.day) \(name) An \(Self.roman(day.year))"
        case .hebrew: return "\(day.day) \(name) AM \(day.year)"
        case .islamic: return "\(day.day) \(name) AH \(day.year)"
        }
    }

    // MARK: Day counts

    /// Validates `d` in this calendar and returns its day count.
    func fixed(from d: CalendarDay) -> Int? {
        guard let last = lastDayOfMonth(year: d.year, month: d.month), (1...last).contains(d.day) else { return nil }
        typealias A = CalendarArithmetic
        switch self {
        case .standard: return Self.fixedDay(stored: d)
        case .julian: return A.fixedFromJulian(d.year, d.month, d.day)
        case .julianEnglish1752:
            let ymd = (d.year, d.month, d.day)
            if ymd <= (1752, 9, 2) { return A.fixedFromJulian(d.year, d.month, d.day) }
            if ymd >= (1752, 9, 14) { return A.fixedFromGregorian(d.year, d.month, d.day) }
            return nil
        case .frenchRepublican: return A.fixedFromFrench(d.year, d.month, d.day)
        case .hebrew: return A.fixedFromHebrew(d.year, d.month, d.day)
        case .islamic: return A.fixedFromIslamic(d.year, d.month, d.day)
        }
    }

    /// The day count shown in this calendar; nil before the calendar's year 1.
    func day(fromFixed f: Int) -> CalendarDay? {
        typealias A = CalendarArithmetic
        let ymd: (Int, Int, Int)
        switch self {
        case .standard: ymd = A.gregorianFromFixed(f)
        case .julian: ymd = A.julianFromFixed(f)
        case .julianEnglish1752:
            ymd = f < A.fixedFromGregorian(1752, 9, 14) ? A.julianFromFixed(f) : A.gregorianFromFixed(f)
        case .frenchRepublican:
            guard f >= A.frenchEpoch else { return nil }
            ymd = A.frenchFromFixed(f)
        case .hebrew:
            guard f >= A.hebrewEpoch else { return nil }
            ymd = A.hebrewFromFixed(f)
        case .islamic:
            guard f >= A.islamicEpoch else { return nil }
            ymd = A.islamicFromFixed(f)
        }
        guard ymd.0 >= 1 else { return nil }
        return CalendarDay(year: ymd.0, month: ymd.1, day: ymd.2)
    }

    private static let westernMonths = ["January", "February", "March", "April", "May", "June", "July",
                                        "August", "September", "October", "November", "December"]
    private static let frenchMonths = ["Vendémiaire", "Brumaire", "Frimaire", "Nivôse", "Pluviôse", "Ventôse",
                                       "Germinal", "Floréal", "Prairial", "Messidor", "Thermidor", "Fructidor",
                                       "jours complémentaires"]
    private static let hebrewMonths = ["Nisan", "Iyyar", "Sivan", "Tammuz", "Av", "Elul", "Tishri", "Heshvan",
                                       "Kislev", "Tevet", "Shevat", "Adar", "Adar II"]
    private static let islamicMonths = ["Muharram", "Safar", "Rabi' al-awwal", "Rabi' al-thani",
                                        "Jumada al-ula", "Jumada al-akhira", "Rajab", "Sha'ban", "Ramadan",
                                        "Shawwal", "Dhu al-Qa'dah", "Dhu al-Hijjah"]

    static func roman(_ n: Int) -> String {
        let table = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
                     (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, out = ""
        for (value, glyph) in table { while n >= value { out += glyph; n -= value } }
        return out
    }
}
