import AppKit
import PDFKit
import XCTest

/// Independent UI reproductions with synthetic inputs and replies. All assertions observe the
/// settings window, Process Files status, requests as built, or files in the run's scratch output.
@MainActor
final class MessageJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws { app?.terminate() }

    func testWizardReportsRefusedKeySave() throws {
        try prepare()
        launch("key", loadPhotos: false)
        let settings = app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Accounts"))
        let guided = element("ap.settings.guidedKeySetup")
        reveal(guided, in: settings.scrollViews.firstMatch)
        XCTAssertFalse(text("Validated").exists, "the scratch row starts without a validation chip")
        guided.click()
        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        sheet.radioButtons["OpenAI"].click()
        let field = element("ap.keyWizard.keyField")
        reveal(field, in: sheet.scrollViews.firstMatch)
        field.click()
        field.typeText("sk-scratch-wizard-input")
        let validate = sheet.buttons["Validate key"]
        reveal(validate, in: sheet.scrollViews.firstMatch)
        validate.click()
        let failure = element("ap.keyWizard.saveFailure")
        XCTAssertTrue(failure.waitForExistence(timeout: 10), sheet.debugDescription)
        reveal(failure, in: sheet.scrollViews.firstMatch)
        XCTAssertTrue(sheet.staticTexts["✓ Your OpenAI key works."].exists)
        shot("s024-wizard-save-failed")
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        XCTAssertTrue(text("Save failed").waitForExistence(timeout: 5))
        XCTAssertFalse(text("Validated").exists)
        XCTAssertTrue(app.showSettingsPanel("General"))
        XCTAssertTrue(app.showSettingsPanel("Accounts"))
        let account = settings.secureTextFields["OpenAI API key"].firstMatch
        XCTAssertTrue(account.exists, settings.debugDescription)
        reveal(account, in: settings.scrollViews.firstMatch)
        let chip = text("Save failed")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), settings.debugDescription)
        XCTAssertEqual(chip.frame.midY, account.frame.midY, accuracy: 12, "the chip belongs to the OpenAI row")
        let value = account.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == "Not set — paste a key", account.debugDescription)
        XCTAssertFalse(text("Validated").exists)
        shot("s024-accounts-save-failed")
    }

    func testOpenAIPresetHelpAndRequestMatchSelectedModel() throws {
        try prepare()
        try makePhoto("in/one.jpg")
        launch("preset")
        let settings = app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Reading"))
        let backend = element("ap.settings.backendPicker")
        reveal(backend, in: settings.scrollViews.firstMatch)
        backend.click()
        app.menuItems["API Gateway"].firstMatch.click()
        let preset = settings.buttons["Fill in OpenAI preset"]
        reveal(preset, in: settings.scrollViews.firstMatch)
        preset.click()
        let help = element("ap.settings.openAIPresetHelp")
        XCTAssertTrue(help.exists)
        help.click()
        let guidance = settings.popovers.firstMatch.staticTexts.firstMatch
        XCTAssertTrue(guidance.waitForExistence(timeout: 5), settings.debugDescription)
        let helpText = try XCTUnwrap(guidance.value as? String)
        XCTAssertTrue(helpText.contains("GPT-5.4 mini"), helpText)
        XCTAssertTrue(helpText.contains("supports reasoning"), helpText)
        XCTAssertTrue(helpText.contains("uses its OpenAI default"), helpText)
        shot("s025-openai-preset-help")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        let model = settings.textFields["Model ID"]
        reveal(model, in: settings.scrollViews.firstMatch)
        XCTAssertEqual(model.value as? String, "gpt-5.4-mini")
        shot("s025-openai-preset")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        start()
        waitForDone(succeeded: 1)
        let reads = try calls().filter { ($0["images"] as? Int) == 1 && ($0["model"] as? String) == "gpt-5.4-mini" }
        XCTAssertEqual(reads.count, 1)
        let read = try XCTUnwrap(reads.first)
        XCTAssertEqual(read["url"] as? String, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(read["max_completion_tokens"] as? Int, 8192)
        XCTAssertTrue(read["max_tokens"] is NSNull)
        XCTAssertTrue(read["reasoning_effort"] is NSNull)
        print("[s025] preset OCR request \(read)")
    }

    func testCustomGatewayKeepsCompatibleTokenLimitForSameModel() throws {
        try prepare()
        try makePhoto("in/one.jpg")
        launch("custom-gateway", extra: [
            "-useGateway", "YES", "-gatewayLocalModel", "NO", "-gatewayBaseURL", "https://example.invalid/v1",
            "-gatewayModelID", "gpt-5.4-mini", "-gatewayUpstreamProvider", "OpenAI",
        ])
        start()
        waitForDone(succeeded: 1)
        let reads = try calls().filter { ($0["images"] as? Int) == 1 }
        XCTAssertEqual(reads.count, 1)
        let read = try XCTUnwrap(reads.first)
        XCTAssertEqual(read["model"] as? String, "gpt-5.4-mini")
        XCTAssertEqual(read["url"] as? String, "https://example.invalid/v1/chat/completions")
        XCTAssertEqual(read["max_tokens"] as? Int, 8192)
        XCTAssertTrue(read["max_completion_tokens"] is NSNull)
        XCTAssertTrue(read["reasoning_effort"] is NSNull)
    }

    /// S-018: the unverified Codex adapter does not wait for the window, so its message must not promise it.
    func testCodexLimitMessageSaysThePageWasNotRead() throws {
        try prepare()
        try makePhoto("in/one.jpg")
        let cli = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fake_messages_codex", withExtension: "sh"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli.path), cli.path)
        launch("codex", extra: ["-APUITestLocalAgent", "-localAgentTool", "codex", "-localAgentBinaryPath", cli.path])
        start()
        continueAfterFailures()
        waitForDone(succeeded: 0, failed: 1)
        let log = try runLog()
        XCTAssertTrue(log.contains("OpenAI Codex CLI usage limit reached"), log)
        let times = try String(contentsOf: root.appendingPathComponent("cli-calls"), encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        let reset = try String(contentsOf: root.appendingPathComponent("reset"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let secondsRemaining = try XCTUnwrap(Double(reset)) - Date().timeIntervalSince1970
        XCTAssertEqual(times.count, 1)
        XCTAssertGreaterThan(secondsRemaining, 0)
        XCTAssertTrue(log.contains("This page was not read; retry it after the reset."), log)
        XCTAssertFalse(log.contains("paces to your subscription window"), log)
        print("[s018] \(times.count) CLI call and \(Int(secondsRemaining))s remained at completion.\n\(log)")
    }

    func testComparativeRotationReportsFailedVotesAndPagesLeftUnturned() throws {
        for (rotationMode, voteCount) in [("llmSingle", 1), ("llmMajority", 3)] {
            var markerBounds: [CGRect] = []
            for failedVote in [false, true] {
                let mode = failedVote ? "rotation-fail" : "rotation-ok"
                let name = "s029-\(rotationMode)-\(mode)"
                try prepare()
                // A text-free portrait page, scanned clockwise. The blue bar marks its top edge.
                try makePhoto("in/sideways.jpg", width: 640, height: 320)
                launch(mode, extra: ["-useGateway", "YES", "-gatewayBaseURL", "https://api.openai.com/v1",
                                     "-gatewayModelID", "scratch-transcription", "-rotationModeRaw", rotationMode])
                start()
                waitForDone(succeeded: 1)
                let rotations = try calls().filter { ($0["images"] as? Int) == 4 }
                XCTAssertEqual(rotations.count, voteCount)
                let expected = failedVote ? 500 : 200
                XCTAssertTrue(rotations.allSatisfy { ($0["status"] as? Int) == expected })
                let pdf = try XCTUnwrap(PDFDocument(url: root.appendingPathComponent("out/sideways.pdf")))
                let page = try XCTUnwrap(pdf.page(at: 0))
                let bounds = try boundsOfBlueMarker(in: page, name: "\(name)-pdf")
                markerBounds.append(bounds)
                let log = try runLog()
                if failedVote {
                    XCTAssertTrue(text("Comparative rotation check failed on 1 page").exists, app.debugDescription)
                    XCTAssertTrue(text("1 page left unturned, rotation unsure.").exists, app.debugDescription)
                    XCTAssertTrue(log.contains("• sideways.jpg: Comparative rotation check failed."), log)
                    XCTAssertTrue(log.contains("Apple Vision checked rotation instead. Left unturned, rotation unsure."), log)
                } else {
                    XCTAssertFalse(text("rotation unsure").exists, app.debugDescription)
                    XCTAssertFalse(text("rotation check failed").exists, app.debugDescription)
                    XCTAssertFalse(log.contains("Rotation warnings:"), log)
                }
                shot(name)
                print("[s029] \(name) \(rotations.count) vote request(s) at HTTP \(expected), rendered blue marker \(bounds.size)")
                app.terminate()
            }
            XCTAssertGreaterThan(markerBounds[0].width, markerBounds[0].height, "a usable comparative reply turns the page")
            XCTAssertLessThan(markerBounds[1].width, markerBounds[1].height, "with no vote or Vision answer, the page stays sideways")
        }
    }

    func testRunLogKeepsBothSameNamedFailuresByPath() throws {
        try prepare()
        try makePhoto("in/a/same.jpg")
        try makePhoto("in/b/same.jpg", width: 420, height: 280)
        launch("duplicates", loadPhotos: false, extra: ["-useGateway", "YES",
                                                          "-gatewayBaseURL", "https://api.openai.com/v1",
                                                          "-gatewayModelID", "scratch-transcription"])
        let readInside = app.buttons["Read Folders Inside"]
        XCTAssertTrue(readInside.waitForExistence(timeout: 10), app.debugDescription)
        readInside.click()
        start()
        let skipLevels = element("ap.containerLevels.skip")
        if skipLevels.waitForExistence(timeout: 4) { skipLevels.click() }
        continueAfterFailures()
        waitForDone(succeeded: 0, failed: 2)
        let reads = try calls().filter { ($0["images"] as? Int) == 1 }
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(reads.allSatisfy { ($0["status"] as? Int) == 400 })
        let log = try runLog()
        XCTAssertTrue(log.contains("Total files: 2"), log)
        XCTAssertTrue(log.contains("Failed: 2"), log)
        let refusals = log.split(whereSeparator: \.isNewline)
            .filter { $0.contains("[400]: Scratch refusal") }
        XCTAssertEqual(refusals.count, 2, log)
        for (folder, orientation) in [("a", "portrait"), ("b", "landscape")] {
            let input = root.appendingPathComponent("in/\(folder)/same.jpg").standardizedFileURL.path
            XCTAssertTrue(refusals.contains("  • \(input) [400]: Scratch refusal for the \(orientation) page"), log)
        }
        let files = FileManager.default.enumerator(atPath: root.appendingPathComponent("out").path)?.allObjects as? [String] ?? []
        XCTAssertEqual(files.filter { $0.hasSuffix("/same.pdf") }.sorted(), ["in/a/same.pdf", "in/b/same.pdf"])
        shot("s030-two-failures-reported-by-path")
        print("[s030] \(reads.count) refusals; outputs \(files).\n\(log)")
    }

    func testTreeQuestionCanReadOnlyTheSelectedFoldersOwnFiles() throws {
        try launchTreeLevelsJourney()
        shot("files-tree-question")
        app.buttons["Only Its Own Files"].click()

        XCTAssertTrue(text("cover.jpg").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(text("letter.jpg").exists)
        XCTAssertFalse(element("ap.files.treeNote").exists)
        start()
        waitForDone(succeeded: 1)

        XCTAssertEqual(try calls().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("out/cover.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: treeLevelMap.path))
    }

    func testTreeLevelsCanBeEditedAndSavedBeforeFiling() throws {
        try launchTreeLevelsJourney(includeCover: false)
        app.buttons["Read Folders Inside"].click()
        XCTAssertTrue(element("ap.files.treeNote").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(text("letter.jpg").exists, app.debugDescription)

        start()
        let title = text("What do these folder levels name?")
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        element("ap.containerLevels.cancel").click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element("ap.ocr.start").isEnabled, app.debugDescription)
        XCTAssertTrue(try calls().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: treeLevelMap.path))

        start()
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        let preview = text("Container: Box 17")
        XCTAssertTrue(preview.exists, app.debugDescription)
        XCTAssertTrue(text("Folder 8").exists, app.debugDescription)
        element("ap.containerLevels.level1").click()
        app.menuItems["Series"].firstMatch.click()
        XCTAssertTrue(text("Series: in").waitForExistence(timeout: 5), app.debugDescription)
        shot("files-tree-levels")

        element("ap.containerLevels.save").click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        waitForDone(succeeded: 1)

        let map = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: treeLevelMap)) as? [String: Any])
        XCTAssertEqual(map["levels"] as? [String], ["series", "box", "folder"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("out/in/Box 17/Folder 8/letter.pdf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("in/.archivesuite/container-levels.json").path
        ))
    }

    private var treeLevelMap: URL {
        root.appendingPathComponent("out/.archivesuite/container-levels.json")
    }

    private func launchTreeLevelsJourney(includeCover: Bool = true) throws {
        try prepare()
        if includeCover { try makePhoto("in/cover.jpg") }
        try makePhoto("in/Box 17/Folder 8/letter.jpg")
        launch("tree-levels", loadPhotos: false, extra: ["-useGateway", "YES",
                                                         "-gatewayBaseURL", "https://api.openai.com/v1",
                                                         "-gatewayModelID", "scratch-transcription"])
        XCTAssertTrue(text("Read the folders inside?").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Read Folders Inside"].exists)
        XCTAssertTrue(app.buttons["Only Its Own Files"].exists)
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    func testTreeSummaryReportsSkippedBranchesAndDotFolderFiling() throws {
        try prepare()
        let boundary = ".in/" + (1...12).map { "Level \($0)" }.joined(separator: "/")
        try makePhoto("\(boundary)/edge.jpg")
        try makePhoto("\(boundary)/Folder 10/ignored.jpg")
        try makePhoto("\(boundary)/Folder 2/Below/ignored.jpg")
        launch("tree-depth", loadPhotos: false, extra: ["-useGateway", "YES",
                                                         "-gatewayBaseURL", "https://api.openai.com/v1",
                                                         "-gatewayModelID", "scratch-transcription"])

        let readInside = app.buttons["Read Folders Inside"]
        XCTAssertTrue(readInside.waitForExistence(timeout: 10), app.debugDescription)
        readInside.click()
        let warning = text("Skipped 2 folder branches more than 12 levels deep.")
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        start()
        waitForDone(succeeded: 1)

        XCTAssertTrue(warning.exists)
        XCTAssertTrue(text("\(boundary)/Folder 2").exists, app.debugDescription)
        XCTAssertTrue(text("Its folder structure is skipped when filing PDFs.").exists, app.debugDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("out/edge.pdf").path))
        XCTAssertEqual(try calls().count, 1)
        shot("tree-depth-summary")

        let tools = [app.radioButtons["Tools"], app.buttons["Tools"]].first { $0.exists }
        try XCTUnwrap(tools).click()
        XCTAssertTrue(app.buttons["View History…"].waitForExistence(timeout: 5))
        let processFiles = [app.radioButtons["Process Files"], app.buttons["Process Files"]].first { $0.exists }
        try XCTUnwrap(processFiles).click()
        waitForDone(succeeded: 1)
        XCTAssertTrue(warning.exists, app.debugDescription)
        XCTAssertTrue(text("Its folder structure is skipped when filing PDFs.").exists, app.debugDescription)

        app.buttons["Clear"].click()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
    }

    private func prepare() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-messages-\(UUID().uuidString)")
        for child in ["in", "out", "calls", "backup"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(child), withIntermediateDirectories: true)
        }
    }

    private func makePhoto(_ relativePath: String, width: Int = 320, height: Int = 480) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * bitmap.bytesPerRow + x * 3
                let border = x > width * 4 / 5 && y > height / 6 && y < height * 5 / 6
                pixels[index] = border ? 55 : 244
                pixels[index + 1] = border ? 85 : 244
                pixels[index + 2] = border ? 160 : 244
            }
        }
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
        try jpeg.write(to: url)
    }

    private func boundsOfBlueMarker(in page: PDFPage, name: String) throws -> CGRect {
        let image = page.thumbnail(of: CGSize(width: 306, height: 396), for: .mediaBox)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        saveShot(png, name)
        var bounds = CGRect.null
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.blueComponent > color.redComponent + 0.20,
                      color.blueComponent > color.greenComponent + 0.15 else { continue }
                bounds = bounds.union(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        XCTAssertFalse(bounds.isNull, "the rendered PDF contains the fixture's blue border")
        return bounds
    }

    private func launch(_ mode: String, loadPhotos: Bool = true, extra: [String] = []) {
        let output = root.appendingPathComponent("out").path
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode", "-APUITestStandInGateway", "-APUITestOutputDirectory", output, "-outputDirectory", output,
            "-settingsLevel", "advanced", "-selectedProvider", "OpenAI", "-batchMode", "NO", "-taggingModeRaw", "none",
            "-enableCollectionSegmentation", "NO", "-reviewRotation", "NO", "-reviewDocumentSegmentation", "NO",
            "-outputImageFile", "NO", "-mergeDocuments", "NO", "-sendPreviousImage", "NO", "-skipAlreadyProcessed", "NO",
            "-preOCRedInput", "NO", "-useAppleVision", "NO", "-writeLogFile", "YES", "-ocrPageKindRouting", "NO"
        ] +
            (mode.hasPrefix("rotation") ? [] : ["-rotationModeRaw", "off"]) +
            (loadPhotos ? ["-APUITestInputImages", root.appendingPathComponent("in").path] : []) + extra)
        app.launchEnvironment = ["ARCHIVEPROC_HEADLESS": "1", "AP_MESSAGE_JOURNEY": mode,
                                 "ARCHIVEPROC_TEST_BACKUP_ROOT": root.appendingPathComponent("backup").path,
                                 "AP_MESSAGE_CLI_DIR": root.path]
        app.launch()
        XCTAssertTrue(element("ap.mode.picker").waitForExistence(timeout: 15))
    }

    private func start() {
        let button = element("ap.ocr.start")
        XCTAssertTrue(button.waitForExistence(timeout: 10) && button.isEnabled, app.debugDescription)
        reveal(button, in: app.scrollViews.firstMatch)
        button.click()
    }

    private func continueAfterFailures() {
        let button = app.buttons["Continue Without Retrying"].firstMatch
        if button.waitForExistence(timeout: 15) { button.click() }
    }

    private func waitForDone(succeeded: Int, failed: Int = 0) {
        let done = "Done. \(succeeded) succeeded, \(failed) failed."
        XCTAssertTrue(text(done).waitForExistence(timeout: 35), app.debugDescription)
    }

    private func runLog() throws -> String {
        let output = root.appendingPathComponent("out")
        let files = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        let log = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("ArchiveProcessor_Log_") })
        return try String(contentsOf: log, encoding: .utf8)
    }

    private func calls() throws -> [[String: Any]] {
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("calls"),
                                                               includingPropertiesForKeys: nil)
        return try files.map { try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any]) }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func text(_ fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                                             fragment, fragment)).firstMatch
    }

    private func reveal(_ control: XCUIElement, in scroll: XCUIElement) {
        XCTAssertTrue(control.waitForExistence(timeout: 10))
        if scroll.exists {
            for _ in 0..<14 {
                let mid = control.frame.midY
                let viewport = scroll.frame.insetBy(dx: 0, dy: 6)
                if (viewport.minY...viewport.maxY).contains(mid), control.isHittable { return }
                scroll.scroll(byDeltaX: 0, deltaY: mid < viewport.minY ? 180 : -180)
            }
        }
        XCTAssertTrue(control.isHittable, control.debugDescription)
    }

    private func shot(_ name: String) {
        saveShot(app.screenshot().pngRepresentation, name)
    }

    private func saveShot(_ png: Data, _ name: String) {
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = root.appendingPathComponent("\(name).png")
        if (try? png.write(to: path)) != nil { print("[shot] \(name): wrote \(path.path)") }
    }
}
