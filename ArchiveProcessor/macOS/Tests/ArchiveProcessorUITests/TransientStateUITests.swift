import XCTest

/// W40.e13 — transient states between two settled screens (`packages/UITestSupport/Runner/TransientCheck.swift`).
/// The app's DEBUG recorder samples the watched sections after every committed run-loop pass; each transition here
/// must take them from the old settled state to the new one without showing anything else on the way. Like the
/// rest of this suite it runs on an unguessable scratch IN/OUT pair with `ARCHIVEPROC_HEADLESS=1`: no OCR, no
/// network, no Keychain.
@MainActor
final class TransientStateUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!

    /// Process Files (its panels and the segmentation row), Settings and the key wizard, plus every sheet.
    static let sections = ["ap.ocr", "ap.segmentation", "ap.settings", "ap.keyWizard", TransientCheck.sheets]

    override func setUp() async throws {
        continueAfterFailure = true   // one flickering transition must not hide the next one's
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-transient-\(UUID().uuidString)", isDirectory: true)
        for sub in ["IN", "OUT"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testTransientAnalysisCatchesPlantedFlickers() {
        TransientCheckSelfTest.run()
    }

    func testCommonTransitionsShowNoTransientState() throws {
        guard launch(plant: false) else { return }
        startFromManualSegmentation()
        TransientCheck.check("segmentation: Gemini only", in: app, test: self) { chooseSegmentation("Gemini only") }
        TransientCheck.check("segmentation: ChatGPT only", in: app, test: self) { chooseSegmentation("ChatGPT only") }
        TransientCheck.check("segmentation: Full manual", in: app, test: self) { chooseSegmentation("Full manual") }
        TransientCheck.check("open Settings", in: app, test: self) {
            app.typeKey(",", modifierFlags: .command)
        }
        TransientCheck.check("open the guided key setup", in: app, test: self) {
            let guided = element("ap.settings.guidedKeySetup")
            XCTAssertTrue(guided.waitForExistence(timeout: 10), "Settings must expose the guided key setup")
            guided.click()
        }
        TransientCheck.check("close the guided key setup", in: app, test: self) {
            app.typeKey(.escape, modifierFlags: [])
        }
        TransientCheck.check("close Settings", in: app, test: self) {
            app.typeKey("w", modifierFlags: .command)
        }
    }

    /// The recorder must fail on a real flicker before its passes are trusted: with `-ArchiveTransientPlant
    /// blink` the app hides its window's content for one pass during each transition, and that must be reported.
    func testRecorderCatchesAPlantedFlicker() throws {
        guard launch(plant: true) else { return }
        startFromManualSegmentation()
        let findings = TransientCheck.check("segmentation, planted flicker", in: app, test: self,
                                            expectFindings: true) { chooseSegmentation("Gemini only") }
        XCTAssertTrue(findings.contains { $0.contains(" removed: ") },
                      "the planted blink should be reported as a section leaving and coming back: \(findings)")
    }

    private func launch(plant: Bool) -> Bool {
        app = .archiveProcessorUITestApp()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", scratchRoot.appendingPathComponent("IN").path,
            "-APUITestOutputDirectory", scratchRoot.appendingPathComponent("OUT").path,
        ] + TransientCheck.launchArguments(sections: Self.sections, plant: plant))
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launch()
        app.activate()
        guard app.windows.containing(.any, identifier: "ap.ocr.dropZone").firstMatch.waitForExistence(timeout: 10) else {
            print("PROCESSOR_UI_NO_WINDOW")   // the gate's VM/keychain-launch marker (see ProcessorUITests)
            XCTFail("the Process Files window should appear within 10 seconds")
            return false
        }
        return true
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// The chooser's choice persists in the app's defaults from one launch to the next (another test, or this one's
    /// last run, can leave "Gemini only" chosen, and choosing it again changes nothing). Choose Full manual first,
    /// outside any check, so each checked choice after it is a real change.
    private func startFromManualSegmentation() {
        chooseSegmentation("Full manual")
    }

    /// The segmentation chooser is a pop-up menu: open it and pick the item whose title starts with `label`.
    private func chooseSegmentation(_ label: String) {
        let picker = element("ap.segmentation.picker")
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "Process Files must show the Segmentation chooser")
        picker.click()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", label)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the chooser must offer \(label)")
        item.click()
    }
}
