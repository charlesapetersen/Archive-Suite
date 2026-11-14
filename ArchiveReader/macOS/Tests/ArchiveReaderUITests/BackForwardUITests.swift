import XCTest

/// W40.reader-back-forward: Go ▸ Back and Forward (⌘[ / ⌘]) through the navigation window's folders, with the
/// toolbar's buttons as in Finder, and through a document window's page jumps, as in Preview. Read-only on the
/// fixture.
final class BackForwardUITests: FixtureUITestCase {

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func isCurrent(_ id: String) -> Bool { (app.buttons[id].value as? String) == "current" }
    private var selectedRows: XCUIElementQuery { table.tableRows.matching(NSPredicate(format: "isSelected == true")) }
    private func goItem(_ title: String) -> XCUIElement { app.menuBars.menuBarItems["Go"].menuItems[title] }

    private func waitForRowCount(_ expected: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while table.tableRows.count != expected, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return table.tableRows.count == expected
    }

    private func wait(_ what: String, timeout: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(condition(), what)
    }

    func testBackAndForwardRetraceTheFoldersWithTheirSelection() throws {
        waitForRows(minimum: 5, timeout: 10)
        let allFiles = app.staticTexts.matching(identifier: "ar.sidebar.allFiles").firstMatch
        if !allFiles.exists { toolbarButton("ar.toolbar.sidebar").click() }
        XCTAssertTrue(allFiles.waitForExistence(timeout: 5))
        allFiles.click()
        settle(1)
        let everything = table.tableRows.count
        XCTAssertGreaterThan(everything, 1)

        let folder = app.descendants(matching: .any).matching(identifier: "ar.sidebar.folder").firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.click()
        XCTAssertTrue(waitForRowCount(1), "Box 2 contains one fixture file")
        clickRow(0)
        wait("the folder's file is selected") { selectedRows.count == 1 }

        let back = toolbarButton("ar.toolbar.back"), forward = toolbarButton("ar.toolbar.forward")
        XCTAssertTrue(back.isEnabled, "the toolbar's Back is live after a move")
        XCTAssertTrue(goItem("Back").isEnabled)
        captureScreenshot("w40-back-forward-toolbar")

        pressKey("[", modifiers: .command)
        XCTAssertTrue(waitForRowCount(everything), "⌘[ returns to All Files")
        wait("Forward is live after going back") { forward.isEnabled }

        pressKey("]", modifiers: .command)
        XCTAssertTrue(waitForRowCount(1), "⌘] returns to the folder")
        wait("with its file selected again, as in Finder") { selectedRows.count == 1 }
        XCTAssertFalse(forward.isEnabled, "Forward stops at the last folder")

        back.click()
        XCTAssertTrue(waitForRowCount(everything), "the toolbar's Back goes back too")
        forward.click()
        XCTAssertTrue(waitForRowCount(1), "and its Forward forward")
    }

    func testBackAndForwardRetraceAThumbnailJumpInTheDocumentWindow() throws {
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        settle(0.5)
        app.typeKey(.downArrow, modifierFlags: .shift)
        wait("⇧↓ selects two files") { selectedRows.count == 2 }
        pressKey("o", modifiers: .command)
        settle(2)

        let sidebar = element("ar.doc.thumbnails")
        if !sidebar.exists { pressKey("2", modifiers: [.command, .option]) }
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "the thumbnails are showing")
        wait("the first file is on view") { isCurrent("ar.doc.thumb.1.1") }
        XCTAssertFalse(goItem("Back").isEnabled, "nothing to go back to yet")

        let second = app.buttons["ar.doc.thumb.2.1"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        second.click()
        wait("a thumbnail jumps to the second file") { isCurrent("ar.doc.thumb.2.1") }

        pressKey("[", modifiers: .command)
        wait("⌘[ returns to the page the jump left") { isCurrent("ar.doc.thumb.1.1") }
        XCTAssertTrue(goItem("Forward").isEnabled)
        pressKey("]", modifiers: .command)
        wait("⌘] goes to it again") { isCurrent("ar.doc.thumb.2.1") }
        XCTAssertFalse(goItem("Forward").isEnabled, "Forward stops at the last jump")
        captureScreenshot("w40-back-forward-document")

        pressKey("2", modifiers: [.command, .option])   // leave the remembered sidebar as other tests expect
        pressKey("w", modifiers: .command)
        settle(1)
    }
}
