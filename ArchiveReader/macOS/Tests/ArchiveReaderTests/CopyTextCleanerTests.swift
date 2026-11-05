import XCTest
import PDFKit
import CoreText
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

    // Regression (review finding [13]): de-hyphenation works even when newline-collapsing is OFF.
    func testDeHyphenationWorksWithCollapseOff() {
        var opts = CopyTextOptions(); opts.collapseSingleNewlines = false; opts.deHyphenate = true
        XCTAssertEqual(CopyTextCleaner.clean("wel-\nfare\nstate", options: opts), "welfare\nstate")
    }

    // MARK: - Paragraph breaks from layout (W40.fix-reader-prose-paragraphs)

    /// A line `x` points in from the margin, `width` wide, at row `row` (14 pt line spacing, 12 pt tall).
    private func line(_ text: String, x: CGFloat = 0, width: CGFloat = 400, row: CGFloat, page: Int = 0) -> CopyTextLine {
        CopyTextLine(text: text, box: CGRect(x: 50 + x, y: 700 - row * 14, width: width, height: 12), page: page)
    }

    func testFirstLineIndentStartsParagraph() {
        let lines = [line("The committee met on Tuesday and", row: 0),
                     line("agreed the terms", row: 1),
                     line("The second paragraph begins here", x: 30, width: 370, row: 2),
                     line("and runs on to the margin.", row: 3)]
        let raw = lines.map(\.text).joined(separator: "\n")
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "The committee met on Tuesday and agreed the terms\n\nThe second paragraph begins here and runs on to the margin.")
    }

    func testShortLineEndingSentenceStartsParagraph() {
        let lines = [line("The committee met on Tuesday and", row: 0),
                     line("agreed the terms.", width: 150, row: 1),
                     line("Mr. Smith then moved to adjourn the", row: 2),
                     line("meeting until Friday at noon", row: 3)]
        let raw = lines.map(\.text).joined(separator: "\n")
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "The committee met on Tuesday and agreed the terms.\n\nMr. Smith then moved to adjourn the meeting until Friday at noon")
    }

    func testRaggedLineWithoutSentenceEndDoesNotBreak() {
        // A typewritten page is ragged: a line a third short, mid-sentence, is not a paragraph end.
        let lines = [line("The committee met on Tuesday and", row: 0),
                     line("agreed the terms of the", width: 270, row: 1),
                     line("Treaty after a long debate", row: 2),
                     line("on the floor.", row: 3)]
        let raw = lines.map(\.text).joined(separator: "\n")
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "The committee met on Tuesday and agreed the terms of the Treaty after a long debate on the floor.")
    }

    func testWiderGapStartsParagraph() {
        let lines = [line("one line of text", row: 0), line("another line of text", row: 1),
                     line("a third line of text", row: 2),
                     line("after a gap of a line", row: 3.8), line("and its last line", row: 4.8)]
        let raw = lines.map(\.text).joined(separator: "\n")
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "one line of text another line of text a third line of text\n\nafter a gap of a line and its last line")
    }

    func testIndentedBlockIsNotSplitLineByLine() {
        let lines = [line("He wrote as follows", row: 0), line("to the Secretary", row: 1),
                     line("we cannot accept the", x: 40, width: 300, row: 2),
                     line("terms as they stand", x: 40, width: 300, row: 3),
                     line("without the Senate", x: 40, width: 300, row: 4)]
        XCTAssertEqual(CopyTextCleaner.layoutBreaks(lines), [])
    }

    func testHyphenatedContinuationNeverBreaks() {
        let lines = [line("The committee approved the", row: 0),
                     line("wel-", width: 60, row: 1),
                     line("fare reform bill and", row: 2), line("adjourned", row: 3)]
        XCTAssertEqual(CopyTextCleaner.layoutBreaks(lines), [])
    }

    func testExistingBlankLinesKeptAndNotDoubled() {
        let lines = [line("First paragraph line one", row: 0), line("ends here.", width: 100, row: 1),
                     line("Second paragraph runs on", row: 3), line("to the end", row: 4)]
        let raw = "First paragraph line one\nends here.\n\nSecond paragraph runs on\nto the end"
        XCTAssertEqual(CopyTextCleaner.markLayoutBreaks(raw, lines: lines), raw)
    }

    func testMismatchedLinesFallBackToText() {
        let lines = [line("something else", row: 0), line("entirely", x: 40, row: 1), line("here", row: 2)]
        let raw = "The quick brown\nfox jumped over\nthe lazy dog."
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines), "The quick brown fox jumped over the lazy dog.")
    }

    func testLayoutOptionOff() {
        var opts = CopyTextOptions(); opts.paragraphFromLayout = false
        let lines = [line("The committee met on Tuesday and", row: 0), line("agreed the terms", row: 1),
                     line("The second paragraph", x: 30, row: 2), line("runs on.", row: 3)]
        let raw = lines.map(\.text).joined(separator: "\n")
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines, options: opts),
                       "The committee met on Tuesday and agreed the terms The second paragraph runs on.")
    }

    func testNewColumnIsItsOwnBlock() {
        // The second column starts higher on the page: no break is read from the column jump.
        let lines = [line("left column one", width: 180, row: 0), line("left column two", width: 180, row: 1),
                     line("left column three", width: 180, row: 2),
                     CopyTextLine(text: "right column one", box: CGRect(x: 260, y: 700, width: 180, height: 12), page: 0),
                     CopyTextLine(text: "right column two", box: CGRect(x: 260, y: 686, width: 180, height: 12), page: 0),
                     CopyTextLine(text: "right column three", box: CGRect(x: 260, y: 672, width: 180, height: 12), page: 0)]
        XCTAssertEqual(CopyTextCleaner.layoutBreaks(lines), [])
    }

    /// End to end through PDFKit: lines drawn at set positions (as the OCR text layer places them, no blank
    /// line between paragraphs), selected whole, read back by the pane's line reader, and cleaned.
    @MainActor
    func testRealPDFSelectionFindsIndentedParagraph() throws {
        let rows: [(String, CGFloat)] = [("The committee met on Tuesday and agreed", 0),
                                         ("the terms of the settlement in full.", 0),
                                         ("The second paragraph opens indented and", 36),
                                         ("continues to the end of the page here.", 0)]
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        for (i, (text, indent)) in rows.enumerated() {
            let ctLine = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: NSFont(name: "Courier", size: 12)!]))
            ctx.textPosition = CGPoint(x: 72 + indent, y: 700 - CGFloat(i) * 16)
            CTLineDraw(ctLine, ctx)
        }
        ctx.endPDFPage()
        ctx.closePDF()
        let doc = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(doc.page(at: 0))
        let sel = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        let raw = try XCTUnwrap(sel.string)
        XCTAssertFalse(raw.contains("\n\n"), "the drawn text carries no blank line of its own")
        let lines = PDFPaneController.layoutLines(sel)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "The committee met on Tuesday and agreed the terms of the settlement in full.\n\n"
                       + "The second paragraph opens indented and continues to the end of the page here.")
    }

    /// The Processor's text page: OCR lines typeset one per line, the long one wrapped by the layout, with
    /// no blank line at the paragraph break. The short line that ends a sentence is found; the wrap is not
    /// mistaken for one.
    @MainActor
    func testTypesetTextPageFindsShortLineBreak() throws {
        let text = "The committee met on Tuesday and agreed the terms of the settlement, which it then sent on to the Secretary for his signature without\n"
            + "comment from the house.\n"
            + "Mr. Smith then moved that the meeting\n"
            + "adjourn until Friday at noon and"
        let doc = TestPDFBuilder.textPDF(pages: [text])
        let page = try XCTUnwrap(doc.page(at: 0))
        let sel = try XCTUnwrap(page.selection(for: page.bounds(for: .mediaBox)))
        let raw = try XCTUnwrap(sel.string)
        let lines = PDFPaneController.layoutLines(sel)
        let cleaned = CopyTextCleaner.clean(raw, lines: lines)
        XCTAssertEqual(cleaned,
                       "The committee met on Tuesday and agreed the terms of the settlement, which it then sent on to the Secretary for his signature without comment from the house.\n\n"
                       + "Mr. Smith then moved that the meeting adjourn until Friday at noon and",
                       "raw: \(raw.debugDescription) lines: \(lines.map { ($0.text, $0.box) })")
    }
}
