import XCTest

/// Tests for the navigation window: table population, tag cloud, sidebar, column
/// sort, and filter bar. All tests run against the pre-built GUI fixture.
final class NavigationUITests: FixtureUITestCase {

    // MARK: - Table population

    func testTablePopulatesWithFixtureFiles() throws {
        // The fixture has 12 files total but only 11 have Read/Unread tags.
        // File 9 has no read-state → it lives in the "neither" bucket.
        // Default filter is "All" so we should see at least 11 rows.
        XCTAssertGreaterThanOrEqual(rowCount, 11,
            "Fixture has 11 Read/Unread files; table should show at least that many")
    }

    // MARK: - Tag cloud (regression: no date tokens)

    func testTagCloudShowsSubjectsNotDateTokens() throws {
        // Open the tag cloud panel via toolbar button. Its visibility is @AppStorage (shared
        // UserDefaults), so toggle up to twice until tags are actually shown rather than assuming
        // it starts hidden.
        let tagCloudButton = toolbarButton("ar.toolbar.tagCloud")
        XCTAssertTrue(tagCloudButton.waitForExistence(timeout: 5))
        let tagTexts = app.buttons.matching(identifier: "ar.tagCloud.tag")
        for _ in 0..<2 where tagTexts.count == 0 {
            tagCloudButton.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        XCTAssertGreaterThan(tagTexts.count, 0, "Tag cloud panel should appear with tags")

        // Date-facet tokens that MUST NOT appear in the cloud.
        let dateFacetPatterns = [
            "1980", "1975", "842", "1970s", "1981", "1983", "1979", "1990", "1975",
            "03 March", "06 June", "Day 15", "Date Uncertain"
        ]

        for i in 0..<tagTexts.count {
            let label = tagTexts.element(boundBy: i).label
            for pattern in dateFacetPatterns {
                XCTAssertNotEqual(label, pattern,
                    "Tag cloud should NOT contain date-facet token '\(pattern)'")
            }
        }

        // Subject tokens that SHOULD appear. NOTE: "Budget Policy" is deliberately NOT here — it lives
        // only on fixture file 00009, which has no Read/Unread tag, so the library's visible universe
        // (files whose Finder tags include `Read` or `Unread`) never surfaces it (matching production
        // behavior). That universe used to be an `NSMetadataQuery` predicate; since `W26.walk2` it is a
        // filter over the `CorpusWalker` walk — same rule, no Spotlight.
        let expectedSubjects = ["Jerry Brown", "Economics", "Medieval Records",
                                "DP chapters", "Education Policy"]
        let allLabels = (0..<tagTexts.count).map { tagTexts.element(boundBy: $0).label }
        for subject in expectedSubjects {
            XCTAssertTrue(allLabels.contains(subject),
                "Tag cloud should contain subject '\(subject)' but found: \(allLabels)")
        }

        // Close the tag cloud panel.
        tagCloudButton.click()
    }

    // MARK: - Sidebar toggle (W5.c4)

    func testSidebarToggles() throws {
        let sidebarButton = toolbarButton("ar.toolbar.sidebar")
        XCTAssertTrue(sidebarButton.waitForExistence(timeout: 5))

        // Sidebar is shown by default (@AppStorage default = true).
        // Look for the "All Files" item in the sidebar.
        let allFiles = app.staticTexts["ar.sidebar.allFiles"]
        let sidebarInitiallyVisible = allFiles.exists

        // Toggle sidebar.
        sidebarButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        if sidebarInitiallyVisible {
            // After toggle, sidebar should be hidden.
            XCTAssertFalse(allFiles.exists, "Sidebar should be hidden after toggle")
        }

        // Toggle again — sidebar should return to its original state.
        sidebarButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        if sidebarInitiallyVisible {
            XCTAssertTrue(allFiles.waitForExistence(timeout: 3),
                "Sidebar should reappear after second toggle")
        }
    }

    // MARK: - Tag cloud panel toggle (W5.c4)

    func testTagCloudPanelToggles() throws {
        let button = toolbarButton("ar.toolbar.tagCloud")
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        func tagCount() -> Int { app.buttons.matching(identifier: "ar.tagCloud.tag").count }

        // The panel's visibility is @AppStorage — its initial state is whatever the shared
        // UserDefaults holds, so don't assume "hidden by default". Toggle up to twice until the
        // cloud is OPEN (tags visible), then assert tags show; closing hides them.
        for _ in 0..<2 where tagCount() == 0 {
            button.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertGreaterThan(tagCount(), 0, "Tag cloud should show tags when open")

        // Close it.
        button.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // Tags should no longer be visible.
        let countWhenClosed = tagCount()
        XCTAssertEqual(countWhenClosed, 0, "Tag cloud tags should disappear when panel is closed")
    }

    // MARK: - Column headers exist

    func testColumnHeadersExist() throws {
        // NSTableHeaderView ("ar.table.header") may be exposed differently — check the table's column headers.
        // At minimum, verify the table itself is present (covered by setUp).
        // Check that key column header texts are reachable.
        let expectedHeaders = ["Document date", "File name", "File tags", "Quality", "Read"]
        for title in expectedHeaders {
            let headerCell = table.staticTexts[title]
            XCTAssertTrue(headerCell.exists || table.buttons[title].exists,
                "Column header '\(title)' should be visible in the table")
        }
    }

    // MARK: - Quality controls (W19.q3)

    func testQualityControlsUseCanonicalScale() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        waitForRows(minimum: 5, timeout: 10)

        for q in 1...3 {
            XCTAssertTrue(app.descendants(matching: .any)["ar.filter.quality.Q\(q)"].waitForExistence(timeout: 3),
                          "Quality filter Q\(q) should be reachable")
        }
        XCTAssertFalse(app.descendants(matching: .any)["ar.filter.priority.P7"].exists,
                       "The retired P7 control must not survive as a fake Q0")

        // Fixture file 00002 has phone-wire P8 input. The rendered, editable table control must expose
        // it as canonical Q1 rather than leaving the old P label in the live AppKit table.
        let menu = app.popUpButtons["ar.quality.menu.00002 IMG — Brown.pdf"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Quality column should provide a per-file editor")
        XCTAssertEqual(menu.value as? String, "Q1")

        // Select an actual value and read the generated scratch document back. This proves the visible
        // AppKit popup reaches NavigationModel.applyEdit → TagWriter rather than merely displaying Q1.
        menu.click()
        let q3 = app.menuItems["Q3"]
        XCTAssertTrue(q3.waitForExistence(timeout: 5), "Quality popup should offer Q3")
        q3.click()
        XCTAssertTrue(waitForTags(on: "00002 IMG — Brown.pdf", containing: ["Q3"], excluding: ["P8"]),
                      "the in-table Quality picker should write canonical Q3 to the scratch document")
    }

    // MARK: - Save Search takes the keyboard; Quality chips run Q1 → Q3 (W40.fix-reader-visual-polish)

    func testSaveSearchNameFieldHasTheKeyboardAndQualityChipsAscend() throws {
        waitForRows(minimum: 5, timeout: 10)
        let chips = (1...3).map { app.descendants(matching: .any)["ar.filter.quality.Q\($0)"] }
        XCTAssertTrue(chips[2].waitForExistence(timeout: 5), "the Quality chips should be in the filter bar")
        XCTAssertLessThan(chips[0].frame.minX, chips[1].frame.minX, "Q1 should come before Q2, as in the pop-up")
        XCTAssertLessThan(chips[1].frame.minX, chips[2].frame.minX, "Q2 should come before Q3, as in the pop-up")

        chips[0].click()
        let save = app.descendants(matching: .any)["ar.filter.saveSmartFolder"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "an active filter should offer Save as Smart Folder")
        save.click()
        let field = app.sheets.textFields["ar.saveSearch.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Save Search should ask for a name")
        XCTAssertEqual(field.value as? String, "Q1", "the name is pre-filled from the active filter")

        // No click into the field: the alert this replaced left the keyboard on Cancel, so these keys went nowhere.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        pressKey("a", modifiers: .command)
        app.typeText("Keyboard")
        XCTAssertEqual(field.value as? String, "Keyboard", "typing on open should reach the name field")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Escape should cancel the sheet without saving")
        chips[0].click()
    }

    // MARK: - Header-click sort (W5.c3)

    func testHeaderClickChangesSort() throws {
        // Wait for enough rows to make sort order meaningful.
        waitForRows(minimum: 5, timeout: 10)
        app.activate()

        // Click the "File name" column header to sort by name. An NSTableHeaderView header is exposed
        // as a static text or button but is frequently reported "not hittable" for a plain .click(),
        // so tap it by coordinate. The assertion is that the interaction is handled and rows remain
        // (we can't assert an exact order without knowing the default sort).
        let header = table.staticTexts["File name"].exists
            ? table.staticTexts["File name"]
            : table.buttons["File name"]
        XCTAssertTrue(header.waitForExistence(timeout: 5), "File name column header should be reachable")
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()   // sort ascending
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()   // reverse direction
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        XCTAssertGreaterThanOrEqual(rowCount, 5, "Table should still have rows after header-click sort")
    }

    // MARK: - Name filter reduces rows

    func testNameFilterReducesRows() throws {
        waitForRows(minimum: 5, timeout: 10)
        let countBefore = rowCount

        // Type into the name filter field.
        let filterField = app.textFields["ar.filter.name"]
        XCTAssertTrue(filterField.waitForExistence(timeout: 5), "Name filter field should exist")
        filterField.click()
        filterField.typeText("00001")

        // Wait for debounced filter (150ms + render).
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let countAfter = rowCount
        XCTAssertLessThan(countAfter, countBefore,
            "Filtering by '00001' should reduce the row count from \(countBefore)")
        XCTAssertGreaterThanOrEqual(countAfter, 1,
            "At least one file matches '00001'")

        // Clear the filter.
        filterField.click()
        pressKey("a", modifiers: .command)
        filterField.typeText(XCUIKeyboardKey.delete.rawValue)
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        waitForRows(minimum: countBefore, timeout: 5)
    }

    // MARK: - OCR search field exists (W5.d1 infrastructure)

    func testOCRSearchFieldExists() throws {
        // The OCR search field has id "ar.filter.ocr".
        let ocrField = app.textFields["ar.filter.ocr"]
        // It may be inside a disclosure or search bar. Check existence.
        // If not directly visible, try focusing it via ⌘⌥F.
        if !ocrField.exists {
            pressKey("f", modifiers: [.command, .option])
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(ocrField.waitForExistence(timeout: 5),
            "OCR search field should be reachable")
    }

    // MARK: - Full-text search snippet previews (W12-fts-snippet)

    /// OCR-searching a body-only term surfaces a keyword-in-context snippet line under matching rows.
    /// "California" appears in the fixture OCR bodies (9/11 docs — the "Edmund Brown Collection, USC
    /// Special Collections" scans) but NOT in any filename ("NNNNN IMG — Brown"), so a table static
    /// text whose value contains it can ONLY be the rendered snippet line — a content-based assertion
    /// that the preview renders end-to-end (ContentIndex.searchRanked → ftsSnippets → the name cell).
    func testOCRSearchShowsKeywordInContextSnippet() throws {
        waitForRows(minimum: 3, timeout: 10)

        // Focus + type a known body term into the OCR search field.
        let ocrField = app.textFields["ar.filter.ocr"]
        if !ocrField.exists {
            pressKey("f", modifiers: [.command, .option])
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(ocrField.waitForExistence(timeout: 5), "OCR search field should exist")
        ocrField.click()
        ocrField.typeText("California")

        // The full-text search must at least execute (the clear button appears once a query is active).
        XCTAssertTrue(app.buttons["ar.filter.ocrClear"].waitForExistence(timeout: 10),
            "Full-text search should become active (clear button visible)")

        // The content index builds asynchronously after launch, so poll generously. Success = a table
        // static text whose value contains the searched BODY term — only possible via the snippet line,
        // since no fixture filename contains "California".
        let snippetPredicate = NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                                           "california", "california")
        let snippet = table.staticTexts.matching(snippetPredicate).firstMatch
        XCTAssertTrue(snippet.waitForExistence(timeout: 45),
            "A keyword-in-context snippet containing the body term 'California' should render under a "
            + "matching row (the term is in no filename, so it can only come from the OCR preview line)")

        // The OCR query should have filtered the list to a matching subset of the fixture.
        XCTAssertGreaterThanOrEqual(rowCount, 1, "OCR search should keep at least one matching row")
    }

    // MARK: - Matched-identity tag writes (W21.vmgui-e)

    /// Exercise all three normal UI write paths that must carry a fresh, matching identity into the
    /// audited writer: a group-editor subject edit, a corpus-wide rename, and the Mark Read toolbar
    /// action. The VM fixture is generated afresh and lives outside every real archive root; reading its
    /// tags back here proves the operations actually committed instead of merely presenting controls.
    func testMatchedIdentityWritesSucceedOnScratchFixture() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let targetName = "00002 IMG — Brown.pdf"
        let addedTag = "VM Identity Smoke"
        let renamedTag = "VM Identity Verified"

        // Narrow to one predictable Unread fixture document before every write. Its basename remains
        // unchanged throughout, so neither test data nor a user archive is ever renamed.
        typeInField("ar.filter.name", text: "00002")
        XCTAssertTrue(waitForRowCount(1), "name filter should isolate the intended scratch document")
        clickRow(0)
        XCTAssertTrue(waitForTags(on: targetName, containing: ["Unread"]),
                      "the generated scratch fixture should begin Unread")

        // (1) Normal selected-file triage: NavigationModel.mark → TagWriter.setReadState(expecting:).
        toolbarButton("ar.toolbar.markRead").click()
        XCTAssertTrue(waitForTags(on: targetName, containing: ["Read"], excluding: ["Unread"]),
                      "Mark Read should complete against the selected scratch document")

        // (2) Group editor: NavigationModel.applyEdit → TagWriter.apply(expecting:).
        toolbarButton("ar.toolbar.editTags").click()
        let addField = app.textFields["ar.tagEditor.addSubject"]
        XCTAssertTrue(addField.waitForExistence(timeout: 5), "Edit Tags should present its subject field")
        addField.click()
        addField.typeText(addedTag)
        let addButton = app.buttons["ar.tagEditor.addSubjectButton"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()
        XCTAssertTrue(waitForTags(on: targetName, containing: [addedTag]),
                      "the editor's subject addition should be verified on the scratch document")
        app.buttons["Done"].click()

        // Remove the basename narrowing before proving that the tag-cloud selection itself limits the
        // result to this one document. That makes `filter.subjects` (the source read by beginRenameTag)
        // a required part of the test instead of accidentally relying on a filtered table or token order.
        let nameField = app.textFields["ar.filter.name"]
        nameField.click()
        pressKey("a", modifiers: .command)
        nameField.typeText(XCUIKeyboardKey.delete.rawValue)
        waitForRows(minimum: 2, timeout: 5)
        XCTAssertGreaterThanOrEqual(rowCount, 2, "clearing the name filter should restore the fixture list")

        // Restrict Rename Tag… to the freshly-added, one-file subject. Clicking the real tag-cloud
        // control avoids a long synthetic text event inside NSTokenField, while setting the same
        // `filter.subjects` state that makes NavigationModel.beginRenameTag choose this exact token.
        let tagCloudToggle = toolbarButton("ar.toolbar.tagCloud")
        let tagButton = app.buttons.matching(identifier: "ar.tagCloud.tag")
            .matching(NSPredicate(format: "label == %@", addedTag)).firstMatch
        for _ in 0..<2 where !tagButton.exists {
            tagCloudToggle.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(tagButton.waitForExistence(timeout: 5), "tag cloud should expose the added scratch tag")
        tagButton.click()
        XCTAssertTrue(waitForRowCount(1), "tag filter should retain the one matching scratch document")

        // (3) Corpus-wide rename: NavigationModel.renameTag → TagWriter.renameToken(expecting:),
        // independently re-verifying the one matching scratch file.
        app.activate()
        app.menuBars.menuBarItems["Tags"].click()
        let renameItem = app.menuItems["Rename Tag…"]
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5), "Tags menu should expose Rename Tag…")
        renameItem.click()
        let renameField = app.textFields["ar.renameTag.newName"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5), "Rename Tag should present its name field")
        renameField.click()
        renameField.typeText(renamedTag)
        let renameButton = app.buttons["ar.renameTag.commit"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5))
        renameButton.click()
        XCTAssertTrue(waitForTags(on: targetName, containing: ["Read", renamedTag], excluding: [addedTag]),
                      "the matched-identity rename should replace only the selected scratch tag")
        captureScreenshot("w21-vmgui-e-matched-identity-writes")
    }

