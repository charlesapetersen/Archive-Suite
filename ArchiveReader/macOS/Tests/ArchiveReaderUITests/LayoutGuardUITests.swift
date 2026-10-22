import XCTest

/// W40.e9 — the layout guard (`packages/UITestSupport/LayoutGuard.swift`) over the Reader's main screens: the
/// navigation window with a document selected, then with the tag cloud open, the Edit Tags and Similar Tags sheets, the preview sheet, and the
/// document viewer window. Each at its
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
        sweepTagCloud(main, appearance: appearance)

        // The tag sheets at the window's size (W40.fix-reader-tag-editor-chips): Edit Tags over every row, so
        // its subjects are a mix of full and partial chips, then Find Similar Tags. Done only dismisses.
        app.typeKey("a", modifierFlags: .command)
        toolbarButton("ar.toolbar.editTags").click()
        let editorDone = app.buttons["ar.tagEditor.done"]
        XCTAssertTrue(editorDone.waitForExistence(timeout: 5), "the Edit Tags sheet should open")
        LayoutGuard.sweep(main, screen: "Edit Tags sheet, \(appearance)", in: self, resize: false)
        editorDone.click()
        app.menuBars.menuBarItems["Tags"].click()
        app.menuItems["Find Similar Tags…"].click()
        let similarDone = app.buttons["ar.similarTags.done"]
        XCTAssertTrue(similarDone.waitForExistence(timeout: 5), "the Similar Tags sheet should open")
        LayoutGuard.sweep(main, screen: "Similar Tags sheet, \(appearance)", in: self, resize: false)
        similarDone.click()
        clickRow(0)

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

    /// The navigation window with the tag cloud open (W40.fix-reader-tagcloud-width). The guard exempts what is
    /// inside a scroll view, and the table's cells are, so it cannot see the defect this was filed for: opening
    /// the cloud kept every column at its width and pushed Quality and Read under the panel, reachable only by
    /// scrolling sideways. So the sweep is followed by a direct check that the first row's last cell ends
    /// before the cloud's tags begin, at the 1400-pt window the defect was seen at: at the window's 900-pt
    /// minimum the columns' own minimums cannot fit beside the sidebar and the cloud, and the table scrolls by
    /// design. The window is put back to its size afterwards, and the cloud, a persisted toggle, closed again.
    private func sweepTagCloud(_ main: XCUIElement, appearance: String) {
        let tags = main.buttons.matching(identifier: "ar.tagCloud.tag")
        let button = toolbarButton("ar.toolbar.tagCloud")
        if !tags.firstMatch.exists { button.click() }
        guard tags.firstMatch.waitForExistence(timeout: 5) else {
            return XCTFail("the tag cloud should open from the toolbar, with the fixture's tags in it")
        }
        let original = main.frame
        let wide = LayoutGuard.dragCorner(of: main, to: CGPoint(x: original.minX + 1400, y: original.minY + 860))
        XCTAssertEqual(wide.width, 1400, accuracy: 2, "the window should widen to 1400 pt for the tag cloud check")
        LayoutGuard.sweep(main, screen: "tag cloud, \(appearance)", in: self)

        _ = LayoutGuard.waitUntilSettled(main)
        let cells = table.tableRows.element(boundBy: 0).cells.allElementsBoundByIndex
        let lastEdge = cells.map(\.frame.maxX).max() ?? 0
        let cloudEdge = tags.allElementsBoundByIndex.map(\.frame.minX).min() ?? 0
        XCTAssertGreaterThan(cells.count, 0, "the first row should have cells")
        XCTAssertLessThanOrEqual(lastEdge, cloudEdge + LayoutGuard.tolerance,
                                 "tag cloud, \(appearance): the last column ends at x=\(lastEdge), past the cloud's "
                                    + "first tag at x=\(cloudEdge); the columns should shrink to fit beside it")
        LayoutGuard.dragCorner(of: main, to: CGPoint(x: original.maxX, y: original.maxY))
        button.click()
        XCTAssertTrue(tags.firstMatch.waitForNonExistence(timeout: 5), "the tag cloud should close from the toolbar")
    }
}

/// The checker's self-test, outside the fixture class so it runs even where the GUI fixture is absent.
final class LayoutGuardSelfTests: XCTestCase {
    func testLayoutGuardCatchesPlantedDefects() {
        LayoutGuardSelfTest.run()
    }
}
