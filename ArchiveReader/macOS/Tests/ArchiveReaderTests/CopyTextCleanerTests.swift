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
        XCTAssertEqual(CopyTextCleaner.structure(lines, columns: true).count, 1)
    }

    func testHyphenatedContinuationNeverBreaks() {
        let lines = [line("The committee approved the", row: 0),
                     line("wel-", width: 60, row: 1),
                     line("fare reform bill and", row: 2), line("adjourned", row: 3)]
        XCTAssertEqual(CopyTextCleaner.clean(lines.map(\.text).joined(separator: "\n"), lines: lines),
                       "The committee approved the welfare reform bill and adjourned")
    }

    func testExistingBlankLinesKeptAndNotDoubled() {
        let lines = [line("First paragraph line one", row: 0), line("ends here.", width: 100, row: 1),
                     line("Second paragraph runs on", row: 3), line("to the end", row: 4)]
        let raw = "First paragraph line one\nends here.\n\nSecond paragraph runs on\nto the end"
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "First paragraph line one ends here.\n\nSecond paragraph runs on to the end")
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
        XCTAssertEqual(CopyTextCleaner.structure(lines, columns: true).count, 1)
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

    // MARK: - Paragraphs, lists and headings (W40.reader-prose-structure)
    //
    // The two page fixtures reproduce the geometry measured on two OCR'd corpus pages (a numbered list with
    // lettered sub-items, and a typed memo), with invented text: the repo is public.

    private func at(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, h: CGFloat = 8.5) -> CopyTextLine {
        CopyTextLine(text: text, box: CGRect(x: x, y: y, width: w, height: h), page: 0)
    }

    /// The text PDFKit reports for `lines`: each line's text, with an embedded newline where the OCR's line
    /// ended inside a word that the line geometry split.
    private func rawText(_ lines: [CopyTextLine]) -> String {
        var out = ""
        for l in lines {
            let parts = l.text.components(separatedBy: "\n")
            out += parts.count > 1 ? parts.joined(separator: "\n") : (out.isEmpty || out.hasSuffix(" ") ? "" : "\n") + l.text
        }
        return out
    }

    /// A numbered list after a lead-in, items indented on their first line with continuations back at the
    /// margin, lettered sub-items hanging; one marker its own selection on its item's baseline, and one word
    /// whole at a line end that the selection splits ("consider" | "ing⏎the…").
    func testNumberedListWithLetteredSubItems() {
        let lines = [at("The program serves a number of ends. The most", 36, 600, 390),
                     at("important of these are as follows:", 36, 581.7, 200),
                     at("1. To keep the work of the group at the highest", 98, 563.4, 338),
                     at("level we must find and keep people who are consider", 35, 545.1, 412),
                     at("ing\nthe needs of the client first, and", 35, 526.8, 396),
                     at("act on it.", 35, 508.5, 67),
                     at("2. To meet these ends we must:", 96, 490.2, 306),
                     at("(a) Offer work that is varied and", 119, 471.9, 268),
                     at("useful", 141, 453.6, 49),
                     at("(b) Keep a fair and open", 118, 435.3, 260),
                     at("way of working", 141, 417.0, 180),
                     at("(c) ", 117.5, 398.7, 12.4),
                     at("Offer room to grow", 140.6, 398.7, 228),
                     at("3. To share the rewards fairly among all", 93, 380.4, 340),
                     at("members of the group.", 30, 362.1, 150)]
        let raw = rawText(lines)
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "The program serves a number of ends. The most important of these are as follows:\n\n"
                       + "1. To keep the work of the group at the highest level we must find and keep people who are "
                       + "considering the needs of the client first, and act on it.\n"
                       + "2. To meet these ends we must:\n"
                       + "    (a) Offer work that is varied and useful\n"
                       + "    (b) Keep a fair and open way of working\n"
                       + "    (c) Offer room to grow\n"
                       + "3. To share the rewards fairly among all members of the group.")
    }

    /// A typed memo: a header of short lines, a centred heading in capitals, paragraphs marked only by a
    /// first-line indent, a word split by the selection, and an image's place in the text.
    func testMemoHeadingAndIndentedParagraphs() {
        let lines = [at("TO:", 107, 686, 19, h: 10), at("FROM:", 86, 658, 39, h: 10),
                     at("The Committee", 157, 687, 121, h: 10), at("Jane Writer", 156, 658, 82, h: 10),
                     at("27 December 1966", 457, 657, 108, h: 10),
                     at("QUALIFICATIONS OF THE UCLA M/D", 192, 615, 250, h: 10),
                     at("On the assumption that we will not decide this matter", 121, 580, 422, h: 10),
                     at("for a while, here is the draft of what we hope for, a list of the qualifica", 86, 566, 469, h: 10),
                     at("tions\nwe want in the M/D.", 85, 552, 100, h: 10),
                     at("This version adds the points made at the", 120.5, 523, 402, h: 10),
                     at("meeting and a few more of my own, set out in", 85.5, 509, 441, h: 10),
                     at("full as before.", 84, 495, 192, h: 10),
                     at("\u{FFFC}", 61, 118, 381, h: 202)]
        let raw = rawText(lines)
        XCTAssertEqual(CopyTextCleaner.clean(raw, lines: lines),
                       "To:\nFrom:\nThe Committee\nJane Writer\n\n27 December 1966\n\n"
                       + "Qualifications of the UCLA M/D\n\n"
                       + "On the assumption that we will not decide this matter for a while, here is the draft of "
                       + "what we hope for, a list of the qualifications we want in the M/D.\n\n"
                       + "This version adds the points made at the meeting and a few more of my own, set out in "
                       + "full as before.")
    }

    func testTextPaneListFromLineBreaksAndIndent() {
        let raw = "INTRODUCTION\nThe steps we agreed on at the meeting were these:\n1. Write to the board\n"
            + "2. Ask for the papers\n   a) the minutes\n   b) the accounts\n3. Report back by Friday."
        XCTAssertEqual(CopyTextCleaner.clean(raw),
                       "Introduction\n\nThe steps we agreed on at the meeting were these:\n\n1. Write to the board\n"
                       + "2. Ask for the papers\n    a) the minutes\n    b) the accounts\n3. Report back by Friday.")
    }

    func testBulletsAndAWrappedNumberThatIsNotAnItem() {
        XCTAssertEqual(CopyTextCleaner.clean("Bring:\n• the letters\n• the ledger"),
                       "Bring:\n\n• the letters\n• the ledger")
        // "12." at a line start mid-sentence is the end of a page reference, not an item.
        let raw = "The figures he cited in the report are on page\n12. They show a rise over the year\nbefore it."
        XCTAssertEqual(CopyTextCleaner.clean(raw),
                       "The figures he cited in the report are on page 12. They show a rise over the year before it.")
    }

    func testCapitalsTitleCasedOnlyWhenWhollyCapitals() {
        XCTAssertEqual(CopyTextCleaner.clean("A LETTER FROM THE UCLA LIBRARY TO MR. J. W. SMITH"),
                       "A Letter from the UCLA Library to Mr. J. W. Smith")
        // Prose of several lines in capitals (a cable) is quoted as written, and its short last line is not
        // taken for a heading.
        let cable = "REFERENCE YOUR MESSAGE OF TUESDAY THE MINISTER WILL\nSEE THE AMBASSADOR AT NOON AND WILL CALL.\n"
            + "THE COMMITTEE WILL MEET AFTER\nTHAT."
        XCTAssertEqual(CopyTextCleaner.clean(cable),
                       "REFERENCE YOUR MESSAGE OF TUESDAY THE MINISTER WILL SEE THE AMBASSADOR AT NOON AND WILL CALL. "
                       + "THE COMMITTEE WILL MEET AFTER THAT.")
        XCTAssertEqual(CopyTextCleaner.clean("He wrote to the UCLA\nLIBRARY at once."), "He wrote to the UCLA LIBRARY at once.")
        var opts = CopyTextOptions(); opts.titleCaseCapitals = false
        XCTAssertEqual(CopyTextCleaner.clean("BOX 12\nFOLDER 3", options: opts), "BOX 12 FOLDER 3")
        XCTAssertEqual(CopyTextCleaner.clean("(A) THE MINUTES\n(B) THE ACCOUNTS"), "(A) The Minutes\n(B) The Accounts")
    }

    func testDashInitialAndCompoundAtLineStartsStayProse() {
        let dash = "He said the board would act at once, as he put it\n- and this is the point - we must agree\nby Friday."
        XCTAssertEqual(CopyTextCleaner.clean(dash),
                       "He said the board would act at once, as he put it - and this is the point - we must agree by Friday.")
        let initial = "After the vote the chair then called on Mr.\nJ. Edgar Smith, who said the whole matter\nwas closed."
        XCTAssertEqual(CopyTextCleaner.clean(initial),
                       "After the vote the chair then called on Mr. J. Edgar Smith, who said the whole matter was closed.")
        XCTAssertEqual(CopyTextCleaner.clean("the Anglo-\nAmerican talks and the wel-\nfare state"),
                       "the Anglo-American talks and the welfare state")
    }

    /// A line selection holding two whole lines ("in full.⏎Heading…") must not fuse the words: the rows no
    /// longer match the text space for space, so the text alone is used.
    func testSelectionWithWholeLineBeforeNewlineIsNotFused() {
        let lines = [at("The minutes were read and approved in full.", 36, 600, 300),
                     at("Next\nthe report of the treasurer was heard", 36, 581.7, 390),
                     at("and agreed without a vote of the members.", 36, 563.4, 380)]
        let raw = "The minutes were read and approved in full.\nNext\nthe report of the treasurer was heard\n"
            + "and agreed without a vote of the members."
        let out = CopyTextCleaner.clean(raw, lines: lines)
        XCTAssertFalse(out.contains("full.Next"), out)
        XCTAssertTrue(out.contains("full. Next") || out.contains("full.\n"), out)
    }

    /// The structure pass may only regroup: a result whose letters differ from the selection's is refused.
    func testAssemblyRefusesChangedWords() {
        let units = [CopyTextCleaner.Unit(kind: .paragraph, lines: ["other words"])]
        XCTAssertNil(CopyTextCleaner.assemble(units, raw: "the words", options: CopyTextOptions()))
        XCTAssertEqual(CopyTextCleaner.assemble(units, raw: "OTHER\nwords", options: CopyTextOptions()), "other words")
    }
}
