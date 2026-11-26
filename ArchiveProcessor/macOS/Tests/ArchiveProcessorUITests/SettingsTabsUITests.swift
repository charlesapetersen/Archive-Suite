import XCTest

/// W49.proc-settings-redesign-core — the Settings window as five tabs in the standard toolbar, in the design's order
/// (`execution-plans/processor-settings-redesign.md` §5, Option B). Each tab is shown by its toolbar button, holds the
/// controls the design gives it at one window size, and is photographed in light and dark for a reader to check by eye
/// (`[shot]` lines, collected by `vm-gui-runner.sh`). A collection's own setting is written to that collection only, an
/// Advanced setting in use is named on Processing, and a preset fills the reader. Scratch IN/OUT only.
@MainActor
final class SettingsTabsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!

    override func setUp() async throws {
        continueAfterFailure = true
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-settings-tabs-\(UUID().uuidString)", isDirectory: true)
        for sub in ["IN", "OUT"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        app = .archiveProcessorUITestApp()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", scratchRoot.appendingPathComponent("IN").path,
            "-APUITestOutputDirectory", scratchRoot.appendingPathComponent("OUT").path,
            "-offerExperimentalRoutes", "NO",
        ])
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    private func launch(_ extra: [String] = []) -> XCUIElement? {
        app.launchArguments += extra
        app.launch()
        app.activate()
        guard app.windows.firstMatch.waitForExistence(timeout: 10) else {
            print("PROCESSOR_UI_NO_WINDOW")   // the gate's VM/keychain-launch marker (see ProcessorUITests)
            XCTFail("the main Archive Processor window should appear within 10 seconds")
            return nil
        }
        let settings = app.showSettingsWindow()
        XCTAssertTrue(settings.exists, "Settings must come up on ⌘,")
        return settings
    }

    /// The controls each tab must hold, by identifier.
    private static let marks: [String: [String]] = [
        "Processing": ["ap.settings.scope", "ap.settings.preset.fastFree", "ap.settings.readerPicker",
                       "ap.settings.taggingMode", "ap.segmentation.picker", "ap.settings.numericDates",
                       "ap.settings.batchMode", "ap.settings.costPane", "ap.settings.compareRoutes"],
        "Output": ["ap.settings.pdfFormat", "ap.settings.pdfImageSize", "ap.settings.rotationMode",
                   "ap.settings.vocabulary.summary"],
        "Capture": ["ap.settings.liveProcessingMode", "ap.settings.readContainerLabels", "ap.settings.driveRelay"],
        "Accounts": ["ap.settings.localModels", "ap.settings.localAgentToolPicker", "ap.settings.guidedKeySetup"],
        "Advanced": ["ap.settings.offerExperimental", "ap.settings.postCorrection", "ap.settings.cascadeRoute",
                     "ap.sheet.forms.format", "ap.settings.advanced.resetAll"],
    ]

    func testFiveTabsInTheDesignsOrderEachWithItsControls() throws {
        try tour(appearance: "light")
    }

    func testFiveTabsInDarkMode() throws {
        try tour(appearance: "dark")
    }

    private func tour(appearance: String) throws {
        guard let settings = launch(["-archiveAppearance", appearance]) else { return }
        let buttons = XCUIApplication.settingsPanels.map { app.settingsPanelButton($0) }
        for (title, button) in zip(XCUIApplication.settingsPanels, buttons) {
            XCTAssertTrue(button.waitForExistence(timeout: 5), "the toolbar must hold the \(title) tab")
        }
        let xs = buttons.filter(\.exists).map(\.frame.minX)
        XCTAssertEqual(xs.count, 5, "five tabs")
        XCTAssertEqual(xs, xs.sorted(), "the tabs must sit in the design's order")

        var sizes: Set<String> = []
        for title in XCUIApplication.settingsPanels {
            XCTAssertTrue(app.showSettingsPanel(title), "the \(title) tab must be shown by its toolbar button")
            for id in Self.marks[title] ?? [] {
                XCTAssertTrue(settings.descendants(matching: .any)[id].firstMatch.waitForExistence(timeout: 5),
                              "\(title) must hold \(id)")
            }
            LayoutGuard.waitUntilSettled(settings)
            sizes.insert("\(Int(settings.frame.width))x\(Int(settings.frame.height))")
            shoot(settings, "settings-tab-\(XCUIApplication.settingsPanelID(title))-\(appearance)")
            settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -2000)
            shoot(settings, "settings-tab-\(XCUIApplication.settingsPanelID(title))-\(appearance)-end")
        }
        XCTAssertEqual(sizes.count, 1, "every tab keeps one window size: \(sizes.sorted())")
        // No retired panel and no split between what the window shows and what Process Files runs.
        for gone in ["General", "Collection", "Reading", "Documents", "Pages and output"] {
            XCTAssertFalse(app.settingsPanelButton(gone).exists, "the retired \(gone) panel must be gone")
        }
        XCTAssertFalse(settings.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                                                 "Not switched on yet", "Not switched on yet")).firstMatch.exists)
    }

    /// A collection's own value is written to its folder only, shows its source and Reset, and the general
    /// defaults keep theirs (§3, "Per-collection scope actually works").
    func testCollectionScopeWritesOnlyThatCollection() throws {
        guard let settings = launch() else { return }
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        let dayFirst = settings.radioButtons["DD/MM (International)"].firstMatch
        XCTAssertTrue(dayFirst.waitForExistence(timeout: 5), settings.debugDescription)
        for _ in 0..<15 where !dayFirst.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -150) }
        dayFirst.click()
        let file = scratchRoot.appendingPathComponent("OUT/.archivesuite/collection-settings.json")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("numericDatesDayFirst")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 5), .completed, "the collection's file holds the choice")
        let source = settings.staticTexts["ap.settings.source.numericDatesDayFirst"].firstMatch
        let wording = (source.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? source.label
        XCTAssertTrue(wording.contains("Set for this collection"), wording)
        let reset = settings.buttons["ap.settings.reset.numericDatesDayFirst"].firstMatch
        XCTAssertTrue(reset.exists, "a collection's own value offers Reset")
        shoot(settings, "settings-collection-scope-dd-mm")

        // The general defaults are untouched.
        let scope = settings.descendants(matching: .any)["ap.settings.scope"].firstMatch
        for _ in 0..<15 where !scope.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 300) }
        scope.click()
        app.menuItems["General defaults"].firstMatch.click()
        let monthFirst = settings.radioButtons["MM/DD (US)"].firstMatch
        for _ in 0..<15 where !monthFirst.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -150) }
        XCTAssertEqual(monthFirst.value.map { String(describing: $0) }, "1", "the general default stays month first")
        shoot(settings, "settings-general-scope-mm-dd")

        // Back on the collection, Reset returns it to the inherited value.
        for _ in 0..<15 where !scope.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 300) }
        scope.click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Collection: ")).firstMatch.click()
        for _ in 0..<15 where !reset.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -150) }
        reset.click()
        XCTAssertTrue(waitUntil { !reset.exists }, "Reset clears the collection's own value")
        XCTAssertEqual(monthFirst.value.map { String(describing: $0) }, "1", "the collection inherits month first again")
    }

    /// An Advanced setting in use is named on Processing, with View and Reset (§5.5).
    func testAdvancedSettingInUseIsNamedOnProcessing() throws {
        guard let settings = launch() else { return }
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        let banner = settings.descendants(matching: .any)["ap.settings.advancedInUse"].firstMatch
        XCTAssertFalse(banner.exists, "nothing Advanced is in use at the start")
        XCTAssertTrue(app.showSettingsPanel("Advanced"))
        let log = settings.descendants(matching: .any)["ap.settings.logFile"].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        for _ in 0..<20 where !log.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        log.click()
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "a log file switched on is named on Processing")
        shoot(settings, "settings-advanced-in-use")
        settings.buttons["ap.settings.advancedInUse.view"].firstMatch.click()
        XCTAssertTrue(settings.descendants(matching: .any)["ap.settings.panel.advanced"].firstMatch.waitForExistence(timeout: 5),
                      "View opens the Advanced tab")
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        settings.buttons["ap.settings.advancedInUse.reset"].firstMatch.click()
        let confirm = app.descendants(matching: .button).matching(NSPredicate(format: "label == %@", "Reset")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Reset asks first")
        confirm.click()
        XCTAssertTrue(waitUntil { !banner.exists }, "Reset puts the Advanced setting back")
    }

    /// A preset fills the reader, and the rows below follow it.
    func testFastAndFreePresetChoosesAppleVision() throws {
        // No launch arguments for the reader's flags: an argument outranks what the preset writes.
        guard let settings = launch() else { return }
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        let fast = settings.buttons["ap.settings.preset.fastFree"].firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 5))
        fast.click()
        let reader = settings.descendants(matching: .any)["ap.settings.readerPicker"].firstMatch
        XCTAssertTrue(waitUntil { self.text(of: reader).contains("Apple Vision") }, text(of: reader))
        let batch = settings.descendants(matching: .any)["ap.settings.batchModeUnavailable"].firstMatch
        XCTAssertTrue(batch.waitForExistence(timeout: 5) && text(of: batch).contains("Apple Vision"))
        shoot(settings, "settings-preset-fast-free")
        settings.buttons["ap.settings.preset.cloud"].firstMatch.click()
        XCTAssertTrue(waitUntil { self.text(of: reader).contains(" · ") }, "Cloud chooses a provider's model: \(text(of: reader))")
    }

    func testSearchablePlacementCanBeSetForOneInputFormat() throws {
        guard let settings = launch() else { return }
        XCTAssertTrue(app.showSettingsPanel("Advanced"))
        let picker = settings.descendants(matching: .any)["ap.sheet.forms.format"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        for _ in 0..<20 where !picker.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180) }
        picker.click()
        app.menuItems["JPEG"].click()
        let printed = settings.descendants(matching: .any)["ap.sheet.forms.printed"].firstMatch
        guard printed.waitForExistence(timeout: 5) else { return XCTFail(settings.debugDescription) }
        let scroll = settings.scrollViews.firstMatch
        for _ in 0..<12 where !(printed.isHittable && scroll.frame.insetBy(dx: 0, dy: 20).contains(printed.frame)) {
            scroll.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "0")
        printed.click()
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "1")
        shoot(settings, "settings-placement-jpeg")
        picker.click()
        app.menuItems["PNG"].click()
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "0")
        picker.click()
        app.menuItems["JPEG"].click()
        XCTAssertEqual(printed.value.map { String(describing: $0) }, "1")
    }

    /// Owner, 2026-11-24 (W49.proc-pipeline-prune-ok 6): on a direct Gemini key the agreement rule's disagreements ask
    /// the run's own OCR model, so the tab says so and no longer says the page is left as it is.
    func testDirectKeyRotationAsksTheOCRModel() throws {
        guard let settings = launch(["-selectedProvider", "Gemini", "-useAppleVision", "NO", "-useGateway", "NO",
                                     "-useLocalAgent", "NO", "-preOCRedInput", "NO", "-rotationModeRaw", "agreement"])
        else { return }
        XCTAssertTrue(app.showSettingsPanel("Output"))
        let note = settings.staticTexts["ap.settings.ocrModelRotation"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: note).contains("ask your OCR model"), text(of: note))
        XCTAssertFalse(settings.staticTexts["ap.settings.rotationUnsure"].exists)
        XCTAssertFalse(settings.staticTexts["ap.settings.openRouterRotation"].exists)
        shoot(settings, "settings-direct-key-rotation")
    }

    func testOpenRouterRotationExplainsCloudCallsAndKeepsBatchUnavailable() throws {
        guard let settings = launch(["-selectedProvider", "OpenRouter", "-useAppleVision", "NO", "-useGateway", "NO",
                                     "-useLocalAgent", "NO", "-preOCRedInput", "NO", "-rotationModeRaw", "agreement"])
        else { return }
        XCTAssertTrue(app.showSettingsPanel("Output"))
        let rotation = settings.staticTexts["ap.settings.openRouterRotation"]
        XCTAssertTrue(rotation.waitForExistence(timeout: 5))
        XCTAssertTrue(text(of: rotation).contains("Gemini 3.7 Flash through OpenRouter"), text(of: rotation))
        XCTAssertTrue(text(of: rotation).contains("estimate includes these calls"), text(of: rotation))
        XCTAssertFalse(settings.staticTexts["ap.settings.rotationUnsure"].exists)
        shoot(settings, "settings-openrouter-rotation")
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        let batch = settings.descendants(matching: .any)["ap.settings.batchMode"].firstMatch
        for _ in 0..<12 where !batch.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        XCTAssertTrue(batch.exists)
        XCTAssertFalse(batch.isEnabled)
    }

    private func text(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
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
