// PageRotationTests.swift — W40.reader-view-rotate: a page turned in the viewer, remembered in the Reader's own
// store, the file untouched. The render guards show the image page in a real PDFView (in an NSWindow never ordered
// front) at all four turns, from both sources (the PDF's image page and a JPEG original). The page the pane holds is
// drawn to pixels through PDFKit (`cacheDisplay` does not capture PDFKit's asynchronously drawn page tiles, measured:
// every pixel came back dark), and the dark band along the scan's top edge must be on the side the turn puts it.
// PDFKit's own layout of the live view is read back too: the page is laid out turned, and the text layer's find
// highlight and the JPEG's find boxes move with it.

import XCTest
import PDFKit
import AppKit
import CryptoKit
@testable import ArchiveReader

@MainActor
final class PageRotationTests: XCTestCase {

    // MARK: the store

    func testStoreRemembersTurnsAcrossLaunchesAndForgetsUpright() throws {
        let dir = makeTempDir("turn-store")
        let db = dir.appendingPathComponent("library-index-v1.sqlite3")
        let pdf = try makeScanPDF(in: dir)

        let store = PageTurnStore(url: db)
        XCTAssertEqual(store.turns(path: pdf.path, page: 0), 0, "a page never turned is upright")
        store.set(1, path: pdf.path, page: 0)
        store.set(-1, path: pdf.path, page: 2)
        XCTAssertEqual(store.turns(path: pdf.path, page: 0), 1)
        XCTAssertEqual(store.turns(path: pdf.path, page: 2), 3, "a left turn is three right turns")
        XCTAssertEqual(store.turns(path: pdf.path, page: 1), 0, "turns are per page")
        store.flush()

        let relaunched = PageTurnStore(url: db)
        XCTAssertEqual(relaunched.turns(path: pdf.path, page: 0), 1, "the turn survives a relaunch")
        XCTAssertEqual(relaunched.turns(path: pdf.path, page: 2), 3)
        XCTAssertEqual(relaunched.turnedPageCount, 2, "the turned pages are counted: rotation-truth candidates")
        XCTAssertEqual(relaunched.turnedPages().map(\.page), [0, 2])

        relaunched.set(4, path: pdf.path, page: 0)   // four turns is upright again
        relaunched.set(0, path: pdf.path, page: 2)   // Reset Rotation
        relaunched.flush()
        XCTAssertEqual(PageTurnStore(url: db).turnedPageCount, 0, "an upright page has no row")
    }

