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

    func testNeedsAttentionIsEverythingButStandard() {
        XCTAssertFalse(PDFFormatStatus.standard.needsAttention)
        XCTAssertTrue(PDFFormatStatus.unreadable.needsAttention)
        XCTAssertTrue(PDFFormatStatus.noTextLayer.needsAttention)
    }
}
