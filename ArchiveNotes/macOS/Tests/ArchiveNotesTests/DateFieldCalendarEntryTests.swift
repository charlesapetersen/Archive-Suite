import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

// W24.cal1-validator — the date row's days-in-month rule follows the item's calendar. With a calendar
// chosen (Settings switch on), a day is judged by that calendar's month lengths and converted to the
// proleptic ISO day for storage; with the switch off every rule is today's `GregorianDay` one. The case
// the item exists for: an English `1700-02-29` is a real day under Julian with the 1752 cutover (1700
// was a Julian leap year) and is not one under Gregorian. Under a calendar only a whole storable day is
// ever written: anything less commits nothing (never a guessed month, never a clear), and a stored date
// that is not a whole day is entered in Gregorian. Scratch `mktemp` stores only.

@Suite("DateFieldEntry — the day rule follows the item's calendar")
struct DateFieldCalendarEntryTests {

    private typealias Commit = DateFieldEntry.Commit
    private let english = DisplayCalendar.julianEnglish1752

    private func commit(_ y: String, _ m: Int, _ d: String, _ p: Item.DatePrecision = .day,
                        _ cal: DisplayCalendar = .standard, stored: String? = nil) -> Commit {
        DateFieldEntry.commit(yearText: y, month: m, dayText: d, precision: p, calendar: cal, storedDate: stored)
    }

    // MARK: - The reported case, both ways

