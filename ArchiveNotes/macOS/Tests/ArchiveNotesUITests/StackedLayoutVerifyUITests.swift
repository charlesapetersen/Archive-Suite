import XCTest
import AppKit   // NSScreen — room for the window drags

/// W48.notes-stacked-layout-verify — the independent re-check of the stacked layout (phase rule 6), by a session that
/// did not build it. Written from the promise of ledger rows N-49, N-50 and N-51 before the code was read, for what
/// `StackedLayoutUITests` does not reach: an extract being edited in the Extracts window when the layout switches,
/// the Extracts window's own divider, the divider when the window shrinks under it and grows back, and a relaunch in
/// each layout with the Extracts window open. Scratch fixture only; the layout is put back to side by side at the end.
final class StackedLayoutVerifyUITests: NotesFixtureUITestCase {

    override var layoutLaunchArguments: [String] { [] }   // the menu decides; an argument would override it

    /// N-49, N-51 — the Extracts window: text typed into the open extract just before each switch stays in its
    /// editor and reaches disk, the extract stays open, the note window follows, and the Extracts window's divider
    /// is the shared list height.
    func testExtractBeingEditedSurvivesASwitchFromTheExtractsWindow() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            defer { chooseLayout(.sideBySide) }
            chooseLayout(.sideBySide)
            let extracts = openExtracts()
            let cell = extracts.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 15), "the seeded extract should be listed")
            cell.click()
            let extractEditor = extracts.textViews["an.editor.text"]
            XCTAssertTrue(extractEditor.waitForExistence(timeout: 10), "the extract should open")

            for (n, layout) in [Layout.stacked, .sideBySide, .stacked].enumerated() {
                let sentinel = "Verify extract line \(n + 1)."
                try type("\n" + sentinel, into: extractEditor)
                chooseLayout(layout)                                     // Extracts is the key window
                assertLayout(layout, in: extracts)
                assertLayout(layout, in: mainWindow)
                XCTAssertTrue(((extractEditor.value as? String) ?? "").contains(sentinel),
                              "switch \(n + 1): the unsaved extract text must still be in its editor")
                XCTAssertTrue(pollUntil(timeout: 10) { (self.noteBody(uuid: Self.idExtract) ?? "").contains(sentinel) },
                              "switch \(n + 1): the extract text typed before the switch must reach disk")
            }

            // Stacked now: the Extracts window's divider drags and clamps like the note window's.
            let divider = extracts.descendants(matching: .any)["an.divider.list"]
            XCTAssertTrue(divider.waitForExistence(timeout: 5), "the Extracts window should show the stacked divider")
            XCTAssertEqual(divider.label, "Item list height")
            drag(divider, by: -400)
            XCTAssertEqual(height(divider), 220, accuracy: 0.5, "the Extracts list should clamp at its minimum")
            XCTAssertTrue(extractEditor.exists, "the extract stays open while its divider moves")
            print("[w48v] Extracts divider \(height(divider)); note window divider "
                  + "\(height(mainWindow.descendants(matching: .any)["an.divider.list"]))")
        }
    }

    /// N-50 — the divider at its limits, and the window shrinking under it: dragged to the bottom in a tall window,
    /// then the window cut to its minimum height, the list gives way and the note keeps its editor; grown again, the
    /// list comes back to the height it was left at. Past the top and the bottom the divider does not move.
    func testDividerGivesWayToAShorterWindowAndComesBack() throws {
        try withFixture {
            continueAfterFailure = true   // report every limit measured, not only the first miss
            defer { chooseLayout(.sideBySide) }
            chooseLayout(.stacked)
            assertLayout(.stacked, in: mainWindow)
            _ = selectItem(uuid: Self.idPlain)
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            let screen = NSScreen.main?.frame.height ?? 1000
            let start = mainWindow.frame
            LayoutGuard.dragCorner(of: mainWindow, to: CGPoint(x: start.maxX, y: screen - 8))
            let tall = mainWindow.frame.height
            let divider = mainWindow.descendants(matching: .any)["an.divider.list"]

            drag(divider, by: 600)
            let bottom = height(divider)
            drag(divider, by: 300)
            XCTAssertEqual(height(divider), bottom, accuracy: 0.5, "past its bottom limit the divider should not move")
            XCTAssertLessThanOrEqual(bottom, 440.5, "the list should clamp at 440 pt")
            drag(divider, by: -600)
            XCTAssertEqual(height(divider), 220, accuracy: 0.5, "the list should clamp at 220 pt")
            drag(divider, by: -300)
            XCTAssertEqual(height(divider), 220, accuracy: 0.5, "past its top limit the divider should not move")
            drag(divider, by: 600)
            XCTAssertEqual(height(divider), bottom, accuracy: 0.5, "the bottom limit is the same each time")
            print("[w48v] window \(tall) pt tall: list \(bottom) at the bottom of the drag")

            // Cut the window as short as it goes.
            let f = mainWindow.frame
            LayoutGuard.dragCorner(of: mainWindow, to: CGPoint(x: f.maxX, y: f.minY + 100))
            let short = mainWindow.frame.height
            let squeezed = height(divider)
            let shownEditor = mainWindow.scrollViews.containing(.textView, identifier: "an.editor.text").firstMatch
            print("[w48v] window \(short) pt tall: list \(squeezed), editor \(shownEditor.frame.height)")
            XCTAssertLessThan(short, tall, "the window should have got shorter")
            XCTAssertGreaterThanOrEqual(squeezed, 219.5, "the list never goes below its floor")
            XCTAssertGreaterThan(shownEditor.frame.height, 100, "in the shortest window the note keeps a usable editor")
            XCTAssertLessThanOrEqual(mainWindow.tables.firstMatch.frame.minY, divider.frame.minY,
                                     "the list stays above the divider")

            // Grow it back: the remembered height returns.
            let g = mainWindow.frame
            LayoutGuard.dragCorner(of: mainWindow, to: CGPoint(x: g.maxX, y: screen - 8))
            print("[w48v] window back to \(mainWindow.frame.height) pt: list \(height(divider))")
            XCTAssertEqual(height(divider), bottom, accuracy: 0.5,
                           "a taller window should give the list back the height it was left at")
        }
    }

    /// N-51 — the choice survives a relaunch both ways, in both windows, with the divider where it was left.
    func testRelaunchRestoresEachLayoutInBothWindows() throws {
        try withFixture {
            defer { chooseLayout(.sideBySide) }
            chooseLayout(.stacked)
            let divider = mainWindow.descendants(matching: .any)["an.divider.list"]
            XCTAssertTrue(divider.waitForExistence(timeout: 5))
            // At the window's minimum height the note's floor leaves the list no room to move: grow it first.
            let f = mainWindow.frame
            LayoutGuard.dragCorner(of: mainWindow, to: CGPoint(x: f.maxX, y: (NSScreen.main?.frame.height ?? 1000) - 8))
            drag(divider, by: -400)
            drag(divider, by: 37)
            let kept = height(divider)
            XCTAssertGreaterThan(kept, 225, "the drag should have moved the list off its floor")
            _ = openExtracts()

            relaunch()
            assertLayout(.stacked, in: mainWindow)
            XCTAssertEqual(height(mainWindow.descendants(matching: .any)["an.divider.list"]), kept, accuracy: 0.5,
                           "the list height should be remembered across a relaunch")
            let extracts = openExtracts()
            assertLayout(.stacked, in: extracts)

            chooseLayout(.sideBySide)
            relaunch()
            assertLayout(.sideBySide, in: mainWindow)
            assertLayout(.sideBySide, in: openExtracts())
            chooseLayout(.stacked)
            XCTAssertEqual(height(mainWindow.descendants(matching: .any)["an.divider.list"]), kept, accuracy: 0.5,
                           "the list height outlives a spell side by side")
        }
    }

    // MARK: - Helpers

    func chooseLayout(_ layout: Layout) {
        let view = app.menuBars.menuBarItems["View"]
        guard view.waitForExistence(timeout: 10) else { return XCTFail("the View menu should exist") }
        view.click()
        let item = app.menuItems[layout == .stacked ? "List Above Note" : "Side by Side"]
        guard item.waitForExistence(timeout: 5) else {
            app.typeKey(.escape, modifierFlags: [])
            return XCTFail("View ▸ \(layout) should be offered")
        }
        item.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func height(_ divider: XCUIElement) -> Double {
        if let n = divider.value as? NSNumber { return n.doubleValue }
        return Double(divider.value as? String ?? "") ?? .nan
    }

    private func drag(_ divider: XCUIElement, by dy: CGFloat) {
        let from = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.3, thenDragTo: from.withOffset(CGVector(dx: 0, dy: dy)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func type(_ text: String, into field: XCUIElement) throws {
        func focused() -> Bool { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        for _ in 0..<4 where !focused() {
            app.activate()
            field.click()
            _ = pollUntil(timeout: 2, focused)
        }
        guard focused() else {
            throw StepError("the extract editor never took keyboard focus — focus is on \(keyboardFocusDescription())")
        }
        app.typeKey(.downArrow, modifierFlags: .command)
        field.typeText(text)
    }

    private struct StepError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    @discardableResult
    private func openExtracts() -> XCUIElement {
        let extracts = app.windows["Extracts"]
        if extracts.exists { return extracts }
        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu should exist")
        windowMenu.click()
        let item = app.menuItems["Extracts"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Window ▸ Extracts should be offered")
        item.click()
        XCTAssertTrue(extracts.waitForExistence(timeout: 15), "the Extracts window should open")
        return extracts
    }

    private func relaunch() {
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
    }
}
