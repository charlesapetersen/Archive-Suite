import Foundation

/// The suite's one typed date field (W40.suite-date-design; owner, notes-2 row 9: "reuse it for every date the suite
/// sets"). Moved here from Archive Notes, where it is the inspector's and the list's date field, so the Reader's
/// Inspector and the Processor can type dates by the same rules. Precision is `ArchiveDate.Precision`; what a commit
/// writes is the year, month and day as numbers (`1968`, `1968-3`, `1968-3-12`), which each app pads and stores in its
/// own form (Notes: `Item.normalizedDate`; a tag write: `ArchiveDate`).
///
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
public enum DateFieldEntry {

    /// Month names for the picker — one list, shared with the messages below so they can't drift.
    public static let monthNames = ["January", "February", "March", "April", "May", "June",
                             "July", "August", "September", "October", "November", "December"]

    /// What a commit does: write `date` (nil clears it), or leave the stored date alone.
    public enum Commit: Equatable {
        case write(String?)
        case keep
    }

    /// What the three fields hold.
    public struct Fields: Equatable {
        public var yearText: String
        public var month: Int          // 0 = none
        public var dayText: String
        public init(yearText: String, month: Int, dayText: String) {
            (self.yearText, self.month, self.dayText) = (yearText, month, dayText)
        }
    }

    /// The calendar the fields are typed in: the item's active display calendar at day precision,
    /// `.standard` otherwise (and always, with the Settings switch off — `active` is then nil).
    public static func entryCalendar(_ active: DisplayCalendar?, precision: ArchiveDate.Precision) -> DisplayCalendar {
        precision == .day ? (active ?? .standard) : .standard
    }

    /// The typed year when it parses to a positive one — the only case any date is written at all.
    public static func year(_ yearText: String) -> Int? {
        guard let y = Int(yearText.trimmingCharacters(in: .whitespaces)), y > 0 else { return nil }
        return y
    }

    /// The month menu's entries for the typed year: 12 Western months under `.standard`/Julian, 13 in a
    /// Hebrew leap year (Adar I, Adar II) and in every French Republican year.
    public static func monthChoices(yearText: String, calendar: DisplayCalendar = .standard) -> [(month: Int, name: String)] {
        guard calendar != .standard else { return monthNames.enumerated().map { ($0.offset + 1, $0.element) } }
        let y = year(yearText) ?? 1
        let count = calendar.monthsInYear(y) ?? 12
        return (1...count).map { ($0, calendar.monthName($0, year: y) ?? String($0)) }
    }

