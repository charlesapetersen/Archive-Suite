import XCTest
import AppKit
@testable import ArchiveReader

/// W40.fix-reader-tag-entry: the keys the tag-entry fields share around an autocompletion.
@MainActor
final class TagEntryTests: XCTestCase {
    private let subjects = ["Civil War", "Civil Rights", "civilian", "Civ Aero", "Lincoln"]

    func testCompletionsArePrefixMatchesWithoutTheExactOne() {
        XCTAssertEqual(TagEntry.completions(for: "civ", in: subjects), ["Civil War", "Civil Rights", "civilian", "Civ Aero"])
        XCTAssertEqual(TagEntry.completions(for: "Lincoln", in: subjects), [], "an exact match is not a completion")
        XCTAssertEqual(TagEntry.completions(for: "  Linc", in: subjects), ["Lincoln"], "leading space after a comma is dropped")
        XCTAssertEqual(TagEntry.completions(for: " ", in: subjects), [])
        XCTAssertEqual(TagEntry.completions(for: "c", in: subjects, limit: 2).count, 2)
    }

    /// Row 36: "Civ " is what was typed. Trimmed, it matched "Civil War" and the field put the suggestion back over
    /// the space; now it matches only subjects that really start "Civ ".
    func testATrailingSpaceIsKeptSoItEndsTheCompletion() {
        XCTAssertEqual(TagEntry.completions(for: "Civ ", in: subjects), ["Civ Aero"])
        XCTAssertEqual(TagEntry.completions(for: "Lin ", in: subjects), [])
        XCTAssertEqual(TagEntry.completions(for: "Civil ", in: subjects), ["Civil War", "Civil Rights"],
                       "a space inside a two-word subject still completes it")
    }

    func testPendingTextLeavesOutTokens() {
        let tv = NSTextView()
        tv.string = "\u{FFFC}\u{FFFC} Civil W"
        XCTAssertEqual(TagEntry.pendingText(in: tv), "Civil W")
        tv.string = "\u{FFFC}"
        XCTAssertEqual(TagEntry.pendingText(in: tv), "")
    }

    func testTabTakesASelectedCompletionAndOtherwiseKeepsItsMeaning() {
        let tv = NSTextView()
        tv.string = "\u{FFFC}Civil War"
        tv.setSelectedRange(NSRange(location: 4, length: 6))   // "il War", the suggested rest after "Civ"
        XCTAssertTrue(TagEntry.acceptInlineCompletion(in: tv))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 10, length: 0))
        XCTAssertEqual(tv.string, "\u{FFFC}Civil War", "taking the completion changes no text")

        XCTAssertFalse(TagEntry.acceptInlineCompletion(in: tv), "no selection: Tab moves on as usual")
        tv.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertFalse(TagEntry.acceptInlineCompletion(in: tv), "a selected token is not a completion")
    }
}
