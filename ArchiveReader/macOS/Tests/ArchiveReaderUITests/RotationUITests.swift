import XCTest
import AppKit

/// W40.reader-view-rotate: Rotate Left / Right (⌃⌘L / ⌃⌘R) turn the image page in the document window and the preview
/// sheet, the PDF image and the JPEG original alike, and the turn is remembered for the file. The page's extent is read
/// from screenshots: the fixture's PDF image page carries one line of black text, which runs down the pane once the
/// page is turned, and its JPEG original is solid tan and portrait, so a quarter turn trades its width and height. A fixture launch keeps the turns in memory only.
final class RotationUITests: FixtureUITestCase {

    func testRotateTurnsBothImagesAndIsRemembered() throws {
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
        let control = app.descendants(matching: .any)["ar.doc.imageSource"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        let docWindow = app.windows.containing(.any, identifier: "ar.doc.imageSource").firstMatch
        let pdfSide = control.descendants(matching: .any).matching(NSPredicate(format: "label == 'PDF' OR title == 'PDF'")).firstMatch
        let jpegSide = control.descendants(matching: .any).matching(NSPredicate(format: "label == 'JPEG' OR title == 'JPEG'")).firstMatch
        let isTan: (Int, Int, Int) -> Bool = { r, g, b in abs(r - 180) < 30 && abs(g - 160) < 30 && abs(b - 140) < 30 }
        XCTAssertTrue(app.buttons["ar.doc.rotateRight"].waitForExistence(timeout: 5), "the toolbar has Rotate Right")

        // Start on the PDF, upright, zoomed out so the whole page sits inside the pane at a fixed scale.
        pdfSide.click()
        let reset = documentMenuItem("Reset Rotation")   // a failed run leaves the remembered turn behind
        if reset.isEnabled { reset.click() } else { closeMenu() }
        pressKey("0", modifiers: [.command, .option])
        settle(0.5)
        let zoomOut = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
                                                       "ar.doc.imageZoomOut", "Zoom Out Image")).firstMatch
        zoomOut.click(); zoomOut.click()
        settle(1)
        captureScreenshot("w40-rotate-0-upright")
        // The PDF page is white on a pane as light as it, so its one line of text is what shows the turn.
        let line = inkBounds(in: docWindow)
        XCTAssertGreaterThan(line.width, line.height * 3, "upright, the page's text line runs across")
        jpegSide.click()
        settle(1)
        let jpegUpright = pageExtent(in: docWindow, isTan)
        XCTAssertGreaterThan(jpegUpright.height, jpegUpright.width, "the fixture's JPEG is portrait")
        pdfSide.click()
        settle(0.5)

        pressKey("r", modifiers: [.command, .control])
        settle(1)
        captureScreenshot("w40-rotate-1-right")
        let turnedLine = inkBounds(in: docWindow)
        print("[view-rotate] PDF text line upright \(line), turned \(turnedLine)")
        XCTAssertGreaterThan(turnedLine.height, turnedLine.width * 3, "⌃⌘R turns the page: its text line runs down")
        XCTAssertEqual(turnedLine.height, line.width, accuracy: line.width * 0.05, "a quarter turn, at the same size")
        let resetTurned = documentMenuItem("Reset Rotation")
        XCTAssertTrue(resetTurned.isEnabled, "a turned page can be reset")
        closeMenu()

        jpegSide.click()
        settle(1)
        captureScreenshot("w40-rotate-2-jpeg")
        let jpeg = pageExtent(in: docWindow, isTan)
        print("[view-rotate] JPEG upright \(jpegUpright), turned \(jpeg)")
        XCTAssertEqual(jpeg.width, jpegUpright.height, accuracy: jpegUpright.height * 0.03,
                       "the JPEG original is turned with the PDF's image page")
        XCTAssertEqual(jpeg.height, jpegUpright.width, accuracy: jpegUpright.width * 0.03)
        pdfSide.click()
        settle(0.5)

        // Remembered for the file: close the window and open it again.
        pressKey("w", modifiers: .command)
        settle(0.5)
        clickRow(0)
        pressKey("o", modifiers: .command)
        settle(2)
        let reopened = inkBounds(in: docWindow)
        XCTAssertGreaterThan(reopened.height, reopened.width * 3, "the turn is remembered when the file is opened again")

        // ⌃⌘L turns it back, and Reset Rotation then has nothing to do.
        pressKey("l", modifiers: [.command, .control])
        settle(1)
        let back = inkBounds(in: docWindow)
        XCTAssertGreaterThan(back.width, back.height * 3, "⌃⌘L turns it back upright")
        XCTAssertFalse(documentMenuItem("Reset Rotation").isEnabled, "an upright page has nothing to reset")
        closeMenu()
        pressKey("0", modifiers: [.command, .option])
        settle(0.5)
        pressKey("w", modifiers: .command)
        settle(0.5)

