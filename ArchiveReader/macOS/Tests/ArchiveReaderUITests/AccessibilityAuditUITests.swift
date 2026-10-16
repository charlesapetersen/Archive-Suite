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
        app.launchArguments += appearance
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
        sweep.audit(main, screen: "navigation window")

        toolbarButton("ar.toolbar.preview").click()
        let open = app.buttons["ar.preview.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), "the preview sheet should open")
        LayoutGuard.waitUntilSettled(main)
        sweep.audit(main, screen: "preview sheet")

        open.click()
        let viewer = app.windows.matching(NSPredicate(format: "title != %@", "Archive Reader")).firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "Open in Viewer should bring up the document window")
        LayoutGuard.waitUntilSettled(viewer)
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

    // Filed 2026-10-16 from the first VM runs; each fix's session deletes its entry (the audit fails once it
    // stops reproducing).
    @MainActor static let known: [AccessibilityAudit.KnownIssue] = [
        AccessibilityAudit.KnownIssue(tag: "W40.fix-reader-a11y-labels") { f in
            switch f.audit {
            case .sufficientElementDescription:
                return ["ar.divider.sidebar", "ar.divider.tagCloud", "ar.filter.tagField", "ar.filter.name",
                        "ar.filter.ocr", "ar.table"].contains(f.identifier)
                    || f.identifier == "text.magnifyingglass"
                    // the flag and OCR-warning cells of a row that has neither: empty text, no label
                    || (f.type == .staticText && f.identifier.isEmpty && f.label.isEmpty && f.frame.width < 40)
                    // the preview's and viewer's PDF page views
                    || (f.type == .other && f.identifier.isEmpty && f.label.isEmpty && f.frame.width > 300)
            case .elementDetection:
                return f.identifier == "text.magnifyingglass"
            default:
                return false
            }
        },
        // Measured failures are all light-mode secondary text (3.45–4.32:1) and the orange ⚠ (2.11:1).
        AccessibilityAudit.KnownIssue(tag: "W40.fix-reader-a11y-contrast", appearances: ["light"]) { f in
            guard f.audit == .contrast, f.type == .staticText else { return false }
            return ["ar.sidebar.allFiles", "ar.tagCloud"].contains(f.identifier)   // the counts beside them
                || f.label == "⚠"                                                    // a row's OCR warning
                || f.label.range(of: #"^\d+ of \d+$"#, options: .regularExpression) != nil   // page counter
                || f.label.contains(" shown · ") || f.label.hasSuffix(" selected")  // status bar
        },
    ]
}
