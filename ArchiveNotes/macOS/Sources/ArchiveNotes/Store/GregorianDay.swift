import Foundation

/// Calendar arithmetic for validating a `(year, month, day)` triple at Notes' date **input seams**
/// (W23.l4). Those seams used to validate month (`1…12`) and day (`1…31`) *independently*, never
/// against a calendar — so `2026-02-31` was accepted, persisted as a day-precision front-matter date
/// and handed a normal chronological sort key. Every seam that accepts a day now asks this type first
/// (`Item.normalizedDate`, `NoteMetadataInspector`, `ZoteroCSLItem.mappedDate`).
///
/// **Deliberately arithmetic — never `Foundation.Calendar`.** `DateComponents.isValidDate(in:)` is
/// wrong for an archival corpus in *both* directions. Measured on this machine (macOS 15), identically
/// for the `.gregorian` and `.iso8601` identifiers — both model ICU's Julian→Gregorian *hybrid*:
///   * `1500-02-29` → reported **valid** (a Julian leap year, not a Gregorian one), so `Calendar`
///     would not even have closed the bug for pre-cutover dates; and
///   * `1582-10-10` → reported **invalid**, because ICU deletes the ten cutover days — so a genuine
///     date transcribed off an early-modern document would have been silently rejected.
/// The rules below are also locale-independent by construction, which `Calendar.current` is not: it
/// follows the user's chosen calendar identifier, which need not be Gregorian at all.
enum GregorianDay {

    /// Length of `month` in `year`, or nil when `year`/`month` is not a real (positive) year-month.
    ///
    /// February gets 29 days when the year is a leap year under **either reckoning that could have
    /// produced the date**: proleptic Gregorian, or — for a year before the 1582 cutover — Julian
    /// (every 4th year). `1500-02-29` off a pre-cutover document is a real day and must not be
    /// thrown away; `1900-02-29` and `2026-02-31` are not, and are. The 1582 boundary is a chosen
    /// trade-off, not an oversight: regions on the old calendar into the 20th century did have a
    /// real `1900-02-29`, but honoring that would re-admit the most likely modern typo.
    static func daysInMonth(year: Int, month: Int) -> Int? {
        guard year > 0, (1...12).contains(month) else { return nil }
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeapYear(year) ? 29 : 28
        }
    }

    /// True when `(year, month, day)` names a day that exists — the only question the input seams ask.
    /// A `false` means the triple is **impossible** (`2026-02-31`, `1968-04-31`, day 0, month 13),
    /// never merely unusual, so a seam can reject or coarsen on it without second-guessing the source.
    static func isValidDay(year: Int, month: Int, day: Int) -> Bool {
        guard let last = daysInMonth(year: year, month: month) else { return false }
        return (1...last).contains(day)
    }

    /// Leap year under the reckoning in force for `year` (see `daysInMonth`): Gregorian
    /// (÷4, except ÷100 unless ÷400) from 1582 on, Julian (÷4) before it.
    static func isLeapYear(_ year: Int) -> Bool {
        guard year > 0 else { return false }
        if year < 1582 { return year % 4 == 0 }
        return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }
}
