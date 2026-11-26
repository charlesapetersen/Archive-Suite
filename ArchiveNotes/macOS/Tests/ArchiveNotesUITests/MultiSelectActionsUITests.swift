import XCTest

/// W49.notes-multiselect-actions — with two notes selected, the inspector sets Quality and adds and removes a tag on
/// both, the row menu offers Delete 2 Notes… (one prompt), and Edit ▸ Undo puts both back. Scratch fixture only; the
/// assertions read the notes' own `.md` files.
final class MultiSelectActionsUITests: NotesFixtureUITestCase {

    private var inspector: XCUIElement { mainWindow.descendants(matching: .any)["an.inspector"] }

    private func noteText(_ id: String) -> String {
        let dir = Self.fixturePath + "/items/" + id
        guard let md = mdFiles(inItemDir: id).first,
              let text = try? String(contentsOfFile: dir + "/" + md, encoding: .utf8) else { return "" }
        return text
    }

    private func frontMatterLine(_ id: String, _ key: String) -> String {
        noteText(id).components(separatedBy: "\n").first { $0.hasPrefix(key + ":") } ?? ""
    }

    func testBulkQualityTagsDeleteAndUndo() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let a = Self.idPlain, b = Self.idReader
            XCTAssertTrue(waitForIndexReady(timeout: 20))
            _ = selectItem(uuid: a)
            let rowB = mainWindow.descendants(matching: .any)["an.cell.title.\(b)"]
            XCTAssertTrue(rowB.waitForExistence(timeout: 10))
            revealRow(rowB)
            XCUIElement.perform(withKeyModifiers: .command) { rowB.click() }

            if !inspector.waitForExistence(timeout: 3) { app.typeKey("i", modifierFlags: [.command, .option]) }
            let bulk = mainWindow.descendants(matching: .any)["an.inspector.bulk"]
            XCTAssertTrue(bulk.waitForExistence(timeout: 10), "two selected notes show the bulk inspector")
            let inside = bulk.descendants(matching: .any)
            XCTAssertTrue(inside["an.bulk.quality.mixed"].exists, "one note has Quality 3 and one none: Mixed")
            shot("bulk-inspector")

            // Quality 2 on both.
            let quality = inside["an.bulk.quality"]
            XCTAssertTrue(quality.waitForExistence(timeout: 5))
            quality.buttons["2"].click()
            XCTAssertTrue(pollUntil(timeout: 10) {
                self.frontMatterLine(a, "quality") == "quality: 2" && self.frontMatterLine(b, "quality") == "quality: 2"
            }, "both notes should be Quality 2: \(frontMatterLine(a, "quality")) / \(frontMatterLine(b, "quality"))")

            // A tag added to both, then the shared Intel tag removed from both.
            let field = inside["an.bulk.tags.input"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.click()
            field.typeText("Bulk Tag\r")
            XCTAssertTrue(pollUntil(timeout: 10) {
                self.frontMatterLine(a, "tags").localizedCaseInsensitiveContains("bulk tag")
                    && self.frontMatterLine(b, "tags").localizedCaseInsensitiveContains("bulk tag")
            }, "the tag should be on both: \(frontMatterLine(a, "tags")) / \(frontMatterLine(b, "tags"))")
            let removeIntel = inside["an.bulk.tags.remove.Intel"]
            XCTAssertTrue(removeIntel.waitForExistence(timeout: 5), "Intel is on both and can be removed from both")
            removeIntel.click()
            XCTAssertTrue(pollUntil(timeout: 10) {
                !self.frontMatterLine(a, "tags").localizedCaseInsensitiveContains("intel")
                    && !self.frontMatterLine(b, "tags").localizedCaseInsensitiveContains("intel")
            }, "Intel should be off both: \(frontMatterLine(a, "tags")) / \(frontMatterLine(b, "tags"))")
            XCTAssertTrue(frontMatterLine(b, "tags").localizedCaseInsensitiveContains("corporate culture"),
                          "each note keeps its other tags")

            // One prompt deletes both.
            app.activate()
            rowB.rightClick()
            // Edit ▸ Delete 2 Notes… has the same title, so take the open row menu's (the hittable one).
            let titled = app.menuItems.matching(NSPredicate(format: "title == %@", "Delete 2 Notes…"))
            var delete: XCUIElement?
            XCTAssertTrue(pollUntil(timeout: 5) {
                delete = titled.allElementsBoundByIndex.first { $0.isHittable }
                return delete != nil
            }, "the row menu should offer Delete 2 Notes…")
            XCTAssertTrue(app.menuItems["Set Quality"].exists, "and Set Quality for both")
            try XCTUnwrap(delete).click()
            let confirm = app.descendants(matching: .any)["an.dialog.deleteLastInstance.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 8), "the delete should ask once")
            shot("bulk-delete-prompt", app.windows.firstMatch)
            confirm.click()
            XCTAssertTrue(pollUntil(timeout: 15) { !self.itemDirs().contains(a) && !self.itemDirs().contains(b) },
                          "both notes should leave items/")
            XCTAssertFalse(confirm.exists, "no second prompt follows")
            XCTAssertFalse((organizationMemberships() ?? []).contains { $0[1] == a || $0[1] == b },
                           "no placement is left on either")

            // One Undo brings both back.
            app.activate()
            let edit = app.menuBars.menuBarItems["Edit"]
            edit.click()
            let undo = edit.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Undo'")).firstMatch
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            XCTAssertTrue(undo.isEnabled, "Edit ▸ Undo should be enabled after the delete (title: \(undo.title))")
            undo.click()
            XCTAssertTrue(pollUntil(timeout: 15) { self.itemDirs().contains(a) && self.itemDirs().contains(b) },
                          "one Undo should bring both notes back")
            XCTAssertTrue(pollUntil(timeout: 8) {
                (self.organizationMemberships() ?? []).contains([Self.folderReading, a])
            }, "and file them again")
        }
    }

    private func shot(_ name: String, _ window: XCUIElement? = nil) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-multiselect-\(name).png")
        do {
            try (window ?? mainWindow).screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] multiselect-\(name): wrote \(url.path)")
        } catch {
            print("[shot] multiselect-\(name): could not write \(url.path) — \(error)")
        }
    }
}
