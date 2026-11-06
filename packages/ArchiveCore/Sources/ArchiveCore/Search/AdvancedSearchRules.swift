import Foundation

// MARK: - Advanced Search, the parts both apps share (W40.notes-advanced-search)
//
// The Reader's and Notes' Advanced Search are Finder-style rule trees: "all" or "any of the following rules", each
// row a field, an operator and a value. The fields differ by app (OCR text and read state in the Reader; note
// text, authors and kind in Notes), so each app keeps its own field enum and rule row; what is the same is here:
// how a list combines, the operators, which of an item's two dates a date rule reads, how typed words become a
// safe FTS5 expression, and how a typed date becomes a key range. Pure and UI-free.

/// How a list of rules combines.
public enum RuleCombine: String, Codable, Sendable, CaseIterable {
    case all, any
}

public enum RuleOperator: String, Codable, Sendable {
    case allWords, phrase, anyWords, noWords
    case contains, doesNotContain, beginsWith, endsWith
    case hasAll, hasAny, hasNone
    case `is`, isNot
    /// Dates: `between` uses the "from" … "to" values; `after` and `before` are inclusive of the value typed, which
    /// is a year, a year-month, a full date or a decade.
    case between, after, before, undated
}

/// Which of an item's two dates a date rule looks at (W37.dual-date).
public enum DateRoleChoice: String, Codable, Sendable, CaseIterable {
    case either, own, sentWith

    public var roles: [DateRole] {
        switch self {
        case .either: return DateRole.allCases
        case .own: return [.own]
        case .sentWith: return [.sentWith]
        }
    }
}

public enum AdvancedSearchText {
    /// The words of a text box: split on white space, outer quotes dropped. A token with no letter or digit
    /// ("-", "&") is no word: an FTS5 index holds no such token, so it could only ever match nothing.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201c}\u{201d}")) }
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
    }

    /// A safe FTS5 expression for one text rule; no typed text can be FTS5 syntax. Each word is quoted, its own
    /// quotes doubled; a word typed with a trailing `*` matches as a prefix. `column` restricts it to one column.
    /// `op` is one of the text operators (`allWords`, `phrase`, `anyWords`, `noWords`); for `noWords` the
    /// expression finds the items to leave out (any of the words).
    public static func ftsExpression(op: RuleOperator, text: String, column: String?) -> String? {
        let ws = words(text)
        guard !ws.isEmpty else { return nil }
        func quoted(_ w: String) -> String {
            let prefix = w.hasSuffix("*")
            let bare = prefix ? String(w.dropLast()) : w
            return "\"" + bare.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (prefix ? "*" : "")
        }
        let body: String
        switch op {
        case .phrase:
            let phrase = ws.map { $0.hasSuffix("*") ? String($0.dropLast()) : $0 }.joined(separator: " ")
            body = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .anyWords, .noWords: body = ws.map(quoted).joined(separator: " OR ")
        default: body = ws.map(quoted).joined(separator: " ")
        }
        guard let column else { return ws.count == 1 || op == .phrase ? body : "(\(body))" }
        return "\(column) : (\(body))"
    }

    /// The inclusive key range a typed date covers: "1981", "1981-06", "1981-06-30" or "1950s". Single-digit
    /// months and days are accepted ("1981-6-3"). nil when it is not a date.
    public static func dateKeys(_ text: String) -> (lower: Int, upper: Int)? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let padded = s.split(separator: "-", omittingEmptySubsequences: false).enumerated()
            .map { i, p in i > 0 && p.count == 1 ? "0" + p : String(p) }.joined(separator: "-")
        guard let d = ArchiveDate.parse(wireValue: padded) else { return nil }
        let key = d.sortKey
        switch d.precision {
        case .decade: return (key, (d.year + 9) * 10_000 + 1231)
        case .year: return (key, d.year * 10_000 + 1231)
        case .month: return (key, d.year * 10_000 + d.month! * 100 + 31)
        case .day: return (key, key)
        }
    }

    /// A date rule's inclusive key bounds (`DocumentTags.sortDateKey` space), or nil while a value it needs is
    /// missing or unreadable. A year runs from its first to its last day, a month likewise. `between` with one
    /// side left empty is open on that side.
    public static func dateBounds(op: RuleOperator, from text: String, to text2: String) -> DateRangeFilter? {
        let from = dateKeys(text), to = dateKeys(text2)
        switch op {
        case .after: return from.map { DateRangeFilter(lower: $0.lower, upper: nil) }
        case .before: return from.map { DateRangeFilter(lower: nil, upper: $0.upper) }
        case .between:
            switch (from, to) {
            case let (f?, t?): return DateRangeFilter(lower: f.lower, upper: t.upper)
            case let (f?, nil) where text2.trimmingCharacters(in: .whitespaces).isEmpty:
                return DateRangeFilter(lower: f.lower, upper: nil)
            case let (nil, t?) where text.trimmingCharacters(in: .whitespaces).isEmpty:
                return DateRangeFilter(lower: nil, upper: t.upper)
            default: return nil
            }
        default: return nil
        }
    }

    /// Whether a date rule matches an item's date keys: `undated` when none of the chosen roles has a date, else
    /// when one of them lies inside `bounds`.
    public static func dateMatches(op: RuleOperator, bounds: DateRangeFilter?, role: DateRoleChoice,
                                   keys: [DateRole: Int]) -> Bool? {
        let roles = role.roles
        if op == .undated { return !roles.contains { keys[$0] != nil } }
        guard let bounds else { return nil }
        return roles.contains { keys[$0].map(bounds.contains) ?? false }
    }
}
