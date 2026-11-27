import XCTest

/// W40.tag-rename-suite — Tags ▸ Rename Tag… renames a subject on every note carrying it, Edit ▸ Undo Rename Tag puts
/// it back in one step, and Tags ▸ Tag Changes from Other Apps… opens (empty: the fixture grants no archive). Scratch
/// fixture only; the assertions read the notes' own `.md` files.
final class TagRenameUITests: NotesFixtureUITestCase {

    private func tagsLine(_ id: String) -> String {
        let dir = Self.fixturePath + "/items/" + id
        guard let md = mdFiles(inItemDir: id).first,
              let text = try? String(contentsOfFile: dir + "/" + md, encoding: .utf8) else { return "" }
        return text.components(separatedBy: "\n").first { $0.hasPrefix("tags:") } ?? ""
    }

    private func shot(_ name: String, _ window: XCUIElement? = nil) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-tagrename-\(name).png")
        do {
            try (window ?? mainWindow).screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] tagrename-\(name): wrote \(url.path)")
        } catch {
            print("[shot] tagrename-\(name): could not write \(url.path) — \(error)")
        }
    }

    private func menu(_ bar: String, _ item: String) {
        app.activate()
        app.menuBars.menuBarItems[bar].click()
        let entry = app.menuBars.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(bar) ▸ \(item) should be in the menu")
        entry.click()
    }

    func testRenameTagAcrossNotesAndUndo() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let a = Self.idPlain, b = Self.idReader
            XCTAssertTrue(waitForIndexReady(timeout: 20))
            _ = selectItem(uuid: a)

            menu("Tags", "Rename Tag…")
            let from = app.descendants(matching: .any)["an.renameTag.from"]
            XCTAssertTrue(from.waitForExistence(timeout: 8), "the Rename Tag sheet should open")
            from.click()
            let intel = app.menuItems["Intel"]
            XCTAssertTrue(intel.waitForExistence(timeout: 5), "Intel is one of the subjects offered")
            intel.click()
            let name = app.descendants(matching: .any)["an.renameTag.newName"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.click()
            name.typeText("Intel Corporation")
            shot("rename-tag-sheet", app.windows.firstMatch)
            app.descendants(matching: .any)["an.renameTag.commit"].click()

            XCTAssertTrue(pollUntil(timeout: 15) {
                self.tagsLine(a).contains("Intel Corporation") && self.tagsLine(b).contains("Intel Corporation")
            }, "both notes carrying Intel are renamed: \(tagsLine(a)) / \(tagsLine(b))")
            XCTAssertTrue(tagsLine(a).localizedCaseInsensitiveContains("silicon valley"), "other tags stay")
            XCTAssertTrue(tagsLine(b).localizedCaseInsensitiveContains("corporate culture"), "other tags stay")

            // The list's Undo, as for a delete: the note editor keeps its own text Undo while it has the focus.
            let row = mainWindow.descendants(matching: .any)["an.cell.title.\(a)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            revealRow(row)
            row.click()
            app.activate()
            let edit = app.menuBars.menuBarItems["Edit"]
            edit.click()
            let undo = edit.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo'")).firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            print("[tagrename] Edit menu undo title: \(undo.title)")
            XCTAssertTrue(undo.isEnabled, "Edit ▸ Undo should be enabled after the rename (title: \(undo.title))")
            undo.click()
            XCTAssertTrue(pollUntil(timeout: 15) {
                !self.tagsLine(a).contains("Intel Corporation") && !self.tagsLine(b).contains("Intel Corporation")
                    && self.tagsLine(a).localizedCaseInsensitiveContains("intel")
                    && self.tagsLine(b).localizedCaseInsensitiveContains("intel")
            }, "one Undo puts Intel back on both: \(tagsLine(a)) / \(tagsLine(b))")

            menu("Tags", "Tag Changes from Other Apps…")
            let none = app.descendants(matching: .any)["an.tagChanges.none"]
            XCTAssertTrue(none.waitForExistence(timeout: 8), "with no archive granted there is nothing waiting")
            shot("tag-changes-sheet", app.windows.firstMatch)
            app.descendants(matching: .any)["an.tagChanges.done"].click()
        }
    }
}
