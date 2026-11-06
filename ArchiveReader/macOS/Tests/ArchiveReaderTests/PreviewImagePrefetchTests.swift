// PreviewImagePrefetchTests.swift — the preview's image arrives with its text (W40.fix-reader-preview-image-speed).
// The prerenderer draws a scan's image page ahead of time; the pane shows that bitmap over the page at once,
// where PDFKit alone shows an empty page until its first, slow draw of the scan lands.

import XCTest
import PDFKit
import AppKit
import SwiftUI
@testable import ArchiveReader

@MainActor
final class PreviewImagePrefetchTests: XCTestCase {

    // MARK: The bitmap

    /// The page is drawn as a PDFView displays it: fitted into the pixel box, upright, rotation applied.
    func testRenderDrawsThePageAsDisplayed() throws {
        let url = try writeScanPDF(width: 1200, height: 1600, name: "upright")
        let r = try XCTUnwrap(PreviewImagePrefetcher.render(path: url.path, pageIndex: 0,
                                                            pixelBox: CGSize(width: 300, height: 600)))
        XCTAssertEqual(r.image.width, 300)
        XCTAssertEqual(r.image.height, 400)
        XCTAssertLessThan(luminance(r.image, atFractionX: 0.5, y: 0.25), 0.3, "the scan's dark top half is at the top")
        XCTAssertGreaterThan(luminance(r.image, atFractionX: 0.5, y: 0.75), 0.7, "and its light half below")

        // A turned page is drawn unrotated (PDFKit turns the overlay with the page), fitted by its long side.
        let turned = try writeScanPDF(width: 1200, height: 1600, rotation: 90, name: "turned")
        let t = try XCTUnwrap(PreviewImagePrefetcher.render(path: turned.path, pageIndex: 0,
                                                            pixelBox: CGSize(width: 800, height: 600)))
        XCTAssertEqual(t.image.width, 600)
        XCTAssertEqual(t.image.height, 800)
        XCTAssertLessThan(luminance(t.image, atFractionX: 0.5, y: 0.25), 0.3)
        XCTAssertEqual(PDFDocument(url: turned)?.page(at: 0)?.rotation, 90, "the file itself is untouched")

        XCTAssertNil(PreviewImagePrefetcher.render(path: url.path, pageIndex: 5, pixelBox: CGSize(width: 10, height: 10)))
        XCTAssertNil(PreviewImagePrefetcher.render(path: url.deletingLastPathComponent().appendingPathComponent("missing.pdf").path,
                                                   pageIndex: 0, pixelBox: CGSize(width: 10, height: 10)))
    }

    // MARK: The cache

    func testPrefetchCachesAndForgetsAChangedFile() throws {
        let url = try writeScanPDF(width: 800, height: 1000, name: "cached")
        let prefetcher = PreviewImagePrefetcher(pixelBox: CGSize(width: 200, height: 250))
        XCTAssertNil(prefetcher.image(path: url.path, pageIndex: 0))
        prefetcher.prefetch(paths: [url.path])
        try waitUntil { prefetcher.image(path: url.path, pageIndex: 0) != nil }
        XCTAssertNil(prefetcher.image(path: url.path, pageIndex: 1), "only the first image page is drawn ahead")

        // The Processor rewrites a file: a bitmap of the old scan must never be shown over the new one.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        XCTAssertNil(prefetcher.image(path: url.path, pageIndex: 0), "a changed file has no bitmap until redrawn")
    }

    /// Holding ↓ through the list asks for file after file: only the newest request is drawn, beyond the one
    /// already running, so the queue never falls behind the selection.
    func testNewestRequestReplacesQueuedOnes() throws {
        let urls = try (0..<4).map { try writeScanPDF(width: 600, height: 800, name: "q\($0)") }
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.prefetch")
        queue.async { gate.wait() }                       // hold the queue until all requests are made
        let prefetcher = PreviewImagePrefetcher(pixelBox: CGSize(width: 100, height: 100), queue: queue)
        prefetcher.prefetch(paths: [urls[0].path, urls[1].path])   // 0 starts (queued behind the gate)
        prefetcher.prefetch(paths: [urls[2].path])                 // replaces 1
        prefetcher.prefetch(paths: [urls[3].path])                 // replaces 2
        gate.signal()
        try waitUntil { prefetcher.image(path: urls[3].path, pageIndex: 0) != nil }
        XCTAssertNotNil(prefetcher.image(path: urls[0].path, pageIndex: 0), "the render already started finishes")
        XCTAssertNil(prefetcher.image(path: urls[1].path, pageIndex: 0))
        XCTAssertNil(prefetcher.image(path: urls[2].path, pageIndex: 0))
    }

