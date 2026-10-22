import XCTest
@testable import ArchiveReader

/// W40.fix-reader-preview-sheet-oversize — the preview sheet fits inside the window it hangs from.
@MainActor
final class PreviewSheetSizeTests: XCTestCase {
    func testSheetShrinksInsideTheMinimumWindow() {
        // The size the layout guard measured: a 900×612 window, whose content area is 900×560.
        let size = PreviewSheet.fittedSize(in: CGSize(width: 900, height: 560))
        XCTAssertLessThan(size.width, 900)
        XCTAssertLessThan(size.height, 560)
        XCTAssertEqual(size, CGSize(width: 860, height: 520))
    }

    func testSheetKeepsItsPreferredSizeInALargeWindow() {
        XCTAssertEqual(PreviewSheet.fittedSize(in: CGSize(width: 1600, height: 1000)), PreviewSheet.preferredSize)
    }

    func testUnmeasuredWindowUsesThePreferredSize() {
        XCTAssertEqual(PreviewSheet.fittedSize(in: .zero), PreviewSheet.preferredSize)
    }
}

/// W40.fix-reader-tag-editor-chips — the Edit Tags and Similar Tags sheets fit inside the minimum window too.
@MainActor
final class TagSheetSizeTests: XCTestCase {
    func testTagSheetsShrinkInsideTheMinimumWindow() {
        let window = CGSize(width: 900, height: 560)
        XCTAssertEqual(SheetSizing.fitted(TagEditorView.preferredSize, in: window), CGSize(width: 480, height: 520))
        XCTAssertEqual(SheetSizing.fitted(SimilarTagsSheet.preferredSize, in: window), CGSize(width: 520, height: 520))
    }

    func testTagSheetsKeepTheirPreferredSizeInALargeWindow() {
        let window = CGSize(width: 1600, height: 1000)
        XCTAssertEqual(SheetSizing.fitted(TagEditorView.preferredSize, in: window), TagEditorView.preferredSize)
        XCTAssertEqual(SheetSizing.fitted(SimilarTagsSheet.preferredSize, in: window), SimilarTagsSheet.preferredSize)
    }
}
