import XCTest

/// W40.e9 — the layout guard (`packages/UITestSupport/LayoutGuard.swift`) over Notes' main screens: the note
/// window with a note open in the editor and inspector, and the Extracts window with an extract open (the owner's
/// report of `W40.fix-notes-row-clip` was the Extracts list; its every-cell-fits check is this sweep). Each at its typical and minimum size, on open and
/// once settled; one test per appearance, because the appearance is a launch argument
/// (`-ArchiveUITestAppearance`, read by the app's DEBUG `UITestAppearance`). Read-only: nothing here
/// edits the fixture.
final class LayoutGuardUITests: NotesFixtureUITestCase {

    private var dark = false
    private var restoreWidePanes = false
    override var extraLaunchArguments: [String] {
        let appearance = dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments
        return appearance + (restoreWidePanes ? [
            "-an.windowWidth", "640", "-an.windowHeight", "660",
            "-an.treeWidth", "300", "-an.detailWidth", "420",
        ] : [])
    }

    func testMainScreensLayOutInLightMode() throws {
        try withFixture { sweepMainScreens(appearance: "light") }
    }

    func testMainScreensLayOutInDarkMode() throws {
        dark = true
        try withFixture { sweepMainScreens(appearance: "dark") }
    }

    func testUndersizedSavedWindowWithWidePanes() throws {
        restoreWidePanes = true
        try withFixture {
            sweepMainScreens(appearance: "restored-wide-panes")
            let extracts = app.windows["Extracts"]
            for state in ["hidden", "shown"] {
                extracts.buttons["an.toggleTree"].firstMatch.click()
                LayoutGuard.waitUntilSettled(extracts)
                XCTAssertEqual(extracts.descendants(matching: .any)["an.sidebar.newFolder"].firstMatch.exists,
                               state == "shown", "the sidebar must actually be \(state)")
                LayoutGuard.sweep(extracts, screen: "wide panes, sidebar \(state)", in: self, ignore: isHarness)
            }
            checkMinimumControls(extracts, name: "sidebar-restored")
        }
    }

    private func sweepMainScreens(appearance: String) {
        continueAfterFailure = true   // a layout failure on one screen must not hide the next screen's
        open(Self.idPlain, in: mainWindow)
        LayoutGuard.sweep(mainWindow, screen: "note window, \(appearance)", in: self,
                          ignore: isHarness)
        checkMinimumControls(mainWindow, name: "note-\(appearance)")

        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu should exist")
        windowMenu.click()
        let item = app.menuItems["Extracts"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Window ▸ Extracts should be offered")
        item.click()
        let extracts = app.windows["Extracts"]
        XCTAssertTrue(extracts.waitForExistence(timeout: 15), "the Extracts window should be open")
        open(Self.idExtract, in: extracts)
        LayoutGuard.sweep(extracts, screen: "extracts window, \(appearance)", in: self,
                          ignore: isHarness)
        checkMinimumControls(extracts, name: "extracts-\(appearance)")
    }

    /// These controls were entirely off-window before W40.fix-notes-narrow-window. Check reachability
    /// as well as the sweep's geometry, and retain the actual minimum-size pixels on green runs too.
    private func checkMinimumControls(_ window: XCUIElement, name: String) {
        let frame = window.frame
        LayoutGuard.dragCorner(of: window, to: CGPoint(x: frame.minX + 40, y: frame.minY + 40))
        LayoutGuard.waitUntilSettled(window)
        for id in ["an.sidebar.newFolder", "an.editor.rawToggle"] {
            let control = window.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(control.exists && control.isHittable, "\(id) must be reachable at minimum width")
        }
        let removes = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "an.locations.remove."))
        XCTAssertGreaterThan(removes.count, 0, "the selected fixture item has a location")
        for control in removes.allElementsBoundByIndex {
            XCTAssertTrue(control.isHittable, "a location's remove button must be reachable at minimum width")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-minimum-\(name).png")
        do {
            try window.screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] minimum-\(name): wrote \(url.path)")
        } catch {
            XCTFail("could not retain minimum-window screenshot: \(error)")
        }
    }

    /// UI-test-only harness elements (`ArchiveNotesApp` adds them only under the UITest launch arguments): the
    /// 1-line status probes drawn behind the panes, and the editor's test-button strip. Not product layout.
    private func isHarness(_ node: LayoutNode) -> Bool {
        node.identifier.hasPrefix("an.status.") || node.identifier.hasPrefix("an.editor.test.")
    }

    private func open(_ id: String, in window: XCUIElement) {
        let title = window.descendants(matching: .any)["an.cell.title.\(id)"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the seeded row \(id) should be listed")
        title.click()
    }
}

/// The checker's self-test, outside the fixture class so it runs even where the GUI fixture is absent.
final class LayoutGuardSelfTests: XCTestCase {
    func testLayoutGuardCatchesPlantedDefects() {
        LayoutGuardSelfTest.run()
    }
}