        // The preview sheet takes the same keys, and shows the same remembered turn.
        clickRow(0)
        toolbarButton("ar.toolbar.preview").click()
        XCTAssertTrue(app.buttons["ar.preview.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ar.preview.rotateLeft"].exists, "the preview has Rotate Left")
        pressKey("l", modifiers: [.command, .control])
        settle(1)
        captureScreenshot("w40-rotate-3-preview-left")
        let resetInPreview = documentMenuItem("Reset Rotation")
        XCTAssertTrue(resetInPreview.isEnabled, "⌃⌘L turned the preview's page")
        resetInPreview.click()
        settle(0.5)
        XCTAssertFalse(documentMenuItem("Reset Rotation").isEnabled, "Reset Rotation shows it as it is in the file")
        closeMenu()
        app.buttons["ar.preview.done"].click()
        settle(0.5)

        filterField.click()
        pressKey("a", modifiers: .command)
        app.typeKey(.delete, modifierFlags: [])
    }

    // MARK: - Helpers

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func closeMenu() {
        app.typeKey(.escape, modifierFlags: [])
        settle(0.3)
    }

    private func documentMenuItem(_ title: String) -> XCUIElement {
        let bar = app.menuBars.element(boundBy: 0)
        let document = bar.menuBarItems["Document"]
        XCTAssertTrue(document.waitForExistence(timeout: 5), "the Document menu should exist")
        document.click()
        let item = bar.menuItems[title]
        _ = item.waitForExistence(timeout: 5)
        return item
    }

    /// The bounding box, in screen points, of the dark pixels in the document window's image pane (the left ⅔ of
    /// the split, below the toolbar and above the status bar), read from a screenshot.
    private func inkBounds(in window: XCUIElement) -> CGSize {
        let shot = XCUIScreen.main.screenshot().image
        var rect = CGRect(origin: .zero, size: shot.size)
        guard let cg = shot.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              cg.bitsPerPixel == 32, shot.size.width > 0 else { return .zero }
        let scale = CGFloat(cg.width) / shot.size.width
        let f = window.frame
        var x0 = Int.max, x1 = Int.min, y0 = Int.max, y1 = Int.min
        for y in stride(from: max(0, Int((f.minY + 60) * scale)), to: min(cg.height, Int((f.maxY - 30) * scale)), by: 1) {
            for x in stride(from: max(0, Int((f.minX + 4) * scale)), to: min(cg.width, Int((f.minX + f.width * 0.65) * scale)), by: 1) {
                let o = y * cg.bytesPerRow + x * 4
                guard bytes[o] < 90, bytes[o + 1] < 90, bytes[o + 2] < 90 else { continue }
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x0 <= x1 else { return .zero }
        return CGSize(width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale)
    }

    /// The width and height, in screen points, of the run of pixels passing `match` through the middle of the
    /// document window's image pane (the left ⅔ of the split, below the toolbar), read from a screenshot.
    /// As `ViewerUITests.pageExtent`.
    private func pageExtent(in window: XCUIElement, _ match: (Int, Int, Int) -> Bool) -> CGSize {
        let shot = XCUIScreen.main.screenshot().image
        var rect = CGRect(origin: .zero, size: shot.size)
        guard let cg = shot.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              cg.bitsPerPixel == 32, shot.size.width > 0 else { return .zero }
        let scale = CGFloat(cg.width) / shot.size.width
        let f = window.frame
        let bgra = cg.bitmapInfo.contains(.byteOrder32Little)
        func hit(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return false }
            let o = y * cg.bytesPerRow + x * 4
            let (r, g, b) = bgra ? (bytes[o + 2], bytes[o + 1], bytes[o]) : (bytes[o], bytes[o + 1], bytes[o + 2])
            return match(Int(r), Int(g), Int(b))
        }
        let left = Int((f.minX + 4) * scale), right = Int((f.minX + f.width * 0.65) * scale)
        let top = Int((f.minY + 60) * scale), bottom = Int((f.maxY - 30) * scale)
        let midX = (left + right) / 2, midY = (top + bottom) / 2
        let row = (left...right).filter { hit($0, midY) }, column = (top...bottom).filter { hit(midX, $0) }
        guard let x0 = row.first, let x1 = row.last, let y0 = column.first, let y1 = column.last else { return .zero }
        return CGSize(width: CGFloat(x1 - x0 + 1) / scale, height: CGFloat(y1 - y0 + 1) / scale)
    }
}
