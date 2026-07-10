import Foundation

// MARK: - Facet types
//
// This file classifies a file's macOS Finder tag array into facets for DISPLAY / SORT / FILTER only.
// Parsing NEVER mutates a file and its result must NEVER drive a destructive write — TagWriter always
// operates on the verbatim raw array, not on these interpreted facets. (See CLAUDE.md → Safety.)
//
// It is intentionally UI-free (no SwiftUI/AppKit) so it can move into the shared `ArchiveCore`
// package at Archive Suite convergence.

/// The read-state facet — the token the fast-path triage toggles.
enum ReadState: String, Sendable, CaseIterable {
    case read = "Read"
    case unread = "Unread"

    var opposite: ReadState { self == .read ? .unread : .read }
}

/// Finder color-label meanings assigned by Archive Processor.
enum ArchiveColor: Sendable, Equatable {
    case box     // Red,    Finder labelNumber 6
    case folder  // Purple, Finder labelNumber 3

    init?(labelNumber: Int) {
        switch labelNumber {
        case 6: self = .box
        case 3: self = .folder
        default: return nil
        }
    }

    /// The color-name token Archive Processor also stores in the tag array.
    var tokenName: String { self == .box ? "Red" : "Purple" }

    /// The Finder label number for this color (box = Red = 6, folder = Purple = 3).
    var labelNumber: Int { self == .box ? 6 : 3 }
}

/// A file's tags parsed into facets. `raw` is preserved verbatim and is the source of truth.
struct DocumentTags: Sendable, Equatable {
    struct Month: Sendable, Equatable { var number: Int; var name: String }  // e.g. 3 / "March"

    let raw: [String]          // verbatim tag names, original order — never mutated here
    let labelNumber: Int?

    var year: Int?
    var month: Month?
    var day: Int?
    var dateUncertain: Bool
    var decade: Int?           // decade START year, e.g. 1970 (from "1970s"); nil when absent
    var priority: Int?         // 7...10 (P10 highest)
    var readState: ReadState?
    var color: ArchiveColor?
    var subjects: [String]     // everything not claimed by another facet, verbatim

    // The EXACT verbatim raw token that was consumed for each single-valued date/priority facet
    // (the "last one wins" winner). These — never a facet PREDICATE over all tokens — are what a
    // facet-replacing edit removes, so a subject that merely parses as a facet is never destroyed.
    // `nil` when the facet is absent. (See CORE DIRECTIVE: classification must not drive a write.)
    var yearToken: String?
    var monthToken: String?
    var dayToken: String?
    var decadeToken: String?   // the verbatim raw token consumed for the decade facet ("1970s")
    var priorityToken: String?

    /// Chronological sort key derived from the date tags. **No epoch limit** (medieval-safe).
    /// `nil` when there is no year → the caller sorts undated rows to the end.
    /// Month/day absent count as 0, so a year-only doc sorts just before its January.
    var sortDate: Int? {
        if let year { return year * 10_000 + (month?.number ?? 0) * 100 + (day ?? 0) }
        if let decade { return decade * 10_000 }
        return nil
    }

    /// When true, the derived date is speculative and should be shown in italics.
    /// (`Date Uncertain` flags a speculative year; the file usually still carries a Year tag.)
    var dateIsSpeculative: Bool { dateUncertain || (year == nil && decade != nil) }

    /// Tokens for the "File tags" column and the tag cloud: the raw tags minus the WINNING date facets
    /// (yearToken / monthToken / dayToken / `Date Uncertain`) and read-state (`Read`/`Unread`), since
    /// those have their own columns. Demoted same-facet tokens (e.g. "1984" when year=1980) stay visible.
    var topicalTags: [String] {
        let excluded: Set<String> = {
            var s = Set<String>()
            if let t = yearToken { s.insert(t) }
            if let t = monthToken { s.insert(t) }
            if let t = dayToken { s.insert(t) }
            if let t = decadeToken { s.insert(t) }
            return s
        }()
        return raw.filter { token in
            let s = token.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return false }
            if ReadState.allCases.contains(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) { return false }
            if s.caseInsensitiveCompare("Date Uncertain") == .orderedSame { return false }
            if excluded.contains(token) { return false }
            return true
        }
    }

    /// Human-readable date for the "Document date" column. `nil` when undated.
    /// Year only → "1980"; +month → "Mar 1980"; +day → "Mar 25, 1980".
    var displayDate: String? {
        guard let year else { return decadeToken }
        guard let month else { return String(year) }
        let mon = DocumentTags.monthNames[month.number - 1].prefix(3)
        if let day { return "\(mon) \(day), \(year)" }
        return "\(mon) \(year)"
    }
}

// MARK: - Parsing

