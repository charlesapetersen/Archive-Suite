import XCTest

// Processor has deliberately no corpus fixture. Every launch below receives an unguessable scratch
// input/output pair, and `ARCHIVEPROC_HEADLESS=1` keeps KeychainHelper from opening, saving, or seeding
// a credential. These are rendering/interaction checks only: none starts OCR or makes a network call.
@MainActor
final class ProcessorUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!
    private var inputDirectory: URL!
    private var outputDirectory: URL!

    // XCTest's synchronous `…WithError` hooks are nonisolated in Swift 6. Async hooks inherit this
    // class's main-actor isolation, so XCUITest state stays warning-free and race-checked.
    override func setUp() async throws {
        continueAfterFailure = false
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-uitest-\(UUID().uuidString)", isDirectory: true)
        inputDirectory = scratchRoot.appendingPathComponent("IN", isDirectory: true)
        outputDirectory = scratchRoot.appendingPathComponent("OUT", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        app = .archiveProcessorUITestApp()
        relaunch()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        // The OS owns this uniquely named temporary root. Leaving it avoids broad cleanup code in a
        // test target and is harmless: macOS removes /tmp contents on its normal schedule.
    }

    func testDefaultProcessFilesShowsScratchDropZoneAndTaggingPanel() throws {
        XCTAssertTrue(element("ap.ocr.dropZone").waitForExistence(timeout: 10),
                      "the default, no-corpus launch must show the Process Files drop zone")
        XCTAssertTrue(element("ap.ocr.taggingPanel").exists,
                      "the Process Files tagging panel needs a stable UI-test identity")
        attachScreenshot("processor-default-drop-zone")
    }

    func testAnthropicGuidedKeySetupShowsConsoleCostPrivacyAndKeyShape() throws {
        openSettings()
        let guidedSetup = element("ap.settings.guidedKeySetup")
        XCTAssertTrue(guidedSetup.waitForExistence(timeout: 10), "Settings must expose the guided key setup")
        guidedSetup.click()

        XCTAssertTrue(element("ap.keyWizard.providerPicker").waitForExistence(timeout: 10),
                      "the reusable provider wizard needs a stable selector")
        let console = element("ap.keyWizard.openConsole")
        XCTAssertTrue(console.exists && console.label.contains("Anthropic"),
                      "Anthropic is the first guided provider and opens its own Console")
        XCTAssertTrue(element("ap.keyWizard.keyField").exists, "the Anthropic key field must be exposed")
        XCTAssertTrue(renderedText(of: element("ap.keyWizard.step.2")).contains("sk-ant-"),
                      "the guide must tell an operator the Anthropic key prefix")
        XCTAssertTrue(renderedText(of: element("ap.keyWizard.costNote")).contains("Pay-as-you-go"),
                      "the guide must state that Anthropic API use has no free tier")
        XCTAssertTrue(renderedText(of: element("ap.keyWizard.privacyNote")).contains("does not use data sent through its API to train"),
                      "the guide must surface the provider privacy note before a key is entered")
        attachScreenshot("processor-anthropic-guided-key")
    }

    func testMultiPageScratchPDFDisablesTaggingAndExplainsAutoReOCR() throws {
        relaunch(extra: ["-APUITestSyntheticMultiPagePDF"])

        let reOCRNote = element("ap.ocr.reOCRExplanation")
        XCTAssertTrue(reOCRNote.waitForExistence(timeout: 10),
                      "a multi-page PDF admitted through the scratch drop route must announce auto re-OCR")
        XCTAssertTrue(renderedText(of: reOCRNote).contains("Not applied to a multi-page PDF"),
                      "the multi-page explanation must describe the automatic re-OCR route")
        let taggingPicker = element("ap.ocr.taggingPicker")
        XCTAssertTrue(taggingPicker.exists && !taggingPicker.isEnabled,
                      "tagging controls must be disabled whenever auto re-OCR owns the document")
        attachScreenshot("processor-multipage-auto-reocr")
    }

    func testLocalAgentSettingsAndFilesShowSubscriptionCostAndGuidedSetup() throws {
        relaunch(extra: ["-APUITestLocalAgent", "-APUITestSyntheticMultiPagePDF"])

        let filesCost = element("ap.ocr.localAgentCost")
        XCTAssertTrue(filesCost.waitForExistence(timeout: 10),
                      "the OCR Files card must never imply a per-page API charge for Local Agent")
        XCTAssertTrue(renderedText(of: filesCost).contains("Included in your subscription — usage limits apply."),
                      "the OCR Files card must state the subscription cost model")
        XCTAssertTrue(renderedText(of: element("ap.ocr.localAgentPacing")).contains("paces and resumes"),
                      "the OCR Files card must explain subscription-window pacing")

        openSettings()
        XCTAssertTrue(element("ap.settings.localAgentToolPicker").waitForExistence(timeout: 10),
                      "the active Local Agent backend must reveal the CLI picker")
        let settingsCost = element("ap.settings.costPane")
        XCTAssertTrue(settingsCost.exists,
                      "the pinned Settings cost pane needs a stable UI-test identity")
        XCTAssertTrue(renderedText(of: settingsCost).contains("Included in your subscription — usage limits apply."),
                      "the pinned Settings pane must use the same no-dollar cost message")
        XCTAssertTrue(renderedText(of: settingsCost).contains("paces automatically, then resumes"),
                      "the pinned Settings pane must describe its subscription pacing")

        let guidedSetup = element("ap.settings.localAgentGuidedSetup")
        XCTAssertTrue(guidedSetup.exists, "Local Agent setup must be reachable without a key or CLI login")
        guidedSetup.click()
        let wizardToolPicker = element("ap.localAgentWizard.toolPicker")
        XCTAssertTrue(wizardToolPicker.waitForExistence(timeout: 10),
                      "the Local Agent wizard must expose its Claude/Gemini selector")
        XCTAssertTrue(wizardToolPicker.label.contains("Claude Code") && wizardToolPicker.label.contains("Gemini CLI"),
                      "the visible segmented wizard selector must offer both Claude Code and Gemini CLI")
        XCTAssertTrue(element("ap.localAgentWizard.install").exists,
                      "the selected Local Agent needs a first-party install link")
        XCTAssertTrue(element("ap.localAgentWizard.docs").exists,
                      "the selected Local Agent needs its setup documentation link")
        XCTAssertTrue(renderedText(of: element("ap.localAgentWizard.entitlementNote")).contains("Claude Code enabled"),
                      "the default guided step must explain Claude's subscription login")
        attachScreenshot("processor-local-agent-cost-and-wizard")
    }

    private func relaunch(extra: [String] = []) {
        app.terminate()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", inputDirectory.path,
            "-APUITestOutputDirectory", outputDirectory.path
        ] + extra)
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launch()
        app.activate()
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            // The gate recognizes this marker as a VM/keychain-launch infrastructure failure, keeps this
            // rendered snapshot, and SKIPs rather than turning an unlock panel into a false product RED.
            attachScreenshot("processor-no-window")
            print("PROCESSOR_UI_NO_WINDOW")
            XCTFail("the main Archive Processor window should appear within 10 seconds")
            return
        }
    }

    private func openSettings() {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// SwiftUI's grouped accessibility elements expose their visible string as `value` on some macOS
    /// releases and as `label` on others. Both are read-only AX snapshots of the rendered control.
    private func renderedText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = scratchRoot.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: path, options: .atomic)
            // `vm-gui-runner.sh` copies this test-runner-owned file through the guest agent. A sandboxed
            // UI-test runner cannot write directly to the host's mounted artifact directory.
            print("[shot] \(name): wrote \(path.path)")
        } catch {
            XCTFail("could not write UI-test screenshot: \(error)")
        }
    }
}

enum UITestLaunch {
    /// Harness arguments are not documents. Without this AppKit treats the scratch-path switches as
    /// open-file requests and starts this `WindowGroup` with no Process Files window at all.
    static let deterministicWindowState = ["-NSTreatUnknownArgumentsAsOpen", "NO"]

    static func arguments(_ extra: [String]) -> [String] {
        deterministicWindowState + extra
    }
}

extension XCUIApplication {
    static func archiveProcessorUITestApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += UITestLaunch.deterministicWindowState
        return app
    }
}
