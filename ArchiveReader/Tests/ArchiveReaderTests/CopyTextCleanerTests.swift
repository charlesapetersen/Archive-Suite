import XCTest
@testable import ArchiveReader

final class CopyTextCleanerTests: XCTestCase {

    func testSingleNewlinesBecomeSpaces() {
        let input = "The quick brown\nfox jumped over\nthe lazy dog."
        XCTAssertEqual(CopyTextCleaner.clean(input), "The quick brown fox jumped over the lazy dog.")
    }

    func testBlankLineIsParagraphBreak() {
        let input = "First paragraph line one\nline two.\n\nSecond paragraph."
        XCTAssertEqual(CopyTextCleaner.clean(input), "First paragraph line one line two.\n\nSecond paragraph.")
    }

    func testMultipleBlankLinesCollapseToOneBreak() {
        let input = "A\n\n\n\nB"
        XCTAssertEqual(CopyTextCleaner.clean(input), "A\n\nB")
    }

    func testDeHyphenationJoinsSplitWord() {
        let input = "The committee approved the wel-\nfare reform bill."
        XCTAssertEqual(CopyTextCleaner.clean(input), "The committee approved the welfare reform bill.")
    }

    func testDeHyphenationOffKeepsHyphen() {
        var opts = CopyTextOptions(); opts.deHyphenate = false
        let input = "wel-\nfare"
        XCTAssertEqual(CopyTextCleaner.clean(input, options: opts), "wel- fare")
    }

    func testNonLetterHyphenNotJoined() {
        // A trailing dash after a digit (e.g. a range) is not a word split.
        let input = "pages 10-\n20"
        XCTAssertEqual(CopyTextCleaner.clean(input), "pages 10- 20")
    }

    func testLeadingTrailingWhitespaceTrimmedPerLine() {
        let input = "  hello   \n   world  "
        XCTAssertEqual(CopyTextCleaner.clean(input), "hello world")
    }

    func testCRLFNormalized() {
        let input = "line one\r\nline two"
        XCTAssertEqual(CopyTextCleaner.clean(input), "line one line two")
    }

    func testCollapseOffPreservesLineBreaks() {
        var opts = CopyTextOptions(); opts.collapseSingleNewlines = false
        let input = "line one\nline two"
        XCTAssertEqual(CopyTextCleaner.clean(input, options: opts), "line one\nline two")
    }
}
