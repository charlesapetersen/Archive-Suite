import XCTest
@testable import ArchiveReader

/// Pure parser tests for the FTS5 `snippet()` → highlight-segment conversion. No SQLite — exercises
/// the marker vocabulary and the malformed-input robustness directly.
final class SearchSnippetTests: XCTestCase {

    private let open = SearchSnippet.openMark
    private let close = SearchSnippet.closeMark

    private func seg(_ text: String, _ isMatch: Bool) -> SearchSnippet.Segment {
        SearchSnippet.Segment(text: text, isMatch: isMatch)
    }

    func testEmptyIsNoSegments() {
        XCTAssertTrue(SearchSnippet.segments(from: "").isEmpty)
    }

    func testPlainTextIsOneUnhighlightedRun() {
        let segs = SearchSnippet.segments(from: "no markers here")
        XCTAssertEqual(segs, [seg("no markers here", false)])
        XCTAssertFalse(SearchSnippet.hasMatch(segs))
    }

    func testSingleMatchInMiddle() {
        let marked = "the \(open)cold\(close) war budget"
        let segs = SearchSnippet.segments(from: marked)
        XCTAssertEqual(segs, [seg("the ", false), seg("cold", true), seg(" war budget", false)])
        XCTAssertTrue(SearchSnippet.hasMatch(segs))
    }

    func testMultipleMatches() {
        let marked = "…\(open)cold\(close) war and \(open)cold\(close) weather…"
        let segs = SearchSnippet.segments(from: marked)
        XCTAssertEqual(segs, [
            seg("…", false), seg("cold", true), seg(" war and ", false),
            seg("cold", true), seg(" weather…", false),
        ])
    }

    func testLeadingAndTrailingMatch() {
        let marked = "\(open)Budget\(close) report on the \(open)economy\(close)"
        let segs = SearchSnippet.segments(from: marked)
        XCTAssertEqual(segs, [seg("Budget", true), seg(" report on the ", false), seg("economy", true)])
    }

    func testEllipsisIsPreservedAsText() {
        // The ellipsis FTS5 inserts is ordinary text, not a marker.
        let marked = "\(SearchSnippet.ellipsis) the \(open)war\(close) \(SearchSnippet.ellipsis)"
        let segs = SearchSnippet.segments(from: marked)
        XCTAssertEqual(segs, [seg("… the ", false), seg("war", true), seg(" …", false)])
    }

    // MARK: malformed input robustness (never throws / never loses non-marker text)

    func testStrayCloseMarkIsDropped() {
        let segs = SearchSnippet.segments(from: "plain\(close) text")
        XCTAssertEqual(segs, [seg("plain text", false)])
    }

    func testUnterminatedMatchRunsToEnd() {
        let segs = SearchSnippet.segments(from: "start \(open)tail")
        XCTAssertEqual(segs, [seg("start ", false), seg("tail", true)])
    }

    func testDuplicateOpenIsIgnored() {
        let segs = SearchSnippet.segments(from: "\(open)\(open)term\(close)")
        XCTAssertEqual(segs, [seg("term", true)])
    }

    func testOnlyMarkersProduceNoSegments() {
        XCTAssertTrue(SearchSnippet.segments(from: "\(open)\(close)").isEmpty)
    }

    func testMarksAreDistinctControlChars() {
        XCTAssertNotEqual(SearchSnippet.openMark, SearchSnippet.closeMark)
        XCTAssertEqual(SearchSnippet.openMark.count, 1)
        XCTAssertEqual(SearchSnippet.closeMark.count, 1)
    }
}