    func testAChangedFileShowsUprightAgain() throws {
        let dir = makeTempDir("turn-stale")
        let pdf = try makeScanPDF(in: dir)
        let store = PageTurnStore(url: nil)
        store.set(2, path: pdf.path, page: 0)
        XCTAssertEqual(store.turns(path: pdf.path, page: 0), 2)
        // A Processor re-run rewrites the scan (this is the test's own scratch file).
        let handle = try FileHandle(forWritingTo: pdf)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("%% rewritten\n".utf8))
        try handle.close()
        XCTAssertEqual(store.turns(path: pdf.path, page: 0), 0, "the turn described the old scan")
        XCTAssertEqual(store.turnedPageCount, 1, "the row is kept until the page is turned again")
    }

    // MARK: the viewer — the file and the model's pages are never turned

    func testViewerTurnsTheImagePageOnlyAndLeavesTheFileUntouched() throws {
        let dir = makeTempDir("turn-viewer")
        let pdf = try makeScanPDF(in: dir)
        let before = try sha256(pdf)
        let store = PageTurnStore(url: dir.appendingPathComponent("turns.sqlite3"))

        let model = DocumentViewerModel(persists: false, pageTurns: store, thumbnailer: nil)
        model.load(DocumentSelection(filePaths: [pdf.path]))
        XCTAssertTrue(model.canRotate)
        XCTAssertFalse(model.isRotated)
        let identity = model.imagePaneIdentity
        model.rotateRight()
        XCTAssertEqual(model.imageTurns, 1)
        XCTAssertNotEqual(model.imagePaneIdentity, identity, "a turn builds a fresh image pane")
        model.rotateRight()
        model.rotateLeft()
        model.rotateLeft()
        model.rotateLeft()
        XCTAssertEqual(model.imageTurns, 3, "right, right, left, left, left is one left turn")
        XCTAssertEqual(model.imagePage?.rotation, 0, "the model's own page is never turned")
        XCTAssertEqual(model.textPage?.rotation, 0, "nor the OCR text page")
        store.flush()

        let reopened = DocumentViewerModel(persists: false, pageTurns: PageTurnStore(url: dir.appendingPathComponent("turns.sqlite3")),
                                           thumbnailer: nil)
        reopened.load(DocumentSelection(filePaths: [pdf.path]))
        XCTAssertEqual(reopened.imageTurns, 3, "the turn is remembered for the file and page")
        reopened.resetRotation()
        XCTAssertEqual(reopened.imageTurns, 0)
        XCTAssertFalse(reopened.isRotated)

        XCTAssertEqual(try sha256(pdf), before, "the file's bytes are unchanged")
    }

    func testTheTurnIsPerPagePair() throws {
        let dir = makeTempDir("turn-pairs")
        let pdf = try makeScanPDF(in: dir, pairs: 2)
        let model = DocumentViewerModel(persists: false, pageTurns: PageTurnStore(url: nil), thumbnailer: nil)
        model.load(DocumentSelection(filePaths: [pdf.path]))
        model.rotateRight()
        model.next()
        XCTAssertEqual(model.pair, 1)
        XCTAssertEqual(model.imageTurns, 0, "the second scan was not turned")
        model.rotateLeft()
        model.previous()
        XCTAssertEqual(model.imageTurns, 1)
        model.next()
        XCTAssertEqual(model.imageTurns, 3)
    }

    // MARK: render guards — four turns, both sources

    func testPDFImagePageRendersTurnedWithItsTextLayer() throws {
        let dir = makeTempDir("turn-render-pdf")
        let doc = try XCTUnwrap(PDFDocument(url: try makeScanPDF(in: dir)))
        let page = try XCTUnwrap(doc.page(at: 0))
        for turns in 0..<4 {
            let (controller, view, window) = makePane()
            defer { window.close() }
            controller.setFindTarget(query: "zulu", currentIndex: 0)
            controller.show(page, reference: page, turns: turns, in: view)
            settle()
            XCTAssertEqual(page.rotation, 0, "the document's page is not turned (turns \(turns))")
            XCTAssertEqual(view.document?.page(at: 0)?.rotation, turns * 90, "the pane's copy is")
            let shownPage = try XCTUnwrap(view.document?.page(at: 0))
            try assertRendersTurned(shownPage, band: Self.topEdge(turns), named: "w40-view-rotate-pdf-\(turns * 90).png",
                                    "PDF image page, turns \(turns)")
            assertLaidOutTurned(shownPage, in: view, turns: turns, "PDF image page")

            // The text layer turns with the page: the find hit, at the scan's left edge, follows it.
            let shown = try XCTUnwrap(view.document?.page(at: 0))
            let hit = try XCTUnwrap(view.highlightedSelections?.first, "find highlights the text layer")
            assertSide(view.convert(hit.bounds(for: shown), from: shown), in: view, on: shown,
                       is: Self.leftEdge(turns), "find highlight, turns \(turns)")
            XCTAssertEqual(view.currentSelection?.string?.lowercased(), "zulu", "the current hit is selected")
        }
    }

    func testJPEGOriginalRendersTurnedWithItsFindBoxes() throws {
        let dir = makeTempDir("turn-render-jpeg")
        let doc = try XCTUnwrap(PDFDocument(url: try makeScanPDF(in: dir)))
        let source = try XCTUnwrap(doc.page(at: 0))
        let jpeg = try makeJPEGPage(width: 800, height: 1040)
        for turns in 0..<4 {
            let (controller, view, window) = makePane()
            defer { window.close() }
            controller.setFindTarget(query: "zulu", currentIndex: 0)
            controller.show(jpeg, reference: source, turns: turns, in: view)
            settle()
            XCTAssertEqual(jpeg.rotation, 0, "the JPEG's page is not turned (turns \(turns))")
            let shown = try XCTUnwrap(view.document?.page(at: 0))
            try assertRendersTurned(shown, band: Self.topEdge(turns), named: "w40-view-rotate-jpeg-\(turns * 90).png",
                                    "JPEG original, turns \(turns)")
            assertLaidOutTurned(shown, in: view, turns: turns, "JPEG original")

            // The stand-in's find boxes come from the PDF page turned the same way, so they stay on the word.
            let box = try XCTUnwrap(controller.standInOverlay.rects.first, "one box per hit")
            XCTAssertFalse(box.isEmpty)
            assertSide(view.convert(box, from: shown), in: view, on: shown, is: Self.leftEdge(turns),
                       "JPEG find box, turns \(turns)")
        }
    }

    // MARK: - Geometry

    enum Side: CustomStringConvertible { case top, right, bottom, left
        var description: String { "\(self == .top ? "top" : self == .right ? "right" : self == .bottom ? "bottom" : "left")" }
    }

    /// Where the scan's top edge is on screen after `turns` quarter turns clockwise.
    static func topEdge(_ turns: Int) -> Side { [.top, .right, .bottom, .left][turns % 4] }
    /// Where the scan's left edge is.
    static func leftEdge(_ turns: Int) -> Side { [.left, .top, .right, .bottom][turns % 4] }

    /// Draw the pane's page as PDFKit draws it (its turn applied), check it is not blank, and that the dark pixels'
    /// centre lies toward `band`.
    private func assertRendersTurned(_ page: PDFPage, band: Side, named name: String, _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let image = page.thumbnail(of: CGSize(width: 260, height: 260), for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: image.size)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: &proposed, context: nil, hints: nil))
        let png = try XCTUnwrap(RenderProbe.pngData(from: cg))
        writeRenderArtifact(png, named: name)
        let stats = PixelStats.from(cgImage: cg)
        XCTAssertFalse(stats.isEffectivelyBlank(), "\(message): the page drew", file: file, line: line)
        let rep = NSBitmapImageRep(cgImage: cg)
        var sx = 0.0, sy = 0.0, n = 0.0
        for px in 0..<rep.pixelsWide {
            for py in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB),
                      (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.12 else { continue }
                sx += Double(px); sy += Double(rep.pixelsHigh - 1 - py)   // rows run top-down; y up, as the view's
                n += 1
            }
        }
        let area = Double(rep.pixelsWide * rep.pixelsHigh)
        XCTAssertGreaterThan(n / area, 0.05, "\(message): the dark band was drawn", file: file, line: line)
        XCTAssertLessThan(n / area, 0.4, "\(message): and only the band is dark", file: file, line: line)
        guard n > 0 else { return }
        assertSide(CGRect(x: sx / n, y: sy / n, width: 0, height: 0), in: nil,
                   pageRect: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh), is: band,
                   "\(message): the scan's top band", file: file, line: line)
    }

    /// PDFKit lays the live view's page out turned: a quarter turn swaps the page's width and height on screen.
    private func assertLaidOutTurned(_ page: PDFPage, in view: PDFView, turns: Int, _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let own = page.bounds(for: view.displayBox).size
        let onScreen = view.convert(page.bounds(for: view.displayBox), from: page).size
        XCTAssertGreaterThan(onScreen.width, 0, file: file, line: line)
        let ownTall = own.height > own.width, screenTall = onScreen.height > onScreen.width
        XCTAssertEqual(screenTall, turns % 2 == 0 ? ownTall : !ownTall,
                       "\(message), turns \(turns): laid out \(onScreen) for a \(own) page", file: file, line: line)
    }

    private func assertSide(_ rect: CGRect, in view: PDFView, on page: PDFPage, is side: Side, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        assertSide(rect, in: view as PDFView?, pageRect: view.convert(page.bounds(for: view.displayBox), from: page), is: side,
                   message, file: file, line: line)
    }

    /// `rect`'s centre is on `side` of the page's centre, by more than a sixth of the page, and not off along the
    /// other axis by more than that.
    private func assertSide(_ rect: CGRect, in view: PDFView?, pageRect: CGRect, is side: Side, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let dx = (rect.midX - pageRect.midX) / pageRect.width, dy = (rect.midY - pageRect.midY) / pageRect.height
        let found: Side = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .top : .bottom)
        XCTAssertEqual(found, side, "\(message): at dx \(dx), dy \(dy) of the page", file: file, line: line)
        XCTAssertGreaterThan(max(abs(dx), abs(dy)), 1.0 / 6, "\(message): clearly to one side", file: file, line: line)
    }

    // MARK: - Fixtures

    private func makePane() -> (PDFPaneController, PDFView, NSWindow) {
        let controller = PDFPaneController(key: "left", persists: false)
        let view = ReaderPDFView(frame: CGRect(x: 0, y: 0, width: 360, height: 360))
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        // A real window, never ordered onto the screen, so the view lays out and draws for `cacheDisplay`.
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        controller.pdfView = view
        return (controller, view, window)
    }

    /// A scratch archival PDF: each pair is an image page (a grey scan with a black band along its top edge and
    /// the word "zulu" in its text layer at the left edge, halfway down) and an OCR text page.
    private func makeScanPDF(in dir: URL, pairs: Int = 1) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 400, height: 520)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = pageRect
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pairs {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
            ctx.fill(pageRect)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 450, width: 400, height: 70))
            drawText("zulu", into: ctx, at: CGPoint(x: 12, y: 250), fontSize: 28)
            ctx.endPDFPage()
            ctx.beginPDFPage(nil)
            drawText("Sample OCR text, page two of the pair.", into: ctx, at: CGPoint(x: 24, y: 470), fontSize: 16)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let url = dir.appendingPathComponent("scan-\(UUID().uuidString).pdf")
        try (data as Data).write(to: url, options: .atomic)
        return url
    }

    /// A JPEG original's page, sized in pixels as the Reader's NSImage-built page is: grey, the top 13% black.
    private func makeJPEGPage(width: Int, height: Int) throws -> PDFPage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(gray: 0.55, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: Int(Double(height) * 0.87), width: width, height: height))
        let jpegData = try XCTUnwrap(RenderProbe.jpegData(from: try XCTUnwrap(ctx.makeImage())))
        let image = try XCTUnwrap(NSImage(data: jpegData))
        image.size = NSSize(width: width, height: height)
        return try XCTUnwrap(PDFPage(image: image))
    }

    private func drawText(_ string: String, into ctx: CGContext, at origin: CGPoint, fontSize: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: string, attributes: [.font: NSFont.systemFont(ofSize: fontSize),
                                         .foregroundColor: NSColor(white: 0.3, alpha: 1)]))
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTempDir(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
