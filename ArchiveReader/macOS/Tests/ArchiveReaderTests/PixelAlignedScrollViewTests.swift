import XCTest
import AppKit
@testable import ArchiveReader

/// W40.fix-reader-sidebar-slide-1pt — the file list's scroll view rounds every frame SwiftUI gives it to whole
/// backing pixels, so the clip view never shifts its content by a fraction while the sidebar slides. No window here
/// (the unit host draws nothing), so the pixel comes from the main screen: a point at 1×, half a point at 2×.
@MainActor
final class PixelAlignedScrollViewTests: XCTestCase {

    private var container = NSView(frame: NSRect(x: 0, y: 0, width: 2000, height: 800))
    private var scale: CGFloat { container.convertToBacking(NSSize(width: 1, height: 1)).width }

    private func makeScrollView() -> PixelAlignedScrollView {
        let scrollView = PixelAlignedScrollView()
        container.addSubview(scrollView)
        return scrollView
    }

    /// Each edge lands on a whole pixel, within half a pixel of the edge asked for.
    private func assertAligned(_ frame: NSRect, asked: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        for (got, want) in [(frame.minX, asked.minX), (frame.maxX, asked.maxX), (frame.minY, asked.minY),
                            (frame.maxY, asked.maxY)] {
            XCTAssertEqual(got * scale, (got * scale).rounded(), "\(got) is not on a pixel", file: file, line: line)
            XCTAssertLessThanOrEqual(abs(got - want), 0.5 / scale, "\(got) is too far from \(want)",
                                     file: file, line: line)
        }
    }

    /// The frames measured in the VM during a slide.
    func testAFractionalFrameIsRoundedToWholePixels() {
        let scrollView = makeScrollView()
        for asked in [NSRect(x: 82.44, y: 28, width: 1717.56, height: 639),
                      NSRect(x: 113.37, y: 28.3, width: 1686.63, height: 638.6)] {
            scrollView.frame = asked
            assertAligned(scrollView.frame, asked: asked)
            let clipX = scrollView.contentView.bounds.origin.x
            XCTAssertEqual(clipX * scale, (clipX * scale).rounded(), "the clip view keeps a whole-pixel origin")
        }
    }

    /// An origin and a size set one after the other round from the edges asked for, not from the rounded frame:
    /// x 0.6 then width 99.8 asks for a right edge at 100.4.
    func testOriginAndSizeSetSeparatelyRoundFromTheRequestedEdges() {
        let scrollView = makeScrollView()
        scrollView.setFrameOrigin(NSPoint(x: 0.6, y: 0))
        scrollView.setFrameSize(NSSize(width: 99.8, height: 50))
        assertAligned(scrollView.frame, asked: NSRect(x: 0.6, y: 0, width: 99.8, height: 50))
    }

    /// A whole-point frame (every settled layout) is left exactly as asked.
    func testAWholePointFrameIsUnchanged() {
        let scrollView = makeScrollView()
        let frame = NSRect(x: 240, y: 28, width: 1560, height: 639)
        scrollView.frame = frame
        XCTAssertEqual(scrollView.frame, frame)
    }
}
