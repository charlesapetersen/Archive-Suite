import AppKit
import XCTest
@testable import ArchiveCoreUI

@MainActor
final class TagEntryAndFilterBarTests: XCTestCase {
    func testCompletionsKeepTrailingSpaceAndExcludeExactMatches() {
        let subjects = ["Civil War", "Civil Rights", "Civics", "Intelligence", "Intel"]
        XCTAssertEqual(TagEntry.completions(for: "Civ", in: subjects), ["Civil War", "Civil Rights", "Civics"])
        // Trailing space stays part of what was typed so multi-word typing is never hijacked.
        XCTAssertEqual(TagEntry.completions(for: "Civ ", in: subjects), [])
        // Leading whitespace is dropped.
        XCTAssertEqual(TagEntry.completions(for: "  civ", in: subjects), ["Civil War", "Civil Rights", "Civics"])
        // Exact match (case-insensitive) is omitted from suggestions.
        XCTAssertEqual(TagEntry.completions(for: "intel", in: subjects), ["Intelligence"])
        // Limit caps output.
        XCTAssertEqual(TagEntry.completions(for: "civ", in: subjects, limit: 2), ["Civil War", "Civil Rights"])
        // Whitespace-only returns nothing.
        XCTAssertEqual(TagEntry.completions(for: "   ", in: subjects), [])
    }

    func testFilledInIndexPreservesTypedCaseAndRespectsExactExistingSubject() {
        let subjects = ["Intel", "Intelligence", "W40d8 Match"]
        let completions = TagEntry.completions(for: "w40d8", in: subjects)
        XCTAssertEqual(completions, ["W40d8 Match"])
        // Case mismatch is never auto-filled in strict mode (so user can type case variants).
        XCTAssertEqual(TagEntry.filledInIndex(for: "w40d8", in: completions), -1)
        XCTAssertEqual(TagEntry.filledInIndex(for: "W40d8", in: completions), 0)
        // anyCase mode fills the first completion when not already an existing subject.
        XCTAssertEqual(TagEntry.filledInIndex(for: "w40d8", in: completions, among: subjects, anyCase: true), 0)
        // Typing an exact existing subject ("Intel") never auto-fills a longer subject ("Intelligence").
        let intelCompletions = TagEntry.completions(for: "Intel", in: subjects)
        XCTAssertEqual(intelCompletions, ["Intelligence"])
        XCTAssertEqual(TagEntry.filledInIndex(for: "Intel", in: intelCompletions, among: subjects, anyCase: true), -1)
        XCTAssertEqual(TagEntry.filledInIndex(for: "intel", in: intelCompletions, among: subjects, anyCase: false), -1)
    }

    func testPendingTextStripsAttachmentsAndOptionalInlineSuggestion() {
        let textView = NSTextView()
        textView.string = "\u{FFFC} Civil War"
        textView.setSelectedRange(NSRange(location: 5, length: 6)) // "il War" selected as suggestion
        XCTAssertEqual(TagEntry.pendingText(in: textView, includingSuggestion: true), "Civil War")
        XCTAssertEqual(TagEntry.pendingText(in: textView, includingSuggestion: false), "Civ")
    }

    func testFilterBarLayoutWrapsGrowsAndAlignsTrailingControls() {
        let items = [
            FilterBarLayout.Item(min: 100, ideal: 150, max: 220),
            FilterBarLayout.Item(min: 100, ideal: 140, max: 140),
            FilterBarLayout.Item(min: 80, ideal: 80, max: 80, trailing: true),
        ]

        // Wide width: all fit on one row, leading items grow up to ideal/max, trailing sits flush right.
        let wide = FilterBarLayout.rows(items, width: 500, spacing: 10)
        XCTAssertEqual(wide.count, 1)
        XCTAssertEqual(wide[0].map(\.index), [0, 1, 2])
        XCTAssertEqual(wide[0][0].width, 220)
        XCTAssertEqual(wide[0][1].width, 140)
        XCTAssertEqual(wide[0][2].x, 420)
        XCTAssertEqual(wide[0][2].width, 80)

        // Narrow width: third item wraps to row 2, trailing against the narrow width.
        let narrow = FilterBarLayout.rows(items, width: 250, spacing: 10)
        XCTAssertEqual(narrow.count, 2)
        XCTAssertEqual(narrow[0].map(\.index), [0, 1])
        XCTAssertEqual(narrow[1].map(\.index), [2])
        XCTAssertEqual(narrow[1][0].x, 170)
    }
}
