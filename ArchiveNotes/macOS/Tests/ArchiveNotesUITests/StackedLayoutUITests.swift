import XCTest
import AppKit   // NSScreen — room for the divider drag

/// W48.notes-stacked-layout — View ▸ List Above Note, in the VM. Written from the item's promise (ledger rows N-49,
/// N-50, N-51): the folder tree stays on the left, the list sits above the note with a horizontal divider that drags,
/// clamps and persists its height; the choice is a View menu item remembered across relaunches; switching keeps the
/// selection, the open note's unsaved text and the scroll position; the divider is the same accessible splitter as the
/// vertical one, oriented horizontally.
///
/// These tests switch layouts through the menu, so they launch WITHOUT the base class's layout pin (an argument-domain
/// value would override what the menu writes) and put the layout back to side by side before they return, because the
/// choice persists in the app's defaults beyond the fixture restore. Scratch fixture only.
final class StackedLayoutUITests: NotesFixtureUITestCase {

    private var pinned: Layout?
    override var layoutLaunchArguments: [String] { pinned.map(Self.layoutArguments) ?? [] }

    /// N-49 — a switch with a note being edited loses nothing: the selection, the text typed a moment before (still
    /// inside the autosave delay), the scroll position, and the text then reaches disk. Both directions, both windows.
    func testSwitchingLayoutsKeepsSelectionUnsavedTextAndScroll() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            defer { chooseLayout(.sideBySide) }
            chooseLayout(.sideBySide)
            assertLayout(.sideBySide, in: mainWindow)

            let id = Self.idPlain
            let row = selectItem(uuid: id)
            XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor should exist")
            XCTAssertTrue(pollUntil(timeout: 10) { self.editorText.contains("A plain note") }, "the note should load")
            // Enough lines that the editor scrolls, then the caret (and the view) at the end.
            // Short lines: typeText is slow in the VM (60 long lines once took 18 minutes).
            let filler = (1...30).map { "Filler \($0)." }.joined(separator: "\n")
            try typeIntoEditor("\n" + filler)
            XCTAssertTrue(pollUntil(timeout: 10) { self.bodyContains(id, "Filler 30.") }, "the filler should save")

            var expected = [String]()
            for (n, layout) in [Layout.stacked, .sideBySide, .stacked, .sideBySide].enumerated() {
                let sentinel = "Typed just before switch \(n + 1)."
                try typeIntoEditor("\n" + sentinel)
                expected.append(sentinel)
                let scrolledBefore = editorScroll()
                chooseLayout(layout)                       // inside the editor + save debounces
                assertLayout(layout, in: mainWindow)
                XCTAssertTrue(editorText.contains(sentinel), "switch \(n + 1): the unsaved text must still be in the editor")
                XCTAssertTrue(isSelected(row), "switch \(n + 1): the note must stay selected")
                XCTAssertTrue(mainWindow.descendants(matching: .any)["an.detail.header"].exists,
                              "switch \(n + 1): the note's header must still be shown")
                let scrolledAfter = editorScroll()
                print("[w48] switch \(n + 1) to \(layout): scroll \(String(describing: scrolledBefore)) → "
                      + String(describing: scrolledAfter))
                XCTAssertNotNil(scrolledAfter, "switch \(n + 1): the editor's scroll bar should be readable")
                if let before = scrolledBefore, let after = scrolledAfter {
                    XCTAssertGreaterThan(before, 0.5, "switch \(n + 1): the editor should be scrolled to the end before")
                    XCTAssertGreaterThan(after, 0.5, "switch \(n + 1): the switch must not scroll the note back to the top")
                }
                XCTAssertTrue(pollUntil(timeout: 10) { self.bodyContains(id, sentinel) },
                              "switch \(n + 1): the text typed before the switch must reach disk")
            }
            XCTAssertTrue(expected.allSatisfy { editorText.contains($0) }, "every typed line stays in the editor")

