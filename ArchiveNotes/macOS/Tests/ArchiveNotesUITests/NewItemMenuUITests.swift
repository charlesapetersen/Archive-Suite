import XCTest

/// W40.fix-notes-new-note — the owner's steps from Notes guided session 1 (`verification/sessions/notes-1-returned.md`
/// rows 5, 38, 39 and 43), in the VM. Row 5: ⌘N was not in the menu bar and did nothing. Rows 38-39: the toolbar's
/// New offered only New Extract in what read as the Notes window. Row 43: a new template became an extract unasked.
/// Scratch fixture only (`AN-GUI-Fixture`).
final class NewItemMenuUITests: NotesFixtureUITestCase {

    /// Row 5: File ▸ New Note and its ⌘N make a note; File ▸ New Extract makes an extract, shown in the Extracts
    /// window, from the Notes window.
    func testMenuBarNewNoteAndNewExtract() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            app.activate()
            let fileMenu = app.menuBars.menuBarItems["File"]
            XCTAssertTrue(fileMenu.waitForExistence(timeout: 10), "the File menu should exist")
            fileMenu.click()
            let newNote = fileMenu.menuItems["New Note"]
            XCTAssertTrue(newNote.waitForExistence(timeout: 5), "File ▸ New Note should exist")
            XCTAssertTrue(fileMenu.menuItems["New Extract"].exists, "File ▸ New Extract should exist")
            shot("file-menu")
            var before = itemDirs()
            newNote.click()
            let viaMenu = try created(since: before, kind: "note", step: "File ▸ New Note")
            XCTAssertTrue(listed(viaMenu, in: mainWindow, timeout: 10),
                          "the note made from the menu bar should be listed in the Notes window")

            before = itemDirs()
            app.typeKey("n", modifierFlags: .command)
            _ = try created(since: before, kind: "note", step: "⌘N")

            before = itemDirs()
            fileMenu.click()
            fileMenu.menuItems["New Extract"].click()
            let extract = try created(since: before, kind: "extract", step: "File ▸ New Extract")
            let extracts = app.windows["Extracts"]
            XCTAssertTrue(extracts.waitForExistence(timeout: 10), "New Extract should show the Extracts window")
            XCTAssertTrue(listed(extract, in: extracts, timeout: 15),
                          "the new extract should be listed in the Extracts window: \(extracts.debugDescription)")
            shot("after-new-extract", extracts)
        }
    }

    /// Rows 38-39: each window says which it is, and its toolbar New offers both kinds.
    func testToolbarShowsTheWindowKindAndOffersBothKinds() throws {
        try withFixture {
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            let notesKind = mainWindow.descendants(matching: .any)["an.toolbar.windowKind"].firstMatch
            XCTAssertTrue(notesKind.waitForExistence(timeout: 10), "the Notes window should name its kind")
            XCTAssertTrue(label(notesKind).contains("Notes"), "the Notes window reads \(label(notesKind))")
            let extracts = app.windows["Extracts"]
            if extracts.waitForExistence(timeout: 10) {
                let extractsKind = extracts.descendants(matching: .any)["an.toolbar.windowKind"].firstMatch
                XCTAssertTrue(extractsKind.waitForExistence(timeout: 10), "the Extracts window should name its kind")
                XCTAssertTrue(label(extractsKind).contains("Extracts"), "the Extracts window reads \(label(extractsKind))")
            }
            app.activate()
            let newMenu = mainWindow.descendants(matching: .any)["an.toolbar.new"].firstMatch
            XCTAssertTrue(newMenu.waitForExistence(timeout: 10), "the toolbar New menu should exist")
            newMenu.click()
            XCTAssertTrue(newMenu.menuItems["New Note"].waitForExistence(timeout: 5), "the toolbar New should offer a note")
            XCTAssertTrue(newMenu.menuItems["New Extract"].exists, "the toolbar New should offer an extract")
            shot("toolbar-new")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Row 43: New Template asks which kind it makes, and makes that kind.
    func testNewTemplateAsksItsKind() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let templates = mainWindow.staticTexts.matching(identifier: "an.sidebar.templates").firstMatch
            XCTAssertTrue(templates.waitForExistence(timeout: 10))
            templates.click()
            let newButton = mainWindow.descendants(matching: .any)["an.template.new"]
            XCTAssertTrue(newButton.waitForExistence(timeout: 10))
            newButton.click()
            let sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "New Template sheet should open")
            let picker = sheet.descendants(matching: .any)["an.template.new.kind"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "the sheet should ask the kind: \(sheet.debugDescription)")
            let extractChoice = picker.radioButtons["Extracts"].exists ? picker.radioButtons["Extracts"]
                : sheet.descendants(matching: .any)["Extracts"].firstMatch
            XCTAssertTrue(extractChoice.exists, "the kind picker should offer Extracts: \(sheet.debugDescription)")
            shot("template-sheet")
            extractChoice.click()
            let name = sheet.textFields.firstMatch
            name.click()
            name.typeKey("a", modifierFlags: .command)
            name.typeText("Kind Fixture")
            sheet.buttons["Create"].click()

            let root = URL(fileURLWithPath: Self.canonicalFixturePath).appendingPathComponent("Templates", isDirectory: true)
            var text = ""
            XCTAssertTrue(pollUntil(timeout: 15) {
                let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                text = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
                    .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                    .first { $0.contains("Kind Fixture") } ?? ""
                return !text.isEmpty
            }, "the template should be written")
            XCTAssertTrue(text.contains("kind: extract"), "the template takes the chosen kind: \(text)")
        }
    }

    // MARK: helpers

    /// The one item directory with a `.md` made since `before`, checked to be `kind`.
    private func created(since before: Set<String>, kind: String, step: String) throws -> String {
        var made: [String] = []
        XCTAssertTrue(pollUntil(timeout: 15) {
            made = self.itemDirs().subtracting(before).filter { !self.mdFiles(inItemDir: $0).isEmpty }
            return made.count == 1
        }, "\(step) should create exactly one item (made \(made.count))")
        let dir = try XCTUnwrap(made.first, step)
        XCTAssertTrue((rawMarkdown(inItemDir: dir) ?? "").contains("kind: \(kind)"),
                      "\(step) should make a \(kind): \(rawMarkdown(inItemDir: dir) ?? "nil")")
        return dir
    }

    private func listed(_ id: String, in window: XCUIElement, timeout: TimeInterval) -> Bool {
        let upper = window.descendants(matching: .any)["an.cell.title.\(id.uppercased())"].firstMatch
        let lower = window.descendants(matching: .any)["an.cell.title.\(id.lowercased())"].firstMatch
        return pollUntil(timeout: timeout) { upper.exists || lower.exists }
    }

    private func label(_ element: XCUIElement) -> String {
        [element.label, (element.value as? String) ?? "", element.title].joined(separator: " ")
    }

    private func shot(_ name: String, _ window: XCUIElement? = nil) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-newitem-\(name).png")
        do {
            try (window ?? mainWindow).screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] newitem-\(name): wrote \(url.path)")
        } catch {
            print("[shot] newitem-\(name): could not write \(url.path) — \(error)")
        }
    }
}
