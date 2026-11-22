import XCTest

/// W47.settings-panels — the Settings window as eight panels in the standard toolbar, in the design's order
/// (`execution-plans/processing-review/settings-design/levels.md` §2). Each panel is shown by its toolbar button, must
/// hold the controls the design gives it, and is photographed once for a reader to check by eye (`[shot]` lines,
/// collected by `vm-gui-runner.sh`). The reading card's "See the range" link brings up the sheet's Range view.
/// Scratch IN/OUT only.
@MainActor
final class SettingsPanelsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!

    override func setUp() async throws {
        continueAfterFailure = true
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-settings-panels-\(UUID().uuidString)", isDirectory: true)
        for sub in ["IN", "OUT"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        app = .archiveProcessorUITestApp()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", scratchRoot.appendingPathComponent("IN").path,
            "-APUITestOutputDirectory", scratchRoot.appendingPathComponent("OUT").path,
        ])
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
        app.launch()
        app.activate()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    /// The controls (and cards) each panel must hold, by identifier.
    private static let marks: [String: [String]] = [
        "General": ["ap.settings.appearance"],
        "Collection": ["ap.sheet.limits", "ap.sheet.totals", "ap.settings.costPane"],
        "Reading": ["ap.sheet.card.reading", "ap.sheet.seeRange.reading", "ap.settings.backendPicker",
                    "ap.sheet.rule.layout"],
        "Documents": ["ap.sheet.card.segmentation", "ap.segmentation.picker"],
        "Dates and names": ["ap.sheet.card.dating", "ap.sheet.card.entities",
                            "ap.sheet.switch.dating.image_every_document"],
        "Pages and output": ["ap.sheet.rule.reading-copy", "ap.sheet.rule.placement", "ap.settings.batchMode"],
        "Capture": ["ap.sheet.rule.capture"],
        "Accounts": ["ap.settings.guidedKeySetup", "ap.settings.localAgentToolPicker", "ap.settings.planSignIn"],
    ]

    func testEightPanelsInTheDesignsOrderEachWithItsControls() throws {
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            print("PROCESSOR_UI_NO_WINDOW")   // the gate's VM/keychain-launch marker (see ProcessorUITests)
            return XCTFail("the main Archive Processor window should appear within 10 seconds")
        }
        let settings = app.showSettingsWindow()
        XCTAssertTrue(settings.exists, "Settings must come up on ⌘,")

        // The toolbar holds the eight panels, left to right in the design's order.
        let buttons = XCUIApplication.settingsPanels.map { app.settingsPanelButton($0) }
        for (title, button) in zip(XCUIApplication.settingsPanels, buttons) {
            XCTAssertTrue(button.waitForExistence(timeout: 5), "the toolbar must hold the \(title) panel")
        }
        let xs = buttons.filter(\.exists).map(\.frame.minX)
        XCTAssertEqual(xs.count, 8, "eight panels")
        XCTAssertEqual(xs, xs.sorted(), "the panels must sit in the design's order")

        for title in XCUIApplication.settingsPanels {
            XCTAssertTrue(app.showSettingsPanel(title), "the \(title) panel must be shown by its toolbar button")
            for id in Self.marks[title] ?? [] {
                XCTAssertTrue(settings.descendants(matching: .any)[id].firstMatch.waitForExistence(timeout: 5),
                              "\(title) must hold \(id)")
            }
            shoot(settings, "settings-panel-" + XCUIApplication.settingsPanelID(title))
        }

        // A card's "See the range" brings up the sheet's Range view.
        app.showSettingsPanel("Reading")
        let seeRange = settings.descendants(matching: .any)["ap.sheet.seeRange.reading"].firstMatch
        XCTAssertTrue(seeRange.waitForExistence(timeout: 5), "the reading card keeps its See the range link")
        for _ in 0..<12 where !seeRange.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        seeRange.click()
        XCTAssertTrue(app.descendants(matching: .any)["ap.sheet.range.reading"].firstMatch.waitForExistence(timeout: 10),
                      "See the range must show the Range view's reading chart")
        shoot(settings, "settings-panel-see-the-range")
    }

    func testSearchablePlacementCanBeSetForOneInputFormat() throws {
        let settings = app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Pages and output"))
        let picker = settings.descendants(matching: .any)["ap.sheet.forms.format"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<8 where !picker.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180) }
        picker.click()
        app.menuItems["JPEG"].click()
        let printed = settings.descendants(matching: .any)["ap.sheet.forms.printed"].firstMatch
        guard printed.waitForExistence(timeout: 5) else { return XCTFail(settings.debugDescription) }
        for _ in 0..<6 where !printed.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -120) }
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "0")
        printed.click()
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "1")
        shoot(settings, "settings-placement-jpeg")

        picker.click()
        app.menuItems["PNG"].click()
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "0")
        picker.click()
        app.menuItems["All formats"].click()
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "0")
        picker.click()
        app.menuItems["JPEG"].click()
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "1")
    }

    func testOpenRouterRotationExplainsCloudCallsAndKeepsBatchUnavailable() {
        app.terminate()
        app.launchArguments += ["-selectedProvider", "OpenRouter", "-useAppleVision", "NO",
                                "-useGateway", "NO", "-useLocalAgent", "NO", "-preOCRedInput", "NO",
                                "-rotationModeRaw", "agreement"]
        app.launch()
        let settings = app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Pages and output"))
        let rotation = settings.staticTexts["ap.settings.openRouterRotation"]
        XCTAssertTrue(rotation.waitForExistence(timeout: 5))
        let wording = (rotation.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rotation.label
        XCTAssertTrue(wording.contains("Gemini 3.7 Flash through OpenRouter"), wording)
        XCTAssertTrue(wording.contains("estimate includes these calls"), wording)
        XCTAssertFalse(settings.staticTexts["ap.settings.rotationUnsure"].exists)
        shoot(settings, "settings-openrouter-rotation")

        let batch = settings.descendants(matching: .any)["ap.settings.batchMode"].firstMatch
        for _ in 0..<12 where !batch.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(batch.exists)
        XCTAssertFalse(batch.isEnabled)
    }

    private func shoot(_ element: XCUIElement, _ name: String) {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = scratchRoot.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: path, options: .atomic)
            // `vm-gui-runner.sh` copies this test-runner-owned file through the guest agent.
            print("[shot] \(name): wrote \(path.path)")
        } catch {
            XCTFail("could not write UI-test screenshot: \(error)")
        }
    }
}