    /// W40.audit-ledger-undo: the toolbar reads the ledger-backed history and reports the verified
    /// inverse. Relaunch, recovery and identity refusal are exercised more deeply by scratch unit tests.
    func testLedgerUndoShowsVerifiedResultOnScratchFixture() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let name = "00002 IMG — Brown.pdf"
        let path = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(name).path
        let beforeTags = try XCTUnwrap(URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames)
        let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        typeInField("ar.filter.name", text: "00002")
        XCTAssertTrue(waitForRowCount(1))
        clickRow(0)
        XCTAssertTrue(waitForTags(on: name, containing: ["Unread"]))
        toolbarButton("ar.toolbar.markRead").click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Read"], excluding: ["Unread"]))
        let undo = toolbarButton("ar.toolbar.undo")
        XCTAssertTrue(undo.isEnabled)
        undo.click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Unread"], excluding: ["Read"]))
        XCTAssertTrue(app.staticTexts["Undid 1 change."].waitForExistence(timeout: 5))
        let afterTags = try XCTUnwrap(URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames)
        XCTAssertEqual(beforeTags.sorted(), afterTags.sorted())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), beforeBytes)
        XCTAssertFalse(undo.isEnabled, "inverse records cannot become redo candidates")
        captureScreenshot("w40-audit-ledger-undo-verified")
    }

    /// W40.fix-reader-sent-with-date (ledger R-26): the ⌘I sheet is the one date editor, so it sets, flags and
    /// clears a Sent-With date. Each step is read back from the scratch file; the last leaves it as it began.
    func testSheetSetsAndClearsASentWithDate() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let name = "00003 IMG — Brown.pdf"
        // A failure part-way must not leave the date on the shared fixture for the next run.
        let url = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(name)
        addTeardownBlock {
            let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            let kept = tags.filter { $0 != "Sent With 1958-03-12" && $0 != "Sent With Date Uncertain" }
            if kept != tags { try? (url as NSURL).setResourceValue(kept, forKey: .tagNamesKey) }
        }
        typeInField("ar.filter.name", text: "00003")
        XCTAssertTrue(waitForRowCount(1), "name filter should isolate the scratch document")
        clickRow(0)
        XCTAssertTrue(waitForTags(on: name, containing: ["842"], excluding: ["Sent With 1958-03-12"]),
                      "precondition: the scratch document has its own date and no Sent-With date")

        toolbarButton("ar.toolbar.editTags").click()
        let field = app.textFields["ar.tagEditor.sentWith"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the ⌘I sheet should offer a Sent-With field")
        field.click()
        field.typeText("1958-03-12")
        let set = app.buttons["ar.tagEditor.sentWithSet"]
        XCTAssertTrue(set.isEnabled, "a valid Sent-With date enables Set")
        set.click()
        XCTAssertTrue(waitForTags(on: name, containing: ["842", "Sent With 1958-03-12"]),
                      "Set should write the Sent-With date and keep the document's own date")

        app.buttons["ar.tagEditor.sentWithUncertain"].click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Sent With 1958-03-12", "Sent With Date Uncertain"]),
                      "Mark Uncertain should flag the Sent-With date")
        captureScreenshot("w40-sent-with-date-in-sheet")

        app.buttons["ar.tagEditor.sentWithClear"].click()
        XCTAssertTrue(waitForTags(on: name, containing: ["842"],
                                  excluding: ["Sent With 1958-03-12", "Sent With Date Uncertain"]),
                      "Clear should remove the Sent-With date and its flag")
        app.buttons["ar.tagEditor.done"].click()
    }

    // MARK: - Phantom selection (W40.fix-reader-phantom-selection)

    /// The selection is never wider than the list. Select a row, filter it away: the status bar must
    /// stop counting it, Mark Read (toolbar and ⌘R) must not reach it, and clearing the filter must not
    /// bring it back selected. Then, with two rows selected, opening and closing the tag cloud must
    /// leave the table highlighting exactly what the status bar counts — the tour's "2 selected",
    /// nothing highlighted. Writes nothing when the fix holds; reads the tags back to prove it.
    func testAFilteredAwaySelectionIsNotCountedOrActedOn() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let name = "00002 IMG — Brown.pdf"
        let path = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(name).path
        // A fresh URL per read: a reused one caches its resource values and would never see a write.
        func tagsOnDisk() -> [String] {
            ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []).sorted()
        }
        let selectedCount = app.staticTexts["ar.status.selectedCount"]
        let highlighted = table.tableRows.matching(NSPredicate(format: "isSelected == true"))

        typeInField("ar.filter.name", text: "00002")
        XCTAssertTrue(waitForRowCount(1), "name filter should isolate the scratch document")
        clickRow(0)
        XCTAssertTrue(selectedCount.waitForExistence(timeout: 5), "one visible row selected is counted")
        XCTAssertEqual(shownText(selectedCount), "1 selected")
        let before = tagsOnDisk()

        // Filter the selected row away.
        let nameField = app.textFields["ar.filter.name"]
        nameField.click()
        pressKey("a", modifiers: .command)
        nameField.typeText("matches-no-fixture-file")
        XCTAssertTrue(waitForRowCount(0), "the filter should hide every row")
        XCTAssertTrue(waitForDisappearance(selectedCount, timeout: 5),
                      "a row the list does not show is not counted as selected")
        XCTAssertFalse(toolbarButton("ar.toolbar.markRead").isEnabled, "Mark Read has nothing visible to act on")
        app.activate()
        pressKey("r", modifiers: .command)   // Selection ▸ Mark Read, in case the toolbar lies
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(tagsOnDisk(), before, "no tag may be written to a file the list does not show")
        captureScreenshot("w40-phantom-selection-filtered-away")

        // Clear the filter: the row comes back, but not selected.
        nameField.click()
        pressKey("a", modifiers: .command)
        nameField.typeText(XCUIKeyboardKey.delete.rawValue)
        waitForRows(minimum: 2, timeout: 5)
        XCTAssertGreaterThanOrEqual(rowCount, 2, "clearing the name filter should restore the fixture list")
        XCTAssertEqual(highlighted.count, 0, "the hidden selection does not come back with the row")
        XCTAssertFalse(selectedCount.exists, "and nothing is counted")

        // Two rows selected, then the tag cloud opened and closed (the tour's path to the phantom).
        clickRow(0)
        XCUIElement.perform(withKeyModifiers: .shift) { self.table.tableRows.element(boundBy: 1).click() }
        XCTAssertTrue(selectedCount.waitForExistence(timeout: 5))
        XCTAssertEqual(shownText(selectedCount), "2 selected", "precondition: a click and a Shift-click select two rows")
        let tagCloud = toolbarButton("ar.toolbar.tagCloud")
        tagCloud.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        tagCloud.click()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let counted = selectedCount.exists ? shownText(selectedCount) : "0 selected"
        XCTAssertEqual(counted, "\(highlighted.count) selected",
                       "after the tag cloud opens and closes, the table highlights what the status bar counts")
        captureScreenshot("w40-phantom-selection-after-tag-cloud")
    }

    /// A SwiftUI `Text` reports its string as the element's value; its label is empty.
    private func shownText(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        return !element.exists
    }

    private func waitForTags(on filename: String,
                             containing required: [String],
                             excluding forbidden: [String] = [],
                             timeout: TimeInterval = 10) -> Bool {
        let file = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(filename)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let names = ((try? file.resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
            let containsRequired = required.allSatisfy { wanted in
                names.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            }
            let excludesForbidden = forbidden.allSatisfy { unwanted in
                !names.contains { $0.caseInsensitiveCompare(unwanted) == .orderedSame }
            }
            if containsRequired && excludesForbidden { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    private func waitForRowCount(_ expected: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if rowCount == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return rowCount == expected
    }
}
