import XCTest
import AppKit

/// W40.fix-reader-text-zoom, in the real app: a SINGLE-page PDF — almost all of the corpus — whose right pane
/// is its text layer as plain text. The owner focused that pane and chose Zoom In, and nothing changed.
/// The shared fixture's PDFs all have two pages, so this suite writes its own one-file corpus into a
/// throwaway directory (the `WarmStartUITests` pattern; no real corpus, no shared fixture).
///
/// A text's on-screen frame is what its size does to the layout: the same text at a fixed pane width
/// wraps onto more lines as it grows, so its frame gets taller. Screenshots bracket the sequence for a
/// human to read; the frames are what the test judges.
@MainActor
final class TextZoomUITests: XCTestCase {

    private var scratch: URL!
    private var app: XCUIApplication?
    private let sentinel = "Zoomable extracted text"

    override func setUp() async throws {
        continueAfterFailure = false
        scratch = try WarmStartUITests.makeScratchDirectory(prefix: "AR-TextZoom")
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testZoomKeysResizeTheExtractedTextOfASinglePagePDF() throws {
        let (app, text) = try openSinglePageDocument()

        app.typeKey(.rightArrow, modifierFlags: [.command, .option])   // Document ▸ Focus Text Page
        app.typeKey("0", modifierFlags: .command)                      // a size another run left behind
        settle()
        let base = text.frame.height
        captureScreenshot("w40textzoom-1-default")

        app.typeKey("+", modifierFlags: .command)        // the menu's ⌘+
        settle()
        let plus = text.frame.height
        XCTAssertGreaterThan(plus, base, "⌘+ on the focused text pane should enlarge its text")

        app.typeKey("=", modifierFlags: .command)        // ⌘+ without Shift
        settle()
        let equals = text.frame.height
        XCTAssertGreaterThan(equals, plus, "⌘= should zoom in too")

        app.typeKey(.upArrow, modifierFlags: .command)   // the older ⌘↑
        settle()
        let up = text.frame.height
        XCTAssertGreaterThan(up, equals, "⌘↑ should still zoom in")
        captureScreenshot("w40textzoom-2-zoomed-in")

        app.typeKey("-", modifierFlags: .command)
        settle()
        XCTAssertLessThan(text.frame.height, up, "⌘− should shrink it")

        app.typeKey("0", modifierFlags: .command)        // Fit Page resets the text size
        settle()
        XCTAssertEqual(text.frame.height, base, accuracy: 1, "⌘0 should return it to the default size")
        captureScreenshot("w40textzoom-3-after-cmd0")
    }

    /// W40.fix-reader-doc-toolbar, reader-1 rows 10 and 11: the toolbar's second pair of magnifying glasses
    /// (the text pane's zoom) and its Fit arrows appeared to do nothing. The text pair now shows text-size
    /// glyphs and sizes a one-page PDF's text; the per-pane Fit buttons are gone, and Reset Zoom, which did
    /// what both did, is disabled while there is nothing to reset, so no live control has no visible effect.
    func testToolbarZoomButtonsActAndResetZoomIsLiveOnlyWhenItCanAct() throws {
        let (app, text) = try openSinglePageDocument()
        let toolbarButton: (String, String) -> XCUIElement = { id, label in
            app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", id, label)).firstMatch
        }
        let larger = toolbarButton("ar.doc.textZoomIn", "Larger Text")
        let smaller = toolbarButton("ar.doc.textZoomOut", "Smaller Text")
        let imageIn = toolbarButton("ar.doc.imageZoomIn", "Zoom In Image")
        let reset = toolbarButton("ar.doc.resetZoom", "Reset Zoom")
        for (button, name) in [(larger, "Larger Text"), (smaller, "Smaller Text"), (imageIn, "Zoom In Image"),
                               (reset, "Reset Zoom")] {
            XCTAssertTrue(button.waitForExistence(timeout: 5), "the document toolbar should carry \(name)")
        }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Fit '")).count, 0,
                       "the per-pane Fit buttons are gone from the toolbar")

        if reset.isEnabled { reset.click(); settle() }   // a zoom another run left behind
        XCTAssertFalse(reset.isEnabled, "with both pages fitted and the text at its normal size, Reset Zoom is disabled")
        let base = text.frame.height
        captureScreenshot("w40doctoolbar-1-default")

        larger.click()
        settle()
        XCTAssertGreaterThan(text.frame.height, base, "Larger Text should enlarge a one-page PDF's text")
        XCTAssertTrue(reset.isEnabled, "once the text is resized, Reset Zoom has something to do")
        captureScreenshot("w40doctoolbar-2-larger-text")
        smaller.click(); smaller.click()
        settle()
        XCTAssertLessThan(text.frame.height, base, "Smaller Text should shrink it below the normal size")

        reset.click()
        settle()
        XCTAssertEqual(text.frame.height, base, accuracy: 1, "Reset Zoom returns the text to its normal size")
        XCTAssertFalse(reset.isEnabled, "and is disabled again")

        imageIn.click()
        settle()
        XCTAssertTrue(reset.isEnabled, "zooming the image page also gives Reset Zoom something to do")
        captureScreenshot("w40doctoolbar-3-image-zoomed")
        app.typeKey("0", modifierFlags: [.command, .option])   // ⌥⌘0, Reset Zoom's shortcut
        settle()
        XCTAssertFalse(reset.isEnabled, "⌥⌘0 fits the image page again")
    }

