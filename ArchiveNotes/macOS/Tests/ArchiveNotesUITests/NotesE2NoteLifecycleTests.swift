import XCTest

/// W9.e2-notes — the note-lifecycle part of the gap-closure runtime sweep (`09-gap-closure.md` §E2).
/// Most of that part is already driven elsewhere in this bundle: delete + the delete-last-instance guard
/// (`testG8_…`, `testG19_…`), tag editing with the Finder-tag projection following (`testG17_…`), the
/// inline quality edit (`testW9D4_…`) and the empty states (`testW9D8_…`). This class covers the two
/// behaviours nothing drove yet: manual authors (B8) and the row context menu's "Open" (D2).
///
/// Scratch fixture only. Each check puts the fixture back the way it found it, because the container and
/// fixture are shared by every class in a VM run and this one sorts before `NotesGUITests`.
final class NotesE2NoteLifecycleTests: NotesFixtureUITestCase {

    /// B8 — authors typed in the inspector, with no Zotero involved, reach front matter for a note AND an
    /// extract, and keyword search finds the note by that author.
    func testE2_ManualAuthorsPersistForNoteAndExtractAndAreSearchable() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            selectItem(uuid: Self.idPlain)
            setAuthors("Zenobia Quartermaine", in: mainWindow)
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: Self.idPlain) ?? "").contains("authors: [Zenobia Quartermaine]")
            }, "Set should write the note's authors to front matter")

            let search = mainWindow.textFields["an.filter.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.click()
            search.typeText("Quartermaine")
            XCTAssertTrue(pollUntil(timeout: 15) { self.visibleNotes() == [Self.idPlain] },
                          "searching the new author should find only that note")
            mainWindow.buttons["an.filter.searchClear"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes().count == 3 },
                          "clearing the search should bring back every fixture note")

            // The extract lives in the Extracts window, which the note window's list never shows.
            let win = openExtractsWindow()
            let extractCell = win.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
            XCTAssertTrue(extractCell.waitForExistence(timeout: 15), "the fixture extract should be listed")
            extractCell.click()
            setAuthors("Ignatius Fenwick", in: win)
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: Self.idExtract) ?? "").contains("authors: [Ignatius Fenwick]")
            }, "Set should write the extract's authors to front matter")

            // Put both back so the later checks see the fixture as generated.
            win.buttons["an.detail.authors.clear"].click()
            XCTAssertTrue(pollUntil(timeout: 10) {
                !(self.rawMarkdown(inItemDir: Self.idExtract) ?? "").contains("Ignatius Fenwick")
            }, "Clear should remove the extract's authors")
            closeExtractsWindow(win)
            selectItem(uuid: Self.idPlain)
            let clear = mainWindow.buttons["an.detail.authors.clear"]
            XCTAssertTrue(clear.waitForExistence(timeout: 10))
            clear.click()
            XCTAssertTrue(pollUntil(timeout: 10) {
                !(self.rawMarkdown(inItemDir: Self.idPlain) ?? "").contains("authors:")
            }, "Clear should remove the note's authors line")
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

    // MARK: - Helpers

    /// Which of the three fixture notes the note window's list currently shows.
    private func visibleNotes() -> Set<String> {
        Set([Self.idPlain, Self.idReader, Self.idZotero].filter {
            mainWindow.descendants(matching: .any)["an.cell.title.\($0)"].exists
        })
    }

    private func setAuthors(_ name: String, in window: XCUIElement) {
        let field = window.descendants(matching: .any)["an.detail.authors"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the authors field should be in the inspector")
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        window.buttons["an.detail.authors.set"].click()
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
