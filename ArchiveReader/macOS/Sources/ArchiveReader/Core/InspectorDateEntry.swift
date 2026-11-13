import Foundation
import ArchiveCore

/// The Inspector's two date fields, the own date and the Sent-with date (W40.fix-reader-date-fields): each is one
/// typed field read by the suite's `DateFieldEntry` (Notes' field rules, W40.suite-date-design), so `1958`, `1950s`,
/// `March 1958`, `1958-3`, `12 March 1958` and `1958-03-12` all work. A field shows its date in words with no
/// leading zero (`12 March 1958`); the tags are unchanged (`SPEC/tag-format.md`), so what is written is padded.
enum InspectorDateEntry {

    /// What a field's text says.
    enum Reading: Equatable {
        case empty
        /// A date to write; `note` says what was dropped (an impossible day), as Notes' field does.
        case date(ArchiveDate, note: String?)
        /// Nothing is written; the message says what to type.
        case invalid(String)
    }

    static func read(_ text: String) -> Reading {
        let (typed, calendar) = DateFieldEntry.resolve(text, calendar: .standard)
        switch typed {
        case .empty: return .empty
        case .unreadable(let message): return .invalid(message)
        case .date(let f, _):
            let (commit, precision) = DateFieldEntry.commit(typed: typed, calendar: calendar, storedDate: nil)
            guard case .write(let written?) = commit else { return .invalid(rangeHint) }
            let parts = written.split(separator: "-").compactMap { Int($0) }
            let date: ArchiveDate?
            if precision == .decade, let y = parts.first {
                date = ArchiveDate(decade: y)
            } else if let y = parts.first {
                date = ArchiveDate(year: y, month: parts.count > 1 ? parts[1] : nil, day: parts.count > 2 ? parts[2] : nil)
            } else {
                date = nil
            }
            guard let date else { return .invalid(rangeHint) }
            let note = DateFieldEntry.impossibleDayNote(yearText: f.yearText, month: f.month, dayText: f.dayText)
            return .date(date, note: note)
        }
    }

    static let rangeHint = "Use a year from 100 to 9999."

    /// A date as its field shows it: `1950s`, `1958`, `March 1958`, `12 March 1958`. No leading zero (owner, Reader
    /// session 2 row 18), and every form reads back as the same date.
    static func text(_ d: ArchiveDate) -> String {
        switch d.precision {
        case .decade: return "\(d.year)s"
        case .year: return String(d.year)
        case .month: return "\(DateFieldEntry.monthNames[d.month! - 1]) \(d.year)"
        case .day: return "\(d.day!) \(DateFieldEntry.monthNames[d.month! - 1]) \(d.year)"
        }
    }

    /// The file's own date from its Year, Month, Day and Decade facets, or nil when they make no date (none set,
    /// or a month or day without the year, or a day without the month). A year wins over a decade, as on read.
    static func ownDate(_ tags: DocumentTags) -> ArchiveDate? {
        if let y = tags.year {
            if tags.month == nil, tags.day != nil { return nil }
            return ArchiveDate(year: y, month: tags.month?.number, day: tags.day)
        }
        guard tags.month == nil, tags.day == nil, let decade = tags.decade else { return nil }
        return ArchiveDate(decade: decade)
    }

    /// The text the own-date field shows for a file. Facets that make no date are shown as they stand, with what is
    /// wrong (`12 March (no year)`, `1958, day 12 (no month)`, `31 February 1958 (no such day)`), so the field never
    /// looks empty over tags that are there, and the text never reads back as a date: typing any date over it writes.
    static func ownText(_ tags: DocumentTags) -> String {
        if let d = ownDate(tags) { return text(d) }
        let month = tags.month.map { DateFieldEntry.monthNames[$0.number - 1] }
        let year = tags.year.map(String.init) ?? tags.decade.map { "\($0)s" }
        guard tags.year != nil || month != nil || tags.day != nil else { return year ?? "" }
        if tags.year == nil {
            return [tags.day.map(String.init), month, year].compactMap { $0 }.joined(separator: " ") + " (no year)"
        }
        if month == nil { return "\(year!), day \(tags.day!) (no month)" }
        return "\(tags.day!) \(month!) \(year!) (no such day)"
    }

    /// What applying a field writes, or nil for nothing. `shared` is the text the field was seeded with: the value
    /// every file shares (`""` when none has one), or `.some(nil)` when the files differ. `op` makes the edit.
    static func edit(typed text: String, shared: String??, op: (ArchiveDate?) -> TagEditOp) -> TagEditOp? {
        switch read(text) {
        case .invalid: return nil
        case .empty:
            // A mixed field emptied again is left alone: empty there means "keep each file's own", never "clear
            // them all". An empty shared value emptied again is not an edit.
            switch shared {
            case .some(.none), .some(.some("")): return nil
            default: return op(nil)
            }
        case .date(let d, _):
            // The date every file already has, however it is typed: nothing to write.
            if case .some(.some(let seeded)) = shared, case .date(let s, _) = read(seeded), s == d { return nil }
            return op(d)
        }
    }

    /// The hint under a field: why the text is not written, else what was dropped from it.
    static func hint(_ text: String) -> (message: String, isError: Bool)? {
        switch read(text) {
        case .empty: return nil
        case .invalid(let message): return (message, true)
        case .date(_, let note): return note.map { ($0, false) }
        }
    }
}
