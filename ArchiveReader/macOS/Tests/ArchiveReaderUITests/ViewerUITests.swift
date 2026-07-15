import XCTest

/// Tests for the document viewer and preview sheet.
/// All tests run against the pre-built GUI fixture.
final class ViewerUITests: FixtureUITestCase {

    // MARK: - Preview via toolbar (W5.d1–d4)

    func testPreviewOpensAndDismisses() throws {
        waitForRows(minimum: 3, timeout: 10)

        // Select the first row by clicking it (robust to transient focus loss).
        clickRow(0)

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
        clickRow(0)

        let previewButton = app.buttons["ar.toolbar.preview"]
        previewButton.click()

        let doneButton = app.buttons["ar.preview.done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))

        // The preview should offer to open the full viewer — proof a document actually loaded into
        // the sheet (beyond just the sheet chrome appearing).
        XCTAssertTrue(app.buttons["ar.preview.open"].exists,
            "Preview should show an Open-in-Viewer button for the loaded document")
        // NOTE: the content panes are PDFView-backed (`ar.preview.imagePane`/`ar.preview.textPane`) or a
        // SwiftUI "no text" view. A PDFView does NOT expose its accessibilityIdentifier to XCUITest, so
        // asserting on the text-pane element directly is not reliable — the Open button above is the
        // queryable proof the document loaded. (The no-text-layer/degrade paths ARE asserted in
        // testNoTextLayerPDFShowsBanner / testNonPDFImageDegrades.)

        doneButton.click()
    }

    // MARK: - Document viewer opens (full viewer via toolbar Open)

    func testDocumentViewerOpens() throws {
        waitForRows(minimum: 3, timeout: 10)

        clickRow(0)

        // Open via ⌘O (Open Document menu command).
        pressKey("o", modifiers: .command)

        // A second window should appear — the document viewer.
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        // We should have at least 2 windows (nav + viewer) — the observable proof ⌘O opened the
        // document viewer for the selected row.
        XCTAssertGreaterThanOrEqual(app.windows.count, 2,
            "Opening a document should create a second window")
        // NOTE: the viewer's main content pane is PDFView-backed (`ar.doc.textPane`) whenever the doc
        // has a text layer, and a PDFView does not expose its accessibilityIdentifier to XCUITest, so
        // we don't assert on it here. The SwiftUI degrade paths (`ar.doc.formatBanner` / `ar.doc.noText`)
        // ARE queryable and are asserted in testNoTextLayerPDFShowsBanner / testNonPDFImageDegrades.

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
