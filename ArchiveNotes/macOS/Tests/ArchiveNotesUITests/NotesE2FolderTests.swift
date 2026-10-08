import XCTest

/// W9.e2-folders — the folder part of the gap-closure runtime sweep (`09-gap-closure.md` §E2): create,
/// subfolder, rename, un-nest, reorder and delete, each asserted on `organization.json`, plus the two D1
/// doubts E1 could not settle from source. Replicate is `NotesGUITests.testG7_…` and a drag onto a folder
/// row re-parenting is `testG18_…`; neither is repeated here.
///
/// D1 doubt 1 — does the row's `.onDrag`/`.onDrop` pre-empt the level's `.onMove`? Yes, so since
/// W9.e2-fu1 the row itself reorders a folder dropped on its top or bottom quarter, and only a middle drop
/// re-parents (`testE2_FolderDragToSiblingGapReorders`, `testE2_FolderDragToBottomEdgeReorders`). D1 doubt 2
/// — can anything re-parent a folder to the top level? No drop target can, so the context menu gained
/// "Move to Top Level", and "Move Up"/"Move Down" as the reorder path that does work.
///
/// Fixture top level, in order: Inbox, Extracts, Reading, Ideas. The fixture is restored from its pristine
/// copy before every test.
final class NotesE2FolderTests: NotesFixtureUITestCase {

    /// A folder can be created, given a subfolder, renamed, moved back to the top level, and deleted.
    func testE2_FolderCreateSubfolderRenameMoveToTopAndDelete() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let newFolder = mainWindow.descendants(matching: .any)["an.sidebar.newFolder"]
            XCTAssertTrue(newFolder.waitForExistence(timeout: 10))
            newFolder.click()
            answerNameAlert("E2 Parent", button: "Create")
            XCTAssertTrue(pollUntil(timeout: 10) { self.folderRecord(named: "E2 Parent") != nil },
                          "New Folder should persist a top-level folder")
            let parent = try XCTUnwrap(folderRecord(named: "E2 Parent"))
            XCTAssertNil(parent.parent, "the bottom-bar + creates a top-level folder")

            folderRow(named: "E2 Parent").rightClick()
            contextItem("New Subfolder…")?.click()
            answerNameAlert("E2 Child", button: "Create")
            XCTAssertTrue(pollUntil(timeout: 10) { self.folderRecord(named: "E2 Child")?.parent == parent.id },
                          "New Subfolder should persist the child under its parent")
            let child = try XCTUnwrap(folderRecord(named: "E2 Child"))

            expand(folderRow(named: "E2 Parent"))
            folderRow(named: "E2 Child").rightClick()
            contextItem("Rename…")?.click()
            answerNameAlert("E2 Renamed", button: "Rename")
            XCTAssertTrue(pollUntil(timeout: 10) { self.folderRecord(id: child.id)?.name == "E2 Renamed" },
                          "Rename should persist the new folder name")

            folderRow(named: "E2 Renamed").rightClick()
            contextItem("Move to Top Level")?.click()
            XCTAssertTrue(pollUntil(timeout: 10) {
                guard let moved = self.folderRecord(id: child.id) else { return false }
                return moved.parent == nil
            }, "Move to Top Level should clear the folder's parent")

            folderRow(named: "Reading").rightClick()
            XCTAssertEqual(contextItem("Move to Top Level")?.isEnabled, false,
                           "a folder already at the top level has nowhere to move to")
            app.typeKey(.escape, modifierFlags: [])

