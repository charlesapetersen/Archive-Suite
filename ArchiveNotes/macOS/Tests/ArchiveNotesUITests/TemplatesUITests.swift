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
            let field = mainWindow.textFields["an.template.rename"]
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
