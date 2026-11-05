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

        let text = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                                        sentinel, sentinel)).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 20),
                      "the document window's text pane should show the page's extracted text")

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
        let body = (0..<40).map { "\(sentinel), sentence \($0), from a single-page archival scan." }
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
