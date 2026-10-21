import XCTest

/// W40.e9 — the layout guard (`packages/UITestSupport/LayoutGuard.swift`) over Notes' main screens: the note
/// window with a note open in the editor and inspector, and the Extracts window with an extract open (the owner's
/// report of `W40.fix-notes-row-clip` was the Extracts list; its every-cell-fits check is this sweep). Each at its typical and minimum size, on open and
/// once settled; one test per appearance, because the appearance is a launch argument
/// (`-ArchiveUITestAppearance`, read by the app's DEBUG `UITestAppearance`). Read-only: nothing here
/// edits the fixture.
final class LayoutGuardUITests: NotesFixtureUITestCase {

    private var dark = false
    override var extraLaunchArguments: [String] {
        dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments
    }

    func testMainScreensLayOutInLightMode() throws {
        try withFixture { sweepMainScreens(appearance: "light") }
    }

    func testMainScreensLayOutInDarkMode() throws {
        dark = true
        try withFixture { sweepMainScreens(appearance: "dark") }
    }

    private func sweepMainScreens(appearance: String) {
        continueAfterFailure = true   // a layout failure on one screen must not hide the next screen's
        open(Self.idPlain, in: mainWindow)
        LayoutGuard.sweep(mainWindow, screen: "note window, \(appearance)", in: self,
                          known: [narrowWindow], ignore: isHarness)

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
                          known: [narrowWindow], ignore: isHarness)
    }

    /// At its minimum width (1053 pt in the VM) the window is narrower than its three panes: the sidebar's scroll
    /// view starts 34 pt off the left edge and the inspector's scroll views end 34 pt past the right one, taking
    /// the new-folder button, a location's remove button and the raw/styled toggle wholly off the window (VM,
    /// 2026-10-11, screenshot in the evidence file). Only at minimum size, and only sideways. Its fix deletes
    /// this entry.
    private let narrowWindow = LayoutGuard.KnownIssue(tag: "W40.fix-notes-narrow-window") {
        let v = $0
        let sideways = v.frame.minX < v.bounds.minX || v.frame.maxX > v.bounds.maxX
        let insideVertically = v.frame.minY >= v.bounds.minY - 2 && v.frame.maxY <= v.bounds.maxY + 2
        // The panes' scroll views, and the three controls they push entirely off the window with them.
        let casualty = v.type == .scrollView || v.identifier == "an.sidebar.newFolder"
            || v.identifier == "an.editor.rawToggle" || v.identifier.hasPrefix("an.locations.remove.")
        return v.state.hasPrefix("minimum") && v.kind == .window && casualty && sideways && insideVertically
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
