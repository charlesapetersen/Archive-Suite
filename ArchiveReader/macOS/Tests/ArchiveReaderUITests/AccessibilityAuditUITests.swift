import XCTest

/// W40.e3 — Xcode's accessibility audit (`packages/UITestSupport/Runner/AccessibilityAudit.swift`) over the
/// Reader's main screens: the navigation window with a document selected, the preview sheet, the document viewer
/// window, and Settings. One test per appearance, because contrast differs and the appearance is a launch argument.
/// Read-only: nothing here edits the fixture. Findings and their triage:
/// `verification/evidence/core/W40.e3-accessibility-audit.md`.
final class AccessibilityAuditUITests: FixtureUITestCase {

    func testMainScreensPassAuditInLightMode() throws {
        relaunch(LayoutGuard.lightModeArguments)
        auditMainScreens(appearance: "light")
    }

    func testMainScreensPassAuditInDarkMode() throws {
        relaunch(LayoutGuard.darkModeArguments)
        auditMainScreens(appearance: "dark")
    }

    /// `FixtureUITestCase.setUp` has already launched with the fixture; relaunch with the appearance added.
    private func relaunch(_ appearance: [String]) {
        app.terminate()
        app.launchArguments += appearance + ["-ar.showSidebar", "YES", "-ar.showTagCloud", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(table.waitForExistence(timeout: 10), "Table should appear after the relaunch")
        waitForRows(minimum: 1, timeout: 15)
    }

    private func auditMainScreens(appearance: String) {
        continueAfterFailure = true   // an issue on one screen must not hide the next screen's
        let sweep = AccessibilityAudit(app, appearance: appearance, in: self,
                                       known: Self.known)
        let main = app.windows["Archive Reader"]
        waitForRows(minimum: 3, timeout: 10)
        clickRow(0)
        LayoutGuard.waitUntilSettled(main)
        for (id, name) in [("ar.filter.tagField", "Filter by tags"), ("ar.filter.name", "Filter file name"),
                           ("ar.filter.ocr", "Search OCR text"), ("ar.table", "Archive files")] {
            XCTAssertEqual(main.descendants(matching: .any).matching(identifier: id).firstMatch.label, name)
        }
        for (id, name) in [("ar.divider.sidebar", "Sidebar width"), ("ar.divider.tagCloud", "Tags in view width")] {
            let splitter = main.splitters[id]
            XCTAssertTrue(splitter.exists, "\(id) should expose the native splitter role")
            XCTAssertEqual(splitter.label, name)
            XCTAssertGreaterThan(splitter.frame.height, 300, "the splitter must fill its panel's height")
        }
        // The native accessibility handle must still support the original pointer resize gesture.
        for id in ["ar.divider.sidebar", "ar.divider.tagCloud"] {
            let splitter = main.splitters[id]
            let before = splitter.frame.midX
            splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: 20, dy: 0)))
            LayoutGuard.waitUntilSettled(main)
            XCTAssertGreaterThan(splitter.frame.midX, before + 10, "\(id) should move with a pointer drag")
            splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: splitter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .withOffset(CGVector(dx: -20, dy: 0)))
            LayoutGuard.waitUntilSettled(main)
            XCTAssertEqual(splitter.frame.midX, before, accuracy: 2)
        }
        sweep.audit(main, screen: "navigation window")

        toolbarButton("ar.toolbar.preview").click()
        let open = app.buttons["ar.preview.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the preview sheet should open")
        LayoutGuard.waitUntilSettled(main)
        let sheet = main.sheets.firstMatch
        XCTAssertTrue(sheet.exists, "the preview should expose its sheet container")
        assertPageTitles(in: sheet)
        sweep.audit(sheet, screen: "preview sheet")

        open.click()
        let viewer = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "Open in Viewer should bring up the document window")
        LayoutGuard.waitUntilSettled(viewer)
        assertPageTitles(in: viewer)
        sweep.audit(viewer, screen: "document viewer")
        viewer.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(viewer.waitForNonExistence(timeout: 5), "the viewer should close")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        LayoutGuard.waitUntilSettled(settings)
        sweep.audit(settings, screen: "settings")
        sweep.finish()
    }

    private func assertPageTitles(in container: XCUIElement) {
        for title in ["Original image page", "OCR text page"] {
            XCTAssertTrue(container.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", title)).firstMatch.exists,
                          "the PDF page must have a name in the external accessibility tree: \(title)")
        }
    }

    // Filed 2026-10-16 from the first VM runs; each fix's session deletes its entry (the audit fails once it
    // stops reproducing).
    @MainActor static let known: [AccessibilityAudit.KnownIssue] = [
        // Original light-mode secondary text/orange warnings, plus Type/Read cells confirmed in both
        // appearances by this item's VM recheck (evidence: reader/W40.fix-reader-a11y-labels.md).
        AccessibilityAudit.KnownIssue(tag: "W40.fix-reader-a11y-contrast") { f in
            guard f.audit == .contrast, f.type == .staticText else { return false }
            return ["ar.sidebar.allFiles", "ar.sidebar.folder", "ar.tagCloud"].contains(f.identifier)   // the counts beside them
                || f.identifier.hasPrefix("ar.cell.warning.")                        // a row's OCR warning
                || f.identifier.hasPrefix("ar.cell.type.") || f.identifier.hasPrefix("ar.cell.read.")
                || f.label.range(of: #"^\d+ of \d+$"#, options: .regularExpression) != nil   // page counter
                || f.label.contains(" shown · ") || f.label.hasSuffix(" selected")  // status bar
        },
    ]
}