extension DocumentTags {
    /// Classify a raw tag array (+ optional Finder label number) into facets.
    /// Order of checks matters: read-state / priority / month / day are recognized before the
    /// generic bare-number "year" test so a `P7` or `Day 25` is never mistaken for a year.
    static func parse(raw: [String], labelNumber: Int?) -> DocumentTags {
        var year: Int?
        var month: Month?
        var day: Int?
        var dateUncertain = false
        var decade: Int?
        var priority: Int?
        var readState: ReadState?
        var subjects: [String] = []

        // The verbatim raw token consumed for each single-valued date/priority facet ("last one
        // wins"). When a SECOND token also parses as the same facet, the previous winner is demoted
        // back to a subject so it stays visible AND so a facet edit only ever removes this one token.
        var yearToken: String?
        var monthToken: String?
        var dayToken: String?
        var decadeToken: String?
        var priorityToken: String?

        let color = labelNumber.flatMap(ArchiveColor.init(labelNumber:))

        for token in raw {
            let s = token.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }

            // Read state — exact whole-string, case-insensitive (never substring).
            if let rs = ReadState.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) {
                readState = rs
                continue
            }
            // Date Uncertain.
            if s.caseInsensitiveCompare("Date Uncertain") == .orderedSame {
                dateUncertain = true
                continue
            }
            // Priority Pn (7...10).
            if let p = parsePriority(s) {
                if let prev = priorityToken { subjects.append(prev) }   // demote the shadowed collision
                priority = p; priorityToken = token
                continue
            }
            // Month "MM Month".
            if let m = parseMonth(s) {
                if let prev = monthToken { subjects.append(prev) }
                month = m; monthToken = token
                continue
            }
            // Day "Day N".
            if let d = parseDay(s) {
                if let prev = dayToken { subjects.append(prev) }
                day = d; dayToken = token
                continue
            }
            // Decade — "NNNNs" (checked before the bare-number Year test; the trailing 's'
            // means it can't collide with parseYear, so relative order is immaterial).
            if let dec = parseDecade(s) {
                if let prev = decadeToken { subjects.append(prev) }
                decade = dec; decadeToken = token
                continue
            }
            // Year — bare 3–4 digit number (medieval-friendly: 800, 1215, 1980).
            if let y = parseYear(s) {
                if let prev = yearToken { subjects.append(prev) }
                year = y; yearToken = token
                continue
            }
            // A color-name token that matches the file's actual Finder label is the marker color,
            // not a subject (a doc about the "Red Scare" with NO red label keeps "Red" as a subject).
            if let color, color.tokenName.caseInsensitiveCompare(s) == .orderedSame {
                continue
            }
            // Everything else is a subject — kept verbatim.
            subjects.append(token)
        }

        return DocumentTags(
            raw: raw, labelNumber: labelNumber,
            year: year, month: month, day: day, dateUncertain: dateUncertain, decade: decade,
            priority: priority, readState: readState, color: color, subjects: subjects,
            yearToken: yearToken, monthToken: monthToken, dayToken: dayToken, decadeToken: decadeToken, priorityToken: priorityToken
        )
    }

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    static func parsePriority(_ s: String) -> Int? {
        guard let first = s.first, first == "P" || first == "p" else { return nil }
        guard let n = Int(s.dropFirst()), (7...10).contains(n) else { return nil }
        return n
    }

    /// "MM Month" where MM is 1...12 and the name matches that month (case-insensitive).
    static func parseMonth(_ s: String) -> Month? {
        let parts = s.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let num = Int(parts[0]), (1...12).contains(num) else { return nil }
        guard monthNames[num - 1].caseInsensitiveCompare(String(parts[1])) == .orderedSame else { return nil }
        return Month(number: num, name: monthNames[num - 1])
    }

    /// "Day N" where N is 1...31 (unpadded).
    static func parseDay(_ s: String) -> Int? {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("Day") == .orderedSame,
              let n = Int(parts[1]), (1...31).contains(n) else { return nil }
        return n
    }

    /// Bare integer of 3–4 digits. Display/sort-only; a numeric subject (a box number, a book title
    /// like "1984") can collide here — acceptable because it never affects a write, and the user can
    /// correct a mis-derived facet in the UI.
    static func parseYear(_ s: String) -> Int? {
        guard (3...4).contains(s.count), s.allSatisfy(\.isNumber), let y = Int(s) else { return nil }
        return y
    }

    /// "1970s"-style decade token (4-digit number + trailing "s").
    /// A decade token "NNNNs": 3–4 digits whose last digit is 0, then a lowercase 's'
    /// (e.g. "1970s", medieval-friendly "970s"). Returns the decade START year (1970).
    static func parseDecade(_ s: String) -> Int? {
        guard (4...5).contains(s.count), s.hasSuffix("s"),
              let y = Int(s.dropLast()), y % 10 == 0 else { return nil }
        return y
    }

    /// True if the trimmed token looks like ANY date facet (year, month, day, decade, "Date Uncertain").
    /// Used to keep date-like tokens out of display surfaces (tag cloud, tag filter suggestions) even
    /// when they were demoted to `subjects` during a facet collision.
    static func isDateFacetLike(_ tag: String) -> Bool {
        let s = tag.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        if s.caseInsensitiveCompare("Date Uncertain") == .orderedSame { return true }
        if parseYear(s) != nil { return true }
        if parseMonth(s) != nil { return true }
        if parseDay(s) != nil { return true }
        if parseDecade(s) != nil { return true }
        return false
    }
}
