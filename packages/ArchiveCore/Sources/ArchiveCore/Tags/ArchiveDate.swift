import Foundation

/// One whole date value with its own precision (decade / year / month / day). Used for a role-labelled
/// date that must travel as a single unit so its precision can never cross-pair with another role's
/// components — W37.dual-date's covering-letter ("sent with") date. The item's own date keeps the
/// separate Year/Month/Day/Decade facets (`DocumentTags`). See SPEC/tag-format.md §Sent-with date.
public struct ArchiveDate: Sendable, Hashable, Codable {
    public enum Precision: String, Sendable, Codable, CaseIterable {
        case decade, year, month, day
    }

    /// The year; for `.decade` precision, the decade START year (1950 for "1950s").
    public let year: Int
    public let month: Int?
    public let day: Int?
    public let precision: Precision

    /// A decade value ("1950s"). `nil` unless `start` is a 3–4 digit year ending in 0.
    public init?(decade start: Int) {
        guard (100...9990).contains(start), start % 10 == 0 else { return nil }
        year = start; month = nil; day = nil; precision = .decade
    }

    /// A year, year-month or year-month-day value. A day needs a month; a day must exist in that month
    /// (Gregorian leap years). `nil` for anything out of range — never a coerced value.
    public init?(year: Int, month: Int? = nil, day: Int? = nil) {
        guard (100...9999).contains(year) else { return nil }
        if let month { guard (1...12).contains(month) else { return nil } }
        if let day {
            guard let month, (1...Self.daysIn(month: month, year: year)).contains(day) else { return nil }
        }
        self.year = year; self.month = month; self.day = day
        precision = day != nil ? .day : (month != nil ? .month : .year)
    }

    /// The SPEC sort key (`year * 10_000 + month * 100 + day`), via the one shared formula.
    public var sortKey: Int {
        precision == .decade
            ? DocumentTags.sortDateKey(year: nil, month: nil, day: nil, decade: year)!
            : DocumentTags.sortDateKey(year: year, month: month, day: day, decade: nil)!
    }

    /// The wire value: "1958", "1958-03", "1958-03-12" or "1950s".
    public var wireValue: String {
        switch precision {
        case .decade: return "\(year)s"
        case .year: return String(year)
        case .month: return String(format: "%d-%02d", year, month!)
        case .day: return String(format: "%d-%02d-%02d", year, month!, day!)
        }
    }

    /// Parse a wire value strictly: 3–4 ASCII year digits with no leading zero, zero-padded two-digit
    /// month/day, or a decade "NNN0s". Anything else (including a valid-looking but impossible date such
    /// as "1958-02-30") is `nil`, so the token stays a verbatim subject rather than inventing a date.
    public static func parse(wireValue s: String) -> ArchiveDate? {
        guard s.allSatisfy(\.isASCII) else { return nil }
        if s.hasSuffix("s") {
            let digits = String(s.dropLast())
            guard let y = strictYear(digits) else { return nil }
            return ArchiveDate(decade: y)
        }
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(parts.count), let y = strictYear(parts[0]) else { return nil }
        var month: Int?
        var day: Int?
        if parts.count >= 2 { guard let m = twoDigits(parts[1]) else { return nil }; month = m }
        if parts.count == 3 { guard let d = twoDigits(parts[2]) else { return nil }; day = d }
        return ArchiveDate(year: y, month: month, day: day)
    }

    /// Display form matching `DocumentTags.displayDate`: "1958", "Mar 1958", "Mar 12, 1958", "1950s".
    public var display: String {
        switch precision {
        case .decade: return "\(year)s"
        case .year: return String(year)
        case .month, .day:
            let mon = DocumentTags.monthNames[month! - 1].prefix(3)
            if let day { return "\(mon) \(day), \(year)" }
            return "\(mon) \(year)"
        }
    }

    private static func strictYear(_ s: String) -> Int? {
        guard (3...4).contains(s.count), s.allSatisfy({ ("0"..."9").contains($0) }),
              let y = Int(s), String(y) == s else { return nil }
        return y
    }

    private static func twoDigits(_ s: String) -> Int? {
        guard s.count == 2, s.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(s)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}

/// The two date roles a document can carry (W37.dual-date). `own` is the item's own date (the
/// Year/Month/Day/Decade facets); `sentWith` is the date of the covering letter it was enclosed with.
public enum DateRole: String, Sendable, Codable, CaseIterable {
    case own
    case sentWith = "sent_with"

    public var label: String { self == .own ? "Date" : "Sent with" }
}

/// The wire spelling of the sent-with date: `Sent With <wireValue>` plus the independent
/// `Sent With Date Uncertain` flag. Exact, case-sensitive title-cased prefix — a lower-cased or
/// malformed lookalike stays an ordinary subject, verbatim.
public enum SentWithTag {
    public static let prefix = "Sent With "
    public static let uncertainToken = "Sent With Date Uncertain"

    public static func token(for date: ArchiveDate) -> String { prefix + date.wireValue }

    /// The date a trimmed token carries, or `nil` when it is not a valid sent-with date token
    /// (including the uncertain flag, which is not a date).
    public static func parse(_ s: String) -> ArchiveDate? {
        guard s.hasPrefix(prefix) else { return nil }
        return ArchiveDate.parse(wireValue: String(s.dropFirst(prefix.count)))
    }
}

/// A closed date range over SPEC sort keys (`year * 10_000 + month * 100 + day`). Each date value is
/// tested on its own: BOTH bounds must be satisfied by the SAME value, so a document dated 1950 and
/// sent with a 1970 letter never matches 1960–1965. Year-only and decade values keep their sort-key
/// position (1950s → 19500000); this is not interval overlap.
public struct DateRangeFilter: Sendable, Hashable, Codable {
    public var lower: Int?
    public var upper: Int?

    public init(lower: Int? = nil, upper: Int? = nil) { self.lower = lower; self.upper = upper }

    /// Whole-year bounds: `fromYear` January 1 (key `y*10_000`, so a year-only value of that year is
    /// inside) through the end of `toYear`.
    public init(fromYear: Int?, toYear: Int?) {
        lower = fromYear.map { $0 * 10_000 }
        upper = toYear.map { $0 * 10_000 + 1231 }
    }

    public var isUnbounded: Bool { lower == nil && upper == nil }

    public func contains(_ key: Int) -> Bool {
        if let lower, key < lower { return false }
        if let upper, key > upper { return false }
        return true
    }

    /// The roles whose own value lies inside the range, in `DateRole` order; empty when none does.
    public func matchingRoles(_ keys: [DateRole: Int]) -> [DateRole] {
        DateRole.allCases.filter { role in keys[role].map(contains) ?? false }
    }
}
