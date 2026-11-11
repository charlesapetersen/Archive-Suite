import XCTest

/// W40.fix-notes-templates — the owner's steps from Notes guided session 1 (`verification/sessions/notes-1-returned.md`
/// rows 35, 41 and 42), in the VM. Rows 35 and 41: a template could be made only from the sidebar's Templates row
/// and its +, which the owner did not find. Row 42: a template could not be renamed in its list, as a note can.
/// Scratch fixture only (`AN-GUI-Fixture`).
final class TemplatesUITests: NotesFixtureUITestCase {

    /// File ▸ New Template… shows the templates manager and its sheet, then the new template is renamed in its
    /// row by Return, by double-click and by Rename…; Escape writes nothing.
    func testNewTemplateFromMenuAndRenameInList() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            app.activate()
            let fileMenu = app.menuBars.menuBarItems["File"]
            XCTAssertTrue(fileMenu.waitForExistence(timeout: 10), "the File menu should exist")
            fileMenu.click()
            let item = fileMenu.menuItems["New Template\u{2026}"]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "File ▸ New Template… should exist")
            shot("file-menu")
            item.click()
            let sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "New Template… should show the sheet")
            XCTAssertTrue(sheet.descendants(matching: .any)["an.template.new.kind"].firstMatch.exists,
                          "the sheet should ask the kind: \(sheet.debugDescription)")
            let name = sheet.textFields.firstMatch
            name.click()
            name.typeKey("a", modifierFlags: .command)
            name.typeText("Menu Template")
            sheet.buttons["Create"].click()
            XCTAssertTrue(mainWindow.descendants(matching: .any)["an.template.new"].waitForExistence(timeout: 10),
                          "the templates manager should be showing")

            let dir = try XCTUnwrap(pollTemplateDir(containing: "Menu Template"), "the template should be written")
            let id = try XCTUnwrap(UUID(uuidString: dir.lastPathComponent)).uuidString
            let row = mainWindow.descendants(matching: .any)["an.template.row.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the template should be listed")
            shot("created")

            // Return on the selected row.
            row.click()
            app.typeKey(.return, modifierFlags: [])
            // The row's identifier reaches its children, so the field is found by its placeholder.
            let field = mainWindow.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Template name")).firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5),
                          "Return should start a rename in the row: \(mainWindow.debugDescription)")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Interview Notes")
            shot("typing")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) { self.templateText(dir).contains("Interview Notes") },
                          "Return should save the name: \(templateText(dir))")
            XCTAssertTrue(pollUntil(timeout: 5) { !field.exists }, "the row should leave editing")

            // Escape leaves the name as it was.
            row.click()
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Return should start a second rename")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Not Saved")
            app.typeKey(.escape, modifierFlags: [])
            pause(1)
            XCTAssertFalse(templateText(dir).contains("Not Saved"), "Escape should write nothing")
            XCTAssertTrue(templateText(dir).contains("Interview Notes"))
            XCTAssertTrue(pollUntil(timeout: 5) { !field.exists }, "Escape should leave editing")

            // Double-click.
            row.doubleClick()
            XCTAssertTrue(field.waitForExistence(timeout: 5), "a double-click should start a rename")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Letter Notes")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) { self.templateText(dir).contains("Letter Notes") },
                          "a double-click rename should save: \(templateText(dir))")

            // Rename… in the row's menu.
            row.rightClick()
            let rename = app.menuItems["Rename\u{2026}"].firstMatch
            XCTAssertTrue(rename.waitForExistence(timeout: 5), "the row's menu should offer Rename…")
            rename.click()
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Rename… should edit in the row")
            XCTAssertFalse(mainWindow.sheets.firstMatch.exists, "Rename… should not show a sheet")
            app.typeKey("a", modifierFlags: .command)
            app.typeText("Diary Notes")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) { self.templateText(dir).contains("Diary Notes") },
                          "a Rename… edit should save: \(templateText(dir))")
            shot("renamed")
        }
    }

    /// W40.fix-notes-template-fields (notes-2 row 18): with a template selected, the inspector offers its folders and
    /// the fields its notes start with; a date typed there is saved in the template. Not yet run: Notes' VM UITests
    /// wait for W40.vm-macos27-notes; the unit bundle's TemplateInspectorRenderTests cover the drawing meanwhile.
    func testTemplateInspectorOffersFoldersAndSavesADate() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 10))
            app.activate()
            let fileMenu = app.menuBars.menuBarItems["File"]
            XCTAssertTrue(fileMenu.waitForExistence(timeout: 10), "the File menu should exist")
            fileMenu.click()
            fileMenu.menuItems["New Template\u{2026}"].click()
            let sheet = mainWindow.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 10), "New Template… should show the sheet")
            let name = sheet.textFields.firstMatch
            name.click()
            name.typeKey("a", modifierFlags: .command)
            name.typeText("Field Template")
            sheet.buttons["Create"].click()

            let dir = try XCTUnwrap(pollTemplateDir(containing: "Field Template"), "the template should be written")
            let id = try XCTUnwrap(UUID(uuidString: dir.lastPathComponent)).uuidString
            let row = mainWindow.descendants(matching: .any)["an.template.row.\(id)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the template should be listed")
            row.click()

            let inspector = mainWindow.descendants(matching: .any)["an.inspector"].firstMatch
            XCTAssertTrue(inspector.waitForExistence(timeout: 10), "the inspector should be showing")
            XCTAssertTrue(inspector.descendants(matching: .any)["an.template.folders.heading"].waitForExistence(timeout: 10),
                          "the inspector should list the template's folders: \(inspector.debugDescription)")
            XCTAssertTrue(inspector.descendants(matching: .any)["an.template.folders.assign"].exists,
                          "and offer Assign to Folder")
            let date = inspector.textFields["an.template.date.field"].firstMatch
            XCTAssertTrue(date.waitForExistence(timeout: 5), "the template's date field should be there")
            date.click()
            date.typeText("1968")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(pollUntil(timeout: 10) { self.templateText(dir).contains("1968") },
                          "the date should be saved in the template: \(templateText(dir))")
            shot("inspector-fields")

            // The manager's row menu assigns too.
            row.rightClick()
            XCTAssertTrue(app.menuItems["Assign to Folder"].firstMatch.waitForExistence(timeout: 5),
                          "the row's menu should offer Assign to Folder")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: helpers

    private var templateRoot: URL {
        URL(fileURLWithPath: Self.canonicalFixturePath).appendingPathComponent("Templates", isDirectory: true)
    }

    private func pollTemplateDir(containing text: String) -> URL? {
        var found: URL?
        _ = pollUntil(timeout: 15) {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: self.templateRoot,
                                                                     includingPropertiesForKeys: nil)) ?? []
            found = dirs.first { self.templateText($0).contains(text) }
            return found != nil
        }
        return found
    }

    private func templateText(_ dir: URL) -> String {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shot(_ name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-templates-\(name).png")
        do {
            try mainWindow.screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] templates-\(name): wrote \(url.path)")
        } catch {
            print("[shot] templates-\(name): could not write \(url.path) — \(error)")
        }
    }
}
