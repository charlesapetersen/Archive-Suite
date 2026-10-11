import XCTest

/// W40.e9 — the layout guard (`packages/UITestSupport/LayoutGuard.swift`) over the Processor's main screens: the
/// default Process Files window and the Settings window. Each at its typical and minimum size, on open and once
/// settled; one test per appearance, because the appearance is a launch argument. Scratch IN/OUT only, as in
/// `ProcessorUITests`; nothing here processes a file.
@MainActor
final class LayoutGuardUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!

    override func setUp() async throws {
        continueAfterFailure = true   // a layout failure on one screen must not hide the next screen's
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-layout-\(UUID().uuidString)", isDirectory: true)
        for sub in ["IN", "OUT"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testLayoutGuardCatchesPlantedDefects() {
        LayoutGuardSelfTest.run()
    }

    func testMainScreensLayOutInLightMode() throws {
        try sweepMainScreens(appearance: "light", extra: LayoutGuard.lightModeArguments)
    }

    func testMainScreensLayOutInDarkMode() throws {
        try sweepMainScreens(appearance: "dark", extra: LayoutGuard.darkModeArguments)
    }

    private func sweepMainScreens(appearance: String, extra: [String]) throws {
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
        LayoutGuard.sweep(main, screen: "process files, \(appearance)", in: self)

        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "ap.settings.guidedKeySetup").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Settings should open")
        // The Settings scene is fixed-size: in the VM it would neither shrink nor grow (2026-10-11).
        LayoutGuard.sweep(settings, screen: "settings, \(appearance)", in: self, resize: false)
    }
}
