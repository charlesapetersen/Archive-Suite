import XCTest

/// W40.tag-window-reader: Window ▸ Tags in the real app, on the generated scratch fixture only (its tags are read back
/// from disk). Two scratch subjects are added through the Inspector, then renamed, merged and removed in the Tags
/// window, each undone with ⌘Z while the Tags window is in front; Tags ▸ Rename Tag… opens it on the tag.
final class TagsWindowUITests: FixtureUITestCase {
    private let fileA = "00002 IMG — Brown.pdf", fileB = "00004 IMG — Brown.pdf"

    func testRenameMergeRemoveAndUndoInTheTagsWindow() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let stamp = Int(Date().timeIntervalSince1970) % 100_000
        let alpha = "Tagswin Alpha \(stamp)", beta = "Tagswin Alphb \(stamp)", renamed = "Tagswin Renamed \(stamp)"
        addSubject(alpha, toFileNamed: "00002", file: fileA)
        addSubject(beta, toFileNamed: "00004", file: fileB)

        // Tags ▸ Rename Tag… with the tag filtered opens the window on it.
        selectTagInCloud(alpha)
        app.menuBars.menuBarItems["Tags"].click()
        app.menuItems["Rename Tag…"].click()
        let tags = app.windows["Tags"]
        XCTAssertTrue(tags.waitForExistence(timeout: 10), "Rename Tag… should open the Tags window")
        let search = tags.textFields["tags.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { (search.value as? String) == alpha }, "the window should open searched for the tag")
        captureScreenshot("w40-tag-window-reader-opened")

        // (1) Rename, then ⌘Z in the Tags window.
        let rename = tags.buttons["tags.rename"]
        XCTAssertTrue(waitFor { rename.isEnabled }, "the tag should be selected, so Rename is offered")
        rename.click()
        let name = app.textFields["tags.rename.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Rename should ask for the new name")
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(renamed)
        let commit = app.buttons["tags.rename.commit"]
        XCTAssertEqual(commit.title.isEmpty ? commit.label : commit.title, "Rename on 1 file")
        commit.click()
        XCTAssertTrue(waitForTags(on: fileA, containing: [renamed], excluding: [alpha]), "renamed on the file")
        XCTAssertTrue(waitFor { (tags.staticTexts["tags.status"].value as? String ?? tags.staticTexts["tags.status"].label)
            .contains("Renamed") }, "the window should say what it did")
        tags.click()
        pressKey("z", modifiers: .command)
        XCTAssertTrue(waitForTags(on: fileA, containing: [alpha], excluding: [renamed]), "⌘Z in the Tags window undoes it")

        // (2) Merge the near-spelling into the first, then undo.
        replaceSearch(search, with: "Tagswin")
        let rowA = tags.descendants(matching: .any)["tags.row.\(alpha)"]
        let rowB = tags.descendants(matching: .any)["tags.row.\(beta)"]
        XCTAssertTrue(rowA.waitForExistence(timeout: 10) && rowB.waitForExistence(timeout: 10), "both tags listed")
        rowA.click()
        XCUIElement.perform(withKeyModifiers: .command) { rowB.click() }
        tags.buttons["tags.merge"].click()
        let pick = app.buttons["tags.merge.pick.\(alpha)"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5), "Merge should offer each tag as the name to keep")
        pick.click()
        app.buttons["tags.merge.commit"].click()
        XCTAssertTrue(waitForTags(on: fileB, containing: [alpha], excluding: [beta]), "merged into the kept spelling")
        captureScreenshot("w40-tag-window-reader-merged")
        tags.click()
        pressKey("z", modifiers: .command)
        XCTAssertTrue(waitForTags(on: fileB, containing: [beta], excluding: [alpha]), "⌘Z undoes the merge")

