import XCTest
import AppKit   // NSScreen — the narrow-and-tall stacked sweep

/// W40.e9 — the layout guard (`packages/UITestSupport/LayoutGuard.swift`) over Notes' main screens: the note
/// window with a note open in the editor and inspector, and the Extracts window with an extract open (the owner's
/// report of `W40.fix-notes-row-clip` was the Extracts list; its every-cell-fits check is this sweep). Each at its typical and minimum size, on open and
/// once settled; one test per appearance, because the appearance is a launch argument
/// (`-ArchiveUITestAppearance`, read by the app's DEBUG `UITestAppearance`). Read-only: nothing here
/// edits the fixture.
final class LayoutGuardUITests: NotesFixtureUITestCase {

    private var dark = false
    private var restoreWidePanes = false
    /// W48.notes-stacked-layout: the sweeps also run with the list above the note.
    private var layout = Layout.sideBySide
    override var layoutLaunchArguments: [String] { Self.layoutArguments(layout) }
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

    func testMainScreensLayOutStackedInLightMode() throws {
        layout = .stacked
        try withFixture { sweepMainScreens(appearance: "light-stacked"); sweepNarrowAndTall(appearance: "light-stacked") }
    }

    func testMainScreensLayOutStackedInDarkMode() throws {
        dark = true
        layout = .stacked
        try withFixture { sweepMainScreens(appearance: "dark-stacked"); sweepNarrowAndTall(appearance: "dark-stacked") }
    }

    /// The stacked layout's other extreme: as narrow as the window goes and as tall as the screen allows. The list
    /// and the note then share one column, so the sweep checks neither is squeezed out.
    private func sweepNarrowAndTall(appearance: String) {
        let window = mainWindow
        app.activate()
        // The Extracts window `sweepMainScreens` opened restores where an earlier test left it, and in a whole-suite
        // run that was exactly over the note window (both at (393,264) 767×759; runs 18 and 20): the corner drag below
        // then pressed Extracts, the note window stayed 759 pt tall and the sweep failed, while alone, with Extracts
        // restored offset, the same drag took. This sweep is of the note window alone, so close Extracts first.
        let extracts = app.windows["Extracts"]
        if extracts.exists {
            let close = extracts.buttons[XCUIIdentifierCloseWindow]
            if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
            XCTAssertTrue(extracts.waitForNonExistence(timeout: 8), "the Extracts window should close before the drag")
            LayoutGuard.waitUntilSettled(window)
        }
        // As tall as the screen allows from where the window opened: down to the top of the Dock. The window is not
        // moved up first, because a synthesized title-bar drag never moved it in the VM, fast or slow; checking
        // "100 pt taller" instead made the sweep pass or fail on where an earlier test had left the window
        // (759 → 918 from y 191, 759 → 845 from y 264; W48.appearance-notes).
        let screen = NSScreen.main?.frame.height ?? 1000
        let dockTop = screen - (NSScreen.main?.visibleFrame.minY ?? 0)   // top-left coordinates, as XCUITest's
        let before = window.frame
        LayoutGuard.dragCorner(of: window, to: CGPoint(x: before.maxX, y: screen - 8))
        LayoutGuard.waitUntilSettled(window)
        print("[layout] narrow and tall, \(appearance): window \(before.size) → \(window.frame.size) at y "
              + "\(window.frame.minY), Dock top \(dockTop), screen \(screen)")
        // No shorter (a window an earlier test left reaching the Dock already cannot grow), and down to the Dock.
        XCTAssertGreaterThanOrEqual(window.frame.height, before.height, "the window should not have shrunk")
        XCTAssertGreaterThanOrEqual(window.frame.maxY, dockTop - 8, "the window should reach down to the Dock")
        // The minimum size was swept above; this is one more size, not a resize check.
        LayoutGuard.sweep(window, screen: "note window, narrow and tall, \(appearance)", in: self, resize: false,
                          ignore: isHarness)
        let list = window.tables.firstMatch
        let divider = window.descendants(matching: .any)["an.divider.list"]
        let editor = window.scrollViews.containing(.textView, identifier: "an.editor.text").firstMatch
        XCTAssertTrue(list.exists && divider.exists && editor.exists, "the list, divider and editor should all show")
        XCTAssertLessThanOrEqual(list.frame.maxY, divider.frame.midY, "the list should sit above the divider")
        XCTAssertGreaterThan(editor.frame.height, 150, "the note should keep a usable editor when tall and narrow")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-narrow-tall-\(appearance).png")
        try? window.screenshot().pngRepresentation.write(to: url, options: .atomic)
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
        assertLayout(layout, in: mainWindow)
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
        checkEditorShare(window, name: "\(name)-typical")
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
        checkEditorShare(window, name: name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-minimum-\(name).png")
        do {
            try window.screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] minimum-\(name): wrote \(url.path)")
        } catch {
            XCTFail("could not retain minimum-window screenshot: \(error)")
        }
    }

    /// W40.fix-notes-editor-squeezed: at minimum size the metadata inspector used to take about two-thirds of
    /// the right pane. The editor must now be the larger of the two, and folding the metadata must give it the room.
    private func checkEditorShare(_ window: XCUIElement, name: String) {
        let editor = window.scrollViews.containing(.textView, identifier: "an.editor.text").firstMatch
        let metadata = window.scrollViews["an.detail.metadataScroll"]
        let toggle = window.buttons["an.detail.metadataToggle"]
        guard editor.exists, metadata.exists, toggle.exists else {
            XCTFail("\(name): the editor, the metadata scroll and its toggle should all be shown")
            return
        }
        let shown = editor.frame.height
        print("[layout] \(name): editor \(Int(shown)) pt, metadata \(Int(metadata.frame.height)) pt, " +
              "window \(Int(window.frame.height)) pt")
        XCTAssertGreaterThan(shown, metadata.frame.height,
                             "\(name): the editor should get the larger share of the right pane")
        toggle.click()
        LayoutGuard.waitUntilSettled(window)
        XCTAssertFalse(metadata.exists, "\(name): Hide details should fold the metadata away")
        let folded = editor.frame.height
        print("[layout] \(name): editor with details hidden \(Int(folded)) pt")
        XCTAssertGreaterThan(folded, shown + 60, "\(name): folding the metadata should give the editor its room")
        let foldedURL = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-minimum-\(name)-folded.png")
        try? window.screenshot().pngRepresentation.write(to: foldedURL, options: .atomic)
        toggle.click()   // the choice is remembered; leave it as later tests expect
        LayoutGuard.waitUntilSettled(window)
        XCTAssertTrue(metadata.waitForExistence(timeout: 5), "\(name): Show details should bring the metadata back")
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
