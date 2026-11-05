import XCTest

/// W40.fix-reader-columns (owner session reader-1, row 5): the list's columns can be chosen from a visible
/// Columns chip in the filter bar, not only from the header's right-click menu. Opens the chip, hides Type,
/// checks the table lost a column, and shows it again. Writes no file; the column choice is app defaults only.
final class ColumnsChipUITests: FixtureUITestCase {

    func testTheColumnsChipShowsAndHidesAColumn() throws {
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        waitForRows(minimum: 1, timeout: 15)

        let chip = app.descendants(matching: .any)["ar.filter.columns"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the Columns chip is in the filter bar")
        XCTAssertTrue(chip.isHittable, "the Columns chip is on screen, not wrapped out of view")
        let before = table.tableColumns.count

        chip.click()
        let flag = app.menuItems["⚑ Flag"]
        XCTAssertTrue(flag.waitForExistence(timeout: 5), "the chip's menu names the ⚑ column in words")
        XCTAssertTrue(app.menuItems["⚠︎ Needs attention"].exists)
        XCTAssertFalse(app.menuItems["File name"].isEnabled, "the file name is always shown")
        _ = captureScreenshot("w40-columns-chip-menu")
        let type = app.menuItems["Type"]
        XCTAssertTrue(type.exists)
        type.click()
        settle(1)
        XCTAssertEqual(table.tableColumns.count, before - 1, "hiding Type takes its column out of the list")

        chip.click()
        XCTAssertTrue(app.menuItems["Type"].waitForExistence(timeout: 5))
        app.menuItems["Type"].click()
        settle(1)
        XCTAssertEqual(table.tableColumns.count, before, "showing Type brings it back")
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
