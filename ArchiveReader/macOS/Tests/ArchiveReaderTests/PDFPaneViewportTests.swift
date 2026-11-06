// PDFPaneViewportTests.swift — the PDF / JPEG switch keeps the zoom and the visible region
// (W40.fix-reader-jpeg-keep-view). Drives `PDFPaneController` against real, windowless PDFViews, so the
// carried region is read back through PDFKit's own coordinate conversion rather than the controller's maths.

import XCTest
import PDFKit
import AppKit
@testable import ArchiveReader

@MainActor
final class PDFPaneViewportTests: XCTestCase {

    func testFractionMappingRoundTripsAtEveryRotation() throws {
        let page = PDFPage()
        page.setBounds(CGRect(x: 10, y: 20, width: 400, height: 520), for: .mediaBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            for f in [CGPoint(x: 0.2, y: 0.7), CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.5)] {
                let p = PDFPaneController.pagePoint(fromDisplayed: f, on: page, box: .mediaBox)
                let back = PDFPaneController.displayedFraction(of: p, on: page, box: .mediaBox)
                XCTAssertEqual(back.x, f.x, accuracy: 1e-9, "rotation \(rotation)")
                XCTAssertEqual(back.y, f.y, accuracy: 1e-9, "rotation \(rotation)")
            }
        }
        page.rotation = 90
        XCTAssertEqual(PDFPaneController.displayedSize(page, box: .mediaBox), CGSize(width: 520, height: 400))
    }

    /// Zoomed in on the lower-right of the PDF's image page, switch to a JPEG sized in pixels (five times the
    /// points), and back: the page keeps its on-screen size and the same place stays in the middle of the pane.
    func testSwitchKeepsOnScreenSizeAndRegion() throws {
        for rotation in [0, 90] {
            let pdfPage = PDFPage()
            pdfPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 520), for: .mediaBox)
            pdfPage.rotation = rotation
            let jpegPage = try makeImagePage(width: 2000, height: 2600)
            if rotation == 90 { jpegPage.rotation = 90 }

            let controller = PDFPaneController(key: "left", persists: false)
            let pdfView = makeView()
            controller.pdfView = pdfView
            controller.show(pdfPage, reference: pdfPage, in: pdfView)
            pdfView.autoScales = false
            pdfView.scaleFactor = 2
            controller.recordScale()
            settle()
            let shown = try XCTUnwrap(pdfView.document?.page(at: 0))
            pdfView.go(to: PDFDestination(page: shown, at: PDFPaneController.pagePoint(
                fromDisplayed: CGPoint(x: 0.55, y: 0.6), on: shown, box: .mediaBox)))
            settle()
            controller.captureViewport()
            let before = try XCTUnwrap(controller.pendingViewport, "a zoomed pane notes its region")
            XCTAssertGreaterThan(before.centre.x, 0.6, "the test should be looking off-centre (rotation \(rotation))")

            let jpegView = makeView()
            controller.pdfView = jpegView
            controller.show(jpegPage, reference: pdfPage, in: jpegView)
            settle()
            XCTAssertEqual(jpegView.scaleFactor * 2000, 2 * 400, accuracy: 1,
                           "the JPEG keeps the PDF page's size on screen (rotation \(rotation))")
            controller.captureViewport()
            let onJPEG = try XCTUnwrap(controller.pendingViewport)
            XCTAssertEqual(onJPEG.centre.x, before.centre.x, accuracy: 0.02, "rotation \(rotation)")
            XCTAssertEqual(onJPEG.centre.y, before.centre.y, accuracy: 0.02, "rotation \(rotation)")

            let backView = makeView()
            controller.pdfView = backView
            controller.show(pdfPage, reference: pdfPage, in: backView)
            settle()
            XCTAssertEqual(backView.scaleFactor, 2, accuracy: 0.001, "switching back restores the PDF's own zoom")
            controller.captureViewport()
            let back = try XCTUnwrap(controller.pendingViewport)
            XCTAssertEqual(back.centre.x, before.centre.x, accuracy: 0.02, "rotation \(rotation)")
            XCTAssertEqual(back.centre.y, before.centre.y, accuracy: 0.02, "rotation \(rotation)")
        }
    }

    /// Fit-to-pane carries as fit-to-pane: nothing is noted, and the other image opens fitted at its top.
    func testFitCarriesAsFit() throws {
        let pdfPage = PDFPage()
        pdfPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 520), for: .mediaBox)
        let controller = PDFPaneController(key: "left", persists: false)
        let view = makeView()
        controller.pdfView = view
        controller.show(pdfPage, reference: pdfPage, in: view)
        settle()
        controller.captureViewport()
        XCTAssertNil(controller.pendingViewport)
        let jpegView = makeView()
        controller.pdfView = jpegView
        controller.show(try makeImagePage(width: 2000, height: 2600), reference: pdfPage, in: jpegView)
        XCTAssertTrue(jpegView.autoScales)
    }

    /// The persisted zoom stays in the PDF page's units, so a zoom made on the JPEG is the PDF's zoom too.
    func testZoomRecordedOnJPEGIsInPDFUnits() throws {
        let pdfPage = PDFPage()
        pdfPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 520), for: .mediaBox)
        let controller = PDFPaneController(key: "left", persists: false)
        let jpegView = makeView()
        controller.pdfView = jpegView
        controller.show(try makeImagePage(width: 2000, height: 2600), reference: pdfPage, in: jpegView)
        jpegView.autoScales = false
        jpegView.scaleFactor = 0.3          // 2000 px × 0.3 = 600 pt on screen
        controller.recordScale()
        let pdfView = makeView()
        controller.pdfView = pdfView
        controller.show(pdfPage, reference: pdfPage, in: pdfView)
        XCTAssertEqual(pdfView.scaleFactor, 1.5, accuracy: 0.001, "400 pt × 1.5 = the same 600 pt")
    }

    private func makeView() -> PDFView {
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 320))
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        return view
    }

    private func makeImagePage(width: Int, height: Int) throws -> PDFPage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = NSImage(cgImage: try XCTUnwrap(ctx.makeImage()), size: NSSize(width: width, height: height))
        let page = try XCTUnwrap(PDFPage(image: image))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, CGFloat(width), accuracy: 1,
                       "a JPEG page is sized in pixels, as the Reader's NSImage-built page is")
        return page
    }

    /// Let the deferred second scroll (and PDFKit's relayout) land.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }
}
