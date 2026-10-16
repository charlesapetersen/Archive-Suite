import XCTest

/// W40.e3 — Xcode's accessibility audit (`packages/UITestSupport/Runner/AccessibilityAudit.swift`) over Notes'
/// main screens: the note window with a note open in the editor and inspector, the Extracts window with an extract
/// open, and Settings. One test per appearance, because contrast differs and the appearance is a launch argument.
/// Read-only: nothing here edits the fixture. Findings and their triage:
/// `verification/evidence/core/W40.e3-accessibility-audit.md`.
final class AccessibilityAuditUITests: NotesFixtureUITestCase {

    private var dark = false
    override var extraLaunchArguments: [String] {
        // Without the editor's two 1×1 test probes: with them Xcode's contrast audit never finishes
        // (`EditorTextView.accessibilityChildren`).
        ["-ANUITestNoEditorProbes", "YES"]
            + (dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments)
    }

    func testMainScreensPassAuditInLightMode() throws {
        try withFixture { auditMainScreens(appearance: "light") }
    }

    func testMainScreensPassAuditInDarkMode() throws {
        dark = true
        try withFixture { auditMainScreens(appearance: "dark") }
    }

    private func auditMainScreens(appearance: String) {
        continueAfterFailure = true   // an issue on one screen must not hide the next screen's
        let sweep = AccessibilityAudit(app, appearance: appearance, in: self, known: Self.known, exempt: [harness])
        open(Self.idPlain, in: mainWindow)
        LayoutGuard.waitUntilSettled(mainWindow)
        sweep.audit(mainWindow, screen: "note window")

        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu should exist")
        windowMenu.click()
        let item = app.menuItems["Extracts"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Window ▸ Extracts should be offered")
        item.click()
        let extracts = app.windows["Extracts"]
        XCTAssertTrue(extracts.waitForExistence(timeout: 15), "the Extracts window should be open")
        open(Self.idExtract, in: extracts)
        LayoutGuard.waitUntilSettled(extracts)
        sweep.audit(extracts, screen: "extracts window")
        extracts.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(extracts.waitForNonExistence(timeout: 5), "the Extracts window should close")

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.matching(NSPredicate(format: "title != %@ AND title != %@",
                                                        "Archive Notes", "Extracts")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        LayoutGuard.waitUntilSettled(settings)
        sweep.audit(settings, screen: "settings")
        sweep.finish()
    }

    /// UI-test-only harness elements (added only under the UITest launch arguments): the 1-line status probes
    /// drawn behind the panes, and the editor's test-button strip. Not the product.
    private let harness = AccessibilityAudit.Exemption(reason: "UI-test harness element, not shipped") {
        $0.identifier.hasPrefix("an.status.") || $0.identifier.hasPrefix("an.editor.test.")
    }

    private func open(_ id: String, in window: XCUIElement) {
        let title = window.descendants(matching: .any)["an.cell.title.\(id)"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "the seeded row \(id) should be listed")
        title.click()
    }

    // Filed 2026-10-16 from the first VM runs; each fix's session deletes its entry (the audit fails once it
    // stops reproducing).
    @MainActor static let known: [AccessibilityAudit.KnownIssue] = [
        AccessibilityAudit.KnownIssue(tag: "W40.fix-notes-a11y-labels") { f in
            switch f.audit {
            case .sufficientElementDescription:
                return f.identifier.hasPrefix("an.divider.")              // the two pane dividers
                    || ["an.filter.search", "an.filter.tagInput", "an.filter.dateFrom", "an.filter.dateTo",
                        "an.list.table", "an.detail.authors", "an.detail.date.year"].contains(f.identifier)
                    || (f.identifier.hasPrefix("an.cell.instances.") && f.label.isEmpty)   // a row with none
                    || (f.identifier == "an.detail.header" && f.type == .image)          // the extract's quote mark
            default:
                return false
            }
        },
        // Measured failures are all light-mode secondary text: 3.95–4.21:1, and the date range's "–" 3.23:1.
        AccessibilityAudit.KnownIssue(tag: "W40.fix-notes-a11y-contrast", appearances: ["light"]) { f in
            guard f.audit == .contrast, f.type == .staticText else { return false }
            return ["an.sidebar.", "an.filter.count", "an.cell.instances.", "an.detail."]
                .contains { f.identifier.hasPrefix($0) }
                || f.label == "–" || f.label.hasSuffix(" note") || f.label.hasSuffix(" notes")
        },
    ]
}
