import XCTest
@testable import ArchiveCore

final class PDFHeaderParserTests: XCTestCase {

    // MARK: - parseClassification

    func testParseClassificationKnownValues() {
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: "Classification: Document Start"), "Document Start")
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: "Classification: Continuation"), "Continuation")
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: "Classification: Box"), "Box")
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: "Classification: Folder"), "Folder")
    }

    func testParseClassificationUnknownValue() {
        // The parser returns the raw string; enum mapping is the caller's job.
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: "Classification: NewType"), "NewType")
    }

    func testParseClassificationEmpty() {
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "Classification: "))
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "Classification:"))
    }

    func testParseClassificationAbsent() {
        XCTAssertNil(PDFHeaderParser.parseClassification(from: "No classification here"))
        XCTAssertNil(PDFHeaderParser.parseClassification(from: ""))
    }

    func testParseClassificationWithLeadingWhitespace() {
        // Tabs/spaces before "Classification:" should still be found.
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: "  Classification: Box"), "Box")
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

    // MARK: - Classification in body text (not header)

    func testClassificationLineInBodyTextIsFound() {
        // A Classification: line appearing in body text on page 1 should still be found
        // by parseClassification (Reader's historical behavior — scan all pages).
        let text = "Some preamble\nClassification: Folder\nSome other text"
        XCTAssertEqual(PDFHeaderParser.parseClassification(from: text), "Folder")
    }
}
