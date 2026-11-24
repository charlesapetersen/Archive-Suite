import XCTest

/// W47.settings-level-switch — the Settings window at each of its three levels (`execution-plans/processing-review/
/// settings-design/levels.md` §3-4): Basic shows the app's picks, the keys and the few switches a new user needs;
/// Standard adds every choice the bench supports; Advanced adds the advanced controls and their reasons. A value changed from its default is shown at Basic with its level and its Reset. Each level is set by a launch
/// argument (the argument domain), so no run leaves a level behind for the next. Photographed once per level for a
/// reader to check by eye (`[shot]` lines). Scratch IN/OUT only.
@MainActor
final class SettingsLevelsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!

    override func setUp() async throws {
        continueAfterFailure = true
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-settings-levels-\(UUID().uuidString)", isDirectory: true)
        for sub in ["IN", "OUT"] {
            try FileManager.default.createDirectory(at: scratchRoot.appendingPathComponent(sub, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    private func launch(_ extra: [String]) -> XCUIElement? {
        app = .archiveProcessorUITestApp()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", scratchRoot.appendingPathComponent("IN").path,
            "-APUITestOutputDirectory", scratchRoot.appendingPathComponent("OUT").path,
        ] + extra)
        app.launchEnvironment["ARCHIVEPROC_HEADLESS"] = "1"
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

    private func element(_ settings: XCUIElement, _ id: String) -> XCUIElement {
        settings.descendants(matching: .any)[id].firstMatch
    }

    /// Asserts which identifiers a panel shows and which it does not, at the launched level.
    private func expect(_ settings: XCUIElement, panel: String, shown: [String], hidden: [String], level: String) {
        XCTAssertTrue(app.showSettingsPanel(panel), "the \(panel) panel must be shown by its toolbar button")
        for id in shown {
            XCTAssertTrue(element(settings, id).waitForExistence(timeout: 5), "\(panel) at \(level) must show \(id)")
        }
        // The panel has drawn (the shown marks waited for it), so an absent element is absent, not late.
        for id in hidden {
            XCTAssertFalse(element(settings, id).exists, "\(panel) at \(level) must not show \(id)")
        }
    }

    func testGeneralHelpHasBottomSpaceInLightAppearance() {
        checkGeneralHelp(appearance: "light", arguments: LayoutGuard.lightModeArguments)
    }

    func testGeneralHelpHasBottomSpaceInDarkAppearance() {
        checkGeneralHelp(appearance: "dark", arguments: LayoutGuard.darkModeArguments)
    }

    private func checkGeneralHelp(appearance: String, arguments: [String]) {
        for level in ["basic", "standard", "advanced"] {
            guard let settings = launch(["-settingsLevel", level] + arguments) else { return }
            XCTAssertTrue(app.showSettingsPanel("General"))
            let detail = element(settings, "ap.settings.level.detail")
            let form = settings.scrollViews.firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 5))
            XCTAssertTrue(form.exists)
            LayoutGuard.waitUntilSettled(settings)
            // General's panel sets a fixed window size, so this is also its minimum size.
            XCTAssertTrue(form.frame.contains(detail.frame), "\(level) help should be visible without scrolling")
            XCTAssertGreaterThanOrEqual(form.frame.maxY - detail.frame.maxY, 16,
                                        "\(level) help needs room below it in \(appearance) appearance")
            shoot(settings, "general-help-\(level)-\(appearance)")
            app.terminate()
        }
    }

    func testBasicShowsTheAppsPicksAndTheFewSwitchesANewUserNeeds() throws {
        // The guest keeps its defaults between runs, and an approach saved there (by another suite, or the app's
        // preselect) is rightly shown at Basic as a change; pin it to its default so this test sees the level alone.
        guard let settings = launch(["-settingsLevel", "basic", "-segmentationApproach", "manual",
                                     "-visionLanguages", "fr-FR"]) else { return }
        expect(settings, panel: "General", shown: ["ap.settings.appearance", "ap.settings.level", "ap.settings.level.detail"],
               hidden: [], level: "Basic")
        shoot(settings, "settings-level-basic-general")
        expect(settings, panel: "Reading", shown: ["ap.settings.activeReader", "ap.settings.readingDetails", "ap.sheet.seeRange.reading"],
               hidden: ["ap.settings.backendPicker", "ap.settings.providerPicker", "ap.sheet.override.reading", "ap.settings.postCorrection"],
               level: "Basic")
        let reader = element(settings, "ap.settings.activeReader")
        let details = element(settings, "ap.settings.readingDetails")
        XCTAssertLessThan(reader.frame.minY, details.frame.minY)
        XCTAssertEqual(details.value as? String, "collapsed")
        XCTAssertFalse(settings.staticTexts["OCR backend and model"].exists,
                       "A saved setting for an inactive backend should not leave an empty section at Basic")
        shoot(settings, "settings-level-basic-reading")
        details.click()
        XCTAssertEqual(details.value as? String, "expanded")
        XCTAssertTrue(settings.staticTexts["What a better figure would need"].waitForExistence(timeout: 5))
        shoot(settings, "settings-level-basic-reading-expanded")
        expect(settings, panel: "Documents", shown: ["ap.sheet.card.segmentation"],
               hidden: ["ap.segmentation.picker", "ap.sheet.override.segmentation"], level: "Basic")
        shoot(settings, "settings-level-basic-documents")
        expect(settings, panel: "Dates and names", shown: ["ap.sheet.card.dating", "ap.sheet.card.entities"],
               hidden: ["ap.sheet.switch.dating.image_every_document", "ap.sheet.switch.entities.low_confidence_on_mac",
                        "ap.sheet.switch.dating.local_image"],
               level: "Basic")
        expect(settings, panel: "Pages and output", shown: ["ap.sheet.rule.reading-copy"],
               hidden: ["ap.settings.batchMode"], level: "Basic")
        shoot(settings, "settings-level-basic-pages")
        expect(settings, panel: "Accounts", shown: ["ap.settings.guidedKeySetup", "ap.settings.planSignIn"],
               hidden: ["ap.settings.localAgentToolPicker"], level: "Basic")
    }

    func testStandardAddsTheMeasuredChoicesButNotTheAdvancedGroups() throws {
        guard let settings = launch(["-settingsLevel", "standard"]) else { return }
        expect(settings, panel: "Reading", shown: ["ap.settings.backendPicker", "ap.sheet.override.reading"],
               hidden: ["ap.settings.level.why.custom-models", "ap.settings.postCorrection"], level: "Standard")
        let reader = element(settings, "ap.settings.activeReader")
        let backend = element(settings, "ap.settings.backendPicker")
        XCTAssertLessThan(reader.frame.minY, backend.frame.minY)
        XCTAssertTrue(settings.scrollViews.firstMatch.frame.contains(backend.frame))
        shoot(settings, "settings-level-standard-reading")
        expect(settings, panel: "Documents", shown: ["ap.segmentation.picker", "ap.sheet.override.segmentation"],
               hidden: ["ap.settings.level.why.custom-prompt"], level: "Standard")
        expect(settings, panel: "Dates and names", shown: ["ap.sheet.switch.dating.image_every_document"],
               hidden: ["ap.sheet.switch.entities.low_confidence_on_mac", "ap.sheet.switch.dating.local_image"], level: "Standard")
        expect(settings, panel: "Pages and output", shown: ["ap.settings.batchMode"],
               hidden: ["ap.settings.level.why.workers", "ap.settings.level.why.log-file", "ap.settings.level.why.image-size"],
               level: "Standard")
        expect(settings, panel: "Accounts", shown: ["ap.settings.localAgentToolPicker"],
               hidden: ["ap.settings.level.why.cli-fields"], level: "Standard")
    }

    func testHandwritingSwitchHelpShowsEligibleReplay() throws {
        guard let settings = launch(["-settingsLevel", "advanced", "-ocrPageKindRouting", "YES",
                                     "-useGateway", "NO", "-useLocalAgent", "NO", "-useAppleVision", "NO"]) else { return }
        XCTAssertTrue(app.showSettingsPanel("Reading"))
        let help = settings.buttons["ap.settings.handwritingOnTyped.help"]
        XCTAssertTrue(help.waitForExistence(timeout: 5))
        let form = settings.scrollViews.firstMatch
        for _ in 0..<15 where !form.frame.contains(help.frame) {
            form.scroll(byDeltaX: 0, deltaY: -110)
        }
        XCTAssertTrue(form.frame.contains(help.frame))
        help.click()
        let explanation = settings.popovers.firstMatch.staticTexts.firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        let text = try XCTUnwrap(explanation.value as? String)
        XCTAssertTrue(text.contains("412 were eligible and flagged"))
        XCTAssertTrue(text.contains("12% to 95%"))
        shoot(XCUIScreen.main.screenshot(), "settings-handwriting-switch-help")
    }

    func testAdvancedShowsTheControlsAndTheirReasons() throws {
        guard let settings = launch(["-settingsLevel", "advanced"]) else { return }
        expect(settings, panel: "Reading",
               shown: ["ap.settings.backendPicker", "ap.settings.level.why.custom-models",
                       "ap.settings.postCorrection", "ap.settings.postCorrection.details"],
               hidden: [], level: "Advanced")
        shoot(settings, "settings-level-advanced-reading-overview")
        shootCorrection(settings, "settings-level-advanced-reading")
        expect(settings, panel: "Documents", shown: ["ap.settings.level.why.custom-prompt"], hidden: [], level: "Advanced")
        let localNamesID = "ap.sheet.switch.entities.low_confidence_on_mac"
        expect(settings, panel: "Dates and names", shown: [localNamesID, "ap.settings.level.why.low-confidence-names",
                "ap.sheet.switch.dating.local_image", "ap.settings.level.why.date-local-image"],
               hidden: [], level: "Advanced")
        let form = settings.scrollViews.firstMatch
        let localDate = element(settings, "ap.sheet.switch.dating.local_image")
        let localDateReason = element(settings, "ap.settings.level.why.date-local-image")
        for _ in 0..<15 where !form.frame.contains(localDateReason.frame) {
            form.scroll(byDeltaX: 0, deltaY: -110)
        }
        XCTAssertTrue(form.frame.contains(localDate.frame))
        XCTAssertTrue(form.frame.contains(localDateReason.frame))
        shoot(settings, "settings-level-advanced-local-image-dating")
        let localNames = element(settings, localNamesID)
        let localNamesReason = element(settings, "ap.settings.level.why.low-confidence-names")
        for _ in 0..<15 where !form.frame.contains(localNamesReason.frame) {
            form.scroll(byDeltaX: 0, deltaY: -110)
        }
        XCTAssertTrue(form.frame.contains(localNames.frame))
        XCTAssertTrue(form.frame.contains(localNamesReason.frame))
        shoot(settings, "settings-level-advanced-low-confidence-names")
        expect(settings, panel: "Pages and output",
               shown: ["ap.settings.level.why.workers", "ap.settings.level.why.log-file", "ap.settings.level.why.image-size"],
               hidden: [], level: "Advanced")
        shoot(settings, "settings-level-advanced-pages")
        expect(settings, panel: "Accounts", shown: ["ap.settings.level.why.cli-fields"], hidden: [], level: "Advanced")
    }

    /// A Basic user never runs a setting they cannot see: an Advanced value off its default is shown, marked, with Reset.
    func testAChangedAdvancedValueShowsAtBasicWithItsReset() throws {
        guard let settings = launch(["-settingsLevel", "basic", "-ocrWorkerCount", "8", "-ocrPostCorrection", "YES"]) else { return }
        expect(settings, panel: "Pages and output",
               shown: ["ap.settings.level.changed.workers", "ap.settings.level.reset.workers"],
               hidden: ["ap.settings.batchMode", "ap.settings.level.changed.log-file"], level: "Basic")
        shoot(settings, "settings-level-basic-changed-workers")
        expect(settings, panel: "Reading",
               shown: ["ap.settings.postCorrection", "ap.settings.level.reset.post-correction"],
               hidden: ["ap.settings.backendPicker"], level: "Basic")
        shootCorrection(settings, "settings-level-basic-changed-post-correction")
    }

    func testAdvancedReadingRangeShowsPairedAccuracyAndMeasuredThroughput() {
        guard let settings = launch(["-settingsLevel", "advanced"]) else { return }
        XCTAssertTrue(app.showSettingsPanel("Reading"))
        let seeRange = element(settings, "ap.sheet.seeRange.reading")
        guard seeRange.waitForExistence(timeout: 5) else { return XCTFail("Reading range link is missing") }
        for _ in 0..<12 where !seeRange.isHittable { settings.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -200) }
        seeRange.click()
        let comparison = app.staticTexts["ap.sheet.range.reading.comparison.qwen3.5-122b-a10b-farmshare"]
        guard comparison.waitForExistence(timeout: 10) else { return XCTFail("Paired reading comparison is missing") }
        let scroll = app.scrollViews.containing(.staticText, identifier: comparison.identifier).firstMatch
        for _ in 0..<24 where !comparison.isHittable && scroll.exists { scroll.scroll(byDeltaX: 0, deltaY: -240) }
        XCTAssertTrue(comparison.isHittable)
        let wording = (comparison.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? comparison.label
        XCTAssertTrue(wording.contains("tied (0.23 points lower, within 0.49 points) on the 93 benchmark pages"), wording)
        XCTAssertTrue(wording.contains("1.54 points lower on 95 pages with failures scored as zero"), wording)
        XCTAssertTrue(wording.contains("3,898.9 pages per hour per GPU (one GPU, Stanford Sherlock)"), wording)
        XCTAssertTrue(wording.contains("729.4 pages per hour per GPU (four NVIDIA L40S, Stanford FarmShare)"), wording)
        shoot(app.windows.firstMatch, "advanced-reading-paired-comparison")
    }

    private func shootCorrection(_ settings: XCUIElement, _ name: String) {
        let form = settings.scrollViews.firstMatch
        let details = element(settings, "ap.settings.postCorrection.details")
        for _ in 0..<15 where !form.frame.contains(details.frame) {
            form.scroll(byDeltaX: 0, deltaY: -110)
        }
        XCTAssertEqual(details.value as? String, "collapsed")
        let results = element(settings, "ap.settings.postCorrection.results")
        XCTAssertFalse(results.exists)
        details.click()
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        for _ in 0..<15 where !form.frame.contains(results.frame) {
            form.scroll(byDeltaX: 0, deltaY: -110)
        }
        XCTAssertTrue(form.frame.contains(results.frame), "the benchmark label should scroll fully into view")
        shoot(settings, name)
    }

    private func shoot(_ element: XCUIElement, _ name: String) {
        shoot(element.screenshot(), name)
    }

    private func shoot(_ screenshot: XCUIScreenshot, _ name: String) {
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
