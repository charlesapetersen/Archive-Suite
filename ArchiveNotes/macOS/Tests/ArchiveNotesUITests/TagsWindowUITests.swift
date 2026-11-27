import XCTest

/// W40.tag-window-notes — Tags ▸ Tags Window opens the suite's shared Tags window over the notes and extracts; Rename
/// and Remove there change every note carrying the tag, and ⌘Z in that window puts each back in one step. Scratch
/// fixture only; the assertions read the notes' own `.md` files.
final class TagsWindowUITests: NotesFixtureUITestCase {

    private func tagsLine(_ id: String) -> String {
        let dir = Self.fixturePath + "/items/" + id
        guard let md = mdFiles(inItemDir: id).first,
              let text = try? String(contentsOfFile: dir + "/" + md, encoding: .utf8) else { return "" }
        return text.components(separatedBy: "\n").first { $0.hasPrefix("tags:") } ?? ""
    }

    private func shot(_ name: String, _ window: XCUIElement) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-tagswindow-\(name).png")
        do {
            try window.screenshot().pngRepresentation.write(to: url, options: .atomic)
            print("[shot] tagswindow-\(name): wrote \(url.path)")
        } catch {
            print("[shot] tagswindow-\(name): could not write \(url.path) — \(error)")
        }
    }

    /// By name in any case: the fixture's front matter spells its tags in lower case, and Notes title-cases a tag it
    /// writes back.
    private func row(_ name: String, in window: XCUIElement, part: String = "row") -> XCUIElement {
        window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier ==[c] %@", "tags.\(part).\(name)")).firstMatch
    }

    private func search(_ field: XCUIElement, _ text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    private func status(_ window: XCUIElement) -> String {
        let s = window.staticTexts["tags.status"]
        return (s.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.label
    }

    func testRenameAndRemoveInTheTagsWindowWithUndo() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let a = Self.idPlain, b = Self.idReader
            XCTAssertTrue(waitForIndexReady(timeout: 20))

            app.activate()
            app.menuBars.menuBarItems["Tags"].click()
            let open = app.menuBars.menuItems["Tags Window"]
            XCTAssertTrue(open.waitForExistence(timeout: 5), "Tags ▸ Tags Window should be in the menu")
            open.click()
            let tags = app.windows["Tags"]
            XCTAssertTrue(tags.waitForExistence(timeout: 10), "the Tags window should open")
            let field = tags.textFields["tags.search"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            search(field, "Intel")
            let intel = row("Intel", in: tags)
            XCTAssertTrue(intel.waitForExistence(timeout: 10), "Intel is listed")
            let count = row("Intel", in: tags, part: "items")
            XCTAssertTrue(count.label.contains("2") || (count.value as? String)?.contains("2") == true,
                          "two notes carry Intel (\(count.label))")
            shot("opened", tags)

            // (1) Rename on both notes, then ⌘Z in the Tags window.
            intel.click()
            let rename = tags.buttons["tags.rename"]
            XCTAssertTrue(pollUntil(timeout: 5) { rename.isEnabled }, "Rename is offered for the selected tag")
            rename.click()
            let name = app.textFields["tags.rename.name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5), "Rename asks for the new name")
            name.click()
            name.typeKey("a", modifierFlags: .command)
            name.typeText("Intel Corporation")
            let commit = app.buttons["tags.rename.commit"]
            XCTAssertEqual(commit.title.isEmpty ? commit.label : commit.title, "Rename on 2 notes")
            commit.click()
            XCTAssertTrue(pollUntil(timeout: 15) {
                self.tagsLine(a).contains("Intel Corporation") && self.tagsLine(b).contains("Intel Corporation")
            }, "both notes carrying Intel are renamed: \(tagsLine(a)) / \(tagsLine(b))")
            XCTAssertTrue(tagsLine(a).localizedCaseInsensitiveContains("silicon valley"), "other tags stay")
            XCTAssertTrue(pollUntil(timeout: 5) { self.status(tags).contains("Renamed") },
                          "the window says what it did: \(status(tags))")
            shot("renamed", tags)
            // Still searched for "Intel": the list follows the notes, the new name selected. No typing before ⌘Z, which
            // would undo the typing first, as anywhere on the Mac.
            let renamed = row("Intel Corporation", in: tags)
            XCTAssertTrue(renamed.waitForExistence(timeout: 10), "the list follows the notes")
            renamed.click()
            tags.typeKey("z", modifierFlags: .command)
            XCTAssertTrue(pollUntil(timeout: 15) {
                !self.tagsLine(a).contains("Intel Corporation") && !self.tagsLine(b).contains("Intel Corporation")
                    && self.tagsLine(a).localizedCaseInsensitiveContains("intel")
                    && self.tagsLine(b).localizedCaseInsensitiveContains("intel")
            }, "⌘Z in the Tags window puts Intel back on both: \(tagsLine(a)) / \(tagsLine(b))")

            // (2) Remove from both after a confirmation that names the count, then ⌘Z.
            search(field, "Intel")
            XCTAssertTrue(intel.waitForExistence(timeout: 10), "Intel is listed again")
            intel.click()
            tags.buttons["tags.remove"].click()
            let confirm = app.buttons["tags.remove.confirm"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Remove asks first")
            XCTAssertEqual(confirm.title.isEmpty ? confirm.label : confirm.title, "Remove from 2 notes")
            confirm.click()
            XCTAssertTrue(pollUntil(timeout: 15) {
                !self.tagsLine(a).localizedCaseInsensitiveContains("intel")
                    && !self.tagsLine(b).localizedCaseInsensitiveContains("intel")
            }, "removed from both: \(tagsLine(a)) / \(tagsLine(b))")
            XCTAssertTrue(tagsLine(b).localizedCaseInsensitiveContains("corporate culture"), "other tags stay")
            shot("removed", tags)
            // The list, not the search field, has the focus for ⌘Z (the search's typing was undone first otherwise).
            tags.descendants(matching: .any)["tags.list"].click()
            tags.typeKey("z", modifierFlags: .command)
            XCTAssertTrue(pollUntil(timeout: 15) {
                self.tagsLine(a).localizedCaseInsensitiveContains("intel")
                    && self.tagsLine(b).localizedCaseInsensitiveContains("intel")
            }, "⌘Z puts it back: \(tagsLine(a)) / \(tagsLine(b))")
            shot("undone", tags)
            tags.buttons[XCUIIdentifierCloseWindow].click()
        }
    }
}