            for (name, id) in [("E2 Renamed", child.id), ("E2 Parent", parent.id)] {
                folderRow(named: name).rightClick()
                contextItem("Delete")?.click()
                // The Touch Bar carries a second "Delete Folder" (and reports it hittable); scope to the
                // confirmation dialog, which may be a window sheet or a free dialog.
                var confirm: XCUIElement?
                XCTAssertTrue(pollUntil(timeout: 5) {
                    confirm = [self.app.sheets.firstMatch, self.app.dialogs.firstMatch]
                        .map { $0.buttons["Delete Folder"].firstMatch }
                        .first { $0.exists }
                    return confirm != nil
                }, "an empty folder deletes without stranding notes")
                confirm?.click()
                XCTAssertTrue(pollUntil(timeout: 10) { self.folderRecord(id: id) == nil },
                              "Delete should remove \(name) from organization.json")
            }
        }
    }

    /// Move Up / Move Down reorder a level and keep every folder at its parent.
    func testE2_FolderMoveUpAndDownReorderTheLevel() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertEqual(ideasAboveReading(), false, "fixture: Ideas starts below Reading")

            folderRow(named: "Ideas").rightClick()
            XCTAssertEqual(contextItem("Move Down")?.isEnabled, false, "the last folder cannot move down")
            contextItem("Move Up")?.click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.ideasAboveReading() == true },
                          "Move Up should put Ideas above Reading")

            folderRow(named: "Ideas").rightClick()
            contextItem("Move Down")?.click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.ideasAboveReading() == false },
                          "Move Down should put Ideas back below Reading")
        }
    }

    /// D1 doubt 1 — dragging a folder to the gap above a sibling should reorder the level (the
    /// `ForEach.onMove`), not be swallowed by the row's own `.onDrop` as a re-parent.
    func testE2_FolderDragToSiblingGapReorders() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let ideasID = Self.folderIdeas.lowercased(), readingID = Self.folderReading.lowercased()
            let reading = folderRow(named: "Reading")
            let ideas = folderRow(named: "Ideas")
            let before = try XCTUnwrap(folderRecord(id: ideasID))
            let readingBefore = try XCTUnwrap(folderRecord(id: readingID))
            XCTAssertNil(before.parent)
            XCTAssertGreaterThan(before.sortOrder, readingBefore.sortOrder, "Ideas starts below Reading")

            ideas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.0,
                       thenDragTo: reading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)))

            var after: FolderRecord?
            var readingAfter: FolderRecord?
            let reordered = pollUntil(timeout: 10) {
                after = self.folderRecord(id: ideasID)
                readingAfter = self.folderRecord(id: readingID)
                guard let a = after, let r = readingAfter else { return false }
                return a.parent == nil && a.sortOrder < r.sortOrder
            }
            let attachment = XCTAttachment(screenshot: mainWindow.screenshot())
            attachment.name = "W9.e2-folder-reorder"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Capture the folder tree after the reorder drag") { $0.add(attachment) }
            XCTAssertTrue(reordered, "dropping Ideas in the gap above Reading should reorder the top level; "
                          + "Ideas is now parent=\(after?.parent ?? "nil") order=\(after?.sortOrder ?? -1), "
                          + "Reading order=\(readingAfter?.sortOrder ?? -1)")
        }
    }

    /// The bottom edge of a row puts the dropped folder after it: Reading onto Ideas' bottom edge.
    func testE2_FolderDragToBottomEdgeReorders() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertEqual(ideasAboveReading(), false, "fixture: Ideas starts below Reading")
            folderRow(named: "Reading").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.0,
                       thenDragTo: folderRow(named: "Ideas").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)))
            XCTAssertTrue(pollUntil(timeout: 10) { self.ideasAboveReading() == true },
                          "dropping Reading on Ideas' bottom edge should put it after Ideas, still at the top level")
        }
    }

    // MARK: - Helpers

    /// Whether Ideas sorts above Reading, both still at the top level; nil if either is missing.
    private func ideasAboveReading() -> Bool? {
        guard let i = folderRecord(id: Self.folderIdeas.lowercased()),
              let r = folderRecord(id: Self.folderReading.lowercased()) else { return nil }
        XCTAssertNil(i.parent); XCTAssertNil(r.parent)
        return i.sortOrder < r.sortOrder
    }

    /// The open context menu's item titled `title`. The main menu can share a label (Edit ▸ Delete), and
    /// only the open context menu's copy is hittable.
    private func contextItem(_ title: String) -> XCUIElement? {
        var hit: XCUIElement?
        _ = pollUntil(timeout: 5) {
            hit = self.app.menuItems.matching(identifier: title).allElementsBoundByIndex.first { $0.isHittable }
            return hit != nil
        }
        XCTAssertNotNil(hit, "the folder context menu should offer \(title)")
        return hit
    }

    private func folderRow(named name: String) -> XCUIElement {
        let row = mainWindow.descendants(matching: .any).matching(identifier: "an.sidebar.folder")
            .matching(NSPredicate(format: "value ==[c] %@ OR label ==[c] %@", name, name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the \(name) folder row should be visible")
        return row
    }

    /// Open a collapsed disclosure row: select it, then Right Arrow (the sidebar is an outline view).
    private func expand(_ row: XCUIElement) {
        row.click()
        app.typeKey(.rightArrow, modifierFlags: [])
    }

    /// Fill the text field of the SwiftUI alert that is up, then press its `button`.
    private func answerNameAlert(_ text: String, button: String) {
        // The alert may be a window sheet or a free dialog, and it appears a beat after the click.
        var alert: XCUIElement?
        XCTAssertTrue(pollUntil(timeout: 8) {
            alert = [self.app.sheets.firstMatch, self.app.dialogs.firstMatch]
                .first { $0.exists && $0.textFields.firstMatch.exists }
            return alert != nil
        }, "the name alert should be up")
        guard let alert else { return }
        let field = alert.textFields.firstMatch
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
        // Scoped to the alert: an unscoped query also matches the Touch Bar's copy of the button.
        alert.buttons[button].firstMatch.click()
    }

    private struct FolderRecord { let id: String; let name: String; let parent: String?; let sortOrder: Int }

    private func folders() -> [FolderRecord] {
        let path = Self.fixturePath + "/organization.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["folders"] as? [[String: Any]] else { return [] }
        return arr.compactMap { f in
            guard let id = f["id"] as? String, let name = f["name"] as? String else { return nil }
            return FolderRecord(id: id.lowercased(), name: name, parent: (f["parentId"] as? String)?.lowercased(),
                                sortOrder: (f["sortOrder"] as? Int) ?? -1)
        }
    }

    private func folderRecord(named name: String) -> FolderRecord? { folders().first { $0.name == name } }
    private func folderRecord(id: String) -> FolderRecord? { folders().first { $0.id == id } }
}
