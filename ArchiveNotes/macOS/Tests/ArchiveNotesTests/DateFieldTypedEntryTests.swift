import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

// W40.fix-notes-date-entry — one typed field per date. The owner (Notes guided session 1, row 22): "I
// shouldn't have to click 'Set' or 'Clear' for the Year. I shouldn't have to choose 'Decade', 'Year',
// 'Month', 'Day' for granularity — this should be auto-detected." `DateFieldEntry.parse` reads the
// precision from what was typed; `commit(typed:)` turns it into the write the field makes on Return or
// on leaving it, an emptied field clearing the date.

@Suite("DateFieldEntry — a typed date applies at the precision typed")
struct DateFieldTypedEntryTests {

    private typealias Fields = DateFieldEntry.Fields

    private func parse(_ s: String, _ cal: DisplayCalendar = .standard) -> DateFieldEntry.Typed {
        DateFieldEntry.parse(s, calendar: cal)
    }

    private func written(_ s: String, _ cal: DisplayCalendar = .standard, stored: String? = nil) -> String? {
        let (value, precision) = DateFieldEntry.commit(typed: parse(s, cal), calendar: cal, storedDate: stored)
        guard case .write(let date) = value else { return "keep" }
        return Item.normalizedDate(date, precision: precision).date.map {
            "\($0) \(Item.normalizedDate(date, precision: precision).precision!.rawValue)"
        }
    }

    @Test("the precision is the one typed")
    func precisionDetected() {
        #expect(written("1960s") == "1960 decade")
        #expect(written("1960's") == "1960 decade")
        #expect(written("1968") == "1968 year")
        #expect(written("1968-03") == "1968-03 month")
        #expect(written("March 1968") == "1968-03 month")
        #expect(written("1968 March") == "1968-03 month")
        #expect(written("3/1968") == "1968-03 month")
        #expect(written("1968-03-12") == "1968-03-12 day")
        #expect(written("1968/3/12") == "1968-03-12 day")
        #expect(written("12 March 1968") == "1968-03-12 day")
        #expect(written("March 12th, 1968") == "1968-03-12 day")
        #expect(written("12 Mar. 1968") == "1968-03-12 day")
        #expect(written("  sept 5 1968 ") == "1968-09-05 day")
    }

    @Test("an emptied field clears the date")
    func emptyClears() {
        #expect(parse("") == .empty)
        #expect(parse("   ") == .empty)
        #expect(written("") == nil)
    }

    @Test("an impossible day is dropped to the month, and the row says so")
    func impossibleDay() {
        #expect(written("31 February 2026") == "2026-02 month")
        #expect(written("2026-02-29") == "2026-02 month")
        #expect(written("2024-02-29") == "2024-02-29 day")
        guard case .date(let f, .day) = parse("31 February 2026") else { Issue.record("not a day"); return }
        #expect(DateFieldEntry.impossibleDayNote(yearText: f.yearText, month: f.month, dayText: f.dayText)
                == "February 2026 has 28 days — the day is ignored.")
    }

    @Test("ambiguous or unreadable text writes nothing")
    func unreadable() {
        for text in ["12/3/1968", "3/12", "March", "March 12", "Smarch 1968", "circa 1968", "1968-13",
                     "1968-03-00", "0", "ma 1968", "12 March 20", "1968a", "1 2 3 4"] {
            guard case .unreadable = parse(text) else {
                Issue.record("\(text) should be unreadable, got \(parse(text))")
                continue
            }
            #expect(written(text) == "keep", "\(text)")
        }
        // "ju" could be June or July; three letters settle it.
        #expect(written("Jun 1968") == "1968-06 month")
        #expect(written("Jul 1968") == "1968-07 month")
    }

    @Test("the starting text reads back as the stored date")
    func seedRoundTrips() {
        let cases: [(String?, Item.DatePrecision?, String)] = [
            (nil, nil, ""), ("1960", .decade, "1960s"), ("1968", .year, "1968"),
            ("1968-03", .month, "1968-03"), ("1968-03-12", .day, "1968-03-12"),
        ]
        for (stored, precision, text) in cases {
            let seeded = DateFieldEntry.seedText(storedDate: stored, precision: precision, active: nil)
            #expect(seeded.text == text)
            #expect(seeded.calendar == .standard)
            #expect(written(seeded.text) == stored.map { "\($0) \(precision!.rawValue)" })
        }
    }

    @Test("under another calendar a whole day is typed in words and stored as its ISO day")
    func otherCalendar() {
        // Julian (English 1752 cutover): 29 February 1700 is Gregorian 11 March 1700.
        let english = DisplayCalendar.julianEnglish1752
        #expect(written("29 February 1700", english) == "1700-03-11 day")
        // Retyping the stored day unchanged writes nothing (a pre-1582 leap day is not rewritten).
        #expect(written("1500-02-29", english, stored: "1500-02-29") == "keep")
        // Anything short of a whole day is not saved under a calendar.
        #expect(written("1700", english) == "keep")
        // An empty date is typed in the item's calendar; its day is shown back in words.
        #expect(DateFieldEntry.seedText(storedDate: nil, precision: nil, active: english).calendar == english)
        let seeded = DateFieldEntry.seedText(storedDate: "1700-03-11", precision: .day, active: english)
        #expect(seeded.text == "29 February 1700")
        #expect(written(seeded.text, english, stored: "1700-03-11") == "keep")
        // A stored year is typed in Gregorian.
        #expect(DateFieldEntry.seedText(storedDate: "1700", precision: .year, active: english).calendar == .standard)
    }

    @Test("month names with several words are read under their calendar")
    func multiWordMonths() {
        let name = DisplayCalendar.hebrew.monthName(7, year: 5784) ?? ""   // 5784 is a Hebrew leap year
        guard case .date(let f, .day) = parse("1 \(name) 5784", .hebrew) else {
            Issue.record("\(name) not read"); return
        }
        #expect(f.month == 7)
    }
}
