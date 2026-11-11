import XCTest

/// W40.notes-advanced-search — the Advanced Search form in the running app (Tart VM): the filter bar's Advanced Search button opens it on the
/// starter rows, the field, operator and combine popups work, the live count follows the rules, Search makes them
/// the list, Save as Smart Folder stores them, and Edit Smart Folder… reopens them filled in and saves in place.
///
/// Fixture notes (see `NotesE2SearchTests`): `idPlain` "My First Note" (tags silicon valley, intel); `idReader`
/// "Moore on Intel culture" (body says "egalitarian"; tags intel, corporate culture); `idZotero` "Lovelace paper".
final class NotesAdvancedSearchUITests: NotesFixtureUITestCase {

    private var allNotes: Set<String> { [Self.idPlain, Self.idReader, Self.idZotero] }

    /// W40.fix-notes-advanced-search-menu: test the real menu and key dispatch, including scene routing.
    func testAdvancedSearchMenuAndShortcutTargetTheFrontWindow() throws {
        try withFixture {
            XCTAssertTrue(waitForIndexReady(timeout: 30))
            _ = selectItem(uuid: Self.idPlain)
            let editor = mainWindow.textViews["an.editor.text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            editor.click()

            app.menuBars.menuBarItems["Edit"].click()
            let command = app.menuItems["Advanced Search…"]
            XCTAssertTrue(command.waitForExistence(timeout: 5), "Edit must contain Advanced Search…")
            XCTAssertTrue(command.isEnabled, "editor focus must retain the window's search action")
            command.click()
            assertSearchAndCancel(in: mainWindow)

            for target in [mainWindow.textFields["an.filter.search"], editor] {
                target.click()
                app.typeKey("f", modifierFlags: [.command, .option, .shift])
                assertSearchAndCancel(in: mainWindow)
            }

            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Extracts"].click()
            let extracts = app.windows["Extracts"]
            XCTAssertTrue(extracts.waitForExistence(timeout: 10))
            extracts.textFields["an.filter.search"].click()
            app.typeKey("f", modifierFlags: [.command, .option, .shift])
            XCTAssertFalse(mainWindow.sheets.firstMatch.exists, "search belongs to the front window")
            assertSearchAndCancel(in: extracts)

            // Switching back must restore Notes' action, rather than retain the Extracts closure.
            app.menuBars.menuBarItems["Window"].click()
            app.menuItems["Archive Notes"].click()
            mainWindow.textFields["an.filter.search"].click()
            app.typeKey("f", modifierFlags: [.command, .option, .shift])
            XCTAssertFalse(extracts.sheets.firstMatch.exists)
            assertSearchAndCancel(in: mainWindow)
        }
    }

    private func assertSearchAndCancel(in window: XCUIElement,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "search should open in \(window.title)", file: file, line: line)
        XCTAssertEqual(sheet.popUpButtons.matching(identifier: "an.advanced.rule.field").count, 3,
                       "the same starter form as the filter-bar action", file: file, line: line)
        shot("advanced-search-menu-\(window.title)", in: window)
        sheet.buttons["Cancel"].click()
        XCTAssertTrue(pollUntil(timeout: 5) { !sheet.exists }, file: file, line: line)
    }

