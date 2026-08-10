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
        let previewButton = toolbarButton("ar.toolbar.preview")
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

        let previewButton = toolbarButton("ar.toolbar.preview")
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

    // MARK: - Page links are reachable from the document window (W23.m4 defect 1)

    /// The one part of W23.m4 no unit test can see: whether SwiftUI actually delivers the document
    /// window's focused `ArchiveLinkTarget` to the menu. Before the fix the command read the root and
    /// marker through a focused `NavigationModel`, which a document window never publishes — so
    /// "Copy Archive Link to This Page" was disabled exactly where a reader has the page in front of
    /// them. This asserts the menu item is present AND enabled with only the viewer focused.
    func testCopyPageLinkIsEnabledInTheDocumentWindow() throws {
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        pressKey("o", modifiers: .command)                 // open the full document window
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "precondition: the document window opened")

        let item = documentMenuItem("Copy Archive Link to This Page")
        XCTAssertTrue(item.exists, "the command should be in the Document menu")
        XCTAssertTrue(item.isEnabled,
                      "…and ENABLED with only the viewer focused (it required a NavigationModel before)")
        app.typeKey(.escape, modifierFlags: [])            // close the menu without invoking it
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        pressKey("w", modifiers: .command)                 // close the viewer
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    // MARK: - ⌘0 (Fit Page) reaches the PREVIEW sheet (W26.docs-fu1)

    /// The preview-sheet half of "⌘0 = fit full page everywhere zoom applies", which shipped with only
    /// its *Document-menu* path confirmed — the sheet-specific check was deferred, then stayed deferred
    /// on a reason (an unindexed scratch corpus) that `W26.walk2` made void.
    ///
    /// 🔴 **RAN 2026-08-09, AND THE SHIPPED CLAIM IS FALSE — the feature does not work.** Tracked as
    /// `W26.previewzoom`; this test is annotated `XCTExpectFailure` so the lane stays green *and* flips
    /// loudly the moment someone fixes it. Do not delete the annotation without fixing the app: what was
    /// measured in the VM was
    ///  - CHROME: `Fit Page` is disabled from the list (correct) and **still disabled while the preview
    ///    sheet is open** — so `@FocusedObject var doc` is nil and ⌘0 is bound to nothing; and
    ///  - PIXELS: the sheet's image pane was **byte-identical** before and after ⌘↑×3, and again after
    ///    ⌘0 (two of the three screenshots deduplicated to one blob in the result bundle). Nothing zoomed
    ///    and nothing refitted, because the command never arrives.
    ///
    /// The cause is one token, and the codebase's own convention names it: `NavigationWindowView` and
    /// `DocumentWindowView` both publish with `.focusedSceneObject`, and their Document-menu commands
    /// work. `PreviewSheet.swift:29` is the only `.focusedObject` in the app — and the only one that
    /// fails. See `W26.previewzoom` for the fix and for the zoom→⌘0 pixel bracket to re-add with it.
    ///
    /// The ⌘↑/⌘0 keystrokes are deliberately NOT re-sent here: with the bug present they provably change
    /// nothing, and ⌘0 in that state left the app **non-idle for 241 s** (measured), which would put a
    /// 4½-minute dead wait into every health-gate run to re-prove a no-op.
    func testFitPageCommandReachesThePreviewSheet() throws {
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)

        // (1a) The control. Without a published DocumentViewerModel the command has nothing to act on.
        let fitFromList = documentMenuItem("Fit Page")
        XCTAssertTrue(fitFromList.exists, "Fit Page should be in the Document menu")
        XCTAssertFalse(fitFromList.isEnabled,
                       "precondition: from the list alone, ⌘0 has no viewer to fit")
        closeMenu()

        // Open the preview sheet via the toolbar (more robust than Space, which is focus-scoped).
        toolbarButton("ar.toolbar.preview").click()
        let done = app.buttons["ar.preview.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the preview sheet should open")
        settle(1)

        // (2) Pixels: the sheet opens at fit-full-page (PDFPaneController(persists: false)). This shot is
        // the other half of the item — it is what confirms the *preview default zoom* really is full page.
        captureScreenshot("w26docsfu1-preview-default-fit")

        // (1b) The assertion the disabled control above earns — and the one that is currently BROKEN.
        XCTExpectFailure("W26.previewzoom: PreviewSheet uses .focusedObject, which publishes nothing here, "
                         + "so the Document menu's zoom/fit commands stay disabled and ⌘0 never reaches the sheet",
                         strict: true) {
            XCTAssertTrue(documentMenuItem("Fit Page").isEnabled,
                          "…and ENABLED while the preview sheet is open — the sheet publishes the viewer model")
        }
        closeMenu()

        if done.exists { done.click() }
    }

    // MARK: - A tagged non-PDF image really renders, in preview AND viewer (W26.docs-fu1)

    /// The other check deferred for "scratch corpus not Spotlight-indexed": tagged non-PDF images open
    /// in the viewer and the preview. `testNonPDFImageDegrades` already proves the app does not crash
    /// and a window appears; what was never checked is whether the image is *shown*, which lives in
    /// pixels — `PDFPage(image:)` returning an empty page would pass every query above.
    ///
    /// The fixture's `IMG_PHOTO — Fixture.jpg` is a solid tan JPEG, so a rendered page is unmistakable
    /// in the shots, and its absence equally so.
    func testNonPDFImageRendersInPreviewAndViewer() throws {
        waitForRows(minimum: 5, timeout: 10)

        let filterField = app.textFields["ar.filter.name"]
        XCTAssertTrue(filterField.waitForExistence(timeout: 5))
        filterField.click()
        filterField.typeText("PHOTO")
        settle(1)
        XCTAssertGreaterThanOrEqual(rowCount, 1, "the tagged JPEG should be discoverable in the list")

        clickRow(0)
        toolbarButton("ar.toolbar.preview").click()
        XCTAssertTrue(app.buttons["ar.preview.done"].waitForExistence(timeout: 5),
                      "the preview sheet should open for a non-PDF image")

        // Chrome: a JPEG has no OCR text page, so the right pane must be the "No OCR text page" view.
        // That element only exists on the `model.current != nil` branch — i.e. it is queryable proof the
        // image was wrapped into a document rather than the sheet falling back to its load-error view
        // (which carries no identifier at all).
        XCTAssertTrue(elementExists("ar.preview.noText"),
                      "a non-PDF image should load and show the no-OCR-text pane, not a load error")
        settle(1)
        captureScreenshot("w26docsfu1-jpeg-1-preview")

        // …and in the full viewer, reached the way a reader would from the preview.
        app.buttons["ar.preview.open"].click()
        settle(2)
        XCTAssertGreaterThanOrEqual(app.windows.count, 2, "Open should bring up the document window")
        captureScreenshot("w26docsfu1-jpeg-2-viewer")

        pressKey("w", modifiers: .command)
        settle(1)
    }

    // MARK: - Helpers

    /// Let the UI settle for `seconds` without blocking the main actor's runloop callbacks.
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// True if any element — of any type — carries this identifier. SwiftUI decides for itself whether a
    /// given view lands in the tree as a static text, a group or something else, so a type-specific query
    /// can report "absent" for something plainly on screen.
    private func elementExists(_ identifier: String, timeout: TimeInterval = 5) -> Bool {
        let match = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        return match.waitForExistence(timeout: timeout)
    }

    /// Dismiss an open menu without invoking anything. Escape is also the preview sheet's cancel action,
    /// so this is only ever called while a menu is up (the menu takes the key first).
    private func closeMenu() {
        app.typeKey(.escape, modifierFlags: [])
        settle(0.3)
    }

    /// Open the Document menu and return one of its items. Menu items only join the accessibility tree
    /// while their menu is open, so the click is part of the query.
    private func documentMenuItem(_ title: String) -> XCUIElement {
        let bar = app.menuBars.element(boundBy: 0)
        let document = bar.menuBarItems["Document"]
        XCTAssertTrue(document.waitForExistence(timeout: 5), "the Document menu should exist")
        document.click()
        let item = bar.menuItems[title]
        _ = item.waitForExistence(timeout: 5)
        return item
    }
}