    /// The typed day when it names a day that really exists in the chosen month and year — i.e. the
    /// value a commit keeps. Nil when the field is empty/unparseable, no month is chosen, the year is
    /// unusable, the day is impossible for that month, or (another calendar) the day converts to a
    /// date outside the years Notes stores.
    public static func acceptedDay(yearText: String, month: Int, dayText: String,
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
    public static func impossibleDayNote(yearText: String, month: Int, dayText: String,
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
    public static func incompleteNote(yearText: String, month: Int, dayText: String,
                               calendar: DisplayCalendar) -> String? {
        guard calendar != .standard,
              !(yearText.trimmingCharacters(in: .whitespaces).isEmpty && month == 0
                && dayText.trimmingCharacters(in: .whitespaces).isEmpty),
              acceptedDay(yearText: yearText, month: month, dayText: dayText, calendar: calendar) == nil,
              impossibleDayNote(yearText: yearText, month: month, dayText: dayText, calendar: calendar) == nil
        else { return nil }
        return "Not saved: enter a year, month and day — only a whole \(calendar.displayName) day is stored."
    }

    // MARK: Typed entry (W40.fix-notes-date-entry)

    /// What one typed date field says. The precision is the one typed — `1960s` is a decade, `1968` a
    /// year, `March 1968` or `1968-03` a month, `12 March 1968` or `1968-03-12` a day — so there is no
    /// precision picker; an emptied field clears the date.
    public enum Typed: Equatable {
        case empty
        case date(Fields, ArchiveDate.Precision)
        /// Nothing is written; the text says why.
        case unreadable(String)
    }

    /// Read a typed date in `calendar`. Accepted: a decade (`1960s`, `1960's`); numbers with the year
    /// first (`1968`, `1968-3`, `1968/03/12`) or a month before a year (`3/1968`); and a month name or
    /// its first three or more letters with a year and an optional day in either order (`March 1968`,
    /// `12 Mar 1968`, `March 12th, 1968`). All-number dates that do not start with the year
    /// (`12/3/1968`) are refused, since day-month and month-day orders cannot be told apart. A day the
    /// month cannot have is kept here; `commit` drops it to the month and `impossibleDayNote` says so.
    public static func parse(_ text: String, calendar: DisplayCalendar = .standard) -> Typed {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty { return .empty }
        if let m = raw.wholeMatch(of: /(\d{2,})0\s*['’]?s/), let y = Int(m.1 + "0"), y > 0 {
            return .date(Fields(yearText: String(y), month: 0, dayText: ""), .decade)
        }
        var numbers: [Substring] = []
        var words: [Substring] = []
        for token in raw.split(whereSeparator: { " ,/.-".contains($0) }) {
            if let m = token.wholeMatch(of: /(\d+)(?:st|nd|rd|th)?/) {
                numbers.append(m.1)
            } else if token.contains(where: \.isNumber) {
                return .unreadable(readHint)
            } else {
                words.append(token)
            }
        }
        let values = numbers.compactMap { Int($0) }
        guard values.count == numbers.count else { return .unreadable(readHint) }
        /// A year is written in full, with three or more digits: `68` could be 1968 or AD 68.
        func isYear(_ i: Int) -> Bool { numbers[i].count >= 3 }
        func make(_ y: Int, _ m: Int = 0, _ d: Int? = nil) -> Typed {
            guard y > 0 else { return .unreadable("The year must be 1 or later.") }
            let choices = monthChoices(yearText: String(y), calendar: calendar)
            if m != 0, !(1...choices.count).contains(m) {
                return .unreadable("There is no month \(m) — write the month as a word or a number up to \(choices.count).")
            }
            if let d, d < 1 { return .unreadable("There is no day \(d).") }
            let precision: ArchiveDate.Precision = d != nil ? .day : (m != 0 ? .month : .year)
            return .date(Fields(yearText: String(y), month: m, dayText: d.map(String.init) ?? ""), precision)
        }

        if words.isEmpty {
            // A month written as 0 is not "no month": `1958-00-12` would drop its day without a word.
            if values.count >= 2, values[isYear(0) ? 1 : 0] == 0 {
                return .unreadable("There is no month 0 — write the month as a word or a number from 1.")
            }
            switch values.count {
            case 1 where isYear(0): return make(values[0])
            case 2 where isYear(0): return make(values[0], values[1])
            case 2 where isYear(1) && values[0] >= 1: return make(values[1], values[0])
            case 3 where isYear(0): return make(values[0], values[1], values[2])
            case 1, 2: return .unreadable("Write the year in full. \(readHint)")
            default: return .unreadable(readHint)
            }
        }
        // A month name, possibly several words long ("Adar II", "Rabi al-Awwal").
        let phrase = words.joined(separator: " ")
        let yearIndex = values.indices.first(where: isYear)
        let choices = monthChoices(yearText: yearIndex.map { String(values[$0]) } ?? "", calendar: calendar)
        guard let month = monthNumber(phrase, choices: choices) else {
            return .unreadable("“\(phrase)” is not a month name. \(readHint)")
        }
        switch values.count {
        case 1:
            guard isYear(0) else { return .unreadable("Write the year in full. \(readHint)") }
            return make(values[0], month)
        case 2:
            guard let y = yearIndex, !isYear(1 - y) else { return .unreadable("Write the year in full. \(readHint)") }
            return make(values[y], month, values[1 - y])
        default: return .unreadable(readHint)
        }
    }

    /// The typed text and the calendar it is read in. A calendar applies to whole days only, so text
    /// that names less than a day (a year, a month, a decade) is read in Gregorian when it can be — the
    /// way choosing a coarser precision used to switch the fields to Gregorian (W24.cal1-validator).
    public static func resolve(_ text: String, calendar: DisplayCalendar) -> (typed: Typed, calendar: DisplayCalendar) {
        let typed = parse(text, calendar: calendar)
        guard calendar != .standard else { return (typed, calendar) }
        if case .date(_, .day) = typed { return (typed, calendar) }
        if case .empty = typed { return (typed, calendar) }
        let gregorian = parse(text)
        if case .date(_, let p) = gregorian, p != .day { return (gregorian, .standard) }
        return (typed, calendar)
    }

    private static let readHint = "Type a year (1968), a decade (1960s), a month (March 1968) or a day (12 March 1968 or 1968-03-12)."

    /// The month a typed name means: a whole name, or an unambiguous start of one at least three
    /// letters long (`mar`, `sept`). Punctuation and spacing inside a name are ignored.
    private static func monthNumber(_ phrase: String, choices: [(month: Int, name: String)]) -> Int? {
        func letters(_ s: String) -> String { s.lowercased().filter(\.isLetter) }
        let typed = letters(phrase)
        guard !typed.isEmpty else { return nil }
        if let whole = choices.first(where: { letters($0.name) == typed }) { return whole.month }
        guard typed.count >= 3 else { return nil }
        let starts = choices.filter { letters($0.name).hasPrefix(typed) }
        return starts.count == 1 ? starts[0].month : nil
    }

    /// The text a typed field starts from for a stored date, in the calendar it is typed in — the
    /// inverse of `parse`. Gregorian shows the stored ISO form (a decade as `1960s`); another calendar
    /// shows its whole day in words (`15 Tishri 5786`).
    public static func text(_ fields: Fields, precision: ArchiveDate.Precision?, calendar: DisplayCalendar) -> String {
        guard let y = year(fields.yearText) else { return "" }
        let day = Int(fields.dayText.trimmingCharacters(in: .whitespaces))
        if calendar != .standard, fields.month > 0, let day {
            return "\(day) \(calendar.monthName(fields.month, year: y) ?? String(fields.month)) \(y)"
        }
        func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        if precision == .decade { return "\((y / 10) * 10)s" }
        guard fields.month > 0 else { return String(y) }
        guard let day else { return "\(y)-\(pad2(fields.month))" }
        return "\(y)-\(pad2(fields.month))-\(pad2(day))"
    }

    /// What committing a typed field does, given the stored date it would replace.
    public static func commit(typed: Typed, calendar: DisplayCalendar, storedDate: String?) -> (Commit, ArchiveDate.Precision?) {
        switch typed {
        case .empty: return (.write(nil), nil)
        case .unreadable: return (.keep, nil)
        case .date(let f, let p):
            return (commit(yearText: f.yearText, month: f.month, dayText: f.dayText, precision: p,
                           calendar: calendar, storedDate: storedDate), p)
        }
    }

    /// The loose date string the fields describe at `precision`; the model normalizes it afterwards
    /// (zero-pads, floors a decade, downgrades a precision the string can't support).
    /// `nil` ⟹ clear the date. Gregorian fields only — `commit` is the calendar-aware entry point.
    public static func composed(yearText: String, month: Int, dayText: String,
                         precision: ArchiveDate.Precision) -> String? {
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
    public static func commit(yearText: String, month: Int, dayText: String, precision: ArchiveDate.Precision,
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
    public static func fields(storedDate: String?, calendar: DisplayCalendar = .standard) -> Fields? {
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
    public static func seed(storedDate: String?, active: DisplayCalendar?,
                     precision: ArchiveDate.Precision) -> (fields: Fields, calendar: DisplayCalendar) {
        let calendar = entryCalendar(active, precision: precision)
        if let f = fields(storedDate: storedDate, calendar: calendar) { return (f, calendar) }
        return (fields(storedDate: storedDate) ?? Fields(yearText: "", month: 0, dayText: ""), .standard)
    }

    /// The typed field's starting text and calendar for a stored date. An empty date is typed in the
    /// item's calendar (a whole day is what a calendar stores); a stored year or month in Gregorian.
    public static func seedText(storedDate: String?, precision: ArchiveDate.Precision?,
                         active: DisplayCalendar?) -> (text: String, calendar: DisplayCalendar) {
        let s = seed(storedDate: storedDate, active: active, precision: storedDate == nil ? .day : (precision ?? .year))
        return (text(s.fields, precision: precision, calendar: s.calendar), s.calendar)
    }

    // MARK: A date written as tags (W40.processor-date-field)

    /// What a typed field gives an app that writes the date as tags, as the Processor does: one whole
    /// `ArchiveDate`, or why nothing is written. Gregorian, as the tag format is.
    public enum Reading: Equatable {
        case empty
        /// `note` says what was dropped: a day the month cannot have (`impossibleDayNote`).
        case date(ArchiveDate, note: String?)
        /// Nothing is written; the text says why.
        case unreadable(String)
    }

    /// Read a typed date as the tag format holds it. The text rules are `parse`'s; an impossible day is
    /// coarsened to its month with a note, never clamped; a year outside the tag format's 100…9999 is refused.
    public static func archiveDate(_ text: String) -> Reading {
        switch parse(text) {
        case .empty: return .empty
        case .unreadable(let why): return .unreadable(why)
        case .date(let f, let precision):
            let range = "Write a year from 100 to 9999."
            guard let y = year(f.yearText) else { return .unreadable(range) }
            switch precision {
            case .decade:
                return ArchiveDate(decade: (y / 10) * 10).map { .date($0, note: nil) } ?? .unreadable(range)
            case .year:
                return ArchiveDate(year: y).map { .date($0, note: nil) } ?? .unreadable(range)
            case .month, .day:
                if precision == .day,
                   let d = acceptedDay(yearText: f.yearText, month: f.month, dayText: f.dayText),
                   let date = ArchiveDate(year: y, month: f.month, day: d) {
                    return .date(date, note: nil)
                }
                guard let date = ArchiveDate(year: y, month: f.month) else { return .unreadable(range) }
                return .date(date, note: impossibleDayNote(yearText: f.yearText, month: f.month, dayText: f.dayText))
            }
        }
    }

    // MARK: The list's Date cell (W40.notes-detail-layout)

    /// What a date typed into the list's Date cell does: the inspector's field rules, in one step.
    public enum ListEdit: Equatable {
        /// Write `date` (nil clears it) at `precision`; `note` says what was dropped, as the inspector's line does.
        case write(String?, ArchiveDate.Precision?, note: String?)
        /// Nothing to write: the text is the stored date's own.
        case unchanged
        /// Nothing written; the message says what to type.
        case refused(String)
    }

    /// The text the list's Date cell edits, in the calendar it is typed in.
    public static func listSeed(storedDate: String?, precision: ArchiveDate.Precision?,
                         active: DisplayCalendar?) -> (text: String, calendar: DisplayCalendar) {
        seedText(storedDate: storedDate, precision: precision, active: active)
    }

    /// Read `text` typed over `seed` (the cell's starting text, typed in `calendar`) for an item whose date is
    /// `storedDate`. An emptied cell clears the date; text the inspector would refuse is refused with its message.
    public static func listEdit(_ text: String, seed: String, calendar: DisplayCalendar, storedDate: String?) -> ListEdit {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != seed.trimmingCharacters(in: .whitespacesAndNewlines) else { return .unchanged }
        let (typed, resolved) = resolve(trimmed, calendar: calendar)
        if case .unreadable(let message) = typed { return .refused(message) }
        let (value, precision) = commit(typed: typed, calendar: resolved, storedDate: storedDate)
        guard case .write(let date) = value else { return .unchanged }
        if date == nil, storedDate == nil { return .unchanged }   // emptying an empty date is not an edit
        var note: String?
        if case .date(let f, _) = typed {
            note = impossibleDayNote(yearText: f.yearText, month: f.month, dayText: f.dayText, calendar: resolved)
        }
        return .write(date, precision, note: note)
    }
}
