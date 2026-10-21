import XCTest

/// W40.e9 — the layout guard (`packages/UITestSupport/LayoutGuard.swift`) over the Reader's main screens: the
/// navigation window with a document selected, the preview sheet, and the document viewer window. Each at its
/// typical and minimum size, on open and once settled; one test per appearance, because the appearance is a
/// launch argument.
final class LayoutGuardUITests: FixtureUITestCase {

    func testMainScreensLayOutInLightMode() throws {
        relaunch(LayoutGuard.lightModeArguments)
        sweepMainScreens(appearance: "light")
    }

    func testMainScreensLayOutInDarkMode() throws {
        relaunch(LayoutGuard.darkModeArguments)
        sweepMainScreens(appearance: "dark")
    }

    /// A PDF page's text (PDFKit's `document` group) is laid out by the page and scaled by the zoom: the
    /// viewer's extracted-text page at fit-width zoom reports 10-pt-tall lines. It is content, not app layout.
    private func isPDFPage(_ node: LayoutNode) -> Bool {
        node.type == .group && node.label == "document"
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

    private func sweepMainScreens(appearance: String) {
        continueAfterFailure = true   // a layout failure on one screen must not hide the next screen's
        let main = app.windows["Archive Reader"]
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        LayoutGuard.sweep(main, screen: "navigation window, \(appearance)", in: self, ignore: isPDFPage)

        toolbarButton("ar.toolbar.preview").click()
        let open = app.buttons["ar.preview.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the preview sheet should open")
        LayoutGuard.sweep(main, screen: "preview sheet, \(appearance)", in: self, resize: false,
                          ignore: isPDFPage)

        open.click()
        let viewer = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "Open in Viewer should bring up the document window")
        LayoutGuard.sweep(viewer, screen: "document viewer, \(appearance)", in: self, ignore: isPDFPage)
    }
}

/// The checker's self-test, outside the fixture class so it runs even where the GUI fixture is absent.
final class LayoutGuardSelfTests: XCTestCase {
    func testLayoutGuardCatchesPlantedDefects() {
        LayoutGuardSelfTest.run()
    }
}