    func testCacheIsBounded() throws {
        let urls = try (0..<(PreviewImagePrefetcher.cacheLimit + 2)).map { try writeScanPDF(width: 200, height: 300, name: "b\($0)") }
        let prefetcher = PreviewImagePrefetcher(pixelBox: CGSize(width: 50, height: 50))
        for url in urls {
            prefetcher.prefetch(paths: [url.path])
            try waitUntil { prefetcher.image(path: url.path, pageIndex: 0) != nil }
        }
        XCTAssertNil(prefetcher.image(path: urls[0].path, pageIndex: 0), "the least recently used bitmap goes first")
        XCTAssertNotNil(prefetcher.image(path: urls.last!.path, pageIndex: 0))
    }

    // MARK: The pane

    /// The pane lays the bitmap over the page the moment the page is shown, upright, covering the page, and
    /// turned with it. The page here is blank, so every dark pixel captured is the overlay's. (PDFKit's own
    /// first draw is the slow part; headless, PDFKit draws synchronously for a capture, so the empty page the
    /// owner saw cannot itself be captured — the timing test below measures that draw instead.)
    func testPaneLaysTheBitmapOverThePage() throws {
        for rotation in [0, 90, 180, 270] {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 1200, height: 1600), for: .mediaBox)
            page.rotation = rotation
            let bitmap = try XCTUnwrap(halfDarkImage(width: 960, height: 1280))   // dark top half, unrotated

            let without = showInPane(page, placeholder: nil)
            XCTAssertNil(without.view.pageOverlayViewProvider, "a pane with no placeholder installs no overlay")
            let baseline = inkFraction(without.view)   // the pane's own background and page shadow

            let with = showInPane(page, placeholder: PlaceholderRequest(key: "p#0", image: bitmap))
            XCTAssertTrue(with.controller.placeholderOverlay.isShowing)
            XCTAssertNotNil(overlays(in: with.view).first, "PDFKit asked for the page's overlay")
            let shown = try XCTUnwrap(with.view.document?.page(at: 0))
            let r = with.view.convert(shown.bounds(for: with.view.displayBox), from: shown)
            // Where the page's top (the bitmap's dark half) lands once PDFKit turns the page clockwise.
            let (dark, light): (CGPoint, CGPoint) = switch rotation {
            case 90: (CGPoint(x: r.minX + r.width * 0.75, y: r.midY), CGPoint(x: r.minX + r.width * 0.25, y: r.midY))
            case 180: (CGPoint(x: r.midX, y: r.minY + r.height * 0.25), CGPoint(x: r.midX, y: r.minY + r.height * 0.75))
            case 270: (CGPoint(x: r.minX + r.width * 0.25, y: r.midY), CGPoint(x: r.minX + r.width * 0.75, y: r.midY))
            default: (CGPoint(x: r.midX, y: r.minY + r.height * 0.75), CGPoint(x: r.midX, y: r.minY + r.height * 0.25))
            }
            XCTAssertLessThan(brightness(with.view, at: dark), 0.3, "rotation \(rotation): the page's top is dark")
            XCTAssertGreaterThan(brightness(with.view, at: light), 0.7, "rotation \(rotation): its bottom is light")
            XCTAssertGreaterThan(inkFraction(with.view), baseline + 0.15, "rotation \(rotation)")

