import XCTest
import AppKit   // NSPasteboard — read back what Copy Link put there

/// W9.e2 — the runtime half of the gap-closure verification (`09-gap-closure.md` §E2). Each check here
/// drives a feature the earlier per-wave checks only reached from source: manual authors (B8), Copy Link
/// and the `archivenotes://open` round trip (B9 ⇄ B5), keyword + facet filtering, and the folder tree's
/// create / subfolder / rename / back-to-top-level / delete path (D1).
///
/// Every check runs against the generated scratch fixture only and puts the fixture back the way it found
/// it, because this class sorts before `NotesGUITests` and shares its fixture within a VM run.
final class NotesE2SweepTests: NotesFixtureUITestCase {

    /// B8 — authors typed in the inspector, with no Zotero involved, land in front matter for a note AND
    /// an extract, and the search index finds the note by that author.
    func testE2_ManualAuthorsPersistForNoteAndExtractAndAreSearchable() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            setAuthors("Zenobia Quartermaine", on: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: Self.idPlain) ?? "").contains("authors: [Zenobia Quartermaine]")
            }, "Set should write the note's authors to front matter")

            let search = mainWindow.textFields["an.filter.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.click()
            search.typeText("Quartermaine")
            XCTAssertTrue(pollUntil(timeout: 15) {
                self.visible() == [Self.idPlain]
            }, "searching the new author should find only that note")
            mainWindow.buttons["an.filter.searchClear"].click()

            // The extract lives in the Extracts window, which the note window's list never shows.
            let win = openExtractsWindow()
            let extractCell = win.descendants(matching: .any)["an.cell.title.\(Self.idExtract)"]
            XCTAssertTrue(extractCell.waitForExistence(timeout: 15), "the fixture extract should be listed")
            extractCell.click()
            setAuthors("Ignatius Fenwick", in: win)
            XCTAssertTrue(pollUntil(timeout: 10) {
                (self.rawMarkdown(inItemDir: Self.idExtract) ?? "").contains("authors: [Ignatius Fenwick]")
            }, "Set should write the extract's authors to front matter")

            // Put both back so the later checks see the fixture as generated.
            win.buttons["Clear"].firstMatch.click()
            closeExtractsWindow(win)
            clearAuthors(on: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) {
                !(self.rawMarkdown(inItemDir: Self.idPlain) ?? "").contains("authors:")
                    && !(self.rawMarkdown(inItemDir: Self.idExtract) ?? "").contains("Ignatius Fenwick")
            }, "Clear should remove the authors again")
        }
    }

    /// B5/B9 — Note ▸ Copy Link puts the item's `archivenotes://open` URL on the pasteboard, and opening
    /// that URL with a different item selected brings the linked one back.
    func testE2_CopyLinkRoundTripSelectsTheLinkedNote() throws {
        try withFixture {
            selectItem(uuid: Self.idReader)
            let editor = mainWindow.textViews["an.editor.text"]
            XCTAssertTrue(pollUntil(timeout: 10) {
                ((editor.value as? String) ?? "").contains("egalitarian")
            }, "the linked note should be loaded before copying its link")
            // Note ▸ Copy Link follows the editor's focused value, so it is greyed out while the list
            // has focus (W9.e2 finding, filed as W9.e2-fu2); click into the editor first.
            editor.click()
            NSPasteboard.general.clearContents()
            clickMenu("Note", "Copy Link")
            var link: String?
            XCTAssertTrue(pollUntil(timeout: 10) {
                link = NSPasteboard.general.string(forType: .string)
                return link?.hasPrefix("archivenotes://open") == true
            }, "Copy Link should put an archivenotes://open URL on the pasteboard, got \(link ?? "nil")")
            let url = try XCTUnwrap(link.flatMap(URL.init(string:)))
            XCTAssertTrue(url.absoluteString.lowercased().contains(Self.idReader),
                          "the copied link should name the selected item: \(url)")

            selectItem(uuid: Self.idPlain)
            XCTAssertTrue(pollUntil(timeout: 10) {
                ((editor.value as? String) ?? "").contains("A plain note")
            }, "a different note should be showing before the link is opened")
            app.open(url)
            XCTAssertTrue(pollUntil(timeout: 15) {
                ((self.mainWindow.textViews["an.editor.text"].value as? String) ?? "").contains("egalitarian")
            }, "opening the copied link should select and load the linked note")
        }
    }

    /// Keyword search plus each facet narrows the list to the expected fixture items, and Clear restores it.
    func testE2_KeywordSearchAndQualityTagDateFiltersNarrowTheList() throws {
        try withFixture {
            XCTAssertTrue(waitForIndexReady(timeout: 30), "the search index should be built")
            let all = [Self.idPlain, Self.idReader, Self.idZotero]
            XCTAssertTrue(pollUntil(timeout: 10) { all.allSatisfy { self.titleCell($0).exists } })

            let search = mainWindow.textFields["an.filter.search"]
            search.click()
            search.typeText("egalitarian")
            XCTAssertTrue(pollUntil(timeout: 15) { visible() == [Self.idReader] },
                          "a body keyword should match only the note that contains it, saw \(visible())")
            mainWindow.buttons["an.filter.searchClear"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { visible() == Set(all) })

            mainWindow.buttons["an.filter.quality.3"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { visible() == [Self.idReader] },
                          "Quality 3 should leave only the quality-3 note, saw \(visible())")
            mainWindow.buttons["an.filter.quality.3"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { visible() == Set(all) })

            let tag = mainWindow.textFields["an.filter.tagInput"]
            tag.click()
            tag.typeText("intel\r")
            XCTAssertTrue(pollUntil(timeout: 10) { visible() == [Self.idPlain, Self.idReader] },
                          "the intel tag should match the two intel notes, saw \(visible())")
            mainWindow.descendants(matching: .any)["an.filter.clear"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { visible() == Set(all) }, "Clear should drop the tag facet")

            let from = mainWindow.textFields["an.filter.dateFrom"]
            from.click()
            from.typeText("1960")
            let to = mainWindow.textFields["an.filter.dateTo"]
            to.click()
            to.typeText("1970\r")
            XCTAssertTrue(pollUntil(timeout: 10) { visible() == [Self.idReader] },
                          "1960–1970 should leave only the 1968 note, saw \(visible())")
            mainWindow.descendants(matching: .any)["an.filter.clear"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { visible() == Set(all) }, "Clear should drop the date range")
        }
    }

    /// D1 — a folder can be created, given a subfolder, renamed, moved back to the top level, and deleted,
    /// each persisting to `organization.json`.
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
            app.menuItems["New Subfolder…"].click()
            answerNameAlert("E2 Child", button: "Create")
            XCTAssertTrue(pollUntil(timeout: 10) { self.folderRecord(named: "E2 Child")?.parent == parent.id },
                          "New Subfolder should persist the child under its parent")
            let child = try XCTUnwrap(folderRecord(named: "E2 Child"))

            expand(folderRow(named: "E2 Parent"))
            folderRow(named: "E2 Child").rightClick()
            app.menuItems["Rename…"].click()
            answerNameAlert("E2 Renamed", button: "Rename")
            XCTAssertTrue(pollUntil(timeout: 10) { self.folderRecord(id: child.id)?.name == "E2 Renamed" },
                          "Rename should persist the new folder name")

            folderRow(named: "E2 Renamed").rightClick()
            let toTop = app.menuItems["Move to Top Level"]
            XCTAssertTrue(toTop.waitForExistence(timeout: 5), "a nested folder should offer Move to Top Level")
            toTop.click()
            XCTAssertTrue(pollUntil(timeout: 10) {
                guard let moved = self.folderRecord(id: child.id) else { return false }
                return moved.parent == nil
            }, "Move to Top Level should clear the folder's parent")

            folderRow(named: "Reading").rightClick()
            XCTAssertFalse(app.menuItems["Move to Top Level"].isEnabled,
                           "a folder already at the top level has nowhere to move to")
            app.typeKey(.escape, modifierFlags: [])

            for (name, id) in [("E2 Renamed", child.id), ("E2 Parent", parent.id)] {
                folderRow(named: name).rightClick()
                app.menuItems["Delete"].click()
                let confirm = app.buttons["Delete Folder"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5), "an empty folder deletes without stranding notes")
                confirm.click()
                XCTAssertTrue(pollUntil(timeout: 10) { self.folderRecord(id: id) == nil },
                              "Delete should remove \(name) from organization.json")
            }
        }
    }

    /// D1 — dragging a folder to the gap above a sibling reorders the level (the `ForEach.onMove`),
    /// rather than the row's own `.onDrag`/`.onDrop` swallowing it as a reparent.
    func testE2_FolderDragToSiblingGapReorders() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            let reading = folderRow(named: "Reading")
            let ideas = folderRow(named: "Ideas")
            let before = try XCTUnwrap(folderRecord(id: Self.folderIdeas.lowercased()))
            let readingBefore = try XCTUnwrap(folderRecord(id: Self.folderReading.lowercased()))
            XCTAssertNil(before.parent)
            XCTAssertGreaterThan(before.sortOrder, readingBefore.sortOrder, "Ideas starts below Reading")

            ideas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 1.0,
                       thenDragTo: reading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0)))

            var after: FolderRecord?
            var readingAfter: FolderRecord?
            let reordered = pollUntil(timeout: 10) {
                after = self.folderRecord(id: Self.folderIdeas.lowercased())
                readingAfter = self.folderRecord(id: Self.folderReading.lowercased())
                guard let a = after, let r = readingAfter else { return false }
                return a.parent == nil && a.sortOrder < r.sortOrder
            }
            let attachment = XCTAttachment(screenshot: mainWindow.screenshot())
            attachment.name = "W9.e2-folder-reorder"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Capture the folder tree after the reorder drag") { $0.add(attachment) }
            // Strict: once the gap drop reorders, this expected failure itself fails and must come out.
            XCTExpectFailure("W9.e2-fu1: the folder row's .onDrop takes the gap drop as a reparent")
            XCTAssertTrue(reordered, "dropping Ideas in the gap above Reading should reorder the top level; "
                          + "Ideas is now parent=\(after?.parent ?? "nil") order=\(after?.sortOrder ?? -1), "
                          + "Reading order=\(readingAfter?.sortOrder ?? -1)")

            // Put Ideas back at the top level so the checks after this one find the fixture tree intact.
            if after?.parent != nil {
                expand(reading)
                folderRow(named: "Ideas").rightClick()
                app.menuItems["Move to Top Level"].click()
                XCTAssertTrue(pollUntil(timeout: 10) {
                    self.folderRecord(id: Self.folderIdeas.lowercased())?.parent == nil
                }, "Move to Top Level should restore Ideas to the root")
            }
        }
    }

    // MARK: - Helpers

    /// Which of the three fixture notes the list currently shows.
    private func visible() -> Set<String> {
        Set([Self.idPlain, Self.idReader, Self.idZotero].filter { titleCell($0).exists })
    }

    private func titleCell(_ id: String) -> XCUIElement {
        mainWindow.descendants(matching: .any)["an.cell.title.\(id)"]
    }

    private func setAuthors(_ name: String, on id: String) {
        selectItem(uuid: id)
        setAuthors(name, in: mainWindow)
    }

    private func setAuthors(_ name: String, in window: XCUIElement) {
        let field = window.descendants(matching: .any)["an.detail.authors"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the authors field should be in the inspector")
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(name)
        window.buttons["Set"].firstMatch.click()
    }

    private func clearAuthors(on id: String) {
        selectItem(uuid: id)
        let clear = mainWindow.buttons["Clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.click()
    }

    private func openExtractsWindow() -> XCUIElement {
        let win = app.windows["Extracts"]
        if !win.exists { clickMenu("Window", "Extracts") }
        XCTAssertTrue(win.waitForExistence(timeout: 15), "the Extracts window should be open")
        return win
    }

    /// Close it again: the sibling checks query editors unscoped and a second window would confuse them.
    private func closeExtractsWindow(_ win: XCUIElement) {
        let close = win.buttons[XCUIIdentifierCloseWindow]
        if close.waitForExistence(timeout: 5), close.isHittable { close.click() }
        _ = pollUntil(timeout: 5) { !win.exists }
    }

    private func clickMenu(_ menu: String, _ item: String) {
        app.activate()
        let bar = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "the \(menu) menu should exist")
        bar.click()
        let entry = app.menuBars.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "\(menu) ▸ \(item) should exist")
        XCTAssertTrue(entry.isEnabled, "\(menu) ▸ \(item) should be enabled")
        entry.click()
    }

    private func folderRow(named name: String) -> XCUIElement {
        let row = mainWindow.descendants(matching: .any).matching(identifier: "an.sidebar.folder")
            .matching(NSPredicate(format: "value ==[c] %@ OR label ==[c] %@", name, name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the \(name) folder row should be visible")
        return row
    }

    private func selectFolder(named name: String) {
        folderRow(named: name).click()
    }

    /// Open a collapsed disclosure row: select it, then Right Arrow (the sidebar is an outline view).
    private func expand(_ row: XCUIElement) {
        row.click()
        app.typeKey(.rightArrow, modifierFlags: [])
    }

    /// Fill the text field of the SwiftUI alert that is up, then press its `button`.
    private func answerNameAlert(_ text: String, button: String) {
        let field = app.sheets.textFields.firstMatch.exists ? app.sheets.textFields.firstMatch
            : app.dialogs.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the name alert should be up")
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
        // Scoped to the alert: an unscoped query also matches the Touch Bar's copy of the button.
        let alert = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
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
