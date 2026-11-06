import XCTest
@testable import ArchiveNotes

/// W40.fix-notes-tag-entry: the tags Notes' tag field suggests.
@MainActor
final class NoteTagSuggestionsTests: XCTestCase {
    private func summary(_ tags: [String]) -> ItemSummary {
        ItemSummary(id: UUID(), title: "T", kind: .note, date: nil, datePrecision: nil, dateUncertain: false,
                    authors: [], sortDate: nil, quality: nil, created: Date(), modified: Date(), mtime: 0,
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
}
