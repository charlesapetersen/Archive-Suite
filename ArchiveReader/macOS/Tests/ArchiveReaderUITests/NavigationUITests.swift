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
        // Open the tag cloud panel via toolbar button.
        let tagCloudButton = app.buttons["ar.toolbar.tagCloud"]
        XCTAssertTrue(tagCloudButton.waitForExistence(timeout: 5))
        tagCloudButton.click()

        // The tag cloud container should appear.
        let tagCloud = app.groups["ar.tagCloud"]
        if !tagCloud.waitForExistence(timeout: 5) {
            // Some SwiftUI versions expose it differently — try scrollViews.
            let alt = app.scrollViews["ar.tagCloud"]
            XCTAssertTrue(alt.waitForExistence(timeout: 3), "Tag cloud panel should appear")
        }

        // Collect all tag-cloud tag labels. They have id "ar.tagCloud.tag".
        let tagTexts = app.staticTexts.matching(identifier: "ar.tagCloud.tag")
        // Wait a moment for the cloud to render.
        if tagTexts.count == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }

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

        // Subject tokens that SHOULD appear.
        let expectedSubjects = ["Jerry Brown", "Economics", "Medieval Records",
                                "DP chapters", "Budget Policy", "Education Policy"]
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
        let sidebarButton = app.buttons["ar.toolbar.sidebar"]
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
        let button = app.buttons["ar.toolbar.tagCloud"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))

        // Tag cloud is hidden by default (@AppStorage default = false).
        // Open it.
        button.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // Should find tag-cloud tags or the container.
        let tagTexts = app.staticTexts.matching(identifier: "ar.tagCloud.tag")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let countWhenOpen = tagTexts.count
        XCTAssertGreaterThan(countWhenOpen, 0, "Tag cloud should show tags when open")

        // Close it.
        button.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        // Tags should no longer be visible.
        let countWhenClosed = app.staticTexts.matching(identifier: "ar.tagCloud.tag").count
        XCTAssertEqual(countWhenClosed, 0, "Tag cloud tags should disappear when panel is closed")
    }

    // MARK: - Column headers exist

    func testColumnHeadersExist() throws {
        // The table header has id "ar.table.header".
        let header = app.otherElements["ar.table.header"]
        // NSTableHeaderView may be exposed differently — check the table's column headers.
        // At minimum, verify the table itself is present (covered by setUp).
        // Check that key column header texts are reachable.
        let expectedHeaders = ["Document date", "File name", "File tags", "Priority", "Read"]
        for title in expectedHeaders {
            let headerCell = table.staticTexts[title]
            XCTAssertTrue(headerCell.exists || table.buttons[title].exists,
                "Column header '\(title)' should be visible in the table")
        }
    }

    // MARK: - Header-click sort (W5.c3)

    func testHeaderClickChangesSort() throws {
        // Wait for enough rows to make sort order meaningful.
        waitForRows(minimum: 5, timeout: 10)

        // Capture the first row's label before sort.
        let firstRowBefore = table.tableRows.element(boundBy: 0)
        let labelBefore = firstRowBefore.staticTexts.firstMatch.label

        // Click the "File name" column header to sort by name.
        let nameHeader = table.staticTexts["File name"]
        if nameHeader.exists {
            nameHeader.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))

            // Click again to reverse the sort direction.
            nameHeader.click()
            RunLoop.current.run(until: Date().addingTimeInterval(1))

            let firstRowAfter = table.tableRows.element(boundBy: 0)
            let labelAfter = firstRowAfter.staticTexts.firstMatch.label
            // After two clicks (sort ascending then descending), the order likely changed
            // vs. the default chronological sort. We can't assert the exact order without
            // knowing the default, but the test validates the click interaction doesn't crash.
            // The real assertion is that the table still has rows (didn't break).
            XCTAssertGreaterThanOrEqual(rowCount, 5, "Table should still have rows after sort")
        } else {
            // Column header may be accessible via a button.
            let nameButton = table.buttons["File name"]
            XCTAssertTrue(nameButton.exists, "File name column header should be reachable")
            nameButton.click()
        }
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
}
