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
    /// 🔴 **This ran on 2026-08-09 and the shipped claim was FALSE** — `Fit Page` stayed disabled with the
    /// sheet wide open, and the image pane was byte-identical across ⌘↑×3 and ⌘0. `PreviewSheet` was the
    /// app's only `.focusedObject`, which publishes solely while the modified subtree holds SwiftUI keyboard
    /// focus — and the pane is an AppKit `PDFView` behind `NSViewRepresentable`, which never gives it.
    /// Fixed 2026-08-10 (`W26.previewzoom`). The `XCTExpectFailure` that held the bug is deleted with it.
    ///
    /// ⚠️ **Assertion 2 below is not paperwork — it FAILED, and it is why the fix is not the one-token one
    /// the issue prescribed.** Swapping the sheet to `.focusedSceneObject` left `Fit Page` enabled *after
    /// dismissal*, because **a focused-scene value is not retracted when the view that set it is torn
    /// down**. The publication now belongs to `NavigationWindowView`, which outlives the sheet and can
    /// withdraw it (`publishedPreviewViewer`). Do not "simplify" this back into the sheet.
    ///
    /// Three things are asserted, because none is sufficient alone:
    ///  1. CHROME, enabled — `Fit Page` is DISABLED from the list and ENABLED while the sheet is open.
    ///     The disabled control is what makes the enabled state mean something.
    ///  2. CHROME, the converse — with the sheet DISMISSED it goes back to DISABLED. It is asserted BEFORE
    ///     the pixels, and the sheet is re-opened afterwards, so the cheap decisive checks cannot end up
    ///     behind the slow one (see the timing note below).
    ///  3. PIXELS — a PDFView's content pane is not XCUITest-queryable (W7.6), so *whether the page
    ///     actually refitted* is only visible in a screenshot. Three shots bracket the sequence:
    ///     fit → zoomed in → ⌘0. A human reads them; the test does not judge them. What they showed on
    ///     2026-08-10: shot 2 differs from shot 1, and shot 3 is **byte-identical to shot 1** — a round
    ///     trip, which is a stronger claim than "something changed".
    ///
    /// ⏱ With the bug present, ⌘0 in the sheet left the app **non-idle for 241 s** (measured twice over).
    /// The stall WAS the bug — a keystroke bound to nothing — and it is gone: ⌘↑×3 = 0.4 s, ⌘0 = 0.1 s.
    /// The bracket keeps printing its elapsed time so a future slow run says which keystroke paid for it.
    func testFitPageCommandReachesThePreviewSheet() throws {
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)

        // (1a) The control. Without a published DocumentViewerModel the command has nothing to act on.
        let fitFromList = documentMenuItem("Fit Page")
        XCTAssertTrue(fitFromList.exists, "Fit Page should be in the Document menu")
        XCTAssertFalse(fitFromList.isEnabled,
                       "precondition: from the list alone, ⌘0 has no viewer to fit")
        closeMenu()

        // (1b) The assertion that control earns: open the sheet and the command comes alive.
        openPreviewSheet()
        XCTAssertTrue(documentMenuItem("Fit Page").isEnabled,
                      "ENABLED while the preview sheet is open — the nav window publishes the viewer model")
        closeMenu()

        // (2) The converse, and the assertion that actually earned its keep: a focused-SCENE value is NOT
        // retracted when the view that set it is torn down, so a sheet that publishes itself leaves this
        // command enabled over a dead preview model. Only a publisher that OUTLIVES the sheet can withdraw
        // it. This failed against the sheet-publishes-itself version and passes against the nav window's.
        dismissPreviewSheet()
        XCTAssertFalse(documentMenuItem("Fit Page").isEnabled,
                       "DISABLED again once the sheet is dismissed — the model must not outlive its sheet")
        closeMenu()

        // (3) Pixels, on a freshly re-opened sheet (which also re-proves 1b survives a second presentation).
        openPreviewSheet()

        // The sheet opens at fit-full-page (PDFPaneController(persists: false)), so shot 1 is both the
        // *preview default zoom* evidence and the reference the third shot has to come back to.
        captureScreenshot("w26previewzoom-1-default-fit")

        let zoomStart = Date()
        for _ in 0..<3 { app.typeKey(.upArrow, modifierFlags: .command) }   // ⌘↑ zoom in the image pane
        print("[timing] ⌘↑×3 took \(String(format: "%.1f", -zoomStart.timeIntervalSinceNow)) s")
        settle(1)
        captureScreenshot("w26previewzoom-2-zoomed-in")

        let fitStart = Date()
        app.typeKey("0", modifierFlags: .command)                          // ⌘0 fit page
        print("[timing] ⌘0 took \(String(format: "%.1f", -fitStart.timeIntervalSinceNow)) s")
        settle(1)
        captureScreenshot("w26previewzoom-3-after-cmd0")

        dismissPreviewSheet()
    }

    /// Open the preview sheet from the navigation toolbar (more robust than Space, which is focus-scoped)
    /// and wait for it to be on screen.
    private func openPreviewSheet() {
        toolbarButton("ar.toolbar.preview").click()
        XCTAssertTrue(app.buttons["ar.preview.done"].waitForExistence(timeout: 5),
                      "the preview sheet should open")
        settle(1)
    }

    /// Dismiss the preview sheet and wait for it to be gone — the wait matters, because the assertion that
    /// follows a dismissal is about what the teardown un-publishes.
    private func dismissPreviewSheet() {
        let done = app.buttons["ar.preview.done"]
        if done.exists { done.click() }
        let deadline = Date().addingTimeInterval(5)
        while done.exists, Date() < deadline { settle(0.25) }
        XCTAssertFalse(done.exists, "the preview sheet should close")
        settle(1)
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
