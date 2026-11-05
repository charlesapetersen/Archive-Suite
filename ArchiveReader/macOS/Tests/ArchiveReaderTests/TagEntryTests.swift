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
        tv.setSelectedRange(NSRange(location: 9, length: 1))   // "W": a suggested rest after "Civil "
        XCTAssertEqual(TagEntry.pendingText(in: tv, includingSuggestion: false), "Civil")
        XCTAssertEqual(TagEntry.pendingText(in: tv), "Civil W")
        tv.string = "\u{FFFC}"
        XCTAssertEqual(TagEntry.pendingText(in: tv), "")
    }
}