            // The Extracts window follows the same choice, both ways, with its extract still open.
            openExtracts()
            let extracts = app.windows["Extracts"]
            let cell = extracts.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 15), "the seeded extract should be listed")
            cell.click()
            let extractEditor = extracts.textViews["an.editor.text"]
            XCTAssertTrue(extractEditor.waitForExistence(timeout: 10), "the extract should open")
            let extractText = (extractEditor.value as? String) ?? ""
            for layout in [Layout.stacked, .sideBySide] {
                chooseLayout(layout)
                assertLayout(layout, in: extracts)
                assertLayout(layout, in: mainWindow)
                XCTAssertEqual((extractEditor.value as? String) ?? "", extractText,
                               "the Extracts window's open extract must survive the switch")
            }
        }
    }

    /// N-50, N-51 — the divider drags, clamps at both ends, and the layout and its height come back after a relaunch.
    func testStackedDividerDragsClampsAndSurvivesRelaunch() throws {
        try withFixture {
            defer { chooseLayout(.sideBySide) }
            chooseLayout(.stacked)
            assertLayout(.stacked, in: mainWindow)
            _ = selectItem(uuid: Self.idPlain)
            // Room for the list to grow: at the window's minimum height the note's floor leaves it none.
            let frame = mainWindow.frame
            let screen = NSScreen.main?.frame.height ?? 1000
            LayoutGuard.dragCorner(of: mainWindow, to: CGPoint(x: frame.maxX, y: min(screen - 8, frame.maxY + 400)))
            print("[w48] window for the drag: \(mainWindow.frame.size)")
            let divider = splitter(.stacked, in: mainWindow)
            XCTAssertEqual(divider.label, "Item list height")

            drag(divider, by: -300)
            XCTAssertEqual(height(divider), 220, accuracy: 0.5, "the list height should clamp at its minimum")
            drag(divider, by: 60)
            XCTAssertEqual(height(divider), 280, accuracy: 6, "dragging down should grow the list")
            let list = mainWindow.tables.firstMatch
            XCTAssertEqual(list.frame.maxY, divider.frame.minY, accuracy: 4, "the list should end at the divider")
            // Down as far as it goes: at most 440, and less when the window is too short to keep the note's
            // floor below it (the VM's is); the note keeps a usable editor either way.
            drag(divider, by: 400)
            let top = height(divider)
            print("[w48] list height at the bottom of the drag: \(top) in a \(mainWindow.frame.height) pt window")
            XCTAssertLessThanOrEqual(top, 440.5, "the list height should clamp at its maximum")
            XCTAssertGreaterThan(top, 280, "dragging down should grow the list up to what fits")
            drag(divider, by: 200)
            XCTAssertEqual(height(divider), top, accuracy: 0.5, "past its limit the list should stay where it stopped")
            let shownEditor = mainWindow.scrollViews.containing(.textView, identifier: "an.editor.text").firstMatch
            XCTAssertGreaterThan(shownEditor.frame.height, 100, "at the list's maximum the note keeps its editor")
            drag(divider, by: -40)
            let kept = height(divider)
            XCTAssertEqual(kept, top - 40, accuracy: 6)

            app.terminate()
            app.launch()
            app.activate()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
            assertLayout(.stacked, in: mainWindow)
            XCTAssertEqual(height(splitter(.stacked, in: mainWindow)), kept, accuracy: 0.5,
                           "the list height should be remembered across a relaunch")
        }
    }

    /// N-51 — reading and keyboard order: the list, then the divider, then the note; the tree hides and shows;
    /// Tab still reaches the editor from the list in the stacked layout whenever it does side by side.
    func testStackedOrderIsListThenNoteAndFocusCrossesTheDivider() throws {
        pinned = .stacked
        try withFixture {
            assertLayout(.stacked, in: mainWindow)
            _ = selectItem(uuid: Self.idPlain)
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            let order = accessibilityOrder(of: mainWindow, ids: ["an.divider.list", "an.editor.text"])
            print("[w48] accessibility order: \(order)")
            XCTAssertEqual(order, ["table", "an.divider.list", "an.editor.text"],
                           "VoiceOver should meet the list, then the divider, then the note")
            let list = mainWindow.tables.firstMatch, divider = splitter(.stacked, in: mainWindow)
            XCTAssertLessThanOrEqual(list.frame.maxY, divider.frame.midY, "the list is above the divider")
            XCTAssertGreaterThanOrEqual(editor.frame.minY, divider.frame.midY, "the note is below the divider")

            // The folder tree's animated hide and show, stacked: this crashed AppKit's layout pass once (a feedback
            // loop through measured state), found by the stacked visual tour.
            let toggle = mainWindow.buttons["an.toggleTree"].firstMatch
            for state in ["hidden", "shown", "hidden", "shown"] {
                toggle.click()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                XCTAssertEqual(app.state, .runningForeground, "the app must survive the tree being \(state), stacked")
                XCTAssertEqual(mainWindow.descendants(matching: .any)["an.sidebar.newFolder"].firstMatch.exists,
                               state == "shown", "the tree should be \(state)")
            }
            assertLayout(.stacked, in: mainWindow)

            let stackedTabs = tabsFromListToEditor()
            relaunchPinned(.sideBySide)
            _ = selectItem(uuid: Self.idPlain)
            let sideTabs = tabsFromListToEditor()
            print("[w48] Tab presses from the list to the editor: stacked \(String(describing: stackedTabs)), "
                  + "side by side \(String(describing: sideTabs))")
            XCTAssertEqual(stackedTabs != nil, sideTabs != nil,
                           "Tab should reach the editor across the divider exactly when it does side by side")
            XCTAssertNotNil(stackedTabs, "Tab should reach the editor from the list")
        }
    }

    // MARK: - Helpers

    private var editorText: String { (editor.value as? String) ?? "" }

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

    private func splitter(_ layout: Layout, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)[layout == .stacked ? "an.divider.list" : "an.divider.detail"]
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

    private func isSelected(_ row: XCUIElement) -> Bool {
        if row.isSelected { return true }
        return mainWindow.tables.firstMatch.tableRows.containing(.any, identifier: row.identifier)
            .firstMatch.isSelected
    }

    /// The editor's vertical scroll position, 0 at the top and 1 at the end; nil when no scroll bar is exposed.
    private func editorScroll() -> Double? {
        let scroll = mainWindow.scrollViews.containing(.textView, identifier: "an.editor.text").firstMatch
        let bar = scroll.scrollBars.firstMatch
        guard bar.exists else { return nil }
        if let n = bar.value as? NSNumber { return n.doubleValue }
        return (bar.value as? String).flatMap(Double.init)
    }

    private func bodyContains(_ id: String, _ text: String) -> Bool {
        (noteBody(uuid: id) ?? "").contains(text)
    }

    private func typeIntoEditor(_ text: String) throws {
        func focused() -> Bool { (editor.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        for _ in 0..<4 where !focused() {
            app.activate()
            editor.click()
            _ = pollUntil(timeout: 2, focused)
        }
        guard focused() else {
            throw StepError("the styled editor never took keyboard focus — focus is on \(keyboardFocusDescription())")
        }
        app.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText(text)
    }

    private struct StepError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    private func openExtracts() {
        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu should exist")
        windowMenu.click()
        let item = app.menuItems["Extracts"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Window ▸ Extracts should be offered")
        item.click()
        XCTAssertTrue(app.windows["Extracts"].waitForExistence(timeout: 15), "the Extracts window should open")
    }

    private func relaunchPinned(_ layout: Layout) {
        app.terminate()
        pinned = layout
        app = .archiveUITestApp()
        app.launchArguments += ["-ANUITestStorePath", Self.fixturePath] + zoteroLaunchArguments
            + ["-an.noteWindow.kindFilter", "notes", "-an.extractWindow.kindFilter", "extracts"]
            + layoutLaunchArguments
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 15), "the window should come back after relaunch")
        let extracts = app.windows["Extracts"]
        if extracts.waitForExistence(timeout: 8) {
            openExtracts()
            let close = extracts.buttons[XCUIIdentifierCloseWindow]
            if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
            _ = extracts.waitForNonExistence(timeout: 8)
        }
        assertLayout(layout, in: mainWindow)
    }

    /// Click the list, then Tab until the editor holds keyboard focus; the presses it took, or nil within 30
    /// (with full keyboard access Tab also stops on every filter and editor-toolbar control).
    private func tabsFromListToEditor() -> Int? {
        func focused() -> Bool { (editor.value(forKey: "hasKeyboardFocus") as? Bool) == true }
        mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idPlain)"].click()
        for n in 1...30 {
            app.typeKey(.tab, modifierFlags: [])
            if pollUntil(timeout: 0.5, focused) { return n }
        }
        print("[w48] Tab never reached the editor; focus is on \(keyboardFocusDescription())")
        return nil
    }

    /// The order the item table ("table") and the given identifiers first appear in a depth-first walk of the
    /// window's accessibility tree, which is the order VoiceOver reads them.
    private func accessibilityOrder(of window: XCUIElement, ids: Set<String>) -> [String] {
        guard let root = try? window.snapshot() else { return [] }
        var seen = [String]()
        func walk(_ node: any XCUIElementSnapshot) {
            let name = node.elementType == .table ? "table" : node.identifier
            if (name == "table" || ids.contains(name)), !seen.contains(name) { seen.append(name) }
            node.children.forEach(walk)
        }
        walk(root)
        return seen
    }
}
