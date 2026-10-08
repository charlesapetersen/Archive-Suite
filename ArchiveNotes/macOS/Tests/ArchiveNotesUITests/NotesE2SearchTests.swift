import XCTest

/// W9.e2-search — the search part of the gap-closure runtime sweep (`09-gap-closure.md` §E2): keyword
/// full-text search, each facet filter (quality, tag, date range), and a smart folder saved from them,
/// then selected as the scope. `testW9D9_…` already proves a saved smart folder's badge COUNT; this class
/// proves that selecting one actually narrows the list, and that the live keyword is folded into it.
///
/// Fixture notes: `idPlain` "My First Note" (tags silicon valley, intel); `idReader` "Moore on Intel
/// culture" (1968, quality 3, tags intel, corporate culture; body says "egalitarian"); `idZotero`
/// "Lovelace paper" (computing history). The fixture is restored from its pristine copy before every test,
/// so the smart folders created here do not leak into later checks.
final class NotesE2SearchTests: NotesFixtureUITestCase {

    private var allNotes: Set<String> { [Self.idPlain, Self.idReader, Self.idZotero] }

    /// Keyword search plus each facet narrows the list to the expected fixture items, and Clear restores it.
    func testE2_KeywordSearchAndQualityTagDateFiltersNarrowTheList() throws {
        try withFixture {
            XCTAssertTrue(waitForIndexReady(timeout: 30), "the search index should be built")
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes })

            // "egalitarian" is in the Reader note's BODY only, so a match proves FTS, not a title substring.
            let search = mainWindow.textFields["an.filter.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.click()
            search.typeText("egalitarian")
            XCTAssertTrue(pollUntil(timeout: 15) { self.visibleNotes() == [Self.idReader] },
                          "a body keyword should match only the note that contains it, saw \(visibleNotes())")
            mainWindow.buttons["an.filter.searchClear"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes })

            mainWindow.buttons["an.filter.quality.3"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idReader] },
                          "Quality 3 should leave only the quality-3 note, saw \(visibleNotes())")
            mainWindow.buttons["an.filter.quality.3"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes },
                          "toggling Quality 3 off should restore the list")

            addTagFacet("intel")
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idPlain, Self.idReader] },
                          "the intel tag should match the two intel notes, saw \(visibleNotes())")
            clearFilters()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes },
                          "Clear should drop the tag facet")

            let from = mainWindow.textFields["an.filter.dateFrom"]
            from.click()
            from.typeText("1960")
            let to = mainWindow.textFields["an.filter.dateTo"]
            to.click()
            to.typeText("1970\r")
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idReader] },
                          "1960–1970 should leave only the 1968 note, saw \(visibleNotes())")
            clearFilters()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes },
                          "Clear should drop the date range")
        }
    }

    /// Smart folders — a query saved from a facet, and one saved from the live keyword, each persist as a
    /// `.smart` folder in `organization.json` and, once selected in the sidebar, scope the list to exactly
    /// their matches; All Notes then brings every note back.
    func testE2_SmartFolderFromFacetAndKeywordScopesTheList() throws {
        try withFixture {
            try requireCanonicalScratchFixtureForStoreWrites()
            XCTAssertTrue(waitForIndexReady(timeout: 30), "the search index should be built")
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes })

            // A facet-based smart folder: the intel tag (two of the three notes).
            addTagFacet("intel")
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idPlain, Self.idReader] })
            saveSmartFolder(named: "E2 Intel")
            clearFilters()

            // A keyword-based one: the live keyword is folded in as a durable TITLE substring on save
            // (`NotesNavigationModel.currentUserFilter`), so use a word from a title.
            let search = mainWindow.textFields["an.filter.search"]
            search.click()
            search.typeText("Lovelace")
            XCTAssertTrue(pollUntil(timeout: 15) { self.visibleNotes() == [Self.idZotero] },
                          "the keyword should find the Lovelace note, saw \(visibleNotes())")
            saveSmartFolder(named: "E2 Lovelace")
            mainWindow.buttons["an.filter.searchClear"].click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes },
                          "with no filters set the list should show every note before a smart folder is picked")

            let intelQuery = try XCTUnwrap(smartQueryJSON(named: "E2 Intel"),
                                           "Save should persist E2 Intel as a smart folder")
            XCTAssertTrue(intelQuery.contains("intel"), "the saved query should carry the tag: \(intelQuery)")
            let keywordQuery = try XCTUnwrap(smartQueryJSON(named: "E2 Lovelace"),
                                             "Save should persist E2 Lovelace as a smart folder")
            XCTAssertTrue(keywordQuery.contains("Lovelace"),
                          "the saved query should carry the keyword: \(keywordQuery)")

            smartRow(named: "E2 Intel").click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idPlain, Self.idReader] },
                          "selecting E2 Intel should scope the list to the intel notes, saw \(visibleNotes())")

            smartRow(named: "E2 Lovelace").click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == [Self.idZotero] },
                          "selecting E2 Lovelace should scope the list to its keyword match, saw \(visibleNotes())")

            let attachment = XCTAttachment(screenshot: mainWindow.screenshot())
            attachment.name = "W9.e2-search-smart-folder"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Capture the smart-folder scope") { $0.add(attachment) }

            let allNotesRow = mainWindow.descendants(matching: .any)
                .matching(identifier: "an.sidebar.allNotes")
                .matching(NSPredicate(format: "value ==[c] %@", "All Notes")).firstMatch
            XCTAssertTrue(allNotesRow.waitForExistence(timeout: 5))
            allNotesRow.click()
            XCTAssertTrue(pollUntil(timeout: 10) { self.visibleNotes() == self.allNotes },
                          "All Notes should drop the smart-folder scope, saw \(visibleNotes())")
        }
    }

    // MARK: - Helpers

    /// Which of the three fixture notes the list currently shows.
    private func visibleNotes() -> Set<String> {
        allNotes.filter { mainWindow.descendants(matching: .any)["an.cell.title.\($0)"].exists }
    }

    private func addTagFacet(_ tag: String) {
        let field = mainWindow.textFields["an.filter.tagInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the tag facet field should exist")
        field.click()
        field.typeText("\(tag)\r")
    }

    private func clearFilters() {
        let clear = mainWindow.descendants(matching: .any)["an.filter.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
    }

    private func saveSmartFolder(named name: String) {
        let save = mainWindow.buttons["an.filter.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.click()
        let sheet = mainWindow.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Save as Smart Folder should ask for a name")
        let field = sheet.textFields.firstMatch
        field.click()
        field.typeText(name)
        sheet.buttons["Save"].click()
        XCTAssertTrue(smartRow(named: name).waitForExistence(timeout: 10),
                      "\(name) should appear under Smart Folders")
    }

    private func smartRow(named name: String) -> XCUIElement {
        mainWindow.descendants(matching: .any).matching(identifier: "an.sidebar.smart")
            .matching(NSPredicate(format: "value == %@", name)).firstMatch
    }

    /// The persisted `queryJSON` of the smart folder called `name` in the scratch `organization.json`.
    private func smartQueryJSON(named name: String) -> String? {
        let path = Self.fixturePath + "/organization.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = obj["folders"] as? [[String: Any]] else { return nil }
        let match = folders.first { ($0["name"] as? String) == name && ($0["kind"] as? String) == "smart" }
        return match?["queryJSON"] as? String
    }
}
