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
    var priority: Int?         // 7...10 (P10 highest)
    var readState: ReadState?
    var color: ArchiveColor?
    var subjects: [String]     // everything not claimed by another facet, verbatim

    /// Chronological sort key derived from the date tags. **No epoch limit** (medieval-safe).
    /// `nil` when there is no year → the caller sorts undated rows to the end.
    /// Month/day absent count as 0, so a year-only doc sorts just before its January.
    var sortDate: Int? {
        guard let year else { return nil }
        return year * 10_000 + (month?.number ?? 0) * 100 + (day ?? 0)
    }

    /// When true, the derived date is speculative and should be shown in italics.
    /// (`Date Uncertain` flags a speculative year; the file usually still carries a Year tag.)
    var dateIsSpeculative: Bool { dateUncertain }

    /// Tokens for the "File tags" column and the tag cloud: the raw tags minus the date facets
    /// (year / `MM Month` / `Day N` / `Date Uncertain`) and read-state (`Read`/`Unread`), since those
    /// have their own columns. Keeps priority / subjects / marker-color tokens, verbatim & in order.
    var topicalTags: [String] {
        raw.filter { token in
            let s = token.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return false }
            if ReadState.allCases.contains(where: { $0.rawValue.caseInsensitiveCompare(s) == .orderedSame }) { return false }
            if s.caseInsensitiveCompare("Date Uncertain") == .orderedSame { return false }
            if DocumentTags.parseMonth(s) != nil { return false }
            if DocumentTags.parseDay(s) != nil { return false }
            if DocumentTags.parseYear(s) != nil { return false }
            return true
        }
    }

    /// Human-readable date for the "Document date" column. `nil` when undated.
    /// Year only → "1980"; +month → "Mar 1980"; +day → "Mar 25, 1980".
    var displayDate: String? {
        guard let year else { return nil }
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
        var priority: Int?
        var readState: ReadState?
        var subjects: [String] = []

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
                priority = p
                continue
            }
            // Month "MM Month".
            if let m = parseMonth(s) {
                month = m
                continue
            }
            // Day "Day N".
            if let d = parseDay(s) {
                day = d
                continue
            }
            // Year — bare 3–4 digit number (medieval-friendly: 800, 1215, 1980).
            if let y = parseYear(s) {
                year = y
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
            year: year, month: month, day: day, dateUncertain: dateUncertain,
            priority: priority, readState: readState, color: color, subjects: subjects
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
}
