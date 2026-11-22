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

    func testWizardShowsValidatedAboveAnEmptyKey() throws {
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
        XCTAssertTrue(sheet.buttons["Test OCR on a sample page"].waitForExistence(timeout: 10))
        sheet.buttons["Done"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))

        let validatedImmediately = text("Validated").exists
        XCTAssertTrue(app.showSettingsPanel("General"))
        XCTAssertTrue(app.showSettingsPanel("Accounts"))
        let account = settings.secureTextFields["OpenAI API key"].firstMatch
        XCTAssertTrue(account.exists, settings.debugDescription)
        reveal(account, in: settings.scrollViews.firstMatch)
        let chip = text("Validated")
        XCTAssertTrue(chip.waitForExistence(timeout: 5), settings.debugDescription)
        XCTAssertEqual(chip.frame.midY, account.frame.midY, accuracy: 12, "the chip belongs to the OpenAI row")
        let value = account.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == "Not set — paste a key", account.debugDescription)
        XCTAssertFalse(text("Save failed").exists)
        shot("s024-validated-empty")
        print("[s024] Validated immediately: \(validatedImmediately); it appears on returning to Accounts; key field is empty.")
    }

    func testOpenAIPresetBuildsLegacyTokenLimit() throws {
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
        XCTAssertEqual(read["max_tokens"] as? Int, 8192)
        XCTAssertTrue(read["max_completion_tokens"] is NSNull)
        print("[s025] preset OCR request \(read)")
    }

    func testCodexEndsPageBeforeThePromisedRetry() throws {
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
        XCTAssertTrue(log.contains("The app paces to your subscription window and retries."), log)
        print("[s018] \(times.count) CLI call and \(Int(secondsRemaining))s remained at completion.\n\(log)")
    }

    func testComparativeVoteFailureLeavesSidewaysPageWithoutWarning() throws {
        var markerBounds: [CGRect] = []
        for mode in ["rotation-ok", "rotation-fail"] {
            try prepare()
            // A text-free portrait page, scanned clockwise. The bar at the right is the turned top border.
            try makePhoto("in/sideways.jpg", width: 640, height: 320)
            launch(mode, extra: ["-useGateway", "YES", "-gatewayBaseURL", "https://api.openai.com/v1",
                                 "-gatewayModelID", "scratch-transcription", "-rotationModeRaw", "llmSingle"])
            start()
            waitForDone(succeeded: 1)
            let rotations = try calls().filter { ($0["images"] as? Int) == 4 }
            XCTAssertFalse(rotations.isEmpty)
            let expected = mode == "rotation-ok" ? 200 : 500
            XCTAssertTrue(rotations.allSatisfy { ($0["status"] as? Int) == expected })
            let pdf = try XCTUnwrap(PDFDocument(url: root.appendingPathComponent("out/sideways.pdf")))
            let page = try XCTUnwrap(pdf.page(at: 0))
            let bounds = try boundsOfBlueMarker(in: page, name: "s029-\(mode)-pdf")
            markerBounds.append(bounds)
            XCTAssertFalse(text("rotation unsure").exists, app.debugDescription)
            XCTAssertFalse(text("rotation check failed").exists, app.debugDescription)
            XCTAssertFalse(try runLog().localizedCaseInsensitiveContains("rotation"))
            shot("s029-\(mode)")
            print("[s029] \(mode) \(rotations.count) vote request(s) at HTTP \(expected), rendered blue marker \(bounds.size)")
            app.terminate()
        }
        XCTAssertGreaterThan(markerBounds[0].width, markerBounds[0].height, "a usable comparative reply turns the page")
        XCTAssertLessThan(markerBounds[1].width, markerBounds[1].height, "the failed vote silently leaves it sideways")
    }

    func testRunLogLosesOneOfTwoSameNamedFailures() throws {
        try prepare()
        try makePhoto("in/a/same.jpg")
        try makePhoto("in/b/same.jpg", width: 280, height: 420)
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
        waitForDone(succeeded: 0, failed: 1)
        let reads = try calls().filter { ($0["images"] as? Int) == 1 }
        XCTAssertEqual(reads.count, 2)
        XCTAssertTrue(reads.allSatisfy { ($0["status"] as? Int) == 400 })
        let log = try runLog()
        XCTAssertTrue(log.contains("Total files: 2"), log)
        XCTAssertTrue(log.contains("Failed: 1"), log)
        let refusals = log.split(whereSeparator: \.isNewline)
            .filter { $0.contains("• same.jpg [400]: Scratch refusal") }
        XCTAssertEqual(refusals.count, 1, log)
        let files = FileManager.default.enumerator(atPath: root.appendingPathComponent("out").path)?.allObjects as? [String] ?? []
        XCTAssertEqual(files.filter { $0.hasSuffix("/same.pdf") }.sorted(), ["in/a/same.pdf", "in/b/same.pdf"])
        shot("s030-two-failures-counted-as-one")
        print("[s030] \(reads.count) refusals; outputs \(files).\n\(log)")
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
