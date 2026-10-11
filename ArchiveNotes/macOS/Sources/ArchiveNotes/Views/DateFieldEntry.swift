import Foundation
import ArchiveCore

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
///
/// **The fields' calendar (W24.cal1-validator).** Every rule takes the calendar the fields are typed
/// in. `.standard` — the default, and the only calendar while Settings ▸ "Show dates in other
/// calendars" is off — is exactly the `GregorianDay` rule above, unchanged. Under any other calendar a
/// day is checked against *that* calendar's month lengths (an English `1700-02-29` is a real day under
/// Julian with the 1752 cutover) and converted to the proleptic ISO day for storage, so what is
/// written is always the ISO 8601 date the store already holds. A calendar applies to **whole days
/// only**, as it does on display: a year or month in the Hebrew or Islamic reckoning has no single
/// Gregorian equivalent, so nothing partial is ever converted. Under a calendar, fields that do not
/// name a whole storable day commit nothing (`Commit.keep`) — never a guessed month, never a clear —
/// and a stored date that is not a whole day is entered in Gregorian (`seed`).
enum DateFieldEntry {

    /// Month names for the picker — one list, shared with the messages below so they can't drift.
    static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]

    /// What a commit does: write `date` (nil clears it), or leave the stored date alone.
    enum Commit: Equatable {
        case write(String?)
        case keep
    }

    /// What the three fields hold.
    struct Fields: Equatable {
        var yearText: String
        var month: Int          // 0 = none
        var dayText: String
    }

    /// The calendar the fields are typed in: the item's active display calendar at day precision,
    /// `.standard` otherwise (and always, with the Settings switch off — `active` is then nil).
    static func entryCalendar(_ active: DisplayCalendar?, precision: Item.DatePrecision) -> DisplayCalendar {
        precision == .day ? (active ?? .standard) : .standard
    }

    /// The typed year when it parses to a positive one — the only case any date is written at all.
    static func year(_ yearText: String) -> Int? {
        guard let y = Int(yearText.trimmingCharacters(in: .whitespaces)), y > 0 else { return nil }
        return y
    }

    /// The month menu's entries for the typed year: 12 Western months under `.standard`/Julian, 13 in a
    /// Hebrew leap year (Adar I, Adar II) and in every French Republican year.
    static func monthChoices(yearText: String, calendar: DisplayCalendar = .standard) -> [(month: Int, name: String)] {
        guard calendar != .standard else { return monthNames.enumerated().map { ($0.offset + 1, $0.element) } }
        let y = year(yearText) ?? 1
        let count = calendar.monthsInYear(y) ?? 12
        return (1...count).map { ($0, calendar.monthName($0, year: y) ?? String($0)) }
    }

    /// The typed day when it names a day that really exists in the chosen month and year — i.e. the
    /// value a commit keeps. Nil when the field is empty/unparseable, no month is chosen, the year is
    /// unusable, the day is impossible for that month, or (another calendar) the day converts to a
    /// date outside the years Notes stores.
    static func acceptedDay(yearText: String, month: Int, dayText: String,
                            calendar: DisplayCalendar = .standard) -> Int? {
        guard let d = Int(dayText.trimmingCharacters(in: .whitespaces)),
              let y = year(yearText), month > 0 else { return nil }
        if calendar == .standard {
            return GregorianDay.isValidDay(year: y, month: month, day: d) ? d : nil
        }
        return calendar.stored(from: CalendarDay(year: y, month: month, day: d)) != nil ? d : nil
    }

    /// Why a typed day is being dropped, to show beside the field so the coarsening is never silent.
    /// Nil unless there is a real day-vs-month contradiction to report: an empty or unparseable field,
    /// or a month/year not yet chosen to judge the day against, is the disabled "Set" button's job.
    /// The month **menu** reaches this without any typing — picking February with 31 already in the
    /// field commits immediately — so this message is what explains the result.
    static func impossibleDayNote(yearText: String, month: Int, dayText: String,
                                  calendar: DisplayCalendar = .standard) -> String? {
        guard let d = Int(dayText.trimmingCharacters(in: .whitespaces)), d > 0,
              let y = year(yearText), month > 0 else { return nil }
        guard calendar != .standard else {
            guard (1...12).contains(month), let last = GregorianDay.daysInMonth(year: y, month: month),
                  d > last else { return nil }
            return "\(monthNames[month - 1]) \(y) has \(last) days — the day is ignored."
        }
        let local = CalendarDay(year: y, month: month, day: d)
        guard calendar.stored(from: local) == nil else { return nil }
        guard let name = calendar.monthName(month, year: y),
              let last = calendar.lastDayOfMonth(year: y, month: month) else {
            return "Year \(y) of the \(calendar.displayName) calendar has no month \(month) — the day is ignored."
        }
        if d > last {
            let count = calendar.daysInMonth(year: y, month: month) ?? last
            return "\(name) \(y) has \(count) days in the \(calendar.displayName) calendar — the day is ignored."
        }
        if !calendar.isValid(local) {   // September 1752 under the English cutover: 3–13 never happened
            return "\(d) \(name) \(y) does not exist in the \(calendar.displayName) calendar — the day is ignored."
        }
        return "\(d) \(name) \(y) falls outside the years Notes can store — the day is ignored."
    }

    /// Under another calendar, why typed fields are not saved yet: they name no whole day, and nothing
    /// short of one is ever written (`commit` → `.keep`). Nil under `.standard`, with every field empty,
    /// or when `impossibleDayNote` already explains it.
    static func incompleteNote(yearText: String, month: Int, dayText: String,
                               calendar: DisplayCalendar) -> String? {
        guard calendar != .standard,
              !(yearText.trimmingCharacters(in: .whitespaces).isEmpty && month == 0
                && dayText.trimmingCharacters(in: .whitespaces).isEmpty),
              acceptedDay(yearText: yearText, month: month, dayText: dayText, calendar: calendar) == nil,
              impossibleDayNote(yearText: yearText, month: month, dayText: dayText, calendar: calendar) == nil
        else { return nil }
        return "Not saved: enter a year, month and day — only a whole \(calendar.displayName) day is stored."
    }

    /// Whether the day row's "Set" is live. It stays live for everything it always covered (a
    /// plausible day, or no month chosen yet — the commit then simply writes the coarser date) and
    /// goes dead only for a day the chosen month cannot have, which `impossibleDayNote` names.
    static func dayCommittable(yearText: String, month: Int, dayText: String,
                               calendar: DisplayCalendar = .standard) -> Bool {
        guard let d = Int(dayText.trimmingCharacters(in: .whitespaces)),
              (1...31).contains(d) else { return false }
        return impossibleDayNote(yearText: yearText, month: month, dayText: dayText, calendar: calendar) == nil
    }

    /// The loose date string the fields describe at `precision`; the model normalizes it afterwards
    /// (zero-pads, floors a decade, downgrades a precision the string can't support).
    /// `nil` ⟹ clear the date. Gregorian fields only — `commit` is the calendar-aware entry point.
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

    /// What committing the fields at `precision` does, the fields being typed in `calendar` (which may
    /// differ from `entryCalendar(_, precision:)` at the moment the precision itself changes).
    /// `.standard` is exactly `composed`. Under another calendar only a whole storable day is written —
    /// converted to its ISO day, then cut to `precision` — and anything less is `.keep`. So is a day
    /// that is the one `storedDate` already holds: a pre-1582 Julian leap day on disk (`1500-02-29`)
    /// is not rewritten as `1500-03-10` by a commit that changes nothing.
    static func commit(yearText: String, month: Int, dayText: String, precision: Item.DatePrecision,
                       calendar: DisplayCalendar = .standard, storedDate: String? = nil) -> Commit {
        guard calendar != .standard else {
            return .write(composed(yearText: yearText, month: month, dayText: dayText, precision: precision))
        }
        guard let y = year(yearText),
              let d = acceptedDay(yearText: yearText, month: month, dayText: dayText, calendar: calendar),
              let s = calendar.stored(from: CalendarDay(year: y, month: month, day: d)) else { return .keep }
        switch precision {
        case .day:
            if let stored = storedDate, sameDay(stored, s) { return .keep }
            return .write("\(s.year)-\(s.month)-\(s.day)")
        case .month: return .write("\(s.year)-\(s.month)")
        case .decade, .year: return .write(String(s.year))
        }
    }

    /// Whether a stored day string names the day `s` (read as the core does — a pre-1582 Julian leap
    /// day is the Julian date it says).
    private static func sameDay(_ stored: String, _ s: CalendarDay) -> Bool {
        let p = stored.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3,
              let a = DisplayCalendar.julian.display(stored: CalendarDay(year: p[0], month: p[1], day: p[2])),
              let b = DisplayCalendar.julian.display(stored: s) else { return false }
        return a == b
    }

    /// The fields that show a stored front-matter date (`"1752"`, `"1752-09"`, `"1752-09-13"`) in
    /// `calendar` — the seed when an item is selected or its calendar changes, or a precision change
    /// moves the fields into or out of a calendar. `.standard` is the stored text split as-is. Another
    /// calendar shows only a whole day; nil for anything else — a year or month (no exact
    /// equivalent), or a day before the calendar's epoch (French Republican before 1792).
    static func fields(storedDate: String?, calendar: DisplayCalendar = .standard) -> Fields? {
        let parts = (storedDate ?? "").split(separator: "-").map(String.init)
        guard calendar != .standard else {
            return Fields(yearText: parts.first ?? "",
                          month: parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0,
                          dayText: parts.count >= 3 ? parts[2] : "")
        }
        if parts.isEmpty { return Fields(yearText: "", month: 0, dayText: "") }
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let local = calendar.display(stored: CalendarDay(year: y, month: m, day: d)) else { return nil }
        return Fields(yearText: String(local.year), month: local.month, dayText: String(local.day))
    }

    /// The fields for a stored date and the calendar they are typed in: the item's calendar at day
    /// precision when the date is empty or a whole day the calendar can show, else `.standard`.
    static func seed(storedDate: String?, active: DisplayCalendar?,
                     precision: Item.DatePrecision) -> (fields: Fields, calendar: DisplayCalendar) {
        let calendar = entryCalendar(active, precision: precision)
        if let f = fields(storedDate: storedDate, calendar: calendar) { return (f, calendar) }
        return (fields(storedDate: storedDate) ?? Fields(yearText: "", month: 0, dayText: ""), .standard)
    }
}