    @Test("1700-02-29 is accepted under Julian with the 1752 cutover, and stored as its ISO day")
    func englishLeapDayAccepted() {
        #expect(DateFieldEntry.acceptedDay(yearText: "1700", month: 2, dayText: "29", calendar: english) == 29)
        #expect(DateFieldEntry.dayCommittable(yearText: "1700", month: 2, dayText: "29", calendar: english))
        #expect(DateFieldEntry.impossibleDayNote(yearText: "1700", month: 2, dayText: "29", calendar: english) == nil)
        // Eleven days behind by then: Julian 29 February 1700 is Gregorian 11 March 1700.
        #expect(commit("1700", 2, "29", .day, english) == .write("1700-3-11"))
        // …and that stored day shows back as the day typed.
        #expect(DateFieldEntry.fields(storedDate: "1700-03-11", calendar: english)
                == .init(yearText: "1700", month: 2, dayText: "29"))
    }

    @Test("1700-02-29 is rejected under Gregorian, and the date drops to the month")
    func englishLeapDayRejectedUnderGregorian() {
        #expect(DateFieldEntry.acceptedDay(yearText: "1700", month: 2, dayText: "29") == nil)
        #expect(!DateFieldEntry.dayCommittable(yearText: "1700", month: 2, dayText: "29"))
        #expect(DateFieldEntry.impossibleDayNote(yearText: "1700", month: 2, dayText: "29")
                == "February 1700 has 28 days — the day is ignored.")
        #expect(commit("1700", 2, "29") == .write("1700-2"))
    }

    @Test("under the English cutover, 3–13 September 1752 never happened")
    func englishCutoverGap() {
        #expect(commit("1752", 9, "2", .day, english) == .write("1752-9-13"))
        #expect(commit("1752", 9, "14", .day, english) == .write("1752-9-14"))
        #expect(DateFieldEntry.acceptedDay(yearText: "1752", month: 9, dayText: "10", calendar: english) == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "1752", month: 9, dayText: "10", calendar: english)
                == "10 September 1752 does not exist in the Julian, English 1752 cutover calendar — the day is ignored.")
        #expect(commit("1752", 9, "10", .day, english) == .keep)   // nothing partial is converted
    }

    // MARK: - Hebrew and Islamic month lengths

    @Test("Hebrew: Iyyar has 29 days; Adar I in a leap year has 30; 1 Tishri 5785 is 3 October 2024")
    func hebrewMonthLengths() {
        #expect(DateFieldEntry.acceptedDay(yearText: "5785", month: 2, dayText: "29", calendar: .hebrew) == 29)
        #expect(DateFieldEntry.acceptedDay(yearText: "5785", month: 2, dayText: "30", calendar: .hebrew) == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "5785", month: 2, dayText: "30", calendar: .hebrew)
                == "Iyyar 5785 has 29 days in the Hebrew calendar — the day is ignored.")
        // 5784 is a leap year: month 12 is Adar I (30 days) and month 13 exists; 5785 has no month 13.
        #expect(DateFieldEntry.acceptedDay(yearText: "5784", month: 12, dayText: "30", calendar: .hebrew) == 30)
        #expect(DateFieldEntry.monthChoices(yearText: "5784", calendar: .hebrew).count == 13)
        #expect(DateFieldEntry.monthChoices(yearText: "5784", calendar: .hebrew)[11].name == "Adar I")
        #expect(DateFieldEntry.monthChoices(yearText: "5785", calendar: .hebrew).count == 12)
        #expect(DateFieldEntry.acceptedDay(yearText: "5785", month: 13, dayText: "1", calendar: .hebrew) == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "5785", month: 13, dayText: "1", calendar: .hebrew)
                == "Year 5785 of the Hebrew calendar has no month 13 — the day is ignored.")
        #expect(commit("5785", 7, "1", .day, .hebrew) == .write("2024-10-3"))
    }

    @Test("Islamic: Muharram has 30 days, Safar 29")
    func islamicMonthLengths() {
        #expect(DateFieldEntry.acceptedDay(yearText: "1446", month: 1, dayText: "30", calendar: .islamic) == 30)
        #expect(DateFieldEntry.acceptedDay(yearText: "1446", month: 2, dayText: "30", calendar: .islamic) == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "1446", month: 2, dayText: "30", calendar: .islamic)
                == "Safar 1446 has 29 days in the Islamic (tabular) calendar — the day is ignored.")
    }

    @Test("a day that converts to before year 1 is never written, and never clears the date")
    func outsideStoredYears() {
        #expect(DateFieldEntry.acceptedDay(yearText: "100", month: 7, dayText: "1", calendar: .hebrew) == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "100", month: 7, dayText: "1", calendar: .hebrew)
                == "1 Tishri 100 falls outside the years Notes can store — the day is ignored.")
        #expect(commit("100", 7, "1", .day, .hebrew) == .keep)
    }

    // MARK: - Option off: today's rule, unchanged

    @Test("with the option off the fields are Gregorian, and 1500-02-29 is still accepted")
    func optionOffUnchanged() {
        // Switch off ⟹ no active calendar ⟹ `.standard` at every precision.
        for p in [Item.DatePrecision.decade, .year, .month, .day] {
            #expect(DateFieldEntry.entryCalendar(nil, precision: p) == .standard)
        }
        #expect(commit("1500", 2, "29") == .write("1500-2-29"))
        #expect(DateFieldEntry.acceptedDay(yearText: "1500", month: 2, dayText: "29") == 29)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "1500", month: 2, dayText: "29") == nil)
        #expect(commit("1900", 2, "29") == .write("1900-2"))
        // Gregorian commits are exactly `composed`, whatever is stored, and the default argument and
        // an explicit `.standard` agree.
        for (y, m, d) in [("2026", 2, "31"), ("1500", 2, "29"), ("1968", 4, "31"), ("1752", 9, "10"),
                          ("2024", 0, "5"), ("", 3, "1")] {
            for p in [Item.DatePrecision.decade, .year, .month, .day] {
                #expect(Commit.write(DateFieldEntry.composed(yearText: y, month: m, dayText: d, precision: p))
                        == commit(y, m, d, p, .standard, stored: "\(y)-\(m)-\(d)"))
            }
            #expect(DateFieldEntry.impossibleDayNote(yearText: y, month: m, dayText: d)
                    == DateFieldEntry.impossibleDayNote(yearText: y, month: m, dayText: d, calendar: .standard))
        }
        // The seed is the stored text split as-is, zero padding and all.
        let s = DateFieldEntry.seed(storedDate: "1500-02-29", active: nil, precision: .day)
        #expect(s.calendar == .standard)
        #expect(s.fields == .init(yearText: "1500", month: 2, dayText: "29"))
        #expect(DateFieldEntry.fields(storedDate: "1968-04-05") == .init(yearText: "1968", month: 4, dayText: "05"))
        #expect(DateFieldEntry.monthChoices(yearText: "1700").map(\.name) == DateFieldEntry.monthNames)
    }

    @Test("a calendar applies at day precision only")
    func coarsePrecisionStaysGregorian() {
        #expect(DateFieldEntry.entryCalendar(.hebrew, precision: .day) == .hebrew)
        #expect(DateFieldEntry.entryCalendar(.hebrew, precision: .month) == .standard)
        #expect(DateFieldEntry.entryCalendar(.hebrew, precision: .year) == .standard)
    }

    // MARK: - Nothing partial, nothing guessed, nothing cleared

    @Test("under a calendar, fields short of a whole day commit nothing")
    func partialCommitsNothing() {
        // No day typed, no month, an impossible day, a year outside the stored range: all `.keep`.
        #expect(commit("5785", 7, "", .day, .hebrew) == .keep)
        #expect(commit("5785", 0, "", .day, .hebrew) == .keep)
        #expect(commit("5785", 2, "30", .day, .hebrew) == .keep)
        #expect(commit("785", 7, "1", .day, .hebrew) == .keep)   // a mistyped year never clears the date
        #expect(commit("", 0, "", .day, .hebrew) == .keep)
        // …and the row says why, unless the impossible-day note already does or nothing is typed.
        #expect(DateFieldEntry.incompleteNote(yearText: "5785", month: 7, dayText: "", calendar: .hebrew)
                == "Not saved: enter a year, month and day — only a whole Hebrew day is stored.")
        #expect(DateFieldEntry.incompleteNote(yearText: "5785", month: 2, dayText: "30", calendar: .hebrew) == nil)
        #expect(DateFieldEntry.incompleteNote(yearText: "", month: 0, dayText: "", calendar: .hebrew) == nil)
        #expect(DateFieldEntry.incompleteNote(yearText: "5785", month: 7, dayText: "1", calendar: .hebrew) == nil)
        #expect(DateFieldEntry.incompleteNote(yearText: "2024", month: 10, dayText: "", calendar: .standard) == nil)
        // Gregorian is unchanged: an empty year still clears, no day still writes the month.
        #expect(commit("", 0, "") == .write(nil))
        #expect(commit("2024", 10, "") == .write("2024-10"))
    }

    @Test("leaving day precision cuts the converted ISO day, never the calendar's own numbers")
    func leavingDayPrecision() {
        // 1 Tishri 5785, switched to month: October 2024, not "5785-7".
        #expect(commit("5785", 7, "1", .month, .hebrew) == .write("2024-10"))
        #expect(commit("5785", 7, "1", .year, .hebrew) == .write("2024"))
        #expect(commit("1700", 2, "29", .month, english) == .write("1700-3"))
    }

    @Test("a stored month or year is entered in Gregorian even with a calendar chosen")
    func partialStoredDateStaysGregorian() {
        for stored in ["1800-10", "1800-9", "2024", "1700-02"] {
            for cal in DisplayCalendar.allCases {
                let s = DateFieldEntry.seed(storedDate: stored, active: cal, precision: .day)
                #expect(s.calendar == .standard)
                #expect(s.fields == DateFieldEntry.fields(storedDate: stored))
            }
        }
        // Round trip (review F1): French Republican, stored 1800-10 at month precision. Month → Day →
        // Month writes 1800-10 back, not 1800-09.
        let day = DateFieldEntry.seed(storedDate: "1800-10", active: .frenchRepublican, precision: .day)
        #expect(commit(day.fields.yearText, day.fields.month, day.fields.dayText, .day, day.calendar)
                == .write("1800-10"))
        #expect(commit(day.fields.yearText, day.fields.month, day.fields.dayText, .month, day.calendar)
                == .write("1800-10"))
    }

    @Test("a whole stored day round-trips through every calendar unchanged")
    func wholeDayRoundTrip() {
        var checked = 0
        for stored in ["1700-03-11", "1752-09-14", "1803-10-06", "2024-10-03", "1500-03-10"] {
            for cal in DisplayCalendar.allCases where cal != .standard {
                let s = DateFieldEntry.seed(storedDate: stored, active: cal, precision: .day)
                guard s.calendar == cal else { continue }   // outside this calendar: Gregorian, covered above
                let plain = stored.split(separator: "-").map { String(Int($0)!) }.joined(separator: "-")
                #expect(commit(s.fields.yearText, s.fields.month, s.fields.dayText, .day, cal) == .write(plain))
                // …and committing it again over itself writes nothing.
                #expect(commit(s.fields.yearText, s.fields.month, s.fields.dayText, .day, cal, stored: stored) == .keep)
                checked += 1
            }
        }
        #expect(checked >= 20)
    }

    @Test("a stored pre-1582 Julian leap day is not rewritten by a commit that changes nothing")
    func julianLeapDayNotRewritten() {
        let s = DateFieldEntry.seed(storedDate: "1500-02-29", active: .julian, precision: .day)
        #expect(s.calendar == .julian)
        #expect(s.fields == .init(yearText: "1500", month: 2, dayText: "29"))
        #expect(commit("1500", 2, "29", .day, .julian, stored: "1500-02-29") == .keep)
        #expect(commit("1500", 2, "28", .day, .julian, stored: "1500-02-29") == .write("1500-3-9"))
    }

    @Test("a date the calendar cannot show is entered as stored")
    func seedFallsBackBeforeEpoch() {
        let s = DateFieldEntry.seed(storedDate: "1700-03-11", active: .frenchRepublican, precision: .day)
        #expect(s.calendar == .standard)
        #expect(s.fields == .init(yearText: "1700", month: 3, dayText: "11"))
        let empty = DateFieldEntry.seed(storedDate: nil, active: .frenchRepublican, precision: .day)
        #expect(empty.calendar == .frenchRepublican)
        #expect(empty.fields == .init(yearText: "", month: 0, dayText: ""))
    }

    // MARK: - The write path (scratch store)

    @Test("a Julian entry writes the same ISO bytes as typing the Gregorian day")
    @MainActor
    func writesIsoDay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-calendar-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = NotesIndex(url: root.appendingPathComponent("index.db"))
        try await index.open()
        defer { Task { await index.close(); try? FileManager.default.removeItem(at: root) } }
        let org = OrganizationStore(index: index)
        try await org.load(storeRoot: root)
        let store = NoteStore(root: root)
        let model = NotesModel(organization: org, index: index, noteStore: store)

        func note() async throws -> UUID {
            let item = Item(id: UUID(), kind: .note, title: "Letter", authors: [], date: nil,
                            datePrecision: nil, dateUncertain: false, quality: nil, tags: [], zotero: [],
                            roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
                            unknownFrontMatter: [], trailingBodyRaw: nil)
            _ = try await store.create(item)
            return item.id
        }
        func dateLine(_ id: UUID) throws -> Substring? {
            let dir = NoteStore.itemDir(root: root, id: id)
            let md = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "md" })
            return String(decoding: try Data(contentsOf: md), as: UTF8.self)
                .split(separator: "\n").first { $0.hasPrefix("date:") }
        }

        let julian = try await note(), gregorian = try await note()
        guard case .write(let j) = commit("1700", 2, "29", .day, english),
              case .write(let g) = commit("1700", 3, "11") else { Issue.record("nothing to write"); return }
        await model.setDate(j, precision: .day, for: julian)
        await model.setDate(g, precision: .day, for: gregorian)
        let line = try #require(try dateLine(julian))
        #expect(line == "date: 1700-03-11" || line == "date: \"1700-03-11\"")
        #expect(try dateLine(julian) == dateLine(gregorian))
        let loaded = try await store.load(julian)
        #expect(loaded.date == "1700-03-11" && loaded.datePrecision == .day)
    }
}
