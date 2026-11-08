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
            let scroll = mainWindow.descendants(matching: .any)["an.inspector"].firstMatch
            print("[inspector] the inspector is a \(scroll.elementType.rawValue) at \(scroll.frame)")
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

            // A toolbar item and its button carry the same identifier.
            let toggle = mainWindow.buttons["an.inspector.toggle"].firstMatch
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

    /// Row 7: the list's Date and Tags cells edit in place — a double-click or the row's context menu, Return saves,
    /// Escape writes nothing, an emptied Date cell clears the date, and removing the tokens removes the tags.
    func testDateAndTagsEditInTheList() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            _ = selectItem(uuid: id)
            @MainActor func markdown() -> String { rawMarkdown(inItemDir: id) ?? "" }
            @MainActor func saved(_ check: @escaping (String) -> Bool) -> Bool { pollUntil(timeout: 12) { check(markdown()) } }
            let before = markdown()
            let dateCell = mainWindow.descendants(matching: .any)["an.cell.date.\(id)"]
            XCTAssertTrue(dateCell.waitForExistence(timeout: 10), "the list shows the Date column")
            let displayedDate = dateCell.value as? String
            XCTAssertFalse(displayedDate?.isEmpty ?? true, "the fixture starts with a visible date")

            // W40.fix-notes-date-cell-erase: merely opening a cell and leaving it must write nothing.
            dateCell.doubleClick()
            mainWindow.textViews["an.editor.text"].click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertEqual(markdown(), before, "an untouched Date cell must preserve the whole note")
            XCTAssertEqual(dateCell.value as? String, displayedDate, "the untouched date stays visible")
            shot("list-date-unchanged")

            dateCell.doubleClick()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("1999")
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertEqual(markdown(), before, "Escape in the Date cell writes nothing")

            dateCell.doubleClick()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("March 1971\r")
            XCTAssertTrue(saved { $0.contains("date: 1971-03") && $0.contains("date_precision: month") },
                          "a date typed in the list saves at the precision typed")
            shot("list-date-edited")

            // Edit Tags from the row's menu first: at the window's minimum width the list is narrow and the Tags
            // column is scrolled out of view, and the menu's edit scrolls it in (a double-click needs it on screen).
            let tagsCell = mainWindow.descendants(matching: .any)["an.cell.tags.\(id)"]
            let tagsField = mainWindow.descendants(matching: .any)["an.cell.tags.edit.\(id)"]
            mainWindow.descendants(matching: .any)["an.cell.title.\(id)"].rightClick()
            let editTags = app.menuItems["Edit Tags"]
            XCTAssertTrue(editTags.waitForExistence(timeout: 5), "the row's menu offers Edit Tags")
            editTags.click()
            if !tagsField.waitForExistence(timeout: 5) {
                shot("list-tags-not-open")
                let status = mainWindow.descendants(matching: .any)["an.sidebar.status"]
                XCTFail("Edit Tags opens the tags field in the cell; status \(status.exists ? status.label : "none"), "
                        + "focus \(app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch.debugDescription)")
                return
            }
            XCTAssertTrue(before.lowercased().contains("silicon valley") && before.lowercased().contains("intel"),
                          "the fixture note starts with two tags")
            let beforeTags = markdown()
            mainWindow.textViews["an.editor.text"].click()
            XCTAssertTrue(pollUntil(timeout: 5) { !tagsField.exists }, "leaving Tags closes the editor")
            XCTAssertEqual(markdown(), beforeTags, "an untouched Tags cell must preserve the whole note")
            tagsCell.doubleClick()
            XCTAssertTrue(tagsField.waitForExistence(timeout: 5))
            app.typeText("list tag\r")
            XCTAssertTrue(saved { $0.contains("List Tag") }, "a tag typed in the list is added")
            let afterAdd = markdown().lowercased()
            XCTAssertTrue(afterAdd.contains("silicon valley") && afterAdd.contains("intel"),
                          "typing in the cell adds to the note's tags, never replaces them")
            XCTAssertTrue(pollUntil(timeout: 5) { !tagsField.exists }, "Return closes the cell's tags field")
            shot("list-tags-edited")

            tagsCell.doubleClick()   // on screen now
            XCTAssertTrue(tagsField.waitForExistence(timeout: 5), "a double-click on Tags opens its field in the cell")
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(saved { !$0.contains("List Tag") }, "removing the tokens in the list removes the tags")

            tagsCell.rightClick()   // the Date column may be scrolled out of view now; the menu scrolls it in
            let editDate = app.menuItems["Edit Date"]
            XCTAssertTrue(editDate.waitForExistence(timeout: 5), "the row's menu offers Edit Date")
            editDate.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(.delete, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(saved { !$0.contains("date: 1971") }, "an emptied Date cell clears the date")
            XCTAssertEqual(markdown().components(separatedBy: "\n---\n").last,
                           before.components(separatedBy: "\n---\n").last, "the note's body is untouched")
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
