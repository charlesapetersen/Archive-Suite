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

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "ap.settings.guidedKeySetup").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        LayoutGuard.waitUntilSettled(settings)
        sweep.audit(settings, screen: "settings")
        sweep.finish()
    }

    // Filed 2026-10-16 from the first VM runs; each fix's session deletes its entry (the audit fails once it
    // stops reproducing). None open: the last, tertiary explanation lines and the drop zone's text under AA,
    // was fixed by W40.fix-processor-a11y-contrast (informational text is primary).
    static let known: [AccessibilityAudit.KnownIssue] = []
}
