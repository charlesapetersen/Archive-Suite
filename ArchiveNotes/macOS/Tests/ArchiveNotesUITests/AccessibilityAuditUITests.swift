import XCTest

/// W40.e3 — Xcode's accessibility audit (`packages/UITestSupport/Runner/AccessibilityAudit.swift`) over Notes'
/// main screens: the note window with a note open in the editor and inspector, the Extracts window with an extract
/// open, and Settings. One test per appearance, because contrast differs and the appearance is a launch argument.
/// Read-only: nothing here edits the fixture. Findings and their triage:
/// `verification/evidence/core/W40.e3-accessibility-audit.md`.
final class AccessibilityAuditUITests: NotesFixtureUITestCase {

    private var dark = false
    /// Force the mode through the stored Appearance setting rather than `-ArchiveUITestAppearance` (W48.appearance-notes).
    private var bySetting = false
    /// W48.notes-stacked-layout: every screen is audited in both layouts.
    private var layout = Layout.sideBySide
    override var layoutLaunchArguments: [String] { Self.layoutArguments(layout) }
    override var extraLaunchArguments: [String] {
        // Without the editor's two 1×1 test probes: with them Xcode's contrast audit never finishes
        // (`EditorTextView.accessibilityChildren`).
        ["-ANUITestNoEditorProbes", "YES"]
            + (bySetting ? (dark ? LayoutGuard.darkSettingArguments : LayoutGuard.lightSettingArguments)
                : (dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments))
    }

    func testMainScreensPassAuditInLightMode() throws {
        try withFixture { auditMainScreens(appearance: "light") }
    }

    func testMainScreensPassAuditInDarkMode() throws {
        dark = true
        try withFixture { auditMainScreens(appearance: "dark") }
    }

    func testMainScreensPassAuditStackedInLightMode() throws {
        layout = .stacked
        try withFixture { auditMainScreens(appearance: "light-stacked") }
    }

    func testMainScreensPassAuditStackedInDarkMode() throws {
        dark = true
        layout = .stacked
        try withFixture { auditMainScreens(appearance: "dark-stacked") }
    }

    // The same sweeps with the mode coming from the Appearance setting rather than the test argument
    // (W48.appearance-notes; plan rule 7: the existing checks run in the new mode as well as the old).
    func testMainScreensPassAuditInLightModeBySetting() throws {
        bySetting = true
        try withFixture { auditMainScreens(appearance: "light") }
    }

    func testMainScreensPassAuditInDarkModeBySetting() throws {
        bySetting = true
        dark = true
        try withFixture { auditMainScreens(appearance: "dark") }
    }

    private func auditMainScreens(appearance: String) {
        continueAfterFailure = true   // an issue on one screen must not hide the next screen's
        let sweep = AccessibilityAudit(app, appearance: appearance, in: self, known: Self.known, exempt: [harness])
        assertLayout(layout, in: mainWindow)
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
        assertLayout(layout, in: extracts)
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
    // stops reproducing). None open: the last, light-mode secondary text under AA, was fixed by
    // W40.fix-notes-a11y-contrast (informational text is primary).
    @MainActor static let known: [AccessibilityAudit.KnownIssue] = []
}
