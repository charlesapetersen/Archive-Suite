import Foundation

/// The pure entry rules behind the metadata strip's DATE row (`NoteMetadataInspector`, W6-S7): given
/// what is typed/picked in the three fields (year text, month index, day text) and the chosen
/// precision, what string gets committed, is the day row's "Set" live, and what does the operator
/// need told. Extracted from the view so these decisions are unit-testable without driving a window;
/// the view holds only `@State` + bindings.
///
/// The day is validated against the month and year it sits in (`GregorianDay`), not independently as
/// `1…31` — the W23.l4 bug, which let `2026-02-31` be committed as a day-precision date. An
/// impossible day is **coarsened, not clamped**: the committed string drops to month precision and
/// `impossibleDayNote` says so, rather than asserting a Feb 28 the source never said.
enum DateFieldEntry {

    /// Month names for the picker — one list, shared with the messages below so they can't drift.
    static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]

    /// The typed year when it parses to a positive one — the only case any date is written at all.
    static func year(_ yearText: String) -> Int? {
        guard let y = Int(yearText.trimmingCharacters(in: .whitespaces)), y > 0 else { return nil }
        return y
    }

    /// The typed day when it names a day that really exists in the chosen month and year — i.e. the
    /// value a commit keeps. Nil when the field is empty/unparseable, no month is chosen, the year is
    /// unusable, or the day is impossible for that month.
    static func acceptedDay(yearText: String, month: Int, dayText: String) -> Int? {
        guard let d = Int(dayText.trimmingCharacters(in: .whitespaces)),
              let y = year(yearText), month > 0,
              GregorianDay.isValidDay(year: y, month: month, day: d) else { return nil }
        return d
    }

    /// Why a typed day is being dropped, to show beside the field so the coarsening is never silent.
    /// Nil unless there is a real day-vs-month contradiction to report: an empty or unparseable field,
    /// or a month/year not yet chosen to judge the day against, is the disabled "Set" button's job.
    /// The month **menu** reaches this without any typing — picking February with 31 already in the
    /// field commits immediately — so this message is what explains the result.
    static func impossibleDayNote(yearText: String, month: Int, dayText: String) -> String? {
        guard let d = Int(dayText.trimmingCharacters(in: .whitespaces)), d > 0,
              let y = year(yearText), (1...12).contains(month),
              let last = GregorianDay.daysInMonth(year: y, month: month), d > last else { return nil }
        return "\(monthNames[month - 1]) \(y) has \(last) days — the day is ignored."
    }

    /// Whether the day row's "Set" is live. It stays live for everything it always covered (a
    /// plausible day, or no month chosen yet — the commit then simply writes the coarser date) and
    /// goes dead only for a day the chosen month cannot have, which `impossibleDayNote` names.
    static func dayCommittable(yearText: String, month: Int, dayText: String) -> Bool {
        guard let d = Int(dayText.trimmingCharacters(in: .whitespaces)),
              (1...31).contains(d) else { return false }
        return impossibleDayNote(yearText: yearText, month: month, dayText: dayText) == nil
    }

    /// The loose date string the fields describe at `precision`; the model normalizes it afterwards
    /// (zero-pads, floors a decade, downgrades a precision the string can't support).
    /// `nil` ⟹ clear the date.
    static func composed(yearText: String, month: Int, dayText: String,
                         precision: Item.DatePrecision) -> String? {
        guard let y = year(yearText) else { return nil }
        switch precision {
        case .decade, .year:
            return String(y)
        case .month:
            return month > 0 ? "\(y)-\(month)" : String(y)
        case .day:
            if let d = acceptedDay(yearText: yearText, month: month, dayText: dayText) {
                return "\(y)-\(month)-\(d)"
            }
            if month > 0 { return "\(y)-\(month)" }
            return String(y)
        }
    }
}