    /// Launch on this suite's one-file corpus and open its document; returns the app and the text pane's text.
    private func openSinglePageDocument() throws -> (XCUIApplication, XCUIElement) {
        let corpus = try buildCorpus()
        let app = XCUIApplication.archiveUITestApp()   // never a bare init — see UITestLaunch
        app.launchArguments += ["-ARUITestRootPath", corpus.path,
                                "-ARUITestLibraryIndexPath", scratch.appendingPathComponent("lib.sqlite3").path]
        app.launch()
        app.activate()
        self.app = app

        let table = app.tables["ar.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 30), "the main window should come up")
        let row = table.tableRows.element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the one-file corpus should list its file")
        row.click()
        app.typeKey("o", modifierFlags: .command)   // Open Document

        // The text pane itself, by its identifier: on macOS 27 PDFKit also exposes the image page's own text
        // as a static text, which a query by content found first, and text zoom never changes that one.
        let text = app.textViews["ar.doc.textPane"]
        XCTAssertTrue(text.waitForExistence(timeout: 20), "the document window's text pane should come up")
        XCTAssertTrue(((text.value as? String) ?? "").contains(sentinel),
                      "the text pane should show the page's extracted text")
        return (app, text)
    }

    // MARK: - Corpus

    /// One single-page PDF whose page carries a text layer (drawn text), tagged Unread so it is listed.
    private func buildCorpus() throws -> URL {
        let corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let url = corpus.appendingPathComponent("00001 — Single page.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        // Long enough to run past the pane at every size the tests reach (two steps smaller included): the
        // text view is as tall as its text only once the text overflows the pane.
        let body = (0..<80).map { "\(sentinel), sentence \($0), from a single-page archival scan." }
            .joined(separator: " ")
        NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 11)])
            .draw(in: box.insetBy(dx: 36, dy: 36))
        NSGraphicsContext.current = nil
        context.endPDFPage()
        context.closePDF()
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Unread", "1980"], forKey: .tagNamesKey)
        let marker = #"{"guid":"\#(UUID().uuidString.lowercased())","name":"AR-TextZoom-Fixture","#
            + #""kind":"reader","createdAt":"2026-11-04T00:00:00Z"}"#
        try Data(marker.utf8).write(to: corpus.appendingPathComponent(".archive-suite-root.json"))
        return corpus
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }
}