        // (3) Remove both after a confirmation that names the count, then undo.
        replaceSearch(search, with: "Tagswin")
        XCTAssertTrue(rowA.waitForExistence(timeout: 10) && rowB.waitForExistence(timeout: 10))
        rowA.click()
        XCUIElement.perform(withKeyModifiers: .command) { rowB.click() }
        tags.buttons["tags.remove"].click()
        let confirm = app.buttons["tags.remove.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Remove should ask first")
        XCTAssertEqual(confirm.title.isEmpty ? confirm.label : confirm.title, "Remove from 2 files")
        confirm.click()
        XCTAssertTrue(waitForTags(on: fileA, containing: ["Unread"], excluding: [alpha]), "removed from the first file")
        XCTAssertTrue(waitForTags(on: fileB, containing: ["Unread"], excluding: [beta]), "removed from the second")
        tags.click()
        pressKey("z", modifiers: .command)
        XCTAssertTrue(waitForTags(on: fileA, containing: [alpha]), "⌘Z puts it back")
        XCTAssertTrue(waitForTags(on: fileB, containing: [beta]))
        captureScreenshot("w40-tag-window-reader-undone")
        tags.buttons[XCUIIdentifierCloseWindow].click()
    }

    func testFindSimilarTagsOpensTheWindowOnItsFindSimilarList() throws {
        app.menuBars.menuBarItems["Tags"].click()
        app.menuItems["Find Similar Tags…"].click()
        let tags = app.windows["Tags"]
        XCTAssertTrue(tags.waitForExistence(timeout: 10), "Find Similar Tags… should open the Tags window")
        let similar = tags.checkBoxes["tags.similar"]
        XCTAssertTrue(similar.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { (similar.value as? Int) == 1 || (similar.value as? Bool) == true },
                      "the window should open on its Find Similar list")
        captureScreenshot("w40-tag-window-reader-similar")
        tags.buttons[XCUIIdentifierCloseWindow].click()
    }

    // MARK: Helpers

    private func addSubject(_ subject: String, toFileNamed prefix: String, file: String) {
        let filter = app.textFields["ar.filter.name"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        filter.typeText(prefix)
        XCTAssertTrue(waitFor { self.rowCount == 1 }, "the name filter should isolate \(file)")
        clickRow(0)
        toolbarButton("ar.toolbar.editTags").click()
        let field = app.textFields["ar.tagEditor.addSubject"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the Inspector should present its subject field")
        field.click()
        field.typeText(subject + "\r")
        XCTAssertTrue(waitForTags(on: file, containing: [subject]), "the subject should reach \(file)")
        app.buttons["ar.tagEditor.done"].firstMatch.click()
        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        filter.typeText(XCUIKeyboardKey.delete.rawValue)
        waitForRows(minimum: 2, timeout: 5)
    }

    private func selectTagInCloud(_ tag: String) {
        let toggle = toolbarButton("ar.toolbar.tagCloud")
        let button = app.buttons.matching(identifier: "ar.tagCloud.tag")
            .matching(NSPredicate(format: "label == %@", tag)).firstMatch
        for _ in 0..<2 where !button.exists {
            toggle.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "the tag cloud should list \(tag)")
        button.click()
        XCTAssertTrue(waitFor { self.rowCount == 1 }, "the tag filter should keep the one file")
    }

    private func replaceSearch(_ search: XCUIElement, with text: String) {
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText(text)
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return condition()
    }

    private func waitForTags(on filename: String, containing required: [String], excluding forbidden: [String] = [],
                             timeout: TimeInterval = 15) -> Bool {
        let path = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(filename).path
        return waitFor(timeout: timeout) {
            // A fresh URL each pass: a reused one caches its resource values and never sees a later write.
            let names = ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
            return required.allSatisfy { w in names.contains { $0.caseInsensitiveCompare(w) == .orderedSame } }
                && forbidden.allSatisfy { u in !names.contains { $0.caseInsensitiveCompare(u) == .orderedSame } }
        }
    }
}
