import XCTest
@testable import ArchiveNotes

/// W40.fix-notes-tag-entry: the tags Notes' tag field suggests.
@MainActor
final class NoteTagSuggestionsTests: XCTestCase {
    private func summary(_ tags: [String]) -> ItemSummary {
        ItemSummary(id: UUID(), title: "T", kind: .note, date: nil, datePrecision: nil, dateUncertain: false,
                    sortDate: nil, quality: nil, created: Date(), modified: Date(), mtime: 0,
                    managedTags: tags)
    }

    func testSuggestsOtherNotesTagsMostUsedFirstInTheirSavedForm() {
        let note = summary(["Intel"])
        let others = [summary(["intel", "silicon valley"]), summary(["Silicon Valley", "corporate culture"]),
                      summary(["computing history", "silicon valley"])]
        XCTAssertEqual(NoteTagBar.suggestions(for: note, in: [note] + others),
                       ["Silicon Valley", "Computing History", "Corporate Culture"],
                       "own tags left out (any case), variants merged in the form a save writes, most used first")
    }

    func testANoteAloneHasNoSuggestions() {
        let note = summary(["Intel"])
        XCTAssertEqual(NoteTagBar.suggestions(for: note, in: [note]), [])
    }

    /// W40.fix-notes-tag-fields: the filter bar's and Advanced Search's tag field suggest every tag on a note, in
    /// each spelling a note has, since the filter bar matches a tag's spelling exactly.
    func testSearchFieldsSuggestEveryTagInEachSpellingMostUsedFirst() {
        let items = [summary(["Intel", "Silicon Valley"]), summary(["intel", "Silicon Valley", "Silicon Valley"]),
                     summary(["Computing History", " "]), summary([])]
        XCTAssertEqual(NoteTagChipsField.suggestions(in: items),
                       ["Silicon Valley", "Computing History", "Intel", "intel"],
                       "counted once per note, blank tags dropped, ties by name")
        XCTAssertEqual(NoteTagChipsField.suggestions(in: []), [])
    }
}
