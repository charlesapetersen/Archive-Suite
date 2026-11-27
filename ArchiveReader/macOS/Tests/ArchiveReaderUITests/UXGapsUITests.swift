import XCTest

/// W49.reader-ux-gaps-small — the pre-user-testing gaps, in the real window: Library health's Show for Both Read +
/// Unread, the sidebar folder's right-click menu, File ▸ Open Recent and Settings' Add Folder…. Writes no file: the
/// Container Levels sheet is cancelled.
final class UXGapsUITests: FixtureUITestCase {

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { settle(0.25) }
        return condition()
    }

    private var folders: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "ar.sidebar.folder")
    }

    private func showSidebar() {
        let allFiles = app.staticTexts.matching(identifier: "ar.sidebar.allFiles").firstMatch
        if !allFiles.exists { toolbarButton("ar.toolbar.sidebar").click() }
        XCTAssertTrue(allFiles.waitForExistence(timeout: 5))
    }

    private func menuItem(titled title: String) -> XCUIElement? {
        app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable }
    }

    func testLibraryHealthOffersShowForBothReadAndUnread() {
        let health = app.descendants(matching: .any)["ar.status.health"]
        XCTAssertTrue(health.waitForExistence(timeout: 10))
        health.click()
        let show = app.descendants(matching: .any)["ar.health.bothReadStates"]
        XCTAssertTrue(show.waitForExistence(timeout: 5), "the corrupt-read-state count has its own Show")
        // The fixture has no file tagged both, so the Show is there and off, as the other counts' are at zero.
        XCTAssertFalse(show.isEnabled, "nothing to show in the fixture")
        captureScreenshot("w49-health-both-read-states")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testTheSidebarFolderMenuOffersRevealExcludeAndContainerLevels() throws {
        waitForRows(minimum: 2, timeout: 10)
        showSidebar()
        let folder = folders.firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), "the fixture has a folder")
        let before = folders.count
        let everything = rowCount
        let name = folder.label
        folder.rightClick()
        settle(0.8)
        for title in ["Reveal in Finder", "Exclude Folder", "Container Levels…"] {
            XCTAssertNotNil(menuItem(titled: title), "the folder's menu offers \(title)")
        }
        captureScreenshot("w49-sidebar-folder-menu")
        // Container Levels… opens on the folder clicked, which the list goes to first. Exclude Folder is not
        // chosen here: it would prune the shared fixture's content index for the later tests
        // (`NavigationModel.excludeFolder` is covered in ReaderUXGapsTests).
        try XCTUnwrap(menuItem(titled: "Container Levels…")).click()
        let cancel = app.buttons["ar.containerLevels.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the Container Levels sheet opens (\(name))")
        XCTAssertTrue(waitFor { self.rowCount < everything }, "the list went to the folder clicked")
        captureScreenshot("w49-sidebar-folder-container-levels")
        cancel.click()
        XCTAssertTrue(waitFor { !cancel.exists }, "and the sheet closes, writing nothing")
        XCTAssertEqual(folders.count, before)
    }

    func testFileMenuOffersOpenRecent() {
        let file = app.menuBars.element(boundBy: 0).menuBarItems["File"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.click()
        let recent = file.menuItems["Open Recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 3), "File offers Open Recent")
        recent.hover()
        let clear = recent.menuItems["Clear Menu"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3), "its submenu ends with Clear Menu")
        XCTAssertFalse(clear.isEnabled, "nothing to clear: a fixture launch records no recent folder")
        XCTAssertTrue(recent.menuItems["No Recent Folders"].exists, "an empty list says so")
        captureScreenshot("w49-file-open-recent")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsAddFolderIsOnWithAFolderOpen() {
        app.typeKey(",", modifierFlags: .command)
        let add = app.buttons["ar.settings.excludedFolders.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "Settings ▸ Excluded folders has Add Folder…")
        XCTAssertTrue(add.isEnabled, "with the fixture folder open it can add one")
        captureScreenshot("w49-settings-add-folder")
        app.typeKey("w", modifierFlags: .command)
    }
}
