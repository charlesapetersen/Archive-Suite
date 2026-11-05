import XCTest

/// W40.fix-notes-list-rename — the owner's steps from Notes guided session 1 (`verification/sessions/notes-1-returned.md`
/// rows 6, 9 and 14), with real keystrokes, in the VM. Row 9: a title given in the list showed there, then went when
/// the note was deselected, though the `.md` kept it. Row 14: Return after typing the title deselected the note.
/// Row 6: clicking the title in the note's header did nothing. Scratch fixture only (`AN-GUI-Fixture`).
final class ListRenameUITests: NotesFixtureUITestCase {

    /// Rows 9 and 14 on a seeded note and on a new one: Return keeps the note selected, and the title stays in
    /// the list after another note is selected.
    func testListRenameStaysShownAndSelected() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            // The first note selected after launch focuses its editor (W9.d12a); a second click gives the list
            // the keyboard, as G17 does.
            let seeded = selectItem(uuid: id)
            XCTAssertTrue(pollUntil(timeout: 10) {
                ((self.mainWindow.textViews["an.editor.text"].value as? String) ?? "").contains("A plain note")
            }, "the note's body should load")
            pause(1)
            seeded.click()
            shot("seeded-selected")
            app.typeKey(.return, modifierFlags: [])
            pause(0.5)
            shot("seeded-return")
            app.typeText("Daily Schedule")
            shot("seeded-typed")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: id) ?? "").contains("title: Daily Schedule")
            }, "Return should save the title — disk: \(rawMarkdown(inItemDir: id) ?? "nil"), cell: \(cellText(id))")
            assertRenamed(id, "Daily Schedule", step: "seeded")

            // A new note, named by double-clicking its row.
            let before = itemDirs()
            let newMenu = mainWindow.descendants(matching: .any)["an.toolbar.new"]
            XCTAssertTrue(newMenu.waitForExistence(timeout: 10), "the toolbar New menu should exist")
            newMenu.click()
            let newNote = app.menuItems["New Note"]
            XCTAssertTrue(newNote.waitForExistence(timeout: 5), "New ▸ New Note should exist")
            newNote.click()
            var created: [String] = []
            XCTAssertTrue(pollUntil(timeout: 15) {
                created = self.itemDirs().subtracting(before).filter { !self.mdFiles(inItemDir: $0).isEmpty }
                return created.count == 1
            }, "New Note should create one note")
            let newID = try XCTUnwrap(created.first).uppercased()
            let cell = titleCell(newID)
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "the new note should be listed")
            revealRow(cell)
            cell.doubleClick()
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Weekly Plan")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: newID.lowercased()) ?? self.rawMarkdown(inItemDir: newID) ?? "")
                    .contains("title: Weekly Plan")
            }, "Return should save the new note's title")
            assertRenamed(newID, "Weekly Plan", step: "new")
            XCTAssertEqual(cellText(id), "Daily Schedule", "the first rename should still be listed")
        }
    }

    /// Row 6: a click on the header's title edits it; Return saves, Escape does not.
    func testHeaderTitleIsEditable() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            selectItem(uuid: id)
            let label = mainWindow.staticTexts["an.detail.title"]
            let field = mainWindow.textFields["an.detail.title"]
            XCTAssertTrue(label.waitForExistence(timeout: 10), "the header should show the title: \(mainWindow.debugDescription)")
            label.click()
            XCTAssertTrue(field.waitForExistence(timeout: 5), "a click on the title should start an edit")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Not Saved")
            app.typeKey(.escape, modifierFlags: [])
            pause(1)
            shot("header-escaped")
            XCTAssertFalse((rawMarkdown(inItemDir: id) ?? "").contains("Not Saved"), "Escape should not save")
            XCTAssertTrue(label.waitForExistence(timeout: 5), "Escape should close the field: \(mainWindow.debugDescription)")
            XCTAssertEqual(label.value as? String, "My First Note", "Escape should put the title back")

            label.click()
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Header Title")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: id) ?? "").contains("title: Header Title")
            }, "Return in the header should save the title")
            XCTAssertTrue(pollUntil(timeout: 10) { self.cellText(id) == "Header Title" }, "the list should follow")
            XCTAssertTrue(isRowSelected(id), "the note should stay selected")
            shot("header-renamed")
        }
    }

    private func assertRenamed(_ id: String, _ title: String, step: String) {
        pause(1)
        shot("\(step)-after-return")
        XCTAssertTrue(isRowSelected(id), "\(step): the note should stay selected after Return")
        XCTAssertFalse(mainWindow.staticTexts["No note selected"].exists, "\(step): the detail should still show the note")
        XCTAssertEqual(cellText(id), title, "\(step): the list should show the new title")

        selectItem(uuid: Self.idReader)
        pause(1)
        shot("\(step)-after-deselect")
        XCTAssertTrue(pollUntil(timeout: 5) { !self.isRowSelected(id) }, "\(step): the other note should be selected")
        XCTAssertEqual(cellText(id), title, "\(step): the title should stay listed after the note is deselected")
    }

    private func titleCell(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)["an.cell.title.\(id)"].firstMatch
    }

    private func cellText(_ id: String) -> String {
        let cell = titleCell(id)
        return (cell.value as? String) ?? cell.label
    }

    private func isRowSelected(_ id: String) -> Bool {
        mainWindow.tables.firstMatch.tableRows.containing(.any, identifier: "an.cell.title.\(id)").firstMatch.isSelected
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shot(_ name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-rename-\(name).png")
        do {
            try mainWindow.screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] rename-\(name): wrote \(url.path)")
        } catch {
            print("[shot] rename-\(name): could not write \(url.path) — \(error)")
        }
    }
}
