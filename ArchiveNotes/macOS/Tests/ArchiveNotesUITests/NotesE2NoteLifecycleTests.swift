import XCTest

/// W9.e2-notes — the note-lifecycle part of the gap-closure runtime sweep (plan E2, record in `SUITE_TODO_DONE.md`).
/// Most of that part is already driven elsewhere in this bundle: delete + the delete-last-instance guard
/// (`testG8_…`, `testG19_…`), tag editing with the Finder-tag projection following (`testG17_…`), the
/// inline quality edit (`testW9D4_…`) and the empty states (`testW9D8_…`). This class covers the two
/// behaviours nothing drove yet: the row context menu's "Open" (D2), and B8, once manual authors and now that
/// notes have none.
///
/// Scratch fixture only. Each check puts the fixture back the way it found it, because the container and
/// fixture are shared by every class in a VM run and this one sorts before `NotesGUITests`.
final class NotesE2NoteLifecycleTests: NotesFixtureUITestCase {

    /// B8 was manual authors; notes have none now (W40.notes-remove-authors, owner's Notes session 2 row 14). The
    /// inspector of a note and of an extract shows its date field and no authors field.
    func testE2_InspectorHasNoAuthorsField() throws {
        try withFixture {
            selectItem(uuid: Self.idPlain)
            assertNoAuthorsField(in: mainWindow)
            // The extract lives in the Extracts window, which the note window's list never shows.
            let win = openExtractsWindow()
            let extractCell = win.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
            XCTAssertTrue(extractCell.waitForExistence(timeout: 15), "the fixture extract should be listed")
            extractCell.click()
            assertNoAuthorsField(in: win)
            closeExtractsWindow(win)
        }
    }

    /// D2 — the row context menu's "Open" selects and loads that row (per the E1 result it only
    /// re-selects; it opens no new window). Read-only with respect to the store.
    func testE2_ContextMenuOpenSelectsAndLoadsTheRow() throws {
        try withFixture {
            selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) { ((self.editor.value as? String) ?? "").contains("A plain note") },
                          "the plain note should be loaded first")
            let windowsBefore = app.windows.count

            let target = mainWindow.descendants(matching: .any)["an.cell.title.\(Self.idReader)"]
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            target.rightClick()
            // The File menu may carry its own "Open…"; only the open context menu's item is hittable.
            let open = app.menuItems.matching(identifier: "Open").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(open, "the row context menu should offer Open")
            open?.click()

            XCTAssertTrue(pollUntil(timeout: 10) { ((self.editor.value as? String) ?? "").contains("egalitarian") },
                          "Open should load the right-clicked note into the editor")
            XCTAssertEqual(app.windows.count, windowsBefore, "Open re-selects in place; it opens no window")
        }
    }

    /// S-010. Drive the real multi-row menu and answer two consecutive window-modal prompts.
    func testS010_MultiRemoveAsksAboutBothNotes() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let reading = mainWindow.descendants(matching: .any).matching(identifier: "an.sidebar.folder")
                .matching(NSPredicate(format: "value == %@ OR label == %@", "Reading", "Reading")).firstMatch
            XCTAssertTrue(reading.waitForExistence(timeout: 10))
            reading.click()

            let before = itemDirs()
            app.typeKey("n", modifierFlags: .command)
            XCTAssertTrue(pollUntil(timeout: 10) { self.itemDirs().subtracting(before).count == 1 })
            let created = try XCTUnwrap(itemDirs().subtracting(before).first)
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.organizationMemberships() ?? []).contains([Self.folderReading, created])
            })
            let titlesByID = [Self.idPlain: "My First Note", created: "Untitled"]
            let memberships = try XCTUnwrap(organizationMemberships())
            for id in titlesByID.keys {
                XCTAssertEqual(memberships.filter { $0[1] == id }, [[Self.folderReading, id]])
            }

            let plainRow = selectItem(uuid: Self.idPlain)
            let createdRow = mainWindow.descendants(matching: .any)["an.cell.title.\(created.uppercased())"]
            XCTAssertTrue(createdRow.waitForExistence(timeout: 10))
            XCUIElement.perform(withKeyModifiers: .command) { createdRow.click() }
            plainRow.rightClick()
            let remove = app.menuItems["Remove 2 Items from “Reading”"]
            XCTAssertTrue(remove.waitForExistence(timeout: 5))
            remove.click()

            let confirm = app.buttons["an.dialog.deleteLastInstance.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 10))
            let firstID = try XCTUnwrap(titlesByID.first {
                app.staticTexts["Delete “\($0.value)”?"].exists
            }?.key)
            let secondID = try XCTUnwrap(titlesByID.keys.first { $0 != firstID })
            let secondTitle = try XCTUnwrap(titlesByID[secondID])
            let firstTrash = Self.fixturePath + "/Trash/" + firstID
            let secondTrash = Self.fixturePath + "/Trash/" + secondID
            XCTAssertTrue(itemDirs().isSuperset(of: titlesByID.keys))
            confirm.click()

            let nextPrompt = app.staticTexts["Delete “\(secondTitle)”?"]
            XCTAssertTrue(nextPrompt.waitForExistence(timeout: 10), "the other note must get its own prompt")
            let shot = FileManager.default.temporaryDirectory.appendingPathComponent("s010-second-prompt.png")
            try app.screenshot().pngRepresentation.write(to: shot)
            print("[shot] s010-second-prompt: wrote \(shot.path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstTrash))
            XCTAssertFalse(itemDirs().contains(firstID))

            let cancel = app.buttons["an.dialog.deleteLastInstance.cancel"]
            XCTAssertTrue(cancel.exists)
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 5) { !cancel.exists })
            XCTAssertTrue(itemDirs().contains(secondID))
            XCTAssertFalse(FileManager.default.fileExists(atPath: secondTrash))
            XCTAssertTrue((organizationMemberships() ?? []).contains([Self.folderReading, secondID]))
        }
    }

    // MARK: - Helpers

    /// Which of the three fixture notes the note window's list currently shows.
    private func visibleNotes() -> Set<String> {
        Set([Self.idPlain, Self.idReader, Self.idZotero].filter {
            mainWindow.descendants(matching: .any)["an.cell.title.\($0)"].exists
        })
    }

    private func assertNoAuthorsField(in window: XCUIElement) {
        XCTAssertTrue(window.descendants(matching: .any)["an.detail.date.field"].firstMatch.waitForExistence(timeout: 10),
                      "the inspector should show the item's date field")
        XCTAssertFalse(window.descendants(matching: .any)["an.detail.authors"].firstMatch.exists,
                       "the inspector should have no authors field")
    }

    private func openExtractsWindow() -> XCUIElement {
        let win = app.windows["Extracts"]
        if !win.exists {
            let windowMenu = app.menuBars.menuBarItems["Window"]
            XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu should exist")
            windowMenu.click()
            app.menuItems["Extracts"].click()
        }
        XCTAssertTrue(win.waitForExistence(timeout: 15), "the Extracts window should be open")
        return win
    }

    /// Close it again: sibling checks query the editor unscoped and a second window would confuse them.
    private func closeExtractsWindow(_ win: XCUIElement) {
        guard win.exists else { return }
        let close = win.buttons[XCUIIdentifierCloseWindow]
        if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
        _ = pollUntil(timeout: 5) { !win.exists }
    }
}
