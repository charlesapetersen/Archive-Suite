import XCTest
import AppKit

/// W40.fix-reader-doc-keys-focus, in the real app (W40.fix-reader-doc-keys-focus-ui). The owner's Reader session 2
/// (rows 6, 7): the arrow keys did nothing in the document window, and a click in the text pane left the focus
/// border on the image. The fix pans the focused PDF page with the plain arrows, moves the border and the zoom keys
/// to the pane that became first responder, and has a rebuilt pane take back a focus that fell to the window,
/// never from the Find field.
///
/// Its own corpus in a throwaway directory (the `CopyTextPaneUITests` pattern): two single-page PDFs, whose right
/// pane is their text layer as plain text, then a two-page PDF, whose right pane is its OCR text page, so cycling
/// crosses from an extracted-text pane to a PDF one and back. The suite reads:
/// - the focus border from the pixels of each pane's top edge against the row just below it;
/// - a zoom from the on-screen size of a PDF page's AXPage node, or of the extracted text (`TextZoomUITests`);
/// - a pan from where the image page's AXPage node sits on screen, which moves as the clip view scrolls.
/// The document in view is read from the window's title (the file's name), so a pan that cycled would show.
@MainActor
final class DocumentPaneKeysUITests: XCTestCase {

    private var scratch: URL!
    private var app: XCUIApplication?

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let words = ["alpha", "bravo", "charlie"]

    override func setUp() async throws {
        continueAfterFailure = false
        scratch = try WarmStartUITests.makeScratchDirectory(prefix: "AR-DocPaneKeys")
    }

