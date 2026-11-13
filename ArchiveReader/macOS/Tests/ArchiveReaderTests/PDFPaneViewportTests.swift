// PDFPaneViewportTests.swift — the PDF / JPEG switch keeps the zoom and the visible region
// (W40.fix-reader-jpeg-keep-view). Drives `PDFPaneController` against real, windowless PDFViews, so the
// carried region is read back through PDFKit's own coordinate conversion rather than the controller's maths.

import XCTest
import PDFKit
import AppKit
import SwiftUI
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

    /// The real SwiftUI wiring: `PDFPaneView`s swapped by identity, as the document window swaps the image
    /// pane, hosted offscreen (never put in a window). A 20 px JPEG against a 400 pt page needs a scale 20
    /// times the PDF's, beyond PDFKit's default zoom limit of 20.
    func testHostedSwapKeepsOnScreenSize() throws {
        let pdfPage = PDFPage()
        pdfPage.setBounds(CGRect(x: 0, y: 0, width: 400, height: 520), for: .mediaBox)
        let jpegPage = try makeImagePage(width: 20, height: 26)
        let controller = PDFPaneController(key: "left", persists: false)
        let state = SwapState()
        let host = NSHostingView(rootView: SwapHost(state: state, pdf: pdfPage, jpeg: jpegPage, controller: controller))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        host.layoutSubtreeIfNeeded(); settle()
        for _ in 0..<4 { controller.zoomIn() }; settle()
        let pdfScale = try XCTUnwrap(controller.pdfView?.scaleFactor)
        controller.captureViewport()
        let before = try XCTUnwrap(controller.pendingViewport)
        state.jpeg = true
        host.layoutSubtreeIfNeeded(); settle()
        let jpegView = try XCTUnwrap(controller.pdfView)
        XCTAssertEqual(jpegView.document?.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 20, accuracy: 0.01)
        XCTAssertEqual(jpegView.scaleFactor * 20, pdfScale * 400, accuracy: 1, "the JPEG keeps the PDF page's size")
        let shownJPEG = try XCTUnwrap(jpegView.document?.page(at: 0))
        let pageRect = jpegView.convert(shownJPEG.bounds(for: .mediaBox), from: shownJPEG)
        XCTAssertTrue(pageRect.contains(CGPoint(x: jpegView.bounds.midX, y: jpegView.bounds.midY)),
                      "the image is under the middle of the pane, not off in the margin")
        controller.captureViewport()
        let onJPEG = try XCTUnwrap(controller.pendingViewport)
        XCTAssertEqual(onJPEG.centre.x, before.centre.x, accuracy: 0.02)
        XCTAssertEqual(onJPEG.centre.y, before.centre.y, accuracy: 0.02)
        state.jpeg = false
        host.layoutSubtreeIfNeeded(); settle()
        XCTAssertEqual(controller.pdfView?.scaleFactor ?? 0, pdfScale, accuracy: 0.001)
    }

    /// Zoomed out, so the page sits inside the pane, in a real window (never ordered onto the screen) with
    /// always-shown scrollers: the VM showed PDFKit rescaling the fresh view by about 2% as they settle.
    func testHostedSwapKeepsZoomedOutSize() throws {
        let pdfPage = PDFPage()
        pdfPage.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        let jpegPage = try makeImagePage(width: 1224, height: 1584)
        let controller = PDFPaneController(key: "left", persists: false)
        let state = SwapState()
        let host = NSHostingView(rootView: SwapHost(state: state, pdf: pdfPage, jpeg: jpegPage, controller: controller))
        // Legacy (always-shown) scrollers, as on a Mac with a mouse rather than a trackpad.
        UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
        defer { UserDefaults.standard.removeObject(forKey: "AppleShowScrollBars") }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 930, height: 780), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded(); settle()
        for _ in 0..<4 { controller.zoomOut(); settle() }
        let pdfScale = try XCTUnwrap(controller.pdfView?.scaleFactor)
        controller.captureViewport()
        state.jpeg = true
        host.layoutSubtreeIfNeeded(); settle()
        let jpegScale = try XCTUnwrap(controller.pdfView?.scaleFactor)
        XCTAssertEqual(jpegScale * 1224, pdfScale * 612, accuracy: 0.5)
        state.jpeg = false
        host.layoutSubtreeIfNeeded(); settle()
        XCTAssertEqual(controller.pdfView?.scaleFactor ?? 0, pdfScale, accuracy: 0.001)
    }

    // MARK: find on the JPEG original (W40.fix-reader-find-both-panes)

    /// The JPEG has no text layer, so its hits come from the PDF image page it stands in for, drawn at the
    /// same place on the photograph: a 400-point page shown as a 2000-pixel JPEG puts each box at five
    /// times the coordinates (rotated with the page when both are turned).
    func testStandInBoxesLandAtTheSamePlaceOnTheJPEG() throws {
        for rotation in [0, 90] {
            let doc = TestPDFBuilder.textPDF(pages: ["zulu here\nand zulu there"])
            let source = try XCTUnwrap(doc.page(at: 0))
            let own = doc.findString("zulu", withOptions: [.caseInsensitive]).map { $0.bounds(for: source) }
            source.rotation = rotation
            let jpeg = try makeImagePage(width: 2000, height: 2000)
            jpeg.rotation = rotation
            let rects = PDFPaneController.standInMatchRects(query: "ZULU", source: source, shown: jpeg, box: .mediaBox)
            XCTAssertEqual(rects.count, 2, "rotation \(rotation)")
            XCTAssertEqual(own.count, 2, "precondition")
            for (rect, r) in zip(rects, own) {
                XCTAssertEqual(rect.minX, r.minX * 5, accuracy: 0.5, "rotation \(rotation)")
                XCTAssertEqual(rect.minY, r.minY * 5, accuracy: 0.5, "rotation \(rotation)")
                XCTAssertEqual(rect.width, r.width * 5, accuracy: 0.5, "rotation \(rotation)")
                XCTAssertEqual(rect.height, r.height * 5, accuracy: 0.5, "rotation \(rotation)")
            }
        }
    }

    /// Showing the JPEG with find on draws one box per hit over the page — pixels, read back from the
    /// view — and marks no page; ending find removes them. Showing the PDF page uses PDFKit's own highlight.
    func testFindOnTheJPEGDrawsBoxesOverThePageOnly() throws {
        let doc = TestPDFBuilder.textPDF(pages: ["zulu here\nand zulu there"])
        let source = try XCTUnwrap(doc.page(at: 0))
        let jpeg = try makeImagePage(width: 2000, height: 2000)
        let controller = PDFPaneController(key: "left", persists: false)
        let view = makeView()
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        controller.pdfView = view
        controller.setFindTarget(query: "zulu", currentIndex: 1)
        controller.show(jpeg, reference: source, in: view)
        settle()
        XCTAssertEqual(controller.standInOverlay.rects.count, 2, "one box per hit")
        XCTAssertEqual(controller.standInOverlay.current, 1)
        XCTAssertTrue(source.annotations.isEmpty && jpeg.annotations.isEmpty, "no page is marked")
        let shown = try XCTUnwrap(view.document?.page(at: 0))
        XCTAssertTrue(shown.annotations.isEmpty)
        let lit = try yellowishPixels(in: view)
        XCTAssertGreaterThan(lit, 20, "the boxes are drawn over the grey photograph")
        controller.applyFind()
        XCTAssertEqual(controller.standInOverlay.rects.count, 2, "re-applying replaces the boxes rather than adding more")
        controller.clearFind()
        XCTAssertTrue(controller.standInOverlay.rects.isEmpty, "ending find removes them")
        settle()
        XCTAssertEqual(try yellowishPixels(in: view), 0, "and they are gone from the screen")

        let pdfView = makeView()
        controller.pdfView = pdfView
        controller.setFindTarget(query: "zulu", currentIndex: 0)
        controller.show(source, reference: source, in: pdfView)
        XCTAssertEqual(pdfView.highlightedSelections?.count, 2, "the PDF page highlights through its own text")
        XCTAssertTrue(pdfView.document?.page(at: 0)?.annotations.isEmpty ?? false, "no boxes on a page with text")
        XCTAssertEqual(pdfView.currentSelection?.string?.lowercased(), "zulu", "the current hit is selected")
    }

    /// Pixels of `view` where red and green clearly outweigh blue — the find boxes over a grey page.
    private func yellowishPixels(in view: NSView) throws -> Int {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent - c.blueComponent > 0.15, c.greenComponent - c.blueComponent > 0.05 { count += 1 }
            }
        }
        return count
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

private final class SwapState: ObservableObject { @Published var jpeg = false }

private struct SwapHost: View {
    @ObservedObject var state: SwapState
    let pdf: PDFPage
    let jpeg: PDFPage
    let controller: PDFPaneController
    var body: some View {
        PDFPaneView(page: state.jpeg ? jpeg : pdf, controller: controller, reference: pdf)
            .id(state.jpeg ? "jpeg" : "pdf")
    }
}
