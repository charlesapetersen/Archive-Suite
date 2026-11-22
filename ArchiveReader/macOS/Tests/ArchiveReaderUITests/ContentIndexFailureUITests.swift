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

        let search = app.textFields["ar.filter.ocr"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let unfilteredCount = rowCount
        search.click()
        search.typeText("California")

        let unavailable = app.descendants(matching: .any)["ar.empty.ocrSearchUnavailable"]
        let noMatches = app.descendants(matching: .any)["ar.empty.filteredOut"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15))
        XCTAssertTrue(unavailable.accessibilityText.contains("OCR search unavailable"), unavailable.accessibilityText)
        XCTAssertTrue(unavailable.accessibilityText.contains("couldn’t open the search index"), unavailable.accessibilityText)
        XCTAssertEqual(rowCount, 0)
        XCTAssertFalse(noMatches.exists)
        _ = captureScreenshot("ocr-search-unavailable")

        // Failed open leaves no SQLite handle. Repair only the marker-checked scratch cache, then use
        // the overlay’s Rescan button. The existing query should find rows again in the same process.
        try Data().write(to: indexURL, options: .atomic)
        let rescan = app.buttons["ar.empty.rescan"]
        XCTAssertTrue(rescan.waitForExistence(timeout: 5))
        rescan.click()

        waitForRows(minimum: 1, timeout: 60)
        XCTAssertGreaterThan(rowCount, 0, "the rescan must refill the repaired cache from scratch PDF text")
        XCTAssertLessThan(rowCount, unfilteredCount, "the original query should still filter the list")
        XCTAssertEqual(search.value as? String, "California")
        XCTAssertFalse(warning.exists)
        XCTAssertFalse(unavailable.exists)

        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("zzunmatchablefixtureword")
        XCTAssertTrue(noMatches.waitForExistence(timeout: 15))
        XCTAssertTrue(noMatches.accessibilityText.contains("No matches"), noMatches.accessibilityText)
        XCTAssertFalse(unavailable.exists)
    }
}
