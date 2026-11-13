import XCTest
import AppKit

/// W40.reader-image-invert: View ▸ Invert Image Colors (⌃⌘I) draws the image page dark, in the document window and
/// the preview sheet, and each window remembers it. The pane's filter is a Core Animation layer filter that the unit
/// lane cannot draw, so the brightness of the image pane is read from screenshots here: the fixture's PDF image page
/// is white with one line of black text, on the light grey pane.
final class InvertImagesUITests: FixtureUITestCase {

    func testInvertImageColorsDarkensTheImagePaneAndIsRemembered() throws {
        waitForRows(minimum: 3, timeout: 10)
        let filterField = app.textFields["ar.filter.name"]
        XCTAssertTrue(filterField.waitForExistence(timeout: 5))
        filterField.click()
        filterField.typeText("00001 IMG")
        settle(1)
        XCTAssertEqual(rowCount, 1, "the scratch GUI fixture has one PDF with a JPEG partner")

        clickRow(0)
        pressKey("o", modifiers: .command)
        settle(2)
        let pane = imagePane
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        let control = app.descendants(matching: .any)["ar.doc.imageSource"].firstMatch
        let pdfSide = control.descendants(matching: .any).matching(NSPredicate(format: "label == 'PDF' OR title == 'PDF'")).firstMatch
        if pdfSide.exists { pdfSide.click(); settle(1) }
        XCTAssertTrue(app.descendants(matching: .any)["ar.doc.invertImages"].exists, "the toolbar has Invert Image Colors")
        let bar = app.menuBars.element(boundBy: 0)
        bar.menuBarItems["View"].click()
        XCTAssertTrue(bar.menuItems["Invert Image Colors"].waitForExistence(timeout: 5), "the View menu has the item")
        app.typeKey(.escape, modifierFlags: [])
        settle(0.3)

        // A failed run may leave the window's setting on: start from the plain page.
        var plain = brightness(of: pane)
        if plain < 0.5 { pressKey("i", modifiers: [.command, .control]); settle(1); plain = brightness(of: pane) }
        captureScreenshot("w40-image-invert-0-plain")
        XCTAssertGreaterThan(plain, 0.6, "the plain page and its pane are light")

        pressKey("i", modifiers: [.command, .control])
        settle(1.5)
        captureScreenshot("w40-image-invert-1-inverted")
        let dark = brightness(of: pane)
        print("[image-invert] image pane brightness plain \(plain), inverted \(dark)")
        XCTAssertLessThan(dark, 0.3, "⌃⌘I draws the image page and its pane dark")
        XCTAssertGreaterThan(lightPixels(of: pane), 3, "the page's black text line shows light")

        // Remembered by the window: close it and open the file again.
        pressKey("w", modifiers: .command)
        settle(0.5)
        clickRow(0)
        pressKey("o", modifiers: .command)
        settle(2)
        let reopened = imagePane
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertLessThan(brightness(of: reopened), 0.3, "the document window remembers the setting")

        // The toolbar button turns it off again.
        app.descendants(matching: .any)["ar.doc.invertImages"].firstMatch.click()
        settle(1.5)
        XCTAssertGreaterThan(brightness(of: reopened), 0.6, "the toolbar button turns it off")
        pressKey("w", modifiers: .command)
        settle(0.5)

        // The preview sheet has its own setting and the same key.
        clickRow(0)
        toolbarButton("ar.toolbar.preview").click()
        XCTAssertTrue(app.buttons["ar.preview.done"].waitForExistence(timeout: 5))
        let previewPane = imagePane
        XCTAssertTrue(previewPane.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["ar.preview.invertImages"].exists, "the preview has the button")
        settle(1)
        var previewPlain = brightness(of: previewPane)
        if previewPlain < 0.5 { pressKey("i", modifiers: [.command, .control]); settle(1); previewPlain = brightness(of: previewPane) }
        pressKey("i", modifiers: [.command, .control])
        settle(1.5)
        captureScreenshot("w40-image-invert-2-preview")
        let previewDark = brightness(of: previewPane)
        print("[image-invert] preview pane brightness plain \(previewPlain), inverted \(previewDark)")
        XCTAssertGreaterThan(previewPlain, 0.6)
        XCTAssertLessThan(previewDark, 0.3, "⌃⌘I reaches the preview sheet")
        pressKey("i", modifiers: [.command, .control])
        settle(0.5)
        app.buttons["ar.preview.done"].click()
        settle(0.5)

        filterField.click()
        pressKey("a", modifiers: .command)
        app.typeKey(.delete, modifierFlags: [])
    }

    // MARK: - Helpers

    /// The image page's scroll view, in the document window or the preview sheet: PDFKit's page node carries the
    /// pane's title, not its identifier (as `DocumentPaneKeysUITests.imagePane`).
    private var imagePane: XCUIElement {
        app.scrollViews.containing(NSPredicate(format: "title == %@", "Original image page")).firstMatch
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// The pixels of an element's frame in a screenshot, as (r, g, b) 0…255, every fourth pixel each way.
    private func samples(of element: XCUIElement) -> [(Int, Int, Int)] {
        let shot = XCUIScreen.main.screenshot().image
        var rect = CGRect(origin: .zero, size: shot.size)
        guard let cg = shot.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              cg.bitsPerPixel == 32, shot.size.width > 0 else { return [] }
        let scale = CGFloat(cg.width) / shot.size.width
        let f = element.frame.insetBy(dx: 6, dy: 6)
        let bgra = cg.bitmapInfo.contains(.byteOrder32Little)
        var out: [(Int, Int, Int)] = []
        for y in stride(from: max(0, Int(f.minY * scale)), to: min(cg.height, Int(f.maxY * scale)), by: 4) {
            for x in stride(from: max(0, Int(f.minX * scale)), to: min(cg.width, Int(f.maxX * scale)), by: 4) {
                let o = y * cg.bytesPerRow + x * 4
                out.append(bgra ? (Int(bytes[o + 2]), Int(bytes[o + 1]), Int(bytes[o]))
                                : (Int(bytes[o]), Int(bytes[o + 1]), Int(bytes[o + 2])))
            }
        }
        return out
    }

    /// The mean brightness of the element's pixels, 0…1.
    private func brightness(of element: XCUIElement) -> Double {
        let pixels = samples(of: element)
        guard !pixels.isEmpty else { return -1 }
        return pixels.reduce(0.0) { $0 + Double($1.0 + $1.1 + $1.2) / 765 } / Double(pixels.count)
    }

    /// How many sampled pixels are light: the text line once inverted.
    private func lightPixels(of element: XCUIElement) -> Int {
        samples(of: element).filter { $0.0 > 150 && $0.1 > 150 && $0.2 > 150 }.count
    }
}
