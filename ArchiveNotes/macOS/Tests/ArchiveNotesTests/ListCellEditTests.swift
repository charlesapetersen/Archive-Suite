import Testing
import Foundation
import ArchiveCore
@testable import ArchiveNotes

// W40.notes-detail-layout — the list's Date and Tags cells are edited in place (owner session notes-1, row 7: "the
// date and the tags can't be edited in the list, as the title can"). The cell edits go through the inspector's own
// rules: `DateFieldEntry.listEdit` for a typed date, `NoteTagBar.edits` for the tags left in the cell.

@MainActor
@Suite("The list's Date and Tags cells edit in place")
struct ListCellEditTests {

    /// What the model stores for a write (`NotesModel.setDate` normalizes it): "date precision", or nil if no write.
    private func stored(_ edit: DateFieldEntry.ListEdit) -> String? {
        guard case let .write(date, precision, _) = edit else { return nil }
        let n = Item.normalizedDate(date, precision: precision)
        return "\(n.date ?? "nil") \(n.precision?.rawValue ?? "nil")"
    }

    @Test("a typed date writes at the precision typed; the seed text is no edit")
    func dateWritesAtThePrecisionTyped() {
        let seed = DateFieldEntry.listSeed(storedDate: "1968-03", precision: .month, active: nil)
        #expect(DateFieldEntry.listEdit(seed.text, seed: seed.text, calendar: seed.calendar, storedDate: "1968-03")
                == .unchanged)
        #expect(stored(DateFieldEntry.listEdit("1971", seed: seed.text, calendar: seed.calendar,
                                               storedDate: "1968-03")) == "1971 year")
        #expect(stored(DateFieldEntry.listEdit("12 March 1968", seed: seed.text, calendar: seed.calendar,
                                               storedDate: "1968-03")) == "1968-03-12 day")
    }

    @Test("an emptied cell clears the date, and emptying an empty one is no edit")
    func emptyClears() {
        #expect(DateFieldEntry.listEdit("  ", seed: "1968", calendar: .standard, storedDate: "1968")
                == .write(nil, nil, note: nil))
        let none = DateFieldEntry.listSeed(storedDate: nil, precision: nil, active: nil)
        #expect(none.text.isEmpty)
        #expect(DateFieldEntry.listEdit("", seed: "x", calendar: .standard, storedDate: nil) == .unchanged)
    }

    @Test("text the inspector refuses is refused with its message, never guessed")
    func refusesAmbiguousDates() {
        guard case .refused(let message) = DateFieldEntry.listEdit("12/3/1968", seed: "", calendar: .standard,
                                                                   storedDate: nil) else {
            Issue.record("an all-number date not starting with the year should be refused")
            return
        }
        #expect(!message.isEmpty)
        if case .write = DateFieldEntry.listEdit("68", seed: "", calendar: .standard, storedDate: nil) {
            Issue.record("a two-digit year should not be stored as AD 68")
        }
    }

    @Test("a day the month cannot have saves the month and says so")
    func impossibleDayKeepsTheMonth() {
        let edit = DateFieldEntry.listEdit("1968-02-31", seed: "", calendar: .standard, storedDate: nil)
        guard case let .write(_, _, note) = edit else {
            Issue.record("February 31 should still save the month")
            return
        }
        #expect(stored(edit) == "1968-02 month")
        #expect(note != nil)
    }

    @Test("the tags left in the cell become adds and removes, case and repeats aside")
    func tagEdits() {
        let current = ["Intel", "Silicon Valley"]
        let same = NoteTagBar.edits(from: ["intel", "Silicon Valley"], current: current)
        #expect(same.add.isEmpty && same.remove.isEmpty)
        let changed = NoteTagBar.edits(from: ["Intel", " computing history ", "Computing History", ""], current: current)
        #expect(changed.add == ["computing history"])
        #expect(changed.remove == ["Silicon Valley"])
        let cleared = NoteTagBar.edits(from: [], current: current)
        #expect(cleared.add.isEmpty && cleared.remove == current)
    }
}
