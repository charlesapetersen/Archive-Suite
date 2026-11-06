import XCTest

/// W40.notes-detail-layout (owner session notes-1 rows 20, 21, 23, 32): a note's fields and locations are in an
/// inspector panel at the window's right, opened and closed by View ▸ Show/Hide Inspector (⌥⌘I) and a toolbar button,
/// and its tags in a bar under the editor. Scratch fixture only; the inspector is left open and the layout side by
/// side at the end, as later tests expect.
final class InspectorPanelUITests: NotesFixtureUITestCase {

    override var layoutLaunchArguments: [String] { [] }   // the menu decides; an argument would override it

    private var inspector: XCUIElement { mainWindow.descendants(matching: .any)["an.inspector"] }

    /// The inspector holds the fields and the locations, not the tags; it follows the selection; the toolbar button,
    /// the View menu and ⌥⌘I each close and open it.
    func testInspectorHoldsTheFieldsFollowsTheSelectionAndToggles() throws {
        try withFixture {
            _ = selectItem(uuid: Self.idPlain)
            XCTAssertTrue(inspector.waitForExistence(timeout: 10), "the inspector should be open by default")
            let inside = inspector.descendants(matching: .any)
            XCTAssertTrue(inside["an.detail.roundup"].waitForExistence(timeout: 5), "Round-up is in the inspector")
            XCTAssertTrue(inside["an.detail.date.field"].exists, "the date is in the inspector")
            XCTAssertTrue(inside["an.detail.locations"].exists, "the locations are in the inspector")
            XCTAssertFalse(inside["an.detail.tags.input"].exists, "the tags are not in the inspector")
            XCTAssertTrue(mainWindow.descendants(matching: .any)["an.tagbar"].exists, "the tag bar is under the note")
            XCTAssertFalse(mainWindow.buttons["an.detail.metadataToggle"].exists, "the Details strip is gone")
            let readingRemove = "an.locations.remove.\(Self.folderReading)"
            let ideasRemove = "an.locations.remove.\(Self.folderIdeas)"
            XCTAssertTrue(inside[readingRemove].exists, "the plain note is in Reading")
            XCTAssertFalse(inside[ideasRemove].exists, "the plain note is not in Ideas")
            shot("inspector-plain")

            _ = selectItem(uuid: Self.idZotero)   // in Ideas only
            XCTAssertTrue(pollUntil(timeout: 10) { inside[ideasRemove].exists && !inside[readingRemove].exists },
                          "the inspector should follow the selection to the Zotero note's location")

            let toggle = mainWindow.buttons["an.inspector.toggle"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the toolbar has the inspector button")
            let header = mainWindow.descendants(matching: .any)["an.detail.header"]
            toggle.click()
            XCTAssertTrue(pollUntil(timeout: 5) { !self.inspector.exists }, "the toolbar button closes the inspector")
            XCTAssertTrue(header.exists, "the note stays open with the inspector closed")
            shot("inspector-closed")
            toggle.click()
            XCTAssertTrue(inspector.waitForExistence(timeout: 5), "the toolbar button opens the inspector")

            clickViewMenuItem("Hide Inspector")
            XCTAssertTrue(pollUntil(timeout: 5) { !self.inspector.exists }, "View ▸ Hide Inspector closes it")
            clickViewMenuItem("Show Inspector")
            XCTAssertTrue(inspector.waitForExistence(timeout: 5), "View ▸ Show Inspector opens it")

            app.typeKey("i", modifierFlags: [.command, .option])
            XCTAssertTrue(pollUntil(timeout: 5) { !self.inspector.exists }, "⌥⌘I closes the inspector")
            app.typeKey("i", modifierFlags: [.command, .option])
            XCTAssertTrue(inspector.waitForExistence(timeout: 5), "⌥⌘I opens the inspector")
        }
    }

    /// Stacked, the inspector runs the full height beside the list and the note; at the window's minimum width with
    /// the folder list and the inspector both open, every pane is inside the window.
    func testInspectorRunsFullHeightStackedAndFitsTheMinimumWindow() throws {
        try withFixture {
            defer { chooseLayout("Side by Side") }
            _ = selectItem(uuid: Self.idPlain)
            XCTAssertTrue(inspector.waitForExistence(timeout: 10))
            chooseLayout("List Above Note")
            let list = mainWindow.descendants(matching: .any)["an.list.table"]
            let editor = mainWindow.scrollViews.containing(.textView, identifier: "an.editor.text").firstMatch
            XCTAssertTrue(mainWindow.descendants(matching: .any)["an.divider.list"].waitForExistence(timeout: 5))
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            print("[inspector] stacked: inspector \(inspector.frame), list \(list.frame), editor \(editor.frame)")
            XCTAssertLessThanOrEqual(inspector.frame.minY, list.frame.minY + 1, "the inspector starts beside the list")
            XCTAssertGreaterThanOrEqual(inspector.frame.maxY, editor.frame.maxY - 1, "it runs down beside the note")
            XCTAssertGreaterThanOrEqual(inspector.frame.minX, list.frame.maxX - 1, "it is right of the list")
            shot("inspector-stacked")
            chooseLayout("Side by Side")

            let frame = mainWindow.frame
            LayoutGuard.dragCorner(of: mainWindow, to: CGPoint(x: frame.minX + 40, y: frame.minY + 40))
            LayoutGuard.waitUntilSettled(mainWindow)
            let window = mainWindow.frame
            let tree = mainWindow.descendants(matching: .any)["an.sidebar.newFolder"].firstMatch
            print("[inspector] minimum window \(window), inspector \(inspector.frame), tree button \(tree.frame)")
            XCTAssertTrue(inspector.exists && tree.exists, "the folder list and the inspector are both open")
            XCTAssertLessThanOrEqual(inspector.frame.maxX, window.maxX + 1, "the inspector is inside the window")
            XCTAssertGreaterThanOrEqual(inspector.frame.width, 219, "the inspector keeps its width")
            XCTAssertGreaterThanOrEqual(tree.frame.minX, window.minX - 1, "the folder list is inside the window")
            XCTAssertTrue(editor.exists && editor.frame.width > 200, "the note keeps its editor")
            shot("inspector-minimum")
        }
    }

    // MARK: - Helpers

    private func clickViewMenuItem(_ title: String) {
        let view = app.menuBars.menuBarItems["View"]
        guard view.waitForExistence(timeout: 10) else { return XCTFail("the View menu should exist") }
        view.click()
        let item = app.menuItems[title]
        guard item.waitForExistence(timeout: 5) else {
            app.typeKey(.escape, modifierFlags: [])
            return XCTFail("View ▸ \(title) should be offered")
        }
        item.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func chooseLayout(_ title: String) { clickViewMenuItem(title) }

    private func shot(_ name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(name).png")
        try? mainWindow.screenshot().pngRepresentation.write(to: url, options: .atomic)
        print("[shot] \(name): wrote \(url.path)")
    }
}
