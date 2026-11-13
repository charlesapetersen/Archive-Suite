import XCTest
import AppKit

/// W40.fix-reader-copy-text-pane, in the real app (W40.fix-reader-copy-text-pane-ui). A SINGLE-page PDF — almost
/// all of the corpus — shows its text layer as plain text in the right pane. The owner found Edit ▸ Copy greyed
/// there and every copy taking the image page's text; the fix made the pane an AppKit text view and keeps one
/// live selection: selecting in one pane clears the other's, and ⌘C / ⇧⌘C take the pane that holds it.
///
/// The suite writes its own one-file corpus into a throwaway directory (the `TextZoomUITests` pattern; no real
/// corpus, no shared fixture). The page has two lines in a large font, the first ending in a hyphen, so that
/// Copy Cleaned for Prose has something to clean. Words are selected by double-click: in the text pane at its
/// first word, in the image pane at a word whose place on the page is measured from the same font. Whether the
/// text pane still shows a selection is read from the pixels of its first line against its own background.
@MainActor
final class CopyTextPaneUITests: XCTestCase {

    private var scratch: URL!
    private var app: XCUIApplication?

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let font = NSFont.systemFont(ofSize: 36)
    private static let lines: [(text: String, y: CGFloat)] = [("alpha wel-", 680), ("fare bravo", 620)]

    override func setUp() async throws {
        continueAfterFailure = false
        scratch = try WarmStartUITests.makeScratchDirectory(prefix: "AR-CopyTextPane")
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testOneLiveSelectionAndCopyFromTheTextPane() throws {
        let (app, text, window) = try openSinglePageDocument()
        app.typeKey("0", modifierFlags: .command)   // a text size another run left behind
        settle()
        let unselected = selectionPixels(in: text)
        captureScreenshot("copy-text-pane-0-open")

        // 1. A word selected in the text pane: Edit ▸ Copy is on, and ⌘C and ⇧⌘C give exactly that word.
        let firstWord = text.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: ExtractedTextInset.x + 12, dy: ExtractedTextInset.y + 8))
        firstWord.doubleClick()
        settle()
        captureScreenshot("copy-text-pane-1-text-selected")
        let selected = selectionPixels(in: text)
        print("[copy-text-pane] text pane first-line pixels: unselected \(unselected), selected \(selected)")
        XCTAssertGreaterThan(selected, unselected + 150, "the double-click selects a word in the text pane")
        let copy = editMenuItem("Copy")
        XCTAssertTrue(copy.isEnabled, "Edit ▸ Copy is enabled with a selection in the text pane")
        closeMenu()
        XCTAssertEqual(copied(by: "c", [.command]), "alpha", "⌘C copies the text pane's selection")
        XCTAssertEqual(copied(by: "c", [.command, .shift]), "alpha", "⇧⌘C copies it too, cleaned (a word is itself)")

        // 2. A word selected in the image pane: the text pane's selection is gone, and both copies take the image's.
        let imagePage = window.descendants(matching: .any)
            .matching(NSPredicate(format: "title == %@", "Original image page")).firstMatch
        XCTAssertTrue(imagePage.waitForExistence(timeout: 10), "the image pane's page is in the window")
        imagePage.coordinate(withNormalizedOffset: Self.normalizedCentre(of: "bravo", inLine: 1)).doubleClick()
        settle()
        captureScreenshot("copy-text-pane-2-image-selected")
        let afterImage = selectionPixels(in: text)
        print("[copy-text-pane] text pane first-line pixels after the image selection: \(afterImage)")
        XCTAssertLessThan(afterImage, unselected + 40, "selecting in the image pane clears the text pane's selection")
        XCTAssertTrue(editMenuItem("Copy").isEnabled, "Edit ▸ Copy is enabled with a selection in the image pane")
        closeMenu()
        XCTAssertEqual(copied(by: "c", [.command]), "bravo", "⌘C now copies the image page's word")
        XCTAssertEqual(copied(by: "c", [.command, .shift]), "bravo", "and ⇧⌘C the same")

