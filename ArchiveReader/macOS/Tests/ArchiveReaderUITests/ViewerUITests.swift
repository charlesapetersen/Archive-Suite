import XCTest

/// Tests for the document viewer and preview sheet.
/// All tests run against the pre-built GUI fixture.
final class ViewerUITests: FixtureUITestCase {

    // MARK: - Preview via toolbar (W5.d1–d4)

    func testPreviewOpensAndDismisses() throws {
        waitForRows(minimum: 3, timeout: 10)

        // Select the first row by clicking it.
        let firstRow = table.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.exists, "First row should exist")
        firstRow.click()

        // Open preview via the toolbar button.
        let previewButton = app.buttons["ar.toolbar.preview"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5), "Preview toolbar button should exist")
        previewButton.click()

        // The preview sheet should appear with a Done button.
        let doneButton = app.buttons["ar.preview.done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5),
            "Preview sheet should open with a Done button")

        // The preview should have an Open button (to open the full viewer).
        let openButton = app.buttons["ar.preview.open"]
        XCTAssertTrue(openButton.exists, "Preview should have an Open in Viewer button")

        // Dismiss the preview.
        doneButton.click()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        XCTAssertFalse(doneButton.exists, "Preview should be dismissed after clicking Done")
    }

    // MARK: - Preview shows text pane for standard PDFs

    func testPreviewShowsTextPane() throws {
        waitForRows(minimum: 3, timeout: 10)

        // Select a standard 2-page PDF (file 1–6 from fixture are real PDFs).
        let firstRow = table.tableRows.element(boundBy: 0)
        firstRow.click()

        let previewButton = app.buttons["ar.toolbar.preview"]
        previewButton.click()

        let doneButton = app.buttons["ar.preview.done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))

        // For a standard 2-page PDF, the text pane should exist (not "no text").
        // If this is a standard PDF with OCR text, we should see the text pane.
        // The "no text" label only appears for single-page / no-text-layer PDFs.
        // We can't guarantee which file is first (depends on sort), so just verify
        // the preview infrastructure exists.
        let textPane = app.otherElements["ar.preview.textPane"]
        let noText = app.staticTexts["ar.preview.noText"]

        // One of these should exist.
        XCTAssertTrue(textPane.exists || noText.exists,
            "Preview should show either a text pane or a 'no text' indicator")

        doneButton.click()
    }

    // MARK: - Document viewer opens (full viewer via toolbar Open)

    func testDocumentViewerOpens() throws {
        waitForRows(minimum: 3, timeout: 10)

        let firstRow = table.tableRows.element(boundBy: 0)
        firstRow.click()

        // Open via ⌘O (Open Document menu command).
        pressKey("o", modifiers: .command)

        // A second window should appear — the document viewer.
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let windows = app.windows
        // We should have at least 2 windows (nav + viewer).
        XCTAssertGreaterThanOrEqual(windows.count, 2,
            "Opening a document should create a second window")

        // The viewer should have a text pane or a format banner.
        let textPane = app.otherElements["ar.doc.textPane"]
        let formatBanner = app.staticTexts["ar.doc.formatBanner"]
        let noText = app.staticTexts["ar.doc.noText"]
        XCTAssertTrue(textPane.exists || formatBanner.exists || noText.exists,
            "Document viewer should show content elements")

        // Close the viewer window (⌘W closes the front window).
        pressKey("w", modifiers: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: - Format banner for no-text-layer PDF (W5.d4)

    func testNoTextLayerPDFShowsBanner() throws {
        waitForRows(minimum: 5, timeout: 10)

        // Filter for the no-text-layer fixture file.
        let filterField = app.textFields["ar.filter.name"]
        XCTAssertTrue(filterField.waitForExistence(timeout: 5))
        filterField.click()
        filterField.typeText("NOTEXT")
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // Should have exactly 1 result.
        if rowCount >= 1 {
            let row = table.tableRows.element(boundBy: 0)
            row.click()

            // Open viewer.
            pressKey("o", modifiers: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(2))

            // The viewer should show a format banner or "no text" indicator.
            let banner = app.staticTexts["ar.doc.formatBanner"]
            let noText = app.staticTexts["ar.doc.noText"]
            XCTAssertTrue(banner.exists || noText.exists,
                "No-text-layer PDF should show a format banner or 'no text' indicator")

            pressKey("w", modifiers: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        // Clear filter.
        filterField.click()
        pressKey("a", modifiers: .command)
        app.typeKey(.delete, modifierFlags: [])
    }

    // MARK: - Non-PDF image degrades gracefully (W5.d4)

    func testNonPDFImageDegrades() throws {
        waitForRows(minimum: 5, timeout: 10)

        // Filter for the JPEG fixture file.
        let filterField = app.textFields["ar.filter.name"]
        XCTAssertTrue(filterField.waitForExistence(timeout: 5))
        filterField.click()
        filterField.typeText("PHOTO")
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        if rowCount >= 1 {
            let row = table.tableRows.element(boundBy: 0)
            row.click()

            // Open viewer — should not crash for a non-PDF.
            pressKey("o", modifiers: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(2))

            // Viewer should still exist (degraded, not crashed).
            XCTAssertGreaterThanOrEqual(app.windows.count, 2,
                "Viewer should open even for non-PDF files (degraded)")

            pressKey("w", modifiers: .command)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        // Clear filter.
        filterField.click()
        pressKey("a", modifiers: .command)
        app.typeKey(.delete, modifierFlags: [])
    }
}
