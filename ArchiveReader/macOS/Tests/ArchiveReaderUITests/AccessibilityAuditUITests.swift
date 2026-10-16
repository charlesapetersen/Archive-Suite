import XCTest

/// W40.e3 — Xcode's accessibility audit (`packages/UITestSupport/Runner/AccessibilityAudit.swift`) over the
/// Reader's main screens: the navigation window with a document selected, the preview sheet, the document viewer
/// window, and Settings. One test per appearance, because contrast differs and the appearance is a launch argument.
/// Read-only: nothing here edits the fixture.
final class AccessibilityAuditUITests: FixtureUITestCase {

    func testMainScreensPassAuditInLightMode() throws {
        relaunch(LayoutGuard.lightModeArguments)
        auditMainScreens(appearance: "light")
    }

    func testMainScreensPassAuditInDarkMode() throws {
        relaunch(LayoutGuard.darkModeArguments)
        auditMainScreens(appearance: "dark")
    }

    /// `FixtureUITestCase.setUp` has already launched with the fixture; relaunch with the appearance added.
    private func relaunch(_ appearance: [String]) {
        app.terminate()
        app.launchArguments += appearance
        app.launch()
        app.activate()
        XCTAssertTrue(table.waitForExistence(timeout: 10), "Table should appear after the relaunch")
        waitForRows(minimum: 1, timeout: 15)
    }

    private func auditMainScreens(appearance: String) {
        continueAfterFailure = true   // an issue on one screen must not hide the next screen's
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        LayoutGuard.waitUntilSettled(app.windows["Archive Reader"])
        AccessibilityAudit.audit(app, screen: "navigation window, \(appearance)", in: self)

        toolbarButton("ar.toolbar.preview").click()
        let open = app.buttons["ar.preview.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the preview sheet should open")
        LayoutGuard.waitUntilSettled(app.windows["Archive Reader"])
        AccessibilityAudit.audit(app, screen: "preview sheet, \(appearance)", in: self)

        open.click()
        let viewer = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "Open in Viewer should bring up the document window")
        LayoutGuard.waitUntilSettled(viewer)
        AccessibilityAudit.audit(app, screen: "document viewer, \(appearance)", in: self)
        viewer.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5), "the viewer should close")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        LayoutGuard.waitUntilSettled(settings)
        AccessibilityAudit.audit(app, screen: "settings, \(appearance)", in: self)
    }
}
