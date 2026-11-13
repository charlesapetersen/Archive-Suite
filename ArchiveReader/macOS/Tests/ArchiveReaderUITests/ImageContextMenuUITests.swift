import XCTest
import AppKit

/// W40.reader-image-context-menu (owner, 2026-11-13): right-clicking the image page in the document window offers
/// Copy Image and Reveal in Finder above PDFKit's own items, and Copy Image puts the page on the pasteboard as shown,
/// turned as the viewer turns it. The fixture's PDF image page is portrait, so a quarter turn makes the copied image
/// landscape. The text page's menu does not offer them. Reveal in Finder is checked enabled but not chosen: it would
/// open a Finder window over the app. A fixture launch keeps the turns in memory only.
final class ImageContextMenuUITests: FixtureUITestCase {

    func testRightClickOnTheImageCopiesItAsShown() throws {
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
        let pdfSide = control.descendants(matching: .any).matching(NSPredicate(format: "label == 'PDF' OR title == 'PDF'")).firstMatch
        pdfSide.click()
        settle(0.5)
        let docWindow = app.windows.containing(Self.pageTitled("Original image page")).firstMatch
        let imagePane = docWindow.scrollViews.containing(Self.pageTitled("Original image page")).firstMatch
        XCTAssertTrue(imagePane.waitForExistence(timeout: 5), "the document window's image pane")

        let upright = try copyImage(from: imagePane, screenshot: "w40-image-menu-0-upright")
        XCTAssertGreaterThan(upright.height, upright.width, "the fixture's image page is portrait")

        pressKey("r", modifiers: [.command, .control])
        settle(1)
        let turned = try copyImage(from: imagePane, screenshot: "w40-image-menu-1-turned")
        print("[image-menu] copied upright \(upright), turned \(turned)")
        XCTAssertGreaterThan(turned.width, turned.height, "Copy Image takes the page as shown, turned")
        XCTAssertEqual(turned.width, upright.height, accuracy: 1, "the same image, a quarter turn")
        pressKey("l", modifiers: [.command, .control])
        settle(1)

        // The text page keeps PDFKit's own menu.
        let textPane = docWindow.scrollViews.containing(Self.pageTitled("OCR text page")).firstMatch
        if textPane.waitForExistence(timeout: 2) {
            textPane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            settle(0.5)
            captureScreenshot("w40-image-menu-2-text-pane")
            XCTAssertFalse(app.menuItems["Copy Image"].exists, "the text page offers no Copy Image")
            app.typeKey(.escape, modifierFlags: [])
            settle(0.3)
        }

        pressKey("w", modifiers: .command)
        settle(0.5)
        filterField.click()
        pressKey("a", modifiers: .command)
        app.typeKey(.delete, modifierFlags: [])
    }

    // MARK: - Helpers

    /// Right-click the pane, check both items are offered and enabled, choose Copy Image, and return the copied
    /// image's size in pixels.
    private func copyImage(from pane: XCUIElement, screenshot: String) throws -> CGSize {
        NSPasteboard.general.clearContents()
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let popup = app.menus.containing(NSPredicate(format: "title == %@", "Copy Image")).firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "right-clicking the image offers Copy Image")
        captureScreenshot(screenshot)
        let copy = popup.menuItems["Copy Image"], reveal = popup.menuItems["Reveal in Finder"]
        XCTAssertTrue(copy.isEnabled)
        XCTAssertTrue(reveal.exists, "and Reveal in Finder")
        XCTAssertTrue(reveal.isEnabled)
        copy.click()
        settle(1)
        let image = try XCTUnwrap(NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
                                  "Copy Image put an image on the pasteboard")
        let rep = try XCTUnwrap(image.representations.first)
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// PDFKit's page nodes, named by `ReaderPDFView`; the panes' own identifiers do not reach the tree.
    private static func pageTitled(_ title: String) -> NSPredicate { NSPredicate(format: "title == %@", title) }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
