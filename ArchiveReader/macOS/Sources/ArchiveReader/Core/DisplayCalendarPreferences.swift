// DisplayCalendarPreferences.swift — W24.cal1-reader: Options ▸ Dates ▸ "Show dates in other calendars"
// (off by default, as in Notes), a per-document calendar choice, and the Date column's text in it.
//
// Display only. A document's date comes from its Finder tags and stays exactly as tagged — sorting and
// the year filter keep using the stored ISO value. The per-document choice lives app-side in
// UserDefaults, never in the file, so choosing a calendar writes nothing to the corpus.

import Foundation
import ArchiveCore

enum DisplayCalendarSettings {
    /// `UserDefaults` key for Options ▸ Dates ▸ "Show dates in other calendars". Absent = off. The same
    /// key name as Notes' switch, in the Reader's own domain.
    static let enabledKey = "displayCalendarsEnabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    /// A stored day shown in `calendar`, e.g. "2 September 1752 (O.S.)" or "13 Vendémiaire An XII"; nil
    /// when there is nothing to convert — `standard`, or a day before the calendar's epoch (French
    /// Republican before 22 September 1792) — so the caller keeps its stored rendering. Julian dates
    /// carry "(O.S.)", as in Notes: the format is otherwise identical to a Gregorian one.
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
}

/// The per-document calendar choice. Keyed by the durable root GUID and the root-relative path (as
/// `DocumentImageSourcePreferences` is), so it survives relaunches and moving the archive and stays
/// separate between archives. `standard` is the default and is stored as no entry at all.
@MainActor
final class DisplayCalendarPreferences {
    static let key = "ar.displayCalendars"

    private let defaults: UserDefaults
    private var choices: [String: DisplayCalendar]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        choices = stored.compactMapValues(DisplayCalendar.init(rawValue:))
    }

    func calendar(rootGUID: UUID, relativePath: String) -> DisplayCalendar {
        choices[Self.identity(rootGUID, relativePath)] ?? .standard
    }

    func set(_ calendar: DisplayCalendar, rootGUID: UUID, relativePath: String) {
        let id = Self.identity(rootGUID, relativePath)
        choices[id] = calendar == .standard ? nil : calendar
        if choices.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(choices.mapValues(\.rawValue), forKey: Self.key) }
    }

    /// A GUID never contains "/", so the first "/" always ends it.
    private static func identity(_ rootGUID: UUID, _ relativePath: String) -> String {
        rootGUID.uuidString.lowercased() + "/" + relativePath
    }
}

extension ArchiveFile {
    /// `dateCellText` with each day-precision date shown in `calendar`. A year, month or decade is left
    /// as stored, since a Gregorian month does not map onto one month of another calendar; so is a day
    /// the calendar cannot show. `nil` or `standard` gives exactly `dateCellText`.
    func dateCellText(in calendar: DisplayCalendar?) -> String {
        Self.dateCellText(own: ownDateText(in: calendar), sent: sentWithText(in: calendar))
    }

    /// The stored ISO day behind a converted Date cell ("Stored as 1752-09-13 · sent 1752-10-01"), for
    /// the cell's tooltip; nil when nothing in the cell was converted.
    func storedDateTooltip(in calendar: DisplayCalendar?) -> String? {
        guard let calendar, calendar != .standard,
              ownDateText(in: calendar) != tags.displayDate || sentWithText(in: calendar) != tags.displaySentWith
        else { return nil }
        let own = ownDay.map { String(format: "%d-%02d-%02d", $0.y, $0.m, $0.d) }
        let sent = tags.sentWith?.precision == .day ? tags.sentWith?.wireValue : nil
        switch (own, sent) {
        case let (o?, s?): return "Stored as \(o) \u{b7} sent \(s)"
        case let (o?, nil): return "Stored as \(o)"
        case let (nil, s?): return "Sent with, stored as \(s)"
        case (nil, nil): return nil
        }
    }

    static func dateCellText(own: String?, sent: String?) -> String {
        switch (own, sent) {
        case let (own?, sent?): return "\(own) \u{b7} sent \(sent)"
        case let (own?, nil): return own
        case let (nil, sent?): return "Sent with \(sent)"
        case (nil, nil): return "\u{2014}"
        }
    }

    private var ownDay: (y: Int, m: Int, d: Int)? {
        guard let y = tags.year, let m = tags.month?.number, let d = tags.day else { return nil }
        return (y, m, d)
    }

    private func ownDateText(in calendar: DisplayCalendar?) -> String? {
        if let calendar, let day = ownDay,
           let shown = DisplayCalendarSettings.shown(year: day.y, month: day.m, day: day.d, in: calendar) {
            return shown
        }
        return tags.displayDate
    }

    private func sentWithText(in calendar: DisplayCalendar?) -> String? {
        if let calendar, let s = tags.sentWith, s.precision == .day, let m = s.month, let d = s.day,
           let shown = DisplayCalendarSettings.shown(year: s.year, month: m, day: d, in: calendar) {
            return shown
        }
        return tags.displaySentWith
    }
}
