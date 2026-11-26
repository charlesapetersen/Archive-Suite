import XCTest

/// W49.notes-polish-small: a double-click on a row away from its title, Date and Tags cells puts the keyboard in the
/// note's editor; the row menu's Duplicate makes a copy; the inspector shows the note's length and dates. Scratch
/// fixture only.
final class NotesPolishUITests: NotesFixtureUITestCase {

    /// A double-click on the row's In (instances) cell, with the list holding the keyboard, sends typing into the note body.
    func testDoubleClickOnARowFocusesTheEditor() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            let titleBefore = rawMarkdown(inItemDir: id)?.components(separatedBy: "\n").first { $0.hasPrefix("title:") }
            _ = selectItem(uuid: Self.idZotero)   // the list now has the keyboard
            let cell = mainWindow.descendants(matching: .any)["an.cell.instances.\(id)"]
            XCTAssertTrue(cell.waitForExistence(timeout: 10), "the list shows the In column")
            revealRow(cell)
            cell.doubleClick()
            wait(1)
            app.typeText("zqxpolish")
            XCTAssertTrue(pollUntil(timeout: 12) { (self.noteBody(uuid: id) ?? "").contains("zqxpolish") },
                          "typing after the double-click should reach the note body; focus: \(keyboardFocusDescription())")
            let titleAfter = rawMarkdown(inItemDir: id)?.components(separatedBy: "\n").first { $0.hasPrefix("title:") }
            XCTAssertEqual(titleAfter, titleBefore, "a double-click away from the title does not rename")
            shot("polish-doubleclick-focus")
        }
    }

    /// The row menu's Duplicate writes a copy titled "… copy", selects it, and the inspector counts its words.
    func testDuplicateFromTheRowMenuAndInfoSection() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let id = Self.idPlain
            _ = selectItem(uuid: id)
            let info = mainWindow.descendants(matching: .any)["an.inspector.info.counts"]
            XCTAssertTrue(pollUntil(timeout: 10) { info.exists && ((info.value as? String) ?? info.label).contains("word") },
                          "the inspector should count the note's words: \(info.debugDescription)")
            XCTAssertTrue(mainWindow.descendants(matching: .any)["an.inspector.info.modified"].exists,
                          "the inspector shows when the note was modified")
            shot("polish-info")

            let before = itemDirs()
            mainWindow.descendants(matching: .any)["an.cell.title.\(id)"].rightClick()
            let duplicate = app.menuItems["Duplicate"]
            XCTAssertTrue(duplicate.waitForExistence(timeout: 5), "the row's menu offers Duplicate")
            duplicate.click()
            var created: [String] = []
            XCTAssertTrue(pollUntil(timeout: 15) {
                created = self.itemDirs().subtracting(before).filter { !self.mdFiles(inItemDir: $0).isEmpty }
                return created.count == 1
            }, "Duplicate should write one new note")
            let copy = try XCTUnwrap(created.first)
            let markdown = rawMarkdown(inItemDir: copy) ?? ""
            XCTAssertTrue(markdown.contains(" copy"), "the copy's title ends in copy: \(markdown.prefix(300))")
            XCTAssertEqual(noteBody(uuid: copy), noteBody(uuid: id), "the copy has the note's body")
            let copyCell = mainWindow.descendants(matching: .any)["an.cell.title.\(copy.uppercased())"]
            XCTAssertTrue(copyCell.waitForExistence(timeout: 10), "the copy is listed")
            shot("polish-duplicate")
        }
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shot(_ name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-\(name).png")
        do {
            try mainWindow.screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] \(name): wrote \(url.path)")
        } catch {
            print("[shot] \(name): could not write \(url.path) — \(error)")
        }
    }
}