    func testAdvancedSearchFormSearchSaveAndEdit() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertTrue(waitForIndexReady(timeout: 30), "the search index should be built")
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes })

            let advanced = mainWindow.buttons["an.filter.advanced"]
            XCTAssertTrue(advanced.waitForExistence(timeout: 10), "the filter bar should offer Advanced…")
            advanced.click()
            var sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Advanced… should open the form")
            let fields = sheet.popUpButtons.matching(identifier: "an.advanced.rule.field")
            XCTAssertEqual(fields.count, 3, "the form opens on three starter rows")
            XCTAssertEqual(fields.element(boundBy: 0).value as? String, "Any text")
            XCTAssertEqual(fields.element(boundBy: 1).value as? String, "Tags")
            XCTAssertEqual(fields.element(boundBy: 2).value as? String, "Date")
            XCTAssertTrue(pollUntil(timeout: 10) { self.count(in: sheet) == "3 items match" },
                          "empty starter rows match everything, saw \(count(in: sheet))")
            shot("w40-notes-advanced-starter")

            // Row 1: any text contains "egalitarian" (the Reader note's body only).
            let text = sheet.textFields.matching(identifier: "an.advanced.rule.text").firstMatch
            text.click()
            text.typeText("egalitarian")
            XCTAssertTrue(pollUntil(timeout: 10) { self.count(in: sheet) == "1 item matches" },
                          "the count should follow the text rule, saw \(count(in: sheet))")

            // Row 2: tags has any of "silicon valley"; match ANY row → the Reader note and My First Note.
            let tagOp = sheet.popUpButtons.matching(identifier: "an.advanced.rule.op").element(boundBy: 1)
            tagOp.click()
            app.menuItems["has any of"].click()
            let tags = sheet.textFields.matching(identifier: "an.advanced.rule.tags").firstMatch
            tags.click()
            // The field autocompletes (W40.fix-notes-tag-fields): type a key at a time, as the tag bar's test does,
            // since synthesizing a burst while the completion list opens times out. Return makes the tag a chip.
            for ch in "silicon valley" { app.typeText(String(ch)); Thread.sleep(forTimeInterval: 0.1) }
            Thread.sleep(forTimeInterval: 0.5)
            app.typeKey(.return, modifierFlags: [])
            let chip = sheet.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH[c] %@", "an.advanced.rule.tagChip.silicon valley")).firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "the tag should show as a chip")
            let combine = sheet.popUpButtons["an.advanced.combine"]
            combine.click()
            app.menuItems["any"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.count(in: sheet) == "2 items match" },
                          "any of the two rules should match two notes, saw \(count(in: sheet))")
            // A field change offers that field's operators.
            fields.element(boundBy: 2).click()
            app.menuItems["Quality"].click()
            XCTAssertEqual(sheet.popUpButtons.matching(identifier: "an.advanced.rule.op").element(boundBy: 2)
                .value as? String, "is one of")
            shot("w40-notes-advanced-filled")

            sheet.buttons["an.advanced.search"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idPlain, Self.idReader] },
                          "Search should make the rules the list, saw \(visibleNotes())")
            XCTAssertTrue(mainWindow.descendants(matching: .any)["an.filter.advancedScope"].firstMatch.exists,
                          "the bar should say the list is an Advanced Search")
            shot("w40-notes-advanced-scope")

            // Edit… reopens it filled in; save it as a smart folder.
            mainWindow.buttons["an.filter.advancedEdit"].click()
            sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            XCTAssertEqual(sheet.textFields.matching(identifier: "an.advanced.rule.text").firstMatch.value as? String,
                           "egalitarian")
            sheet.buttons["an.advanced.saveAs"].click()
            let name = sheet.textFields["an.advanced.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.click()
            name.typeText("E2 Advanced")
            sheet.buttons["an.advanced.saveNamed"].click()
            XCTAssertTrue(smartRow(named: "E2 Advanced").waitForExistence(timeout: 10),
                          "the saved search should appear under Smart Folders")
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idPlain, Self.idReader] })

            // Edit Smart Folder…: drop the tags row and save in place.
            smartRow(named: "E2 Advanced").rightClick()
            let edit = app.menuItems["Edit Smart Folder\u{2026}"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5), "a smart folder should offer Edit Smart Folder…")
            edit.click()
            sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            XCTAssertTrue(sheet.staticTexts["Edit Smart Folder \u{201c}E2 Advanced\u{201d}"].exists)
            shot("w40-notes-advanced-edit")
            sheet.buttons.matching(identifier: "an.advanced.remove").element(boundBy: 1).click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.count(in: sheet) == "1 item matches" },
                          "without the tags row only the text rule is left, saw \(count(in: sheet))")
            sheet.buttons["an.advanced.search"].click()   // "Save" while editing
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idReader] },
                          "the edited smart folder should show the one egalitarian note, saw \(visibleNotes())")
        }
    }

    // MARK: - Helpers

    private func visibleNotes() -> Set<String> {
        allNotes.filter { mainWindow.descendants(matching: .any)["an.cell.title.\($0)"].exists }
    }

    private func count(in sheet: XCUIElement) -> String {
        let label = sheet.staticTexts["an.advanced.count"]
        return (label.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label.label
    }

    private func smartRow(named name: String) -> XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "an.sidebar.smart")
            .matching(NSPredicate(format: "value == %@", name)).firstMatch
    }

    private func shot(_ name: String, in window: XCUIElement? = nil) {
        let screenshot = (window ?? mainWindow).screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url, options: .atomic)
            print("[shot] \(name): wrote \(url.path)")
        } catch {
            XCTFail("Could not save search screenshot: \(error)")
        }
    }
}
