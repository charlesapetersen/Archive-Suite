import Foundation

// MARK: - The folder-date rule (W47.ct-folder-date; `SPEC/containers.md` §The folder-date rule)
//
// Owner, 2026-10-31: "A date is given, so all the documents inside can be assumed to come from this date if otherwise
// undated." Owner, 2026-11-19 walkthrough (`W47.ct-folder-date-owner-ok`): only a run date the user confirmed dates
// documents; a range becomes the mid-point year under 8 years, the decade from 8 to 19, nothing from 20; a single year
// is inherited without Date Uncertain, a date taken from a range with it; the folder's month fills the Month.
// Measured in `ArchiveProcessor/segbench-results/folder-date.md`: a checked folder date holds for 88% of the dated
// documents inside (49 of 56, 17 folders); Vision + parser's own single-year read for 44%, hence confirmed only.
// Scored by the form written (W46.p17-folder-date-forms): a single year 13 of 14 exact, the mid-point year 20 of 42
// exact and 33 within a year, the decade unmeasured; `FieldStatusPolicy.folderFigure` gives the user that form's figure.

/// A folder run's `date` value read as years: `lo...hi`, and a month where it names one year and one month.
public struct ContainerFolderDate: Equatable, Sendable {
    public let lo: Int
    public let hi: Int
    public let month: Int?
    /// The value as the run holds it, for the evidence line.
    public let text: String
    /// The run's `start`: the folder photo's file name, or the first file of a run the user started.
    public let start: String

    public init(lo: Int, hi: Int, month: Int? = nil, text: String, start: String = "") {
        self.lo = lo; self.hi = hi; self.month = lo == hi && (1...12).contains(month ?? 0) ? month : nil; self.text = text; self.start = start
    }

    /// The years a folder date may name (the dating route's `DateRoute.yearRange`).
    public static let years = 1800...2030

    /// What an undated document in the run takes.
    public enum Inherited: Equatable, Sendable {
        /// A year; `uncertain` when it was taken from a range (the mid-point). `month` only for a single year.
        case year(Int, month: Int?, uncertain: Bool)
        /// A decade's first year (1960 for the 1960s), always with Date Uncertain.
        case decade(Int)
    }

    /// The owner's rule by span in years, inclusive: one year as it is; 2 to 7 the mid-point year (an even span the
    /// earlier middle year); 8 to 19 the decade holding most of its years, a tie going to the earlier; 20 or more nothing.
    public var inherited: Inherited? {
        let span = hi - lo + 1
        switch span {
        case 1: return .year(lo, month: month, uncertain: false)
        case 2...7: return .year(lo + (span - 1) / 2, month: nil, uncertain: true)
        case 8...19:
            var best = lo / 10 * 10, bestCount = 0
            for decade in stride(from: lo / 10 * 10, through: hi, by: 10) {
                let count = min(hi, decade + 9) - max(lo, decade) + 1
                if count > bestCount { best = decade; bestCount = count }   // strictly more: a tie keeps the earlier
            }
            return .decade(best)
        default: return nil
        }
    }

    // MARK: Reading the value

    private static let monthNames: [(String, Int)] = [
        ("january", 1), ("february", 2), ("march", 3), ("april", 4), ("may", 5), ("june", 6), ("july", 7),
        ("august", 8), ("september", 9), ("sept", 9), ("october", 10), ("november", 11), ("december", 12),
        ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9),
        ("oct", 10), ("nov", 11), ("dec", 12),
    ]

    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }
    private static let range = rx(#"^(\d{4})\s*(?:[-–—/]|to)\s*(\d{4}|\d\d)$"#)
    private static let decade = rx(#"^(\d{3}0)['’]?s$"#)
    private static let numeric = rx(#"^(\d{1,2})/(\d{1,2})/(\d{4}|\d\d)$"#)
    private static let numericMonth = rx(#"^(\d{1,2})/(\d{4})$"#)
    private static let year = rx(#"^(\d{4})$"#)
    private static let monthYear = rx(#"^([a-z]+)\.?,?\s+(?:\d{1,2},?\s+)?(\d{4})$"#)

    private static func groups(_ r: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// The value read as a date, or nil when it is none of: a year ("1953"), a range ("1965-1967", "1966-70",
    /// "1939- 78", "1965 to 1967"), a decade ("1960s"), a month and year ("Feb. 1970", "February 12, 1970"), or a
    /// numeric date, month first ("6/2/61", "2/1970"; a two-digit year only with a day, so "6/12" dates nothing). As `folder_date.parse_range`, which the figures were measured
    /// with, plus the month forms the owner's call 3 needs. A two-digit end before the start ("1958-02") is the start
    /// year alone. Anything else (a title, a note) dates nothing: the document keeps its own route.
    public static func parse(_ value: String, start: String = "") -> ContainerFolderDate? {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        func make(_ lo: Int, _ hi: Int, _ month: Int? = nil) -> ContainerFolderDate? {
            years.contains(lo) && years.contains(hi) && hi >= lo
                ? ContainerFolderDate(lo: lo, hi: hi, month: month, text: s, start: start) : nil
        }
        if let g = groups(range, s), let lo = Int(g[0]), let end = Int(g[1]) {
            let hi = g[1].count == 4 ? end : (lo / 100 * 100 + end < lo ? lo : lo / 100 * 100 + end)
            return make(lo, hi)
        }
        if let g = groups(decade, s), let lo = Int(g[0]) { return make(lo, lo + 9) }
        if let g = groups(year, s), let y = Int(g[0]) { return make(y, y) }
        if let g = groups(numeric, s), let m = Int(g[0]), var y = Int(g[2]) {
            if g[2].count == 2 { y += 1900 }
            return make(y, y, (1...12).contains(m) ? m : nil)
        }
        // A month and a four-digit year only: "6/12" is a day, not June 1912.
        if let g = groups(numericMonth, s), let m = Int(g[0]), let y = Int(g[1]) {
            return make(y, y, (1...12).contains(m) ? m : nil)
        }
        if let g = groups(monthYear, s), let y = Int(g[1]),
           let m = monthNames.first(where: { $0.0 == g[0].lowercased() })?.1 {
            return make(y, y, m)
        }
        return nil
    }

    // MARK: Which run dates a file

    /// The date of the folder run live at `fileName` in its directory's `runs`, only where the user set or confirmed
    /// it (source `user`): a label read that nobody confirmed dates nothing. A box or collection run's date does not
    /// date documents, and a dated document never dates its neighbours by this rule. The run's first file is covered
    /// too: a run the user split starts at a document ("set for selection"); a folder photo is never dated as a
    /// document by the caller. Pure: the caller loads the file.
    public static func confirmed(at fileName: String, in runs: [ContainerRun]) -> ContainerFolderDate? {
        guard let folder = ContainerResolver.liveRuns(at: fileName, in: runs).last, folder.level == .folder,
              let value = folder.fields[.date], value.source == .user, let shown = value.shown else { return nil }
        return parse(shown, start: folder.start)
    }
}
