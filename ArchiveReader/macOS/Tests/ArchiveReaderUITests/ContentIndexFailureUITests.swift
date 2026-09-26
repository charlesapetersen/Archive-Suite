import XCTest

/// W23.m9-fu3 — render the warning and exercise same-session recovery in the off-screen VM.
/// The runner seeds only the generated scratch fixture with 1 KiB of invalid SQLite bytes.
@MainActor
final class ContentIndexFailureUITests: FixtureUITestCase {

    func testCorruptIndexWarningRetractsAfterScratchRepairAndReindex() throws {
        try requireGeneratedScratchFixtureForIndexTests()
        let indexURL = URL(fileURLWithPath: Self.canonicalFixturePath)
            .appendingPathComponent("content-index-v2.sqlite3")
        let junk = try Data(contentsOf: indexURL)
        try XCTSkipUnless(junk == Data(repeating: 0x5A, count: 1024),
                          "Run the fixture builder with AR_GUI_CORRUPT_INDEX=1")

        let warning = app.staticTexts["ar.status.indexFailure"]
        XCTAssertTrue(warning.waitForExistence(timeout: 20),
                      "a corrupt content cache must be reported in the status bar")
        XCTAssertTrue(warning.accessibilityText.contains("Search index unavailable"), warning.accessibilityText)

        // Failed open leaves no SQLite handle. Repair this marker-checked scratch cache, then use the
        // normal File ▸ Rescan Archive Folder command to run another index pass in the same process.
        try Data().write(to: indexURL, options: .atomic)
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10))
        fileMenu.click()
        let rescan = app.menuItems["Rescan Archive Folder"]
        XCTAssertTrue(rescan.waitForExistence(timeout: 5))
        rescan.click()

        let deadline = Date().addingTimeInterval(20)
        while warning.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(warning.exists, "the warning must retract after the replacement DB opens")

        let search = app.textFields["ar.filter.ocr"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("California")
        waitForRows(minimum: 1, timeout: 60)
        XCTAssertGreaterThanOrEqual(rowCount, 1,
                                    "the same-session rescan must refill the repaired cache from scratch PDF text")
    }
}
