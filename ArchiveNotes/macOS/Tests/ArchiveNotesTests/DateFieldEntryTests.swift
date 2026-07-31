import Testing
import Foundation
@testable import ArchiveNotes

// W23.l4 — the metadata strip's date row. `DateFieldEntry` holds the rules the view used to carry
// inline, so what a commit composes from (year text, month index, day text) is testable without
// driving a window. The bug: the day was checked as `1…31` only, so typing 31 with February chosen
// composed "2026-2-31" and it was persisted at day precision.
//
// Each impossible-day case re-runs the pre-fix compose rule against the same fields and asserts it
// produced the impossible string, so no pass here is vacuous. The month-menu case matters most: the
// picker commits on selection, so an already-typed 31 goes to the store the instant February is
// chosen — no "Set" press to intercept.

@Suite("DateFieldEntry — what the date row commits, and what it says when it drops a day")
struct DateFieldEntryTests {

    /// The pre-fix `.day` composition, verbatim from `NoteMetadataInspector.composedDate()` before
    /// this item — the baseline every impossible-day assertion below contrasts against.
    private func preFixComposedDay(yearText: String, month: Int, dayText: String) -> String? {
        guard let y = Int(yearText.trimmingCharacters(in: .whitespaces)), y > 0 else { return nil }
        if month > 0, let d = Int(dayText), (1...31).contains(d) { return "\(y)-\(month)-\(d)" }
        if month > 0 { return "\(y)-\(month)" }
        return String(y)
    }

    private func composed(_ y: String, _ m: Int, _ d: String,
                          _ p: Item.DatePrecision = .day) -> String? {
        DateFieldEntry.composed(yearText: y, month: m, dayText: d, precision: p)
    }

    // MARK: - The reported case

    @Test("February 31 is not composed as a day — the date drops to the month")
    func februaryThirtyFirst() {
        #expect(composed("2026", 2, "31") == "2026-2")
        #expect(preFixComposedDay(yearText: "2026", month: 2, dayText: "31") == "2026-2-31")
    }

    @Test("choosing February with 31 already typed still cannot commit an impossible day")
    func monthMenuAfterDayTyped() {
        // The month picker's binding commits immediately, so this is the path a disabled "Set"
        // cannot guard — the compose rule has to be the one that refuses.
        #expect(composed("1968", 3, "31") == "1968-3-31")     // March: fine
        #expect(composed("1968", 2, "31") == "1968-2")        // switch to February: day dropped
        #expect(composed("1968", 4, "31") == "1968-4")        // switch to April: day dropped
        #expect(preFixComposedDay(yearText: "1968", month: 4, dayText: "31") == "1968-4-31")
    }

    @Test("February 29 is composed in a leap year and dropped in a common one")
    func leapDay() {
        #expect(composed("2024", 2, "29") == "2024-2-29")
        #expect(composed("2026", 2, "29") == "2026-2")
        #expect(preFixComposedDay(yearText: "2026", month: 2, dayText: "29") == "2026-2-29")
    }

    // MARK: - Everything the row already did, unchanged

    @Test("a real day composes all three components")
    func realDay() {
        #expect(composed("1968", 4, "15") == "1968-4-15")
        #expect(composed(" 1968 ", 12, " 31 ") == "1968-12-31")   // fields are trimmed
    }

    @Test("no month chosen ⟹ the year is committed, day text ignored")
    func noMonth() {
        #expect(composed("1968", 0, "15") == "1968")
    }

    @Test("no day typed ⟹ the month is committed")
    func noDay() {
        #expect(composed("1968", 7, "") == "1968-7")
        #expect(composed("1968", 7, "  ") == "1968-7")
    }

    @Test("an unusable year clears the date whatever else is filled in")
    func noYear() {
        #expect(composed("", 7, "15") == nil)
        #expect(composed("notayear", 7, "15") == nil)
        #expect(composed("0", 7, "15") == nil)
    }