        // 3. Cleaned really is cleaned: the whole text pane, whose first line ends in "wel-".
        app.typeKey(.rightArrow, modifierFlags: [.command, .option])   // Document ▸ Focus Text Page
        settle()
        app.typeKey("a", modifierFlags: .command)                      // Edit ▸ Select All, in the text view
        settle()
        captureScreenshot("copy-text-pane-3-text-all")
        let plain = copied(by: "c", [.command]) ?? ""
        let cleaned = copied(by: "c", [.command, .shift]) ?? ""
        print("[copy-text-pane] select all: plain \(plain.debugDescription), cleaned \(cleaned.debugDescription)")
        XCTAssertTrue(plain.contains("wel-") && plain.contains("bravo"), "⌘C copies the text as written")
        XCTAssertTrue(cleaned.contains("welfare") && !cleaned.contains("\n"),
                      "⇧⌘C joins the hyphenated word and the line")
        pressKey("w", modifiers: .command)
    }

    // MARK: - Helpers

    /// `ExtractedTextPane.inset` plus the text container's default line fragment padding, where the first glyph sits.
    private enum ExtractedTextInset { static let x: CGFloat = 16 + 5, y: CGFloat = 16 }

    /// Puts a sentinel on the pasteboard, presses the key, and returns what replaced it (nil if nothing did).
    private func copied(by key: String, _ modifiers: XCUIElement.KeyModifierFlags) -> String? {
        let sentinel = "copy-sentinel-\(UUID().uuidString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)
        app?.typeKey(key, modifierFlags: modifiers)
        let deadline = Date().addingTimeInterval(5)
        var now = NSPasteboard.general.string(forType: .string)
        while now == sentinel, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            now = NSPasteboard.general.string(forType: .string)
        }
        return now == sentinel ? nil : now
    }

    /// Where `word` sits in line `line` of the page, as a fraction of the page from its top-left corner.
    private static func normalizedCentre(of word: String, inLine line: Int) -> CGVector {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let (text, y) = lines[line]
        let start = text.range(of: word).map { String(text[..<$0.lowerBound]) } ?? ""
        let x = 72 + (start as NSString).size(withAttributes: attrs).width
            + (word as NSString).size(withAttributes: attrs).width / 2
        let midY = y + (text as NSString).size(withAttributes: attrs).height / 2
        return CGVector(dx: x / pageSize.width, dy: (pageSize.height - midY) / pageSize.height)
    }

    /// Pixels in the text pane's first line that differ from the pane's own background (read at its lower right,
    /// where the short text never reaches): glyphs alone when nothing is selected, the highlight when a word is.
    private func selectionPixels(in text: XCUIElement) -> Int {
        let shot = XCUIScreen.main.screenshot().image
        var rect = CGRect(origin: .zero, size: shot.size)
        guard let cg = shot.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              cg.bitsPerPixel == 32, shot.size.width > 0 else { return 0 }
        let scale = CGFloat(cg.width) / shot.size.width
        let bgra = cg.bitmapInfo.contains(.byteOrder32Little)
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let o = y * cg.bytesPerRow + x * 4
            return bgra ? (Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o]))
                : (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2]))
        }
        let f = text.frame
        let bx = min(cg.width - 1, Int((f.maxX - 24) * scale)), by = min(cg.height - 1, Int((f.maxY - 24) * scale))
        let bg = pixel(bx, by)
        var count = 0
        for y in Int((f.minY + ExtractedTextInset.y) * scale)..<min(cg.height, Int((f.minY + ExtractedTextInset.y + 18) * scale)) {
            for x in Int((f.minX + ExtractedTextInset.x) * scale)..<min(cg.width, Int((f.minX + 140) * scale)) where x >= 0 && y >= 0 {
                let p = pixel(x, y)
                if abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 30 { count += 1 }
            }
        }
        return count
    }

    /// Launch on this suite's one-file corpus and open its document; returns the app, the text pane and its window.
    private func openSinglePageDocument() throws -> (XCUIApplication, XCUIElement, XCUIElement) {
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

        let text = app.textViews["ar.doc.textPane"]
        XCTAssertTrue(text.waitForExistence(timeout: 20), "the document window's text pane should come up")
        XCTAssertTrue(((text.value as? String) ?? "").contains("bravo"), "the text pane shows the page's text")
        let window = app.windows.containing(.textView, identifier: "ar.doc.textPane").firstMatch
        return (app, text, window)
    }

    /// One single-page PDF whose page carries a text layer: two lines in a large font. Tagged Unread so it is listed.
    private func buildCorpus() throws -> URL {
        let corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let url = corpus.appendingPathComponent("00001 — Copy text pane.pdf")
        var box = CGRect(origin: .zero, size: Self.pageSize)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for line in Self.lines {
            NSAttributedString(string: line.text, attributes: [.font: Self.font]).draw(at: CGPoint(x: 72, y: line.y))
        }
        NSGraphicsContext.current = nil
        context.endPDFPage()
        context.closePDF()
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Unread", "1980"], forKey: .tagNamesKey)
        let marker = #"{"guid":"\#(UUID().uuidString.lowercased())","name":"AR-CopyTextPane-Fixture","#
            + #""kind":"reader","createdAt":"2026-11-12T00:00:00Z"}"#
        try Data(marker.utf8).write(to: corpus.appendingPathComponent(".archive-suite-root.json"))
        return corpus
    }

    private func editMenuItem(_ title: String) -> XCUIElement {
        let bar = app!.menuBars.element(boundBy: 0)
        bar.menuBarItems["Edit"].click()
        let item = bar.menuItems[title]
        _ = item.waitForExistence(timeout: 5)
        return item
    }

    private func closeMenu() {
        app?.typeKey(.escape, modifierFlags: [])
        settle()
    }

    private func pressKey(_ key: String, modifiers: XCUIElement.KeyModifierFlags) {
        app?.typeKey(key, modifierFlags: modifiers)
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }
}
