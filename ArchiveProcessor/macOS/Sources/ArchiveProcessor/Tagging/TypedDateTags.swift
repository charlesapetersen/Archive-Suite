import Foundation
import ArchiveCore

/// The Processor's typed date field and the tags it writes (W40.processor-date-field). A date is typed in one field
/// by ArchiveCore `DateFieldEntry`'s rules — the suite's one design, as in Notes — and kept as the same Year / Month /
/// Day strings `GeneratedTags` already writes ("1968" or "1960s", "3 March", "Day 12"), so the tag format is unchanged.
/// A covering letter's date (`sentWith`) is the `ArchiveDate` wire value, as before.
enum TypedDateTags {

    /// The Year / Month / Day strings of a draft (`SegmentTagData`, `ManualTagSegment`).
    struct Components: Equatable {
        var year = ""
        var month = ""
        var day = ""
        var tuple: (String, String, String) { (year, month, day) }
    }

    /// The strings a date is written as. A decade or year carries no month or day; nil clears all three.
    static func components(_ date: ArchiveDate?) -> Components {
        guard let date else { return Components() }
        switch date.precision {
        case .decade, .year:
            return Components(year: date.wireValue)
        case .month, .day:
            return Components(year: String(date.year),
                              month: date.month.flatMap(GeneratedTags.monthTag) ?? "",
                              day: date.day.map { "Day \($0)" } ?? "")
        }
    }

    /// The own date the strings name: Year "1958" or a decade "1950s"; Month "3 March" (or anything
    /// `GeneratedTags.monthNumber` accepts); Day "Day 12". A day without a month is ignored, as
    /// `GeneratedTags.machineDate` ignores it. `nil` when there is no year, or a present component does not
    /// parse or form a real date (Feb 30): a disputed date is left alone, not silently truncated. A decade
    /// never takes a month or day.
    static func date(year: String?, month: String?, day: String?) -> ArchiveDate? {
        guard let rawYear = year?.trimmingCharacters(in: .whitespaces), !rawYear.isEmpty else { return nil }
        let monthText = month?.trimmingCharacters(in: .whitespaces) ?? ""
        let dayText = day?.trimmingCharacters(in: .whitespaces) ?? ""

        if rawYear.hasSuffix("s") {
            guard monthText.isEmpty, dayText.isEmpty else { return nil }
            return ArchiveDate.parse(wireValue: rawYear).flatMap { $0.precision == .decade ? $0 : nil }
        }
        // Reuse the strict wire grammar for the year (3–4 digits, no leading zero).
        guard let yearOnly = ArchiveDate.parse(wireValue: rawYear), yearOnly.precision == .year else { return nil }
        guard !monthText.isEmpty else { return yearOnly }

        guard let m = GeneratedTags.monthNumber(from: monthText) else { return nil }
        var d: Int? = nil
        if !dayText.isEmpty {
            guard let n = GeneratedTags.dayNumber(from: dayText) else { return nil }
            d = n
        }
        return ArchiveDate(year: yearOnly.year, month: m, day: d)
    }

    /// The text a field shows for stored strings that name no date (an odd auto-date reply, say), so it is
    /// seen and fixed rather than shown as empty.
    static func rawText(_ c: Components) -> String {
        [c.year, c.month, c.day].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Live Capture keeps a year and a month for a segment (`CaptureSession.applyMacTags`): a decade cannot
    /// be kept there, and a day is dropped with a note.
    static func liveCaptureReading(_ text: String) -> DateFieldEntry.Reading {
        let reading = DateFieldEntry.archiveDate(text)
        guard case .date(let date, _) = reading else { return reading }
        switch date.precision {
        case .decade:
            return .unreadable("Live Capture keeps a year and a month, not a decade — type a year, such as 1968.")
        case .year, .month:
            return reading
        case .day:
            guard let month = date.month, let kept = ArchiveDate(year: date.year, month: month) else { return reading }
            return .date(kept, note: "Live Capture keeps the year and month; the day is not kept.")
        }
    }
}
