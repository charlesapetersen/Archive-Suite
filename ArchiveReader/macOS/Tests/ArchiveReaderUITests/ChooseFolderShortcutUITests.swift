import XCTest

/// W40.fix-reader-choose-folder-shortcut — ⇧⌘O brings up Choose Archive Folder… whichever Reader window is in
/// front. Owner, Notes guided session 1 (2026-11-05, row 1): "⇧⌘O does nothing." The command was disabled
/// whenever the navigation window was not key, so over a document window it was dead.
///
/// Every panel is cancelled, so the fixture's root is never changed.
final class ChooseFolderShortcutUITests: FixtureUITestCase {

    func testShortcutFromDocumentWindow() throws {
        openDocumentWindow()
        XCTAssertTrue(menuItem("File", "Choose Archive Folder…").isEnabled,
                      "Choose Archive Folder… must be enabled with a document window in front")
        closeMenu()
        pressKey("o", modifiers: [.command, .shift])
        XCTAssertTrue(waitForPanel(), "⇧⌘O over a document window should bring up the folder panel")
        cancelPanel()
        XCTAssertTrue(app.windows["Archive Reader"].exists, "the navigation window is in front for the panel")
        XCTAssertGreaterThanOrEqual(rowCount, 1, "cancelling leaves the archive as it was")
    }

    func testShortcutAfterNavigationWindowWasClosed() throws {
        openDocumentWindow()
        let nav = app.windows["Archive Reader"]
        nav.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
        XCTAssertTrue(waitFor { !nav.exists }, "precondition: the navigation window closed")
        app.windows.firstMatch.click()   // the document window, now the only one
        pressKey("o", modifiers: [.command, .shift])
        XCTAssertTrue(waitForPanel(), "⇧⌘O should reopen the navigation window and bring up the panel")
        cancelPanel()
        XCTAssertTrue(nav.waitForExistence(timeout: 5), "the navigation window came back")
    }

    func testShortcutFromNavigationWindowStillWorks() throws {
        pressKey("o", modifiers: [.command, .shift])
        XCTAssertTrue(waitForPanel(), "⇧⌘O from the navigation window brings up the panel as before")
        cancelPanel()
    }

    // MARK: helpers

    private func openDocumentWindow() {
        waitForRows(minimum: 1, timeout: 10)
        clickRow(0)
        pressKey("o", modifiers: .command)
        XCTAssertTrue(waitFor { self.app.windows.count >= 2 }, "precondition: the document window opened")
        settle(1)
    }

    /// The panel's own button carries the prompt `NavigationModel.chooseRoot` gives it.
    private var panelButton: XCUIElement { app.buttons["Choose Common Archive Folder"].firstMatch }

    private func waitForPanel() -> Bool {
        waitFor(timeout: 8) { self.panelButton.exists || self.app.dialogs.count > 0 }
    }

    private func cancelPanel() {
        let cancel = app.dialogs.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.click() } else { app.typeKey(.escape, modifierFlags: []) }
        XCTAssertTrue(waitFor { !self.panelButton.exists && self.app.dialogs.count == 0 }, "the panel closed")
        settle(0.5)
    }

    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { settle(0.3) }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func closeMenu() { app.typeKey(.escape, modifierFlags: []); settle(0.3) }

    private func menuItem(_ menu: String, _ title: String) -> XCUIElement {
        let item = app.menuBars.element(boundBy: 0).menuBarItems[menu]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the \(menu) menu should exist")
        item.click()
        let entry = item.menuItems[title]
        _ = entry.waitForExistence(timeout: 2)
        return entry
    }
}