    override func tearDown() async throws {
        app?.typeKey("0", modifierFlags: [.command, .option])   // Reset Zoom, so the next run starts fitted
        app?.terminate()
        app = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testDocumentPaneKeyboardFocusAndPan() throws {
        let app = try openAllDocuments()
        app.typeKey("0", modifierFlags: [.command, .option])    // Reset Zoom: a zoom another run left behind
        settle()
        XCTAssertTrue(showing("alpha"), "the first document opens")
        captureScreenshot("doc-keys-0-open")

        // 1. A click in the text pane, not a selection: the border and Zoom In move to it.
        clickTextPane()
        captureScreenshot("doc-keys-1-text-clicked")
        assertFocus(.right, "a click in the extracted-text pane moves the focus border to it")
        let imageWidth = try pageFrame().width
        let textHeight = extractedText.frame.height
        documentMenuItem("Zoom In").click()
        settle()
        XCTAssertGreaterThan(extractedText.frame.height, textHeight + 1, "Zoom In enlarges the clicked text pane's text")
        XCTAssertEqual(try pageFrame().width, imageWidth, accuracy: 1, "and leaves the image page's zoom")
        app.typeKey("0", modifierFlags: .command)                // Fit Page: the focused text back to its size
        settle()

        // 2. A click on the image page: the border goes back, and Zoom In takes it beyond fit.
        imagePane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        settle()
        assertFocus(.left, "a click on the image page moves the focus border back to it")
        let textHeightFitted = extractedText.frame.height
        try zoomImageBeyondFit()
        XCTAssertEqual(extractedText.frame.height, textHeightFitted, accuracy: 1, "zooming the image leaves the text")
        captureScreenshot("doc-keys-2-image-zoomed")

        // 3. All four plain arrows pan the page, clamped at its edges, and none of them cycles the document.
        try assertArrowsPan(in: "alpha", screenshot: "doc-keys-3")

        // 4. Cycling to the next document rebuilds the panes; the new image page takes the focus back, so the
        //    arrows still reach it (they reached nothing after a page turn before the fix).
        app.typeKey(.downArrow, modifierFlags: [.command, .shift])   // Next Page in Segment
        settle()
        XCTAssertTrue(showing("bravo"), "⌘⇧↓ cycles to the second document")
        assertFocus(.left, "the image page keeps the focus across the cycle")
        let before = try pageFrame()
        app.typeKey(.downArrow, modifierFlags: [])
        settle()
        XCTAssertLessThan(try pageFrame().minY, before.minY - 5, "↓ pans the rebuilt image page")
        captureScreenshot("doc-keys-4-cycled-panned")

        // 5. Text pane focus across the extracted-text → PDF-text transition and back.
        clickTextPane()
        assertFocus(.right, "a click in the second document's text pane moves the border to it")
        app.typeKey(.downArrow, modifierFlags: [.command, .shift])
        settle()
        XCTAssertTrue(showing("charlie"), "⌘⇧↓ cycles to the two-page document")
        XCTAssertFalse(extractedText.exists, "its text pane is its OCR text page, not extracted text")
        captureScreenshot("doc-keys-5-two-page")
        assertFocus(.right, "the text pane keeps the focus into a two-page document")
        let ocrWidth = try pageFrame("OCR text page").width
        let imageWidthHere = try pageFrame().width
        documentMenuItem("Zoom In").click()
        settle()
        XCTAssertGreaterThan(try pageFrame("OCR text page").width, ocrWidth + 5, "Zoom In zooms the focused OCR text page")
        XCTAssertEqual(try pageFrame().width, imageWidthHere, accuracy: 1, "and not the image page")

        app.typeKey(.upArrow, modifierFlags: [.command, .shift])     // Previous Page in Segment
        settle()
        XCTAssertTrue(showing("bravo"), "⌘⇧↑ cycles back to the single-page document")
        assertFocus(.right, "the text pane keeps the focus back into extracted text")
        let heightBack = extractedText.frame.height
        documentMenuItem("Zoom In").click()
        settle()
        XCTAssertGreaterThan(extractedText.frame.height, heightBack + 1, "Zoom In still follows the text pane")
        captureScreenshot("doc-keys-6-back-to-extracted")

        // 6. The Find field's caret survives a cycle: the rebuilt panes do not take the focus from it.
        app.typeKey("f", modifierFlags: .command)
        settle()
        let find = app.textFields["ar.doc.findField"]
        XCTAssertTrue(find.waitForExistence(timeout: 5), "⌘F shows the Find field")
        find.typeText("br")
        app.typeKey(.downArrow, modifierFlags: [.command, .shift])
        settle()
        XCTAssertTrue(showing("charlie"), "⌘⇧↓ cycles with the caret in the Find field")
        find.typeText("x")
        settle()
        captureScreenshot("doc-keys-7-find-kept")
        XCTAssertEqual(find.value as? String, "brx", "typing after the cycle still goes into the Find field")
    }

    // MARK: - Panes

    private enum Pane { case left, right }

    // A PDF pane reaches the accessibility tree as a scroll view around PDFKit's AXPage node, which carries the
    // page's title but not the pane's identifier or its DEBUG scale value; the extracted text is a text view.
    private static func pageTitled(_ title: String) -> NSPredicate { NSPredicate(format: "title == %@", title) }

    private var docWindow: XCUIElement {
        app!.windows.containing(Self.pageTitled("Original image page")).firstMatch
    }
    private var imagePane: XCUIElement {
        docWindow.scrollViews.containing(Self.pageTitled("Original image page")).firstMatch
    }
    /// The extracted text of a single-page PDF; its frame grows as its text does.
    private var extractedText: XCUIElement { docWindow.textViews["ar.doc.textPane"] }
    /// The right pane: the extracted text's scroll view for a single-page PDF, the OCR text page's for a two-page one.
    private var textPane: XCUIElement {
        extractedText.exists ? docWindow.scrollViews.containing(.textView, identifier: "ar.doc.textPane").firstMatch
            : docWindow.scrollViews.containing(Self.pageTitled("OCR text page")).firstMatch
    }

    private func showing(_ word: String) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            // The window is titled with the file's name, and each name carries its word.
            if docWindow.title.contains(word) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    /// A click in the text pane's empty lower right, below the short text: focus, and no selection.
    private func clickTextPane() {
        textPane.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.85)).click()
        settle()
    }

    /// The image page's AXPage node, whose frame grows with its zoom and moves on screen as the pane scrolls.
    private func pageFrame(_ title: String = "Original image page") throws -> CGRect {
        let page = docWindow.descendants(matching: .any).matching(Self.pageTitled(title)).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10), "the \(title) is in the window")
        return page.frame
    }

    /// Zoom In on the image page until it overflows its pane both ways, so every arrow has somewhere to go.
    private func zoomImageBeyondFit() throws {
        let fitted = try pageFrame().width
        for _ in 0..<20 {
            let page = try pageFrame(), pane = imagePane.frame
            if page.width > pane.width * 1.3, page.height > pane.height * 1.3 { break }
            documentMenuItem("Zoom In").click()
            settle()
        }
        let page = try pageFrame(), pane = imagePane.frame
        print("[doc-keys] image page width \(fitted) → \(page.width); page \(page) in pane \(pane)")
        XCTAssertGreaterThan(page.width, fitted + 5, "Zoom In follows the clicked image page")
        XCTAssertGreaterThan(page.width, pane.width, "the zoomed page is wider than its pane")
        XCTAssertGreaterThan(page.height, pane.height, "and taller")
    }

    /// ↓ ↑ → ← each move the page the opposite way on screen (the view moves over it), and the document stays.
    /// The page is pinned to its top after a zoom, so ↓ comes first; a second ↑ at the top moves nothing.
    private func assertArrowsPan(in word: String, screenshot: String) throws {
        let steps: [(XCUIKeyboardKey, String, String, (CGRect, CGRect) -> Bool)] = [
            (.downArrow, "↓", "down", { $1.minY < $0.minY - 5 }),
            (.upArrow, "↑", "up", { $1.minY > $0.minY + 5 }),
            (.rightArrow, "→", "right", { $1.minX < $0.minX - 5 }),
            (.leftArrow, "←", "left", { $1.minX > $0.minX + 5 }),
        ]
        for (key, name, label, moved) in steps {
            let before = try pageFrame()
            app!.typeKey(key, modifierFlags: [])
            settle()
            let after = try pageFrame()
            print("[doc-keys] \(name): page \(before.origin) → \(after.origin)")
            XCTAssertTrue(moved(before, after), "\(name) pans the zoomed image page")
            XCTAssertTrue(showing(word), "\(name) leaves the same document in view")
            captureScreenshot("\(screenshot)-panned-\(label)")
        }
        let top = try pageFrame()
        app!.typeKey(.upArrow, modifierFlags: [])
        settle()
        XCTAssertEqual(try pageFrame().minY, top.minY, accuracy: 1, "↑ at the top edge stays put")
        XCTAssertTrue(showing(word), "and does not cycle")
    }

    /// The accent border is drawn 2 pt wide just inside each pane's top edge. Each pane's edge row is compared with
    /// the row 6 pt below it, the same columns: the border makes most of them differ; without it they match.
    private func assertFocus(_ pane: Pane, _ message: String) {
        let left = borderFraction(imagePane.frame), right = borderFraction(textPane.frame)
        print("[doc-keys] border fraction: left \(left), right \(right) — expecting \(pane)")
        let (on, off) = pane == .left ? (left, right) : (right, left)
        XCTAssertGreaterThan(on, 0.6, message)
        XCTAssertLessThan(off, 0.2, "\(message) (and off the other pane)")
    }

    private func borderFraction(_ frame: CGRect) -> Double {
        let shot = XCUIScreen.main.screenshot().image
        var rect = CGRect(origin: .zero, size: shot.size)
        guard let cg = shot.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              cg.bitsPerPixel == 32, shot.size.width > 0 else { return -1 }
        let scale = CGFloat(cg.width) / shot.size.width
        let bgra = cg.bitmapInfo.contains(.byteOrder32Little)
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * cg.bytesPerRow + x * 4
            return bgra ? (Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o]))
                : (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
        }
        let edge = Int((frame.minY + 1) * scale), below = Int((frame.minY + 7) * scale)
        guard edge >= 0, below < cg.height else { return -1 }
        var differing = 0, total = 0
        for x in Int((frame.minX + 24) * scale)..<min(cg.width, Int((frame.maxX - 24) * scale)) where x >= 0 {
            let a = pixel(x, edge), b = pixel(x, below)
            if abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) > 30 { differing += 1 }
            total += 1
        }
        return total == 0 ? -1 : Double(differing) / Double(total)
    }

    // MARK: - App

    /// Launch on this suite's corpus, select its three files and open them together, so ⌘⇧↓ / ⌘⇧↑ cycle them.
    private func openAllDocuments() throws -> XCUIApplication {
        let corpus = try buildCorpus()
        let app = XCUIApplication.archiveUITestApp()   // never a bare init — see UITestLaunch
        app.launchArguments += ["-ARUITestRootPath", corpus.path,
                                "-ARUITestLibraryIndexPath", scratch.appendingPathComponent("lib.sqlite3").path]
        app.launch()
        app.activate()
        self.app = app

        let table = app.tables["ar.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 30), "the main window should come up")
        let last = table.tableRows.element(boundBy: 2)
        XCTAssertTrue(last.waitForExistence(timeout: 30), "the corpus should list its three files")
        table.tableRows.element(boundBy: 0).click()
        XCUIElement.perform(withKeyModifiers: .shift) { last.click() }
        app.typeKey("o", modifierFlags: .command)      // Open Document

        XCTAssertTrue(extractedText.waitForExistence(timeout: 20),
                      "a single-page PDF's text pane is its extracted text")
        XCTAssertTrue(imagePane.waitForExistence(timeout: 20), "the document window's image pane should come up")
        return app
    }

    private func documentMenuItem(_ title: String) -> XCUIElement {
        let bar = app!.menuBars.element(boundBy: 0)
        bar.menuBarItems["Document"].click()
        let item = bar.menuItems[title]
        _ = item.waitForExistence(timeout: 5)
        return item
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }

    // MARK: - Corpus

    /// Three PDFs, each tagged Unread so it is listed: 00001 and 00002 are single pages with a text layer, 00003 an
    /// image page and an OCR text page. Every image page carries a grid of boxes, so a pan shows in a screenshot.
    private func buildCorpus() throws -> URL {
        let corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        for (i, word) in Self.words.enumerated() {
            let url = corpus.appendingPathComponent(String(format: "%05d — Pane keys %@.pdf", i + 1, word))
            var box = CGRect(origin: .zero, size: Self.pageSize)
            let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for row in 0..<8 {
                for column in 0..<6 {
                    NSColor(calibratedHue: CGFloat(row * 6 + column) / 48, saturation: 0.5, brightness: 0.8, alpha: 1)
                        .setFill()
                    NSRect(x: 36 + column * 92, y: 60 + row * 86, width: 80, height: 74).fill()
                }
            }
            let font = NSFont.systemFont(ofSize: 36)
            if i < 2 {   // a single page: its text layer is the right pane
                NSAttributedString(string: "\(word) page text", attributes: [.font: font]).draw(at: CGPoint(x: 72, y: 720))
                // Enough lines that the extracted text overflows its pane, so its frame grows as it is zoomed.
                for line in 0..<70 {
                    NSAttributedString(string: "\(word) line \(line + 1)", attributes: [.font: NSFont.systemFont(ofSize: 8)])
                        .draw(at: CGPoint(x: 72 + CGFloat(line / 35) * 240, y: 700 - CGFloat(line % 35) * 18))
                }
                NSGraphicsContext.current = nil
                context.endPDFPage()
            } else {     // an image page, then its OCR text page
                NSGraphicsContext.current = nil
                context.endPDFPage()
                context.beginPDFPage(nil)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                NSAttributedString(string: "\(word) ocr text", attributes: [.font: font]).draw(at: CGPoint(x: 72, y: 680))
                NSGraphicsContext.current = nil
                context.endPDFPage()
            }
            context.closePDF()
            try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Unread", "1980"], forKey: .tagNamesKey)
        }
        let marker = #"{"guid":"\#(UUID().uuidString.lowercased())","name":"AR-DocPaneKeys-Fixture","#
            + #""kind":"reader","createdAt":"2026-11-12T00:00:00Z"}"#
        try Data(marker.utf8).write(to: corpus.appendingPathComponent(".archive-suite-root.json"))
        return corpus
    }
}
