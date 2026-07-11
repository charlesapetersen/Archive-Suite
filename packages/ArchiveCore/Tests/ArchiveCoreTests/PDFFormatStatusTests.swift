import XCTest
@testable import ArchiveCore

final class PDFFormatStatusTests: XCTestCase {

    func testReadableWithTextIsStandard() {
        XCTAssertEqual(PDFFormatStatus.classify(readable: true, hasText: true), .standard)
        XCTAssertFalse(PDFFormatStatus.standard.needsAttention)
        XCTAssertEqual(PDFFormatStatus.standard.label, "Standard")
    }

    func testUnreadableRegardlessOfText() {
        XCTAssertEqual(PDFFormatStatus.classify(readable: false, hasText: false), .unreadable)
        // Not-readable dominates even if a (spurious) hasText slips through.
        XCTAssertEqual(PDFFormatStatus.classify(readable: false, hasText: true), .unreadable)
        XCTAssertTrue(PDFFormatStatus.unreadable.needsAttention)
        XCTAssertEqual(PDFFormatStatus.unreadable.label, "Unreadable")
    }

    func testReadableNoTextIsNoTextLayer() {
        XCTAssertEqual(PDFFormatStatus.classify(readable: true, hasText: false), .noTextLayer)
        XCTAssertTrue(PDFFormatStatus.noTextLayer.needsAttention)
        XCTAssertEqual(PDFFormatStatus.noTextLayer.label, "No text layer")
    }

    func testClassifyFromExtractedContent() {
        // nil content → couldn't open → unreadable.
        XCTAssertEqual(PDFFormatStatus.classify(nil), .unreadable)
        // Non-empty fullBody → has selectable text → standard.
        let withText = ExtractedContent(fullBody: "Senator Chafee on the budget.",
                                        strippedBody: "Senator Chafee on the budget.",
                                        classification: "Document Start", pageCount: 2)
        XCTAssertEqual(PDFFormatStatus.classify(withText), .standard)
        // Empty fullBody but opened → no text layer (page count is NOT a defect signal).
        let noText = ExtractedContent(fullBody: "", strippedBody: "", classification: nil, pageCount: 5)
        XCTAssertEqual(PDFFormatStatus.classify(noText), .noTextLayer)
    }

    func testNeedsAttentionIsEverythingButStandard() {
        XCTAssertFalse(PDFFormatStatus.standard.needsAttention)
        XCTAssertTrue(PDFFormatStatus.unreadable.needsAttention)
        XCTAssertTrue(PDFFormatStatus.noTextLayer.needsAttention)
    }
}