    @Test("coarser precisions ignore the finer fields")
    func coarserPrecisions() {
        #expect(composed("1975", 2, "31", .decade) == "1975")     // the model floors it to 1970
        #expect(composed("1968", 2, "31", .year) == "1968")
        #expect(composed("1968", 2, "31", .month) == "1968-2")
        #expect(composed("1968", 0, "31", .month) == "1968")
    }

    // MARK: - What the operator is told

    @Test("the note names the month, the year and its real length")
    func message() {
        #expect(DateFieldEntry.impossibleDayNote(yearText: "2026", month: 2, dayText: "31")
                == "February 2026 has 28 days — the day is ignored.")
        #expect(DateFieldEntry.impossibleDayNote(yearText: "2024", month: 2, dayText: "30")
                == "February 2024 has 29 days — the day is ignored.")
        #expect(DateFieldEntry.impossibleDayNote(yearText: "1968", month: 4, dayText: "31")
                == "April 1968 has 30 days — the day is ignored.")
        #expect(DateFieldEntry.impossibleDayNote(yearText: "1968", month: 3, dayText: "45")
                == "March 1968 has 31 days — the day is ignored.")
    }

    @Test("nothing is said when there is no contradiction to report")
    func silentWhenNothingToSay() {
        #expect(DateFieldEntry.impossibleDayNote(yearText: "2024", month: 2, dayText: "29") == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "2026", month: 2, dayText: "") == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "2026", month: 2, dayText: "abc") == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "2026", month: 2, dayText: "0") == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "2026", month: 0, dayText: "31") == nil)
        #expect(DateFieldEntry.impossibleDayNote(yearText: "", month: 2, dayText: "31") == nil)
        // A leap year is unknowable without a year, so nothing is claimed about one.
        #expect(DateFieldEntry.impossibleDayNote(yearText: "circa", month: 2, dayText: "29") == nil)
    }

    // MARK: - The day row's "Set" button

    @Test("Set goes dead only for a day the chosen month cannot have")
    func setEnablement() {
        #expect(DateFieldEntry.dayCommittable(yearText: "1968", month: 4, dayText: "15"))
        #expect(DateFieldEntry.dayCommittable(yearText: "1968", month: 0, dayText: "15"))  // as before
        #expect(DateFieldEntry.dayCommittable(yearText: "", month: 4, dayText: "15"))      // as before
        #expect(DateFieldEntry.dayCommittable(yearText: "2024", month: 2, dayText: "29"))
        #expect(!DateFieldEntry.dayCommittable(yearText: "2026", month: 2, dayText: "29"))
        #expect(!DateFieldEntry.dayCommittable(yearText: "1968", month: 4, dayText: "31"))
        #expect(!DateFieldEntry.dayCommittable(yearText: "1968", month: 4, dayText: ""))   // as before
        #expect(!DateFieldEntry.dayCommittable(yearText: "1968", month: 4, dayText: "0"))  // as before
        #expect(!DateFieldEntry.dayCommittable(yearText: "1968", month: 4, dayText: "32")) // as before
    }

    @Test("a live Set and a shown warning are mutually exclusive")
    func setAndWarningNeverAgree() {
        for y in ["", "0", "1968", "2024", "2026", "1500"] {
            for m in 0...12 {
                for d in ["", "abc", "0", "1", "28", "29", "30", "31", "32"] {
                    let committable = DateFieldEntry.dayCommittable(yearText: y, month: m, dayText: d)
                    let warned = DateFieldEntry.impossibleDayNote(yearText: y, month: m, dayText: d) != nil
                    #expect(!(committable && warned), "\(y)/\(m)/\(d)")
                }
            }
        }
    }

    // MARK: - Month names

    @Test("the picker labels and the messages read from one list")
    func monthNames() {
        #expect(DateFieldEntry.monthNames.count == 12)
        #expect(DateFieldEntry.monthNames.first == "January")
        #expect(DateFieldEntry.monthNames.last == "December")
    }
}
