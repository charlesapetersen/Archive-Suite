import XCTest

/// W40.fix-reader-columns-in-header: Finder-style column choices from the actual header.
/// Column visibility changes only the app's test defaults; no archive file is written.
final class ColumnHeaderUITests: FixtureUITestCase {
    func testHeaderMenuShowsAndHidesAColumn() throws {
        XCTAssertFalse(app.descendants(matching: .any)["ar.filter.columns"].exists,
                       "column choices now live in the header")
        let header = table.staticTexts["File name"].exists
            ? table.staticTexts["File name"] : table.buttons["File name"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        let before = table.tableColumns.count
        let rowsBefore = rowCount

        func openMenu() {
            header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
            XCTAssertTrue(app.menuItems["Type"].waitForExistence(timeout: 5))
        }
        func expectColumns(_ count: Int) {
            let predicate = NSPredicate { _, _ in self.table.tableColumns.count == count }
            expectation(for: predicate, evaluatedWith: table)
            waitForExpectations(timeout: 5)
        }

        openMenu()
        XCTAssertTrue(app.menuItems["⚑ Flag"].exists)
        XCTAssertTrue(app.menuItems["⚠︎ Needs attention"].exists)
        XCTAssertFalse(app.menuItems["File name"].isEnabled, "the file name is always shown")
        XCTAssertTrue(app.menuItems["Default Sort (date, then name)"].exists,
                      "sorting remains available beside column choices")
        _ = captureScreenshot("column-header-menu")
        app.menuItems["Type"].click()
        expectColumns(before - 1)
        XCTAssertEqual(rowCount, rowsBefore)
        _ = captureScreenshot("column-header-type-hidden")

        openMenu()
        app.menuItems["Type"].click()
        expectColumns(before)
        XCTAssertEqual(rowCount, rowsBefore)
        _ = captureScreenshot("column-header-type-restored")
    }
}
