import XCTest
@testable import ArchiveCore

final class PDFHeaderParserTests: XCTestCase {

    // MARK: - parseClassification

    /// An app-format page-2 text whose header carries `line` after the provider line.
    private func page(_ line: String, body: String = "The quick brown fox.") -> String {
        "Extracted text.\nscan_001.jpg\nAnthropic \u{00B7} Claude \u{00B7} 2026-07-10\n\(line)\n\n\(body)"
    }

    func testParseClassificationKnownValues() {
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page("Classification: Document Start")), "Document Start")
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page("Classification: Continuation")), "Continuation")
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page("Classification: Box")), "Box")
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page("Classification: Folder")), "Folder")
    }

    func testParseClassificationUnknownValue() {
        // The parser returns the raw string; enum mapping is the caller's job.
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page("Classification: NewType")), "NewType")
    }

    func testParseClassificationEmpty() {
        XCTAssertNil(PDFHeaderParser.parseClassification(from: page("Classification: ")))
        XCTAssertNil(PDFHeaderParser.parseClassification(from: page("Classification:")))
    }

    func testParseClassificationAbsent() {
        XCTAssertNil(PDFHeaderParser.parseClassification(from: page("Document date: 1957")))
        XCTAssertNil(PDFHeaderParser.parseClassification(from: ""))
    }

    func testParseClassificationWithLeadingWhitespace() {
        // Tabs/spaces before "Classification:" should still be found.
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page("  Classification: Box")), "Box")
    }

    func testParseClassificationMultiline() {
        let text = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 2026-07-10
        Classification: Document Start

        The quick brown fox.
        """
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: text), "Document Start")
    }

    // MARK: - stripHeader

    func testStripHeaderAppFormat() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 2026-07-10
        Classification: Document Start

        The quick brown fox jumps over the lazy dog.
        """
        let stripped = PDFHeaderParser.stripHeader(from: pageText)
        XCTAssertEqual(stripped, "The quick brown fox jumps over the lazy dog.")
    }

    func testStripHeaderNoClassification() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 2026-07-10

        Body text without classification.
        """
        let stripped = PDFHeaderParser.stripHeader(from: pageText)
        XCTAssertEqual(stripped, "Body text without classification.")
    }

    func testStripHeaderPreservesMultilineBody() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 2026-07-10
        Classification: Box

        Line one.
        Line two.
        Line three.
        """
        let stripped = PDFHeaderParser.stripHeader(from: pageText)
        XCTAssertEqual(stripped, "Line one.\nLine two.\nLine three.")
    }

    func testStripHeaderUnknownClassification() {
        // Unknown classification value — the header is still stripped.
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 2026-07-10
        Classification: FutureType

        Body after unknown classification.
        """
        let stripped = PDFHeaderParser.stripHeader(from: pageText)
        XCTAssertEqual(stripped, "Body after unknown classification.")
    }

    func testStraighteningIsAnOptionalOrderedHeaderField() throws {
        let previous = "Title: A memo"
        for (angle, direction) in [(3.25, "counterclockwise"), (-3.25, "clockwise")] {
            let line = try XCTUnwrap(PDFHeaderParser.straighteningLine(degrees: angle))
            XCTAssertEqual(line, "Image straightened: 3.25 degrees \(direction)")
            let parsed = PDFHeaderParser.parse(page(previous + "\n" + line))
            XCTAssertEqual(parsed.header?.straightenedDegrees, angle)
            XCTAssertEqual(parsed.header?.itemFields.title, "A memo")
            XCTAssertEqual(parsed.body, "The quick brown fox.")

            let lookalike = PDFHeaderParser.parse(page(previous, body: line))
            XCTAssertNil(lookalike.header?.straightenedDegrees)
            XCTAssertEqual(lookalike.body, line)
        }
        let malformed = "Image straightened: 0.25 degrees clockwise"
        let parsed = PDFHeaderParser.parse(page(previous + "\n" + malformed))
        XCTAssertNil(parsed.header?.straightenedDegrees)
        XCTAssertTrue(parsed.body.hasPrefix(malformed))
        XCTAssertNil(PDFHeaderParser.straighteningLine(degrees: .infinity))
    }

    func testStraighteningPrefixDoesNotShadowAFilenameContinuation() {
        let parsed = PDFHeaderParser.parse("""
        Extracted text.
        Long source name split at
        Image straightened: scan.jpg
        Apple Vision · macOS Vision · 23 November 2026

        The memo.
        """)
        XCTAssertEqual(parsed.header?.originalFilename, "Long source name split at\nImage straightened: scan.jpg")
        XCTAssertNil(parsed.header?.straightenedDegrees)
        XCTAssertEqual(parsed.body, "The memo.")
    }

    // MARK: - fullBody vs strippedBody contract

    func testFullBodyContainsHeaderAndStrippedBodyDoesNot() {
        // Simulates an app-format page-2 string.
        let header = "Extracted text.\nscan_001.jpg\nAnthropic \u{00B7} Claude \u{00B7} 2026-07-10\nClassification: Document Start"
        let body = "The quick brown fox."
        let pageText = header + "\n\n" + body

        let fullBody = pageText  // All text on the page
        let stripped = PDFHeaderParser.stripHeader(from: pageText)

        // fullBody contains the header text.
        XCTAssertTrue(fullBody.contains("Extracted text."))
        XCTAssertTrue(fullBody.contains("Classification: Document Start"))
        XCTAssertTrue(fullBody.contains("The quick brown fox."))

        // strippedBody does NOT contain header text.
        XCTAssertFalse(stripped.contains("Extracted text."))
        XCTAssertFalse(stripped.contains("Classification:"))
        XCTAssertTrue(stripped.contains("The quick brown fox."))
    }

    // MARK: - W37.dual-date source-date header lines

    func testStripHeaderWithBothSourceDateLines() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 6 October 2026
        Classification: Document Start
        Document date: Nov 3, 1957
        Sent with: Mar 12, 1958

        Report on the harbour works.
        """
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: pageText), "Report on the harbour works.")
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: pageText), "Document Start")
    }

    func testStripHeaderWithOnlyDocumentDate() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 6 October 2026
        Classification: Document Start
        Document date: 1950s

        Body.
        """
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: pageText), "Body.")
    }

    func testStripHeaderWithSentWithOnlyAndNoClassification() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 6 October 2026
        Sent with: 1958

        Body.
        """
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: pageText), "Body.")
        XCTAssertNil(PDFHeaderParser.parseClassification(from: pageText))
    }

    func testSourceDateLookalikesInBodyAreKept() {
        // After the blank separator these are body text, not header — they must survive verbatim.
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 6 October 2026
        Classification: Document Start

        Document date: 3 November 1957
        Sent with: the covering letter of March 12
        Remainder.
        """
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: pageText),
                       "Document date: 3 November 1957\nSent with: the covering letter of March 12\nRemainder.")
    }

    func testSourceDatePrefixIsExactAndCaseSensitive() {
        // A lower-cased lookalike after the meta line is not a recognised header line; it starts the body
        // (the pre-W37 behaviour for any unknown post-meta line), so nothing is silently swallowed.
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 6 October 2026
        document date: 1957

        Body.
        """
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: pageText), "document date: 1957\n\nBody.")
    }

    // MARK: - W46.date-route-header: the date-evidence header line

    func testDateEvidenceLineIsHeaderAfterTheSourceDates() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 6 October 2026
        Classification: Document Start
        Kind: typewritten
        Document date: 1957
        Date evidence: estimate; from scan_000.pdf; "May 3, 1957"; 90% interval 1956-1958

        Report on the harbour works.
        """
        let parsed = PDFHeaderParser.parse(pageText)
        XCTAssertEqual(parsed.body, "Report on the harbour works.")
        XCTAssertEqual(parsed.header?.classification, "Document Start")
        XCTAssertEqual(parsed.header?.kind, .typewritten)
        XCTAssertEqual(parsed.header?.documentDate, "1957")
        XCTAssertEqual(parsed.header?.dateEvidence,
                       "estimate; from scan_000.pdf; \"May 3, 1957\"; 90% interval 1956-1958")
    }

    func testDateEvidenceAloneWithoutSeparatorIsHeader() {
        // PDFKit drops the blank separator from a real page: the line is still consumed, never body.
        let pageText = "Extracted text.\nscan_001.jpg\nAnthropic \u{00B7} Claude \u{00B7} 6 October 2026\n"
            + "Kind: printed\nDate evidence: inherited; from cover.pdf\nDear Sir,"
        let parsed = PDFHeaderParser.parse(pageText)
        XCTAssertEqual(parsed.body, "Dear Sir,")
        XCTAssertEqual(parsed.header?.dateEvidence, "inherited; from cover.pdf")
        XCTAssertNil(parsed.header?.classification)
    }

    // MARK: W47.item-fields-build — the item-field lines

    func testItemFieldLinesAfterDateEvidence() {
        let pageText = """
        Extracted text.
        scan_001.jpg
        Anthropic \u{00B7} Claude \u{00B7} 6 October 2026
        Kind: printed
        Date evidence: image; page 1
        Document kind: newspaper article
        Byline: Mary Jones; John Smith
        Publication: The Sun
        Publication date: 1967-03-02

        Senate acts on the tax bill.
        """
        let parsed = PDFHeaderParser.parse(pageText)
        XCTAssertEqual(parsed.body, "Senate acts on the tax bill.")
        XCTAssertEqual(parsed.header?.dateEvidence, "image; page 1")
        XCTAssertEqual(parsed.header?.itemFields, PDFItemFields(documentKind: "newspaper article",
                                                                byline: "Mary Jones; John Smith",
                                                                publication: "The Sun", publicationDate: "1967-03-02"))
        XCTAssertNil(parsed.header?.documentDate, "the printed issue date is never the document's own date")
        let letter = "Extracted text.\nscan_002.jpg\nAnthropic \u{00B7} Claude \u{00B7} 6 October 2026\n"
            + "Kind: typewritten\nDocument kind: letter\nTitle: Re: the budget\nRecipient place: Boston, MA\nDear Sir,"
        let l = PDFHeaderParser.parse(letter)
        XCTAssertEqual(l.body, "Dear Sir,", "consumed without a separator, as the other header lines are")
        XCTAssertEqual(l.header?.itemFields.title, "Re: the budget")
        XCTAssertEqual(l.header?.itemFields.recipientPlace, "Boston, MA")
        XCTAssertEqual(PDFItemFields(documentKind: "letter", recipientPlace: "Boston, MA").headerLines,
                       ["Document kind: letter", "Recipient place: Boston, MA"])
    }

    func testItemFieldLookalikesInBodyOrOutOfOrderAreKept() {
        let inBody = page("Classification: Continuation", body: "Title: The Annual Report")
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: inBody), "Title: The Annual Report")
        XCTAssertEqual(PDFHeaderParser.parse(inBody).header?.itemFields, PDFItemFields())
        // A field before one it follows starts the body; so does a date line after the item fields.
        let late = "Extracted text.\nscan_001.jpg\nAnthropic \u{00B7} Claude \u{00B7} 6 October 2026\n"
            + "Publication: The Sun\nByline: Mary Jones\nDocument date: 1957\n\nBody."
        let parsed = PDFHeaderParser.parse(late)
        XCTAssertEqual(parsed.header?.itemFields, PDFItemFields(publication: "The Sun"))
        XCTAssertEqual(parsed.body, "Byline: Mary Jones\nDocument date: 1957\n\nBody.")
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: page("title: lower case")), "title: lower case\n\nThe quick brown fox.")
    }

    func testItemFieldLineValue() {
        XCTAssertEqual(PDFItemFields.lineValue(" The \u{00B7} Sun\n\tDaily "), "The , Sun Daily")
        XCTAssertNil(PDFItemFields.lineValue(" \n "))
        XCTAssertNil(PDFItemFields.lineValue(nil))
        let long = PDFItemFields.lineValue(String(repeating: "a", count: 300))
        XCTAssertEqual(long?.count, PDFItemFields.maxValue)
        XCTAssertEqual(long?.last, "…")
    }

    func testDateEvidenceLookalikeInBodyOrOutOfOrderIsKept() {
        // After the separator it is body; a source-date line after it is out of order and starts the body.
        let inBody = page("Classification: Continuation", body: "Date evidence: none here.")
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: inBody), "Date evidence: none here.")
        XCTAssertNil(PDFHeaderParser.parse(inBody).header?.dateEvidence)
        let late = "Extracted text.\nscan_001.jpg\nAnthropic \u{00B7} Claude \u{00B7} 6 October 2026\n"
            + "Date evidence: image; page 1\nDocument date: 1957\n\nBody."
        let parsed = PDFHeaderParser.parse(late)
        XCTAssertEqual(parsed.header?.dateEvidence, "image; page 1")
        XCTAssertNil(parsed.header?.documentDate)
        XCTAssertEqual(parsed.body, "Document date: 1957\n\nBody.")
        // The exact, case-sensitive prefix only.
        XCTAssertEqual(PDFHeaderParser.stripHeader(from: page("date evidence: x")), "date evidence: x\n\nThe quick brown fox.")
    }

    // MARK: - Classification outside the header (W40.fix-core-classification-from-body)

    func testClassificationLineInBodyTextIsNotTheClassification() {
        // An OCR'd security marking in the body is document text, not the page's classification.
        let body = "Memo\nClassification: Top Secret"
        XCTAssertNil(PDFHeaderParser.parseClassification(from: page("Document date: 1957", body: body)))
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: page("Classification: Continuation", body: body)),
                       "Continuation")
    }

    func testClassificationNeedsTheAppFormatHeader() {
        // Text that is not an app-format page 2 (a page-1 text layer, a bare line) has no classification.
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "Classification: Box"))
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "Some preamble\nClassification: Folder\nSome other text"))
    }

    func testFileNameStartingWithClassificationIsNotTheClassification() {
        let meta = "Anthropic \u{00B7} Claude \u{00B7} 2026-07-10"
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "Extracted text.\nClassification: notes.jpg\n\(meta)\n\nBody."))
        XCTAssertEqual(PDFHeaderParser.parseClassification(
            from: "Extracted text.\nClassification: notes.jpg\n\(meta)\nClassification: Box\n\nBody."), "Box")
        // No file name line: the classification directly follows the meta line.
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: "Extracted text.\n\(meta)\nClassification: Box\n\nBody."), "Box")
        // A file name with the separator in it does not hide the classification.
        XCTAssertEqual(PDFHeaderParser.parseClassification(
            from: "Extracted text.\nBox 4 \u{00B7} Folder 2.jpg\n\(meta)\nClassification: Folder\n\nBody."), "Folder")
        XCTAssertEqual(PDFHeaderParser.parseClassification(
            from: "Extracted text.\nA \u{00B7} B \u{00B7} C.jpg\n\(meta)\nClassification: Folder\n\nBody."), "Folder")
    }

    func testClassificationWithoutTheBlankSeparator() {
        // PDFKit drops the blank line under the header from a real page's text; the header still ends at
        // the first line that is not a header line.
        let meta = "Gemini \u{00B7} Gemini 3.1 Flash Lite Preview \u{00B7} 3 April 2026"
        XCTAssertEqual(PDFHeaderParser.parseClassification(
            from: "Extracted text.\n00206 \u{2014} Young.jpg\n\(meta)\nClassification: Document Start\nBOOK NOTE No.20"),
            "Document Start")
        XCTAssertNil(PDFHeaderParser.parseClassification(
            from: "Extracted text.\nscan.jpg\n\(meta)\nMemo\nClassification: Top Secret"))
        XCTAssertNil(PDFHeaderParser.parseClassification(
            from: "Extracted text.\nscan.jpg\n\(meta)\nDocument date: 1957\nClassification: Top Secret"))
        // A body line with middle dots in it is not a second meta line.
        XCTAssertNil(PDFHeaderParser.parseClassification(
            from: "Extracted text.\n\(meta)\nA \u{00B7} B \u{00B7} C\nClassification: Top Secret"))
        // A meta line wrapped before its date still leads to the classification.
        XCTAssertEqual(PDFHeaderParser.parseClassification(
            from: "Extracted text.\nscan.jpg\nOpenRouter \u{00B7} Qwen3-VL 235B (deepinfra fp8) \u{00B7}\n3 April 2026\nClassification: Box\nBody"),
            "Box")
        // So does a file name that has the separator and ends in a year.
        XCTAssertEqual(PDFHeaderParser.parseClassification(
            from: "Extracted text.\nBox 4 \u{00B7} 1957\n\(meta)\nClassification: Box\nBody"), "Box")
    }

    func testProvenanceDateParsingPureASCIIAndGregorianValidation() {
        for valid in ["7 November 2026", "3 April 2026", "29 February 2024", "29 February 2000", "31 December 1999", "10 October 1582"] {
            XCTAssertTrue(PDFHeaderParser.isValidProvenanceDate(valid), "should accept \(valid)")
            let parsed = PDFHeaderParser.parse("Extracted text.\nGemini \u{00B7} Flash \u{00B7} \(valid)\n\nBody")
            XCTAssertEqual(parsed.header?.provenance?.processingDate, valid)
        }
        for invalid in ["07 November 2026", "7 november 2026", "7 Nov 2026", "29 February 2026",
                        "29 February 1900", "31 April 2026", "0 January 2026", "32 January 2026",
                        "7 November 0000", "7 November 26", "7  November 2026"] {
            XCTAssertFalse(PDFHeaderParser.isValidProvenanceDate(invalid), "should reject \(invalid)")
            let parsed = PDFHeaderParser.parse("Extracted text.\nGemini \u{00B7} Flash \u{00B7} \(invalid)\n\nBody")
            XCTAssertNil(parsed.header?.provenance, "should reject provenance with date \(invalid)")
        }
        XCTAssertFalse(PDFHeaderParser.isValidProvenanceDate(" 7 November 2026"))
        XCTAssertFalse(PDFHeaderParser.isValidProvenanceDate("7 November 2026 "))
    }
}
