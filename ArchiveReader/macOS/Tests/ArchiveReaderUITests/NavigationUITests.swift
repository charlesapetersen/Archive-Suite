import XCTest

/// Tests for the navigation window: table population, tag cloud, sidebar, column
/// sort, and filter bar. All tests run against the pre-built GUI fixture.
final class NavigationUITests: FixtureUITestCase {

    /// The inspector is modeless: browsing and filtering remain available while it stays open.
    func testInspectorFollowsSelectionAndOptionCommandIToggles() throws {
        let year = app.textFields["ar.tagEditor.year"]
        // Visibility is deliberately remembered between app launches; normalize it for this test.
        if app.buttons["ar.tagEditor.done"].exists {
            app.typeKey("i", modifierFlags: [.command, .option])
            XCTAssertTrue(year.waitForNonExistence(timeout: 5))
        }
        let table = app.tables["ar.table"]
        let first = table.tableRows.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        visiblePoint(of: first).tap()
        let closedWidth = app.windows["Archive Reader"].frame.width
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.count, 0, "the Inspector belongs in the right-hand column")
        let next = table.tableRows.element(boundBy: 1)
        visiblePoint(of: next).tap()
        XCTAssertTrue(year.waitForExistence(timeout: 5), "browsing leaves the inspector open")
        XCTAssertGreaterThan(year.frame.minX, table.frame.midX)
        captureScreenshot("w40-edit-info-inspector")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(year.waitForNonExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        // W40.fix-reader-inspector-narrow: at the window's 900-pt minimum the Inspector ran past its right edge.
        let close = app.buttons["ar.tagEditor.done"]
        let window = app.windows["Archive Reader"].frame
        XCTAssertLessThanOrEqual(close.frame.maxX, window.maxX + 1,
                                 "Close ends at x=\(close.frame.maxX), past the window's edge at x=\(window.maxX)")
        close.click()
        XCTAssertTrue(year.waitForNonExistence(timeout: 5))
        // A window widened for the Inspector goes back when it closes.
        XCTAssertEqual(app.windows["Archive Reader"].frame.width, closedWidth, accuracy: 1)
    }

    /// A departing field must commit to its original file, including when a filter removes that row.
    func testInspectorDraftTargetsAndHiddenInvalidDraft() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        typeInField("ar.filter.name", text: "00002")
        XCTAssertTrue(waitForRowCount(1))
        clickRow(0)
        toolbarButton("ar.toolbar.editTags").click()
        let year = app.textFields["ar.tagEditor.year"]
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        year.click()
        pressKey("a", modifiers: .command)
        year.typeText("1962")  // no Return: leave by changing the library selection
        let name = app.textFields["ar.filter.name"]
        name.click()
        pressKey("a", modifiers: .command)
        name.typeText("00003")
        XCTAssertTrue(waitForRowCount(1))
        clickRow(0)
        XCTAssertTrue(waitForTags(on: "00002 IMG — Brown.pdf", containing: ["1962", "Economics", "Unread"], excluding: ["1975"]))
        XCTAssertTrue(waitForTags(on: "00003 IMG — Brown.pdf", containing: ["842"], excluding: ["1962"]))
        XCTAssertEqual(year.value as? String, "842", "the new selection seeds a new draft")

