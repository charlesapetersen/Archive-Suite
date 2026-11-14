import XCTest

/// W40.fix-reader-smart-folder-delete (owner, 2026-11-13: "Deleting a smart folder led to beach ball."): a smart
/// folder deleted from the sidebar's menu while it is open, and one deleted while All Files is shown and another
/// folder stays. Each leaves the sidebar, the list shows what it should, and the window answers a click. (The
/// toolbar's Saved ▸ Delete calls the same `deleteSmartFolder`, which `SmartFolderDeleteTests` covers at size.)
/// Writes no file: a smart folder is app defaults only, and the test deletes the ones it made.
final class SmartFolderDeleteUITests: FixtureUITestCase {
    private let prefix = "SFDelete UITest"

    override func tearDown() async throws {
        if app != nil {
            app.typeKey(.escape, modifierFlags: [])
            deleteLeftovers()
        }
        try await super.tearDown()
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func smartFolder(_ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ar.sidebar.smart")
            .matching(NSPredicate(format: "label == %@", name)).firstMatch
    }

    private func waitForRowCount(_ expected: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while rowCount != expected, Date() < deadline { settle(0.25) }
        return rowCount == expected
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline { settle(0.1) }
        return !element.exists
    }

    /// File ▸ Save Current Search…, under `name`.
    private func saveCurrentSearch(as name: String) throws {
        let save = app.menuBars.menuBarItems["File"].menuItems["Save Current Search…"]
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(save.waitForExistence(timeout: 3), "File offers Save Current Search…")
        save.click()
        let field = app.textFields["ar.saveSearch.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the Save Search sheet opens")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        app.buttons["ar.saveSearch.save"].click()
        XCTAssertTrue(smartFolder(name).waitForExistence(timeout: 5), "the sidebar lists \(name)")
    }

    /// The folder's sidebar menu ▸ Delete.
    private func deleteFromSidebar(_ name: String) throws {
        smartFolder(name).rightClick()
        settle(0.8)
        let delete = app.menuItems.matching(NSPredicate(format: "title == %@", "Delete"))
            .allElementsBoundByIndex.first { $0.isHittable }
        try XCTUnwrap(delete, "the smart folder's menu offers Delete").click()
    }

    /// The window answers: Advanced Search's form opens and closes. The timeouts allow for the VM's slow
    /// accessibility queries (about 2.8 s for the round trip), not for a stall.
    private func assertResponsive(_ when: String) {
        let start = Date()
        app.buttons["ar.filter.advanced"].click()
        let count = app.staticTexts["ar.advanced.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5), "\(when): the window answers a click")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitGone(count, timeout: 5), "\(when): and closes the form again")
        print("[sfdel] \(when): a click answered in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    }

    func testDeletingSmartFoldersLeavesTheWindowResponsive() throws {
        waitForRows(minimum: 2, timeout: 15)
        deleteLeftovers()
        let allFiles = app.staticTexts.matching(identifier: "ar.sidebar.allFiles").firstMatch
        if !allFiles.exists { toolbarButton("ar.toolbar.sidebar").click() }
        XCTAssertTrue(allFiles.waitForExistence(timeout: 5))
        allFiles.click()
        settle(0.5)
        let all = rowCount

        // 1. The open one, from the sidebar's own menu, as the owner did.
        let open = "\(prefix) open"
        try saveCurrentSearch(as: open)
        smartFolder(open).click()
        settle(0.5)
        try deleteFromSidebar(open)
        let start = Date()
        XCTAssertTrue(waitGone(smartFolder(open), timeout: 3), "the deleted folder leaves the sidebar")
        XCTAssertTrue(waitForRowCount(all, timeout: 3), "the list shows All Files again")
        print("[sfdel] open folder deleted and the list back in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        assertResponsive("after deleting the open folder")
        _ = captureScreenshot("w40-smart-folder-deleted-open")

        // 2. One not open, while All Files is shown and another folder stays.
        let kept = "\(prefix) kept", other = "\(prefix) other"
        try saveCurrentSearch(as: kept)
        try saveCurrentSearch(as: other)
        allFiles.click()
        settle(0.5)
        try deleteFromSidebar(other)
        XCTAssertTrue(waitGone(smartFolder(other), timeout: 3), "the deleted folder leaves the sidebar")
        XCTAssertTrue(smartFolder(kept).exists, "the other folder stays")
        XCTAssertEqual(rowCount, all, "the list is unchanged")
        assertResponsive("after deleting a folder not open")
    }

    /// Every folder this test names, through the sidebar's menu. Never asserts: it also runs from tearDown.
    private func deleteLeftovers() {
        let mine = app.descendants(matching: .any).matching(identifier: "ar.sidebar.smart")
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
        for _ in 0..<6 where mine.count > 0 {
            mine.firstMatch.rightClick()
            settle(0.8)
            let delete = app.menuItems.matching(NSPredicate(format: "title == %@", "Delete"))
                .allElementsBoundByIndex.first { $0.isHittable }
            if let delete { delete.click() } else { app.typeKey(.escape, modifierFlags: []); return }
            settle(0.5)
        }
    }
}