            // Once retired (a selection, find highlights) the bitmap draws nothing more.
            with.controller.placeholderOverlay.retire()
            XCTAssertFalse(with.controller.placeholderOverlay.isShowing)
            XCTAssertEqual(inkFraction(with.view), baseline, accuracy: 0.01, "rotation \(rotation): back to the bare page")
        }
    }

    /// Shown larger than its own resolution (zoomed in), the overlay draws nothing and leaves PDFKit's sharper
    /// render; it is not retired, since PDFKit also lays a page out at a passing scale before its fit lands.
    func testOverlayDrawsNothingPastItsResolution() throws {
        let url = try writeScanPDF(width: 1200, height: 1600, name: "zoom")
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let small = try XCTUnwrap(PreviewImagePrefetcher.render(path: url.path, pageIndex: 0,
                                                                pixelBox: CGSize(width: 100, height: 130)))
        let pane = showInPane(page, placeholder: PlaceholderRequest(key: "z#0", image: small.image))
        let overlay = try XCTUnwrap(overlays(in: pane.view).first)
        XCTAssertLessThan(inkFraction(overlay), 0.01, "a 100 px bitmap is not drawn over a page about 450 pt wide")
        XCTAssertTrue(pane.controller.placeholderOverlay.isShowing)
    }

    func testLateBitmapIsTakenOnlyForThePageShown() throws {
        let image = try XCTUnwrap(solidImage(gray: 0.1))
        let overlay = PlaceholderPageOverlay()
        overlay.reset(key: "a.pdf#0", image: nil)
        overlay.supply(image, key: "b.pdf#0")
        XCTAssertFalse(overlay.isShowing, "a bitmap of another file never lands on this page")
        overlay.supply(image, key: "a.pdf#0")
        XCTAssertTrue(overlay.isShowing)
        overlay.retire()
        overlay.supply(image, key: "a.pdf#0")
        XCTAssertFalse(overlay.isShowing, "once retired, it stays retired on this page")
        overlay.reset(key: "c.pdf#0", image: image)
        XCTAssertTrue(overlay.isShowing, "a new page starts afresh")
        overlay.reset(key: nil, image: image)
        XCTAssertFalse(overlay.isShowing)
    }

    /// The pane's selection notification retires the bitmap only for a real selection.
    func testSelectionRetiresOnlyWhenSomethingIsSelected() throws {
        let url = try writeTextPDF(name: "text")
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let bitmap = try XCTUnwrap(solidImage(gray: 0.1))
        let pane = showInPane(page, placeholder: PlaceholderRequest(key: "t#0", image: bitmap))
        pane.view.clearSelection()
        pane.controller.selectionChanged()
        XCTAssertTrue(pane.controller.placeholderOverlay.isShowing, "an empty selection hides nothing")
        pane.view.selectAll(nil)
        pane.controller.selectionChanged()
        XCTAssertFalse(pane.controller.placeholderOverlay.isShowing)
    }

    /// Through `PDFPaneView` as the preview hosts it: a bitmap that lands after the page is shown is taken,
    /// PDFKit's own selection notification retires it, and the overlay covers the crop box the bitmap is
    /// drawn from even where the media box is larger.
    func testHostedPaneTakesALateBitmapAndRetiresOnSelection() throws {
        let page = try XCTUnwrap(TestPDFBuilder.textPDF(pages: ["selectable words here"]).page(at: 0))
        page.setBounds(CGRect(x: 20, y: 30, width: 300, height: 340), for: .cropBox)
        let controller = PDFPaneController(key: "left", persists: false)
        let state = LateBitmapState()
        let key = PlaceholderRequest.key(path: "/scratch/a.pdf", pageIndex: 0)
        XCTAssertEqual(key, "/scratch/a.pdf#0")
        let host = NSHostingView(rootView: LateBitmapHost(state: state, page: page, controller: controller, key: key))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 470, height: 640), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let view = try XCTUnwrap(controller.pdfView)
        XCTAssertTrue(view.pageOverlayViewProvider === controller.placeholderOverlay, "installed before the bitmap is ready")
        XCTAssertFalse(controller.placeholderOverlay.isShowing)

        state.image = try XCTUnwrap(solidImage(gray: 0.2))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.placeholderOverlay.isShowing, "the late bitmap is taken for the page shown")
        let overlay = try XCTUnwrap(overlays(in: view).first)
        XCTAssertEqual(overlay.bounds.width, 300, accuracy: 0.5, "the overlay spans the crop box, as the bitmap does")
        XCTAssertEqual(overlay.bounds.height, 340, accuracy: 0.5)

        view.selectAll(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.placeholderOverlay.isShowing, "a selection retires it, through PDFKit's notification")
    }

    // MARK: Before and after

    /// The figures the item asks for, on a fixture scan: the cold first draw PDFKit makes before a page can
    /// appear (before), against the lookup the preview makes once the bitmap is drawn ahead (after). The
    /// corpus figures are in the item's DONE entry; this keeps the comparison honest on every run.
    func testReportsBeforeAndAfterTimes() throws {
        let url = try writeScanPDF(width: 3400, height: 4400, name: "timing")
        var start = CFAbsoluteTimeGetCurrent()
        let doc = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(doc.page(at: 0))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 940, height: 1216, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.scaleBy(x: 940 / 3400, y: 940 / 3400)
        page.draw(with: .cropBox, to: ctx)
        let before = (CFAbsoluteTimeGetCurrent() - start) * 1000

        let prefetcher = PreviewImagePrefetcher()
        prefetcher.prefetch(paths: [url.path])
        try waitUntil { prefetcher.image(path: url.path, pageIndex: 0) != nil }
        start = CFAbsoluteTimeGetCurrent()
        let hit = try XCTUnwrap(prefetcher.image(path: url.path, pageIndex: 0))
        let after = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print(String(format: "W40.fix-reader-preview-image-speed: first draw %.1f ms (before), prefetched lookup %.2f ms (after); background render %.1f ms",
                     before, after, hit.renderMilliseconds))
        XCTAssertLessThan(after, 20, "a drawn-ahead page is in hand at once")
    }

    // MARK: Helpers

    private func showInPane(_ page: PDFPage, placeholder: PlaceholderRequest?) -> (view: PDFView, controller: PDFPaneController) {
        let controller = PDFPaneController(key: "left", persists: false)
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 470, height: 640))
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        // A window that is never shown: PDFKit lays out page overlays only for a view in one.
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { @MainActor in window.close() }
        controller.pdfView = view
        controller.show(page, reference: nil, placeholder: placeholder, in: view)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (view, controller)
    }

    private func overlays(in view: NSView) -> [PlaceholderPageOverlayView] {
        view.subviews.flatMap { ($0 as? PlaceholderPageOverlayView).map { [$0] } ?? overlays(in: $0) }
    }

    /// Share of sampled pixels that are opaque and darker than mid-grey, over the whole view.
    private func inkFraction(_ view: NSView) -> Double {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var dark = 0, n = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 6) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 6) {
                n += 1
                // Opaque and dark: a view that draws nothing captures as clear pixels, which are not ink.
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5,
                   c.brightnessComponent < 0.5 { dark += 1 }
            }
        }
        return n == 0 ? 0 : Double(dark) / Double(n)
    }

    /// Brightness at a point in the view's own (unflipped, y-up) coordinates.
    private func brightness(_ view: NSView, at point: CGPoint) -> Double {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let sx = Double(rep.pixelsWide) / view.bounds.width, sy = Double(rep.pixelsHigh) / view.bounds.height
        let y = view.isFlipped ? point.y : view.bounds.height - point.y   // bitmap rows run top-down
        let c = rep.colorAt(x: Int(point.x * sx), y: Int(y * sy))?.usingColorSpace(.deviceRGB)
        return Double(c?.brightnessComponent ?? -1)
    }

    private func luminance(_ image: CGImage, atFractionX fx: Double, y fy: Double) -> Double {
        let rep = NSBitmapImageRep(cgImage: image)
        let c = rep.colorAt(x: Int(Double(rep.pixelsWide) * fx), y: Int(Double(rep.pixelsHigh) * fy))?
            .usingColorSpace(.deviceRGB)
        return Double(c?.brightnessComponent ?? -1)
    }

    private func halfDarkImage(width: Int, height: Int) -> CGImage? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.setFillColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx?.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))   // y up: the top half
        return ctx?.makeImage()
    }

    private func solidImage(gray: CGFloat) -> CGImage? {
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        ctx?.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        ctx?.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        return ctx?.makeImage()
    }

    /// A scan-like PDF: one raster image page, dark in its top half, plus a blank second page.
    private func writeScanPDF(width: Int, height: Int, rotation: Int = 0, name: String) throws -> URL {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(gray: 0.95, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))   // CG origin is bottom-left
        let image = NSImage(cgImage: try XCTUnwrap(ctx.makeImage()), size: NSSize(width: width, height: height))
        let page = try XCTUnwrap(PDFPage(image: image))
        page.rotation = rotation
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        doc.insert(PDFPage(), at: 1)
        let url = tempDir.appendingPathComponent("\(name).pdf")
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    private func writeTextPDF(name: String) throws -> URL {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Selectable words on a page" as NSString).draw(at: CGPoint(x: 20, y: 300),
                                                        withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        let url = tempDir.appendingPathComponent("\(name).pdf")
        try (data as Data).write(to: url)
        return url
    }

    private lazy var tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewImagePrefetch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }()

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw NSError(domain: "PreviewImagePrefetchTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "timed out waiting for the prerender"])
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private final class LateBitmapState: ObservableObject { @Published var image: CGImage? }

private struct LateBitmapHost: View {
    @ObservedObject var state: LateBitmapState
    let page: PDFPage
    let controller: PDFPaneController
    let key: String
    var body: some View {
        PDFPaneView(page: page, controller: controller, placeholder: PlaceholderRequest(key: key, image: state.image))
    }
}