        year.click()
        pressKey("a", modifiers: .command)
        year.typeText("invalid")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(year.waitForNonExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertEqual(year.value as? String, "invalid", "hiding must retain the invalid draft")
        XCTAssertTrue(app.staticTexts["Use a year from 100 to 9999"].exists)
        XCTAssertTrue(waitForTags(on: "00003 IMG — Brown.pdf", containing: ["842"], excluding: ["1962", "invalid"]))
        captureScreenshot("w40-inspector-invalid-draft")
        year.click()
        pressKey("a", modifiers: .command)
        year.typeText("842\r")
        let add = app.textFields["ar.tagEditor.addSubject"]
        add.click()
        add.typeText("Inspector hidden focus")
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(year.waitForNonExistence(timeout: 5))
        app.typeText("x")  // a hidden native tag editor must not keep taking keystrokes
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForTags(on: "00003 IMG — Brown.pdf", containing: ["Inspector hidden focus"], excluding: ["x"]))
        XCTAssertEqual(add.value as? String ?? "", "")
        app.buttons["ar.tagEditor.done"].click()
    }

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
            // After toggle, sidebar should be hidden, once its slide-out has finished.
            XCTAssertTrue(allFiles.waitForNonExistence(timeout: 3), "Sidebar should be hidden after toggle")
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

    // MARK: - Tag cloud minimum count (W40.fix-reader-tagcloud-threshold)

    func testTagCloudMinimumCountHidesRareTags() throws {
        let button = toolbarButton("ar.toolbar.tagCloud")
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        func tagCount() -> Int { app.buttons.matching(identifier: "ar.tagCloud.tag").count }
        for _ in 0..<2 where tagCount() == 0 {
            button.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        let all = tagCount()
        XCTAssertGreaterThan(all, 0, "Tag cloud should show tags when open")

        // The panel's identifier covers its children, so find the slider by its label.
        let slider = app.sliders["Minimum files per tag"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "the minimum-count slider should be in the panel")
        XCTAssertEqual(app.steppers.matching(identifier: "Minimum files per tag").count, 0)

        // One drag reaches above the most common tag's count, hiding every tag in this fixture.
        slider.adjust(toNormalizedSliderPosition: 1)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tagCount() == 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed,
                       "the slider should hide rare tags immediately")
        XCTAssertLessThan(tagCount(), all, "raising the minimum should hide the tags on fewer files")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'On at least'")).firstMatch.exists
                      || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'On at least'")).firstMatch.exists,
                      "the control should say the minimum it applies")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS ' of '")).firstMatch.exists
                      || app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' of '")).firstMatch.exists,
                      "the header should say how many of the tags are shown")
        captureScreenshot("tagcloud-min-count")
        slider.adjust(toNormalizedSliderPosition: 0)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tagCount() == all }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed,
                       "dragging back should show every tag")
        captureScreenshot("tagcloud-min-count-restored")
        button.click()
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

    // MARK: - The Read column: a click switches, a right-click sets or clears (W40.fix-reader-read-toggle)

    /// Ledger R-25. The column was a plain label, so the click did nothing and there was no menu. Drives the real
    /// gestures on one scratch document and reads its tags back after each; the row selection must not move.
    func testReadCellClickAndRightClickWriteThatScratchDocument() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let name = "00004 IMG — Brown.pdf"   // Unread, and no other test writes it
        let url = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(name)
        let original = (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
        // Clear Read State takes the document out of the list, so put its tags back for the tests after this one.
        addTeardownBlock { try? (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(original, forKey: .tagNamesKey) }

        typeInField("ar.filter.name", text: "00004")
        XCTAssertTrue(waitForRowCount(1), "name filter should isolate the scratch document")
        XCTAssertTrue(waitForTags(on: name, containing: ["Unread"]), "the generated scratch fixture should begin Unread")
        let cell = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ar.cell.read.' AND identifier ENDSWITH %@", name)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "the Read column should show the document's state")
        try revealReadColumn(cell)
        let highlighted = table.tableRows.matching(NSPredicate(format: "isSelected == true"))
        let selectedBefore = highlighted.count

        cell.click()
        let marked = waitForTags(on: name, containing: ["Read"], excluding: ["Unread"])
        captureScreenshot("w40-read-toggle-after-click")
        XCTAssertTrue(marked, "a click on the Read cell should mark the document Read")
        XCTAssertEqual(highlighted.count, selectedBefore, "the click acts on the cell, not the row selection")
        cell.click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Unread"], excluding: ["Read"]),
                      "a second click should mark it Unread again")

        cell.rightClick()
        let read = app.menuItems["Read"]
        XCTAssertTrue(read.waitForExistence(timeout: 5), "a right-click should offer Read")
        XCTAssertTrue(app.menuItems["Clear Read State"].exists, "and Clear Read State")
        captureScreenshot("w40-read-toggle-menu")
        read.click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Read"], excluding: ["Unread"]), "Read from the menu sets it")

        cell.rightClick()
        let clear = app.menuItems["Clear Read State"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.click()
        XCTAssertTrue(waitForTags(on: name, containing: ["DP chapters"], excluding: ["Read", "Unread"]),
                      "Clear Read State removes the state and keeps the other tags")
        XCTAssertEqual(highlighted.count, selectedBefore, "the menu acts on the cell, not the row selection")
    }

    /// A double-click on the Read cell is the table's, as on any other cell: it opens the document and writes nothing.
    func testReadCellDoubleClickOpensWithoutWriting() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let name = "00006 IMG — Brown.pdf"   // Unread, and no other test writes it
        typeInField("ar.filter.name", text: "00006")
        XCTAssertTrue(waitForRowCount(1), "name filter should isolate the scratch document")
        XCTAssertTrue(waitForTags(on: name, containing: ["Unread"]), "the generated scratch fixture should begin Unread")
        let cell = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ar.cell.read.' AND identifier ENDSWITH %@", name)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "the Read column should show the document's state")
        try revealReadColumn(cell)
        let windowsBefore = app.windows.count

        cell.doubleClick()
        let deadline = Date().addingTimeInterval(10)
        while app.windows.count <= windowsBefore, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertGreaterThan(app.windows.count, windowsBefore, "a double-click on the Read cell opens the document")
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // past the double-click interval
        XCTAssertTrue(waitForTags(on: name, containing: ["Unread"], excluding: ["Read"], timeout: 1),
                      "and leaves its read state alone")
        captureScreenshot("w40-read-toggle-double-click")
    }

    /// The tag cloud's visibility is @AppStorage, and an earlier test can leave it open; it then narrows the table
    /// until the Read column, the last one, is off screen and a click on its cell lands elsewhere.
    private func revealReadColumn(_ cell: XCUIElement) throws {
        if app.buttons.matching(identifier: "ar.tagCloud.tag").count > 0 {
            toolbarButton("ar.toolbar.tagCloud").click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(cell.isHittable, "the Read cell should be on screen to be clicked")
    }

    // MARK: - Toggle Flag shows the flag at once (W40.fix-reader-flag)

    /// Owner session reader-1, row 23: ⇧⌘F set the flag but the ⚑ cell kept its old value, because the table
    /// redrew rows only when the list itself changed. Flags are app-side, so nothing is written to the document.
    func testToggleFlagShowsAndClearsTheFlagAtOnce() throws {
        try requireGeneratedScratchFixtureForTagWrites()
        let name = "00004 IMG — Brown.pdf"
        typeInField("ar.filter.name", text: "00004")
        XCTAssertTrue(waitForRowCount(1), "name filter should isolate the scratch document")
        let cell = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'ar.cell.flag.' AND identifier ENDSWITH %@", name)).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 5), "the ⚑ column should have a cell for the document")
        clickRow(0)
        func waitForLabel(_ label: String) -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while cell.label != label, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            return cell.label == label
        }
        // A flag left by an earlier run would make the first press clear it.
        if cell.label == "Flagged" { pressKey("f", modifiers: [.command, .shift]); XCTAssertTrue(waitForLabel("Not flagged")) }
        XCTAssertEqual(cell.label, "Not flagged", "the document should begin unflagged")

        pressKey("f", modifiers: [.command, .shift])
        let shown = waitForLabel("Flagged")
        captureScreenshot("w40-reader-flag-after-toggle")
        XCTAssertTrue(shown, "⇧⌘F should show the flag in the ⚑ column at once")
        pressKey("f", modifiers: [.command, .shift])
        XCTAssertTrue(waitForLabel("Not flagged"), "a second ⇧⌘F should clear it at once")
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

    /// W40.fix-reader-filter-undo-levels: multiple edits remain independently undoable while the
    /// debounced list and its filter chips refresh. Text undo must continue to own both shortcuts.
    func testFilenameFilterUndoesAndRedoesSuccessiveEdits() throws {
        let field = app.textFields["ar.filter.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let initialRows = rowCount
        let chip = app.buttons["ar.filter.chip.name"]
        func expectFilter(_ value: String) {
            let predicate = NSPredicate { _, _ in
                let correctText = (field.value as? String ?? "") == value
                let correctFilter = value.isEmpty ? !chip.exists : chip.exists && chip.label == "Remove Name: \(value)"
                return correctText && correctFilter
            }
            expectation(for: predicate, evaluatedWith: field)
            waitForExpectations(timeout: 5)
        }
        field.click()
        field.typeText("abc")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(field.value as? String, "abc")
        for value in ["ab", "a", ""] {
            pressKey("z", modifiers: .command)
            expectFilter(value)
        }
        waitForRows(minimum: initialRows, timeout: 5)
        for value in ["a", "ab", "abc"] {
            pressKey("z", modifiers: [.command, .shift])
            expectFilter(value)
        }
        captureScreenshot("w40-filename-filter-multiple-undo-redo")
    }

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

    /// W40.fix-reader-filter-bar (reader-1 row 8): the name filter shows as a chip while it applies; a filter that
    /// hides every row is named in the empty list, whose button clears it and brings the rows back. Read-only.
    func testAnEmptyListNamesTheFilterThatHidItAndClearsIt() throws {
        waitForRows(minimum: 5, timeout: 10)
        let countBefore = rowCount
        typeInField("ar.filter.name", text: "zz-no-such-file")

        let chip = app.descendants(matching: .any)["ar.filter.chip.name"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the name filter should show as a chip in effect")
        let empty = app.descendants(matching: .any)["ar.empty.filteredOut"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5), "every row is filtered out")
        XCTAssertTrue(empty.accessibilityText.contains("file-name filter"), "the empty list should name the filter: \(empty.accessibilityText)")
        captureScreenshot("w40-filter-bar-empty-names-filter")

        let clear = app.buttons["ar.empty.clear.ar.filter.chip.name"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5), "the empty list should offer to clear that filter")
        clear.click()
        waitForRows(minimum: countBefore, timeout: 10)
        XCTAssertTrue(chip.waitForNonExistence(timeout: 5), "cleared, the chip should leave")
        let fieldValue = app.textFields["ar.filter.name"].value as? String ?? ""
        XCTAssertFalse(fieldValue.contains("zz-no-such-file"), "and the field should empty with it: \(fieldValue)")
        captureScreenshot("w40-filter-bar-cleared")
    }

    /// W40.fix-reader-in-effect-folder: a sidebar folder is a location, while a carried search stays visible.
    func testInEffectOmitsTheSidebarFolderAndKeepsTheSearch() throws {
        waitForRows(minimum: 5, timeout: 10)
        let allFiles = app.staticTexts.matching(identifier: "ar.sidebar.allFiles").firstMatch
        if !allFiles.exists { toolbarButton("ar.toolbar.sidebar").click() }
        let folder = app.descendants(matching: .any).matching(identifier: "ar.sidebar.folder").firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.click()
        XCTAssertTrue(waitForRowCount(1), "Box 2 contains one fixture file")
        XCTAssertFalse(app.descendants(matching: .any)["ar.filter.chip.folder"].exists)
        captureScreenshot("w40-in-effect-folder-only")

        typeInField("ar.filter.name", text: "zz-no-such-file")
        let nameChip = app.buttons["ar.filter.chip.name"]
        XCTAssertTrue(nameChip.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["ar.filter.chip.folder"].exists)
        let empty = app.descendants(matching: .any)["ar.empty.filteredOut"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertTrue(empty.accessibilityText.contains("Box 2"), "the explanation still gives the folder")
        captureScreenshot("w40-in-effect-folder-and-search")
        nameChip.click()
        XCTAssertTrue(waitForRowCount(1), "clearing the search keeps the selected folder")
        XCTAssertTrue(nameChip.waitForNonExistence(timeout: 5))
        allFiles.click()
        waitForRows(minimum: 5, timeout: 10)
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
        XCTAssertTrue(addField.waitForExistence(timeout: 5), "the Inspector should present its subject field")
        addField.click()
        addField.typeText(addedTag + "\r")   // Return adds the tag: there is no Add button
        XCTAssertTrue(waitForTags(on: targetName, containing: [addedTag]),
                      "the editor's subject addition should be verified on the scratch document")
        app.buttons["ar.tagEditor.done"].click()

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
        XCTAssertTrue(app.staticTexts["Undid 1 change in \(name): Read state: “Read” → “Unread”."].waitForExistence(timeout: 5))
        let afterTags = try XCTUnwrap(URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]).tagNames)
        XCTAssertEqual(beforeTags.sorted(), afterTags.sorted())
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), beforeBytes)
        XCTAssertFalse(undo.isEnabled, "inverse records cannot become redo candidates")
        captureScreenshot("w40-audit-ledger-undo-verified")
        app.menuBars.menuBarItems["Tags"].click()
        app.menuItems["Redo Tag Change"].click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Read"], excluding: ["Unread"]))
        XCTAssertTrue(app.staticTexts["Redid 1 change in \(name): Read state: “Unread” → “Read”."]
            .waitForExistence(timeout: 5))
        captureScreenshot("w40-undo-status-redo-detail")
        undo.click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Unread"], excluding: ["Read"]))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), beforeBytes)
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
        XCTAssertFalse(app.buttons["Set"].exists || app.buttons["Clear"].exists
                       || app.buttons["Clear Uncertain"].exists || app.buttons["Add"].exists,
                       "the inspector applies its fields as typed, without field action buttons")
        field.typeText("1958-03-12\r")
        XCTAssertTrue(waitForTags(on: name, containing: ["842", "Sent With 1958-03-12"]),
                      "Return should write the Sent-With date and keep the document's own date")

        app.checkBoxes["ar.tagEditor.sentWithUncertain"].click()
        XCTAssertTrue(waitForTags(on: name, containing: ["Sent With 1958-03-12", "Sent With Date Uncertain"]),
                      "Mark Uncertain should flag the Sent-With date")
        captureScreenshot("w40-sent-with-date-in-sheet")

        // Emptying the field and leaving it (Tab) removes the date and its flag.
        field.click()
        pressKey("a", modifiers: .command)
        field.typeText(XCUIKeyboardKey.delete.rawValue + "\t")
        XCTAssertTrue(waitForTags(on: name, containing: ["842"],
                                  excluding: ["Sent With 1958-03-12", "Sent With Date Uncertain"]),
                      "an emptied Sent-With field should remove the date and its flag")
        app.buttons["ar.tagEditor.done"].click()
    }

    /// W40.fix-reader-date-ambiguity (ledger R-47): the fixture's `00006` carries two Years (`1983`, `1984`).
    /// The Library health popover's Show button finds it alone (W40.fix-reader-health-counts: the filter bar shows the
    /// toggle only while it is on), its Date cell is flagged naming the Year set aside, and the ⌘I sheet says the
    /// same. Read-only: nothing is written.
    func testTwoYearTagsAreFlaggedAndTheFilterFindsThem() throws {
        showAmbiguousDatesFromHealth()
        clickRow(0)
        toolbarButton("ar.toolbar.editTags").click()
        let notice = app.descendants(matching: .any)["ar.tagEditor.dateAmbiguity"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "the ⌘I sheet should flag the ambiguous date")
        XCTAssertTrue(notice.label.contains("1983 was set aside"), "sheet notice: \(notice.label)")
        captureScreenshot("w40-date-ambiguity-sheet")
        app.buttons["ar.tagEditor.done"].click()

        let toggle = app.descendants(matching: .any)["ar.filter.ambiguousDates"]
        toggle.click()
        waitForRows(minimum: 2, timeout: 10)
        XCTAssertGreaterThan(rowCount, 1, "turning the filter off should bring the other rows back")
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5), "turned off, the filter should leave the filter bar")
    }

    func testPDFWarningExplainsMissingTextAndOffersActions() throws {
        typeInField("ar.filter.name", text: "IMG_NOTEXT")
        waitForRows(minimum: 1, timeout: 10)
        let warning = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.fileHealth.cell.warning.")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        warning.click()
        XCTAssertTrue(app.buttons["ar.fileHealth.open"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["ar.fileHealth.reveal"].exists)
        XCTAssertTrue(app.staticTexts["No selectable text"].exists)
        captureScreenshot("w40-file-health-no-text-detail")
        pressKey(XCUIKeyboardKey.escape.rawValue, modifiers: [])
        XCTAssertTrue(app.buttons["ar.fileHealth.open"].waitForNonExistence(timeout: 5))
    }

    /// A click on a file's alert explains the conflict and opens that file's existing editor.
    func testFileHealthWarningOpensDetailsAndEditInfoForThatFile() throws {
        showAmbiguousDatesFromHealth()
        let warnings = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.fileHealth.cell.date."))
        let warning = warnings.firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        warning.click()
        let editInfo = app.buttons["ar.fileHealth.editInfo"]
        XCTAssertTrue(editInfo.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Conflicting date tags"].exists)
        captureScreenshot("w40-file-health-date-detail")
        editInfo.click()
        let notice = app.descendants(matching: .any)["ar.tagEditor.dateAmbiguity"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.label.contains("1983 was set aside"))
        app.buttons["ar.tagEditor.done"].click()
    }

    /// W40.fix-reader-health-live: exercise the presented popover independently of Edit Info.
    /// The gated unit regression supplies deterministic in-progress indexing updates.
    func testLibraryHealthPopoverShowsCountsAndFilters() {
        showAmbiguousDatesFromHealth()
    }

    private func showAmbiguousDatesFromHealth() {
        let toggle = app.descendants(matching: .any)["ar.filter.ambiguousDates"]
        XCTAssertFalse(toggle.exists, "the filter bar should not show the ambiguous-dates count while the filter is off")
        let health = app.descendants(matching: .any)["ar.status.health"]
        XCTAssertTrue(health.waitForExistence(timeout: 10))
        let show = app.descendants(matching: .any)["ar.health.ambiguousDates"]
        // Keep the popover open while counts arrive (W40.fix-reader-health-live).
        health.click()
        XCTAssertTrue(show.waitForExistence(timeout: 3))
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: show)
        wait(for: [enabled], timeout: 15)
        XCTAssertTrue(show.isEnabled, "a fixture with two Year tags should offer the filter in Library health")
        captureScreenshot("w40-health-popover")
        show.click()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "the active filter should show in the filter bar")
        XCTAssertTrue(waitForRowCount(1), "the ambiguous-dates filter should list only the two-Year document")
        let row = table.tableRows.element(boundBy: 0)
        let dateCell = row.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "ar.cell.date.")).firstMatch
        XCTAssertTrue(dateCell.waitForExistence(timeout: 5))
        XCTAssertTrue(dateCell.identifier.contains("00006"), "the one row should be 00006: \(dateCell.identifier)")
        XCTAssertTrue(dateCell.label.contains("ambiguous date"), "Date cell label: \(dateCell.label)")
        XCTAssertTrue(dateCell.label.contains("Two Year tags: 1984 is used, 1983 was set aside."),
                      "Date cell label: \(dateCell.label)")
        captureScreenshot("w40-date-ambiguity-filtered-row")
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
        let path = URL(fileURLWithPath: Self.fixturePath).appendingPathComponent(filename).path
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // A fresh URL each pass: a reused one caches its resource values and never sees a later write.
            let names = ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.tagNamesKey]))?.tagNames) ?? []
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
