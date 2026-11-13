import XCTest

/// W40.reader-page-views: View ▸ Show/Hide Thumbnails (⌥⌘2, one item that toggles: W40.reader-thumbnails-toggle) and
/// Contact Sheet (⌥⌘6), across the files of a two-file selection, in the document window and the preview sheet.
/// Read-only on the fixture.
final class PageViewsUITests: FixtureUITestCase {

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private func pageViewKey(_ key: String) { pressKey(key, modifiers: [.command, .option]); settle(1) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func isCurrent(_ id: String) -> Bool { (app.buttons[id].value as? String) == "current" }
    private var selectedRows: XCUIElementQuery { table.tableRows.matching(NSPredicate(format: "isSelected == true")) }
    private func viewMenuItem(_ title: String) -> XCUIElement { app.menuBars.menuBarItems["View"].menuItems[title] }

    /// The sidebar is remembered, so a failed run could leave it up: ⌥⌘2 hides it if it is showing.
    private func hideThumbnailsIfShown(_ sidebar: XCUIElement) {
        if sidebar.exists { pageViewKey("2") }
        XCTAssertFalse(sidebar.exists)
    }

    /// Waits for a condition the app reaches asynchronously, rather than a fixed pause.
    private func wait(_ what: String, timeout: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(condition(), what)
    }

    func testThumbnailsAndTheContactSheetSpanTheOpenFiles() throws {
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        settle(0.5)
        app.typeKey(.downArrow, modifierFlags: .shift)
        wait("⇧↓ selects two files") { selectedRows.count == 2 }
        pressKey("o", modifiers: .command)
        settle(2)

        // The document window.
        let sidebar = element("ar.doc.thumbnails")
        hideThumbnailsIfShown(sidebar)
        XCTAssertTrue(viewMenuItem("Show Thumbnails").exists, "one item, named by the hidden sidebar")
        XCTAssertFalse(viewMenuItem("Hide Thumbnails").exists)
        pageViewKey("2")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "⌥⌘2 shows the thumbnails")
        XCTAssertTrue(viewMenuItem("Hide Thumbnails").exists, "and the item now hides them")
        XCTAssertFalse(viewMenuItem("Show Thumbnails").exists)
        let second = app.buttons["ar.doc.thumb.2.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5), "the second file has its thumbnail too")
        wait("the page on view is marked") { isCurrent("ar.doc.thumb.1.1") }
        settle(2)   // let the thumbnails draw before the pixel capture
        captureScreenshot("w40-page-views-thumbnails")
        print("[page-views] thumb 2.1 frame \(second.frame) hittable \(second.isHittable)")
        second.click()
        settle(1)
        captureScreenshot("w40-page-views-thumbnail-clicked")
        print("[page-views] after click: 1.1=\(String(describing: app.buttons["ar.doc.thumb.1.1"].value)) "
              + "2.1=\(String(describing: app.buttons["ar.doc.thumb.2.1"].value))")
        wait("clicking a thumbnail goes to its file") { isCurrent("ar.doc.thumb.2.1") }
        XCTAssertFalse(isCurrent("ar.doc.thumb.1.1"))

        pageViewKey("6")
        let firstTile = app.buttons["ar.doc.pageTile.1.1"]
        XCTAssertTrue(firstTile.waitForExistence(timeout: 5), "⌥⌘6 shows the contact sheet")
        XCTAssertTrue(app.buttons["ar.doc.pageTile.2.1"].exists, "with the pages of both files")
        XCTAssertFalse(sidebar.exists, "the sheet takes the sidebar's place")
        // One grid across the files, as in Preview (W40.reader-contact-sheet-grid): the second file's pages follow
        // the first file's on the same row rather than starting a row of their own.
        let secondFile = app.buttons["ar.doc.pageTile.2.1"], firstSecond = app.buttons["ar.doc.pageTile.1.2"]
        print("[page-views] sheet tiles 1.1 \(firstTile.frame) 1.2 \(firstSecond.frame) 2.1 \(secondFile.frame)")
        XCTAssertEqual(secondFile.frame.midY, firstTile.frame.midY, accuracy: 2, "the files share a row")
        XCTAssertGreaterThan(secondFile.frame.minX, firstSecond.frame.maxX, "in page order")
        settle(2)
        captureScreenshot("w40-page-views-contact-sheet")
        firstTile.click()
        settle(1)
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "a tile returns to the page, sidebar and all")
        wait("on the tile's file") { isCurrent("ar.doc.thumb.1.1") }
        pageViewKey("2")
        XCTAssertFalse(sidebar.exists, "⌥⌘2 again hides the thumbnails")
        XCTAssertTrue(viewMenuItem("Show Thumbnails").exists)
        pressKey("w", modifiers: .command)
        settle(1)

        // The preview sheet, over the same two-file selection.
        toolbarButton("ar.toolbar.preview").click()
        let done = app.buttons["ar.preview.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the preview sheet opens")
        settle(1)
        hideThumbnailsIfShown(element("ar.preview.thumbnails"))
        pageViewKey("2")
        XCTAssertTrue(element("ar.preview.thumbnails").waitForExistence(timeout: 5), "⌥⌘2 reaches the preview sheet")
        XCTAssertTrue(viewMenuItem("Hide Thumbnails").exists, "with the item named by the sheet's sidebar")
        XCTAssertTrue(app.buttons["ar.preview.thumb.2.1"].waitForExistence(timeout: 5))
        settle(2)
        captureScreenshot("w40-page-views-preview-thumbnails")
        pageViewKey("6")
        XCTAssertTrue(element("ar.preview.pageOverview").waitForExistence(timeout: 5), "and so does ⌥⌘6")
        settle(2)
        captureScreenshot("w40-page-views-preview-contact-sheet")
        pageViewKey("6")
        XCTAssertFalse(element("ar.preview.pageOverview").exists, "⌥⌘6 again leaves the contact sheet")
        XCTAssertTrue(element("ar.preview.thumbnails").waitForExistence(timeout: 5), "for the sidebar it came from")
        pageViewKey("2")
        XCTAssertFalse(element("ar.preview.thumbnails").exists, "⌥⌘2 hides the sheet's thumbnails")
        done.click()
    }
}
