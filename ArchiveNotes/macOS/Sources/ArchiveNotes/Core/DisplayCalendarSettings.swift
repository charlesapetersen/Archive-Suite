// DisplayCalendarSettings.swift — W24.cal1-toggle: the Settings switch for showing dates in other
// calendars, and the pure rendering of a stored day in an item's chosen calendar.
//
// Display only. A stored date is always the ISO 8601 value the item already carries; nothing here
// writes it. With the switch off (the default) every date renders exactly as before, whatever calendar
// an item names, so turning the option on and off again changes nothing on disk.

import Foundation
import ArchiveCore

enum DisplayCalendarSettings {
    /// `UserDefaults` key for Settings ▸ Dates ▸ "Show dates in other calendars". Absent = off.
    static let enabledKey = "displayCalendarsEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// The calendars an item may choose, `standard` (as stored) first.
    static var choices: [DisplayCalendar] { DisplayCalendar.allCases }

    /// A stored day-precision date shown in `calendar`, e.g. "2 September 1752 (O.S.)" or
    /// "13 Vendémiaire An XII"; nil when there is nothing to convert — `standard`, a date that is not a
    /// stored day, or a day before the calendar's epoch (French Republican before 22 September 1792) —
    /// so the caller keeps its stored rendering. Julian dates carry "(O.S.)": the format is otherwise
    /// identical to a Gregorian one, and an unmarked Old Style date reads as New Style.
    static func shown(year: Int, month: Int, day: Int, in calendar: DisplayCalendar) -> String? {
        guard calendar != .standard else { return nil }
        let stored = CalendarDay(year: year, month: month, day: day)
        guard let local = calendar.display(stored: stored), let text = calendar.format(local) else { return nil }
        let oldStyle: Bool
        switch calendar {
        case .julian: oldStyle = true
        case .julianEnglish1752: oldStyle = (year, month, day) < (1752, 9, 14)
        case .standard, .frenchRepublican, .hebrew, .islamic: oldStyle = false
        }
        return oldStyle ? "\(text) (O.S.)" : text
    }

    /// `shown` for a front-matter day string ("1752-09-13"); nil for anything that is not `YYYY-MM-DD`.
    static func shown(isoDay: String, in calendar: DisplayCalendar) -> String? {
        let p = isoDay.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return shown(year: y, month: m, day: d, in: calendar)
    }
}
