import Foundation

/// The Processor's tag vocabulary and formatting — the struct that `TagGenerator` builds and
/// `MacOSTagger` writes.  Pure value type, no LLM dependencies.  Moved to ArchiveCore so that
/// Archive Notes (and any future consumer) can read/format the same vocabulary without pulling
/// in Processor's LLM stack.
///
/// The emit order of `allTags` and the title-casing / date-token formatting are the canonical
/// source for `SPEC/tag-format.md §Finder tags (page 1)`.
public struct GeneratedTags: Codable, Sendable {
    public var year: String?             // e.g. "1987"
    public var month: String?            // e.g. "03 March"
    public var day: String?              // e.g. "Day 15"
    public var dateUncertain: Bool
    public var ocrFailed: Bool
    public var subjectTags: [String]
    public var colorTag: String?         // "Red" or "Purple"

    // Extended metadata for JSON export
    public var format: String?           // e.g. "letter", "memo", "newspaper article"
    public var authorName: String?
    public var recipientName: String?
    public var authorLocation: String?
    public var recipientLocation: String?
    public var publicationName: String?

    public init(
        year: String? = nil,
        month: String? = nil,
        day: String? = nil,
        dateUncertain: Bool = false,
        ocrFailed: Bool = false,
        subjectTags: [String] = [],
        colorTag: String? = nil,
        format: String? = nil,
        authorName: String? = nil,
        recipientName: String? = nil,
        authorLocation: String? = nil,
        recipientLocation: String? = nil,
        publicationName: String? = nil
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.dateUncertain = dateUncertain
        self.ocrFailed = ocrFailed
        self.subjectTags = subjectTags
        self.colorTag = colorTag
        self.format = format
        self.authorName = authorName
        self.recipientName = recipientName
        self.authorLocation = authorLocation
        self.recipientLocation = recipientLocation
        self.publicationName = publicationName
    }

    /// Capitalize only the first letter of each word, preserving the rest (unlike .capitalized which lowercases non-initial letters).
    public static func capitalizeFirstLetters(_ string: String) -> String {
        string.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard let first = word.first else { return String(word) }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    public var allTags: [String] {
        var tags: [String] = []
        if ocrFailed {
            tags.append("OCR Failed")
            if let c = colorTag { tags.append(c) }
            return tags
        }
        if let y = year { tags.append(y) }
        if let m = month { tags.append(Self.capitalizeFirstLetters(m)) }
        if let d = day { tags.append(d) }
        if dateUncertain { tags.append("Date Uncertain") }
        tags.append(contentsOf: subjectTags.map { Self.capitalizeFirstLetters($0) })
        if let c = colorTag { tags.append(c) }
        return tags
    }

    /// Machine-readable date string (ISO 8601 partial), e.g. "1987-03-15", "1987-03", "1987"
    public var machineDate: String? {
        guard let y = year else { return nil }
        var date = y
        if let m = month, let monthNum = Self.monthNumber(from: m) {
            date += String(format: "-%02d", monthNum)
            if let d = day, let dayNum = Self.dayNumber(from: d) {
                date += String(format: "-%02d", dayNum)
            }
        }
        return date
    }

    /// Parse a month from the "MM Month" tag form ("03 March"), a bare number, or a bare name — so
    /// the JSON `date` doesn't silently drop a month the user typed as "March" instead of "03 March".
    public static func monthNumber(from s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed.prefix(2)), (1...12).contains(n) { return n }
        if let n = Int(trimmed), (1...12).contains(n) { return n }
        let lower = trimmed.lowercased()
        let names = ["january", "february", "march", "april", "may", "june",
                     "july", "august", "september", "october", "november", "december"]
        if let idx = names.firstIndex(where: { lower.contains($0) }) { return idx + 1 }
        return nil
    }

    /// Canonical English month names — the single source for building "MM MonthName" date tags.
    public static let englishMonthNames = ["January", "February", "March", "April", "May", "June",
                                           "July", "August", "September", "October", "November", "December"]

    /// Build a "MM MonthName" month tag (e.g. "03 March") for a 1...12 month; nil for an out-of-range month.
    public static func monthTag(_ month: Int) -> String? {
        guard (1...12).contains(month) else { return nil }
        return String(format: "%02d %@", month, englishMonthNames[month - 1])
    }

    /// Parse a day-of-month from "Day 15", "day 15", or "15".
    public static func dayNumber(from s: String) -> Int? {
        let digits = s.filter { $0.isNumber }
        guard let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }

    /// Coerce a JSON value to a trimmed non-empty String — LLMs often return year/month/day as a
    /// JSON *number* (`"year": 1987`), which `as? String` would drop, spuriously forcing a no-date.
    public static func stringField(_ value: Any?) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(Int(d)) }
        return nil
    }
}
