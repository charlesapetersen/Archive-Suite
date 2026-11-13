import XCTest
import PDFKit
@testable import ArchiveReader

/// W40.reader-zoom-levels: Zoom In / Out step through a finer ladder than the old ×1.25.
@MainActor
final class ZoomLevelsTests: XCTestCase {
    func testTheLadderIsSortedAndFinerThanTheOldStep() {
        let levels = ZoomLevels.levels
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(Set(levels).count, levels.count)
        XCTAssertTrue(levels.contains(1))
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertLessThanOrEqual(b / a, ZoomLevels.outerStep + 0.0001, "no step is coarser than the old one, \(a) → \(b)")
        }
        // Between 50% and 200% there used to be 6 stops (×1.25); now every step there is a level.
        XCTAssertGreaterThanOrEqual(levels.filter { $0 >= 0.5 && $0 <= 2 }.count, 12)
    }

    func testStepsFromActualSize() {
        XCTAssertEqual(ZoomLevels.zoomIn(from: 1), 1.1)
        XCTAssertEqual(ZoomLevels.zoomIn(from: 1.1), 1.25)
        XCTAssertEqual(ZoomLevels.zoomOut(from: 1), 0.9)
        XCTAssertEqual(ZoomLevels.zoomOut(from: 0.9), 0.8)
    }

    func testAZoomBetweenLevelsMovesToTheNearestOneEachWay() {
        XCTAssertEqual(ZoomLevels.zoomIn(from: 0.43), 0.5)
        XCTAssertEqual(ZoomLevels.zoomOut(from: 0.43), 0.4)
        // Within 1% of a level counts as on it, so a step is never a sliver.
        XCTAssertEqual(ZoomLevels.zoomIn(from: 0.995), 1.1)
        XCTAssertEqual(ZoomLevels.zoomOut(from: 1.005), 0.9)
    }

    func testInAndOutReturnToTheSameLevel() {
        for level in ZoomLevels.levels.dropFirst().dropLast() {
            XCTAssertEqual(ZoomLevels.zoomOut(from: ZoomLevels.zoomIn(from: level)), level)
        }
    }

    func testBeyondTheLadderStepsByTheOldFactor() {
        XCTAssertEqual(ZoomLevels.zoomIn(from: 20), 25, accuracy: 0.0001)
        XCTAssertEqual(ZoomLevels.zoomOut(from: 0.1), 0.08, accuracy: 0.0001)
        XCTAssertEqual(ZoomLevels.zoomIn(from: 0), 1)
    }

    /// The image pane steps in its zoom unit: a pixel-measured JPEG against its PDF page (scale unit 0.5 here)
    /// steps through the same on-screen sizes as the PDF.
    func testThePaneStepsThroughTheLadder() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 520), for: .mediaBox)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let controller = PDFPaneController(key: "zoom-levels", persists: false)
        controller.pdfView = view
        controller.show(page, reference: page, in: view)
        view.autoScales = false
        view.scaleFactor = 1
        controller.zoomIn()
        XCTAssertEqual(view.scaleFactor, 1.1, accuracy: 0.0001)
        controller.zoomOut(); controller.zoomOut()
        XCTAssertEqual(view.scaleFactor, 0.9, accuracy: 0.0001)
    }
}
