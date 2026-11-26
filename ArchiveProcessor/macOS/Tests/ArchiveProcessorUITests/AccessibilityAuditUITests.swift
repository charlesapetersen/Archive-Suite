import XCTest

/// W40.e3 — Xcode's accessibility audit (`packages/UITestSupport/Runner/AccessibilityAudit.swift`) over the
/// Processor's main screens: the default Process Files window and the Settings window. One test per appearance,
/// because contrast differs and the appearance is a launch argument. Scratch IN/OUT only, as in
/// `ProcessorUITests`; nothing here processes a file. Findings and their triage:
/// `verification/evidence/core/W40.e3-accessibility-audit.md`.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!

    override func setUp() async throws {
        continueAfterFailure = true   // an issue on one screen must not hide the next screen's
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-a11y-\(UUID().uuidString)", isDirectory: true)
        for sub in ["IN", "OUT"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testMainScreensPassAuditInLightMode() throws {
        try auditMainScreens(appearance: "light", extra: LayoutGuard.lightModeArguments)
    }

    func testMainScreensPassAuditInDarkMode() throws {
        try auditMainScreens(appearance: "dark", extra: LayoutGuard.darkModeArguments)
    }

    // The same sweeps with the mode coming from the Appearance setting rather than the test argument
    // (W48.appearance-processor; plan rule 7: the existing checks run in the new mode as well as the old).
    func testMainScreensPassAuditInLightModeBySetting() throws {
        try auditMainScreens(appearance: "light", extra: LayoutGuard.lightSettingArguments)
    }

    func testMainScreensPassAuditInDarkModeBySetting() throws {
        try auditMainScreens(appearance: "dark", extra: LayoutGuard.darkSettingArguments)
    }

    private func auditMainScreens(appearance: String, extra: [String]) throws {
        app = .archiveProcessorUITestApp()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", scratchRoot.appendingPathComponent("IN").path,
            "-APUITestOutputDirectory", scratchRoot.appendingPathComponent("OUT").path,
            "-keyValidated_Gemini", "YES",  // show the badge without saving a key or contacting a provider
        ] + extra)
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launch()
        app.activate()

        let main = app.windows.containing(.any, identifier: "ap.ocr.dropZone").firstMatch
        guard main.waitForExistence(timeout: 10) else {
            print("PROCESSOR_UI_NO_WINDOW")   // the gate's VM/keychain-launch marker (see ProcessorUITests)
            XCTFail("the Process Files window should appear within 10 seconds"); return
        }
        let sweep = AccessibilityAudit(app, appearance: appearance, in: self, known: Self.known)
        LayoutGuard.waitUntilSettled(main)
        sweep.audit(main, screen: "process files")

        let settings = app.showSettingsWindow()
        XCTAssertTrue(settings.exists, "Settings should come up")
        // Every panel (W47.settings-panels). Each is a `.grouped` Form, many with TextFields: on macOS 27 each sweep
        // reports SwiftUI's unnamed parent/child orphan there (W40.vm-macos27-processor; the probe is on the exemption).
        for panel in XCUIApplication.settingsPanels {
            XCTAssertTrue(app.showSettingsPanel(panel), "Settings should have a \(panel) panel")
            LayoutGuard.waitUntilSettled(settings)
            if panel == "Accounts" { try checkValidatedBadge(in: settings, appearance: appearance) }
            sweep.audit(settings, screen: "settings, \(panel)", exempt: [AccessibilityAudit.groupedFormTextFieldOrphan])
        }
        try auditAdvisor(settings, sweep: sweep, appearance: appearance)
        sweep.finish()
    }

    /// The Advisor sheet (W49.proc-settings-advisor-advanced), both its tabs, from Settings › Processing.
    private func auditAdvisor(_ settings: XCUIElement, sweep: AccessibilityAudit, appearance: String) throws {
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        let compare = settings.descendants(matching: .any)["ap.settings.compareRoutes"].firstMatch
        XCTAssertTrue(compare.waitForExistence(timeout: 5), "Processing should offer Compare routes & trade-offs")
        guard compare.exists else { return }
        compare.click()
        let advisor = app.sheets.firstMatch
        XCTAssertTrue(advisor.descendants(matching: .any)["ap.advisor.stage.reading"].waitForExistence(timeout: 15),
                      "the Advisor should appear with its stage rows")
        guard advisor.exists else { return }
        for tab in ["Advisor", "Range"] {
            let button = advisor.radioButtons[tab]
            if button.exists { button.click() }
            LayoutGuard.waitUntilSettled(advisor)
            sweep.audit(advisor, screen: "advisor, \(tab)", exempt: [AccessibilityAudit.groupedFormTextFieldOrphan])
            let shot = scratchRoot.appendingPathComponent("uitest-advisor-\(tab.lowercased())-\(appearance).png")
            try advisor.screenshot().pngRepresentation.write(to: shot)
            print("[shot] advisor-\(tab.lowercased())-\(appearance): wrote \(shot.path)")
        }
        advisor.buttons["ap.advisor.cancel"].click()
        XCTAssertTrue(advisor.waitForNonExistence(timeout: 5), "Cancel should close the Advisor")
    }

    private func checkValidatedBadge(in settings: XCUIElement, appearance: String) throws {
        let badge = settings.staticTexts["Validated"].firstMatch
        // The keys sit below the local models and subscriptions (W49.proc-settings-redesign-core): scroll to them.
        for _ in 0..<12 where !(badge.exists && badge.isHittable) {
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200)
        }
        XCTAssertTrue(badge.exists, "The Accounts audit should include a Validated badge")
        guard badge.exists else { return }

        let pixels = try XCTUnwrap(ScreenPixels(XCUIScreen.main.screenshot()))
        let ratio = try XCTUnwrap(pixels.contrast(under: badge.frame), "The badge must be visible")
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "Validated badge contrast in \(appearance) mode")
        print("[a11y-audit] Validated badge in \(appearance) mode: \(String(format: "%.2f", ratio)):1")

        let shot = scratchRoot.appendingPathComponent("uitest-validated-badge-\(appearance).png")
        try badge.screenshot().pngRepresentation.write(to: shot)
        print("[shot] validated-badge-\(appearance): wrote \(shot.path)")
    }

    // Filed 2026-10-16 from the first VM runs; each fix's session deletes its entry (the audit fails once it
    // stops reproducing). None open: the last, tertiary explanation lines and the drop zone's text under AA,
    // was fixed by W40.fix-processor-a11y-contrast (informational text is primary).
    static let known: [AccessibilityAudit.KnownIssue] = []
}
