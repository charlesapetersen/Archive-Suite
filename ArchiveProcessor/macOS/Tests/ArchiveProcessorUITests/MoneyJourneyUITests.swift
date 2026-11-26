import AppKit
import CryptoKit
import XCTest

/// Off-screen scratch journeys for the four spending suspects. The fixture intercepts requests after
/// encoding and before the wire. The tests enter through the app's actual Process and Start buttons.
@MainActor
final class MoneyJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws { app?.terminate() }

    func testStageForLaterKeepsTheBackupWithoutOfferingCompletedPhotos() throws {
        try preparePhotos(count: 2)
        launch(extra: ["-APUITestReceiveScratchPhotos"], staged: true)
        try handOff()
        // Switching back before Start still offers the same two photos and costs nothing.
        try handOff()
        XCTAssertTrue(try requestRecords().isEmpty)
        start()
        waitForDone(count: 2)
        let first = try requestRecords()
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(Set(first.map(\.digest)).count, 2)
        XCTAssertFalse(element("ap.ocr.start").isEnabled)
        app.typeKey("r", modifierFlags: .command)
        try assertNoHandoff()
        shot("s039-completed-capture")

        app.terminate()
        launch(staged: true)
        try assertNoHandoff()
        try assertBackupCopies()
        app.terminate()

        // Replay the two uploads through ingest, as when the phone missed an acknowledgement.
        launch(extra: ["-APUITestReceiveScratchPhotos"], staged: true)
        try assertNoHandoff()
        try assertBackupCopies()
        XCTAssertEqual(try requestRecords(), first)
        app.terminate()

        launch(extra: ["-APUITestReceiveScratchPhotos", "-APUITestReceiveChangedScratchPhoto"], staged: true)
        let changedHandoff = try openLiveCapture().buttons["Process 1 →"]
        XCTAssertTrue(changedHandoff.waitForExistence(timeout: 10) && changedHandoff.isEnabled)
        try assertBackupCopies()
        XCTAssertEqual(try requestRecords(), first)
    }

    func testStageForLaterResumesAnIncompleteRunWithoutReadingCompletedPagesAgain() throws {
        try preparePhotos(count: 2)
        launch(extra: ["-APUITestReceiveScratchPhotos", "-APUITestMonthlyLimit", "1.008", "-ocrWorkerCount", "1"],
               staged: true)
        try handOff()
        start()
        let confirm = app.buttons["Start Within Limit"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.click()
        XCTAssertTrue(text(containing: "Stopped at the monthly spending limit").waitForExistence(timeout: 30))
        let paid = try requestRecords()
        XCTAssertEqual(paid.count, 1)
        XCTAssertTrue(element("ap.ocr.resumeRun").exists)

        app.terminate()
        launch(extra: ["-APUITestMonthlyLimit", "1.03"], staged: true)
        try handOff()
        let resume = element("ap.ocr.resumeRun")
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.click()
        waitForDone(count: 2)
        XCTAssertFalse(element("ap.ocr.start").isEnabled)
        try assertNoHandoff()
        try assertBackupCopies()
        let final = try requestRecords()
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(Set(final.map(\.digest)).count, 2)
        XCTAssertTrue(final.contains(paid[0]))
    }

    func testStageForLaterRecoversWhenTheReceiptCannotBeSaved() throws {
        try preparePhotos(count: 2)
        launch(extra: ["-APUITestReceiveScratchPhotos", "-APUITestRefuseHandoffReceipt"], staged: true)
        try handOff()
        start()
        XCTAssertTrue(text(containing: "the completed photos could not be marked").waitForExistence(timeout: 45))
        let first = try requestRecords()
        XCTAssertEqual(first.count, 2)
        try assertBackupCopies()
        app.terminate()

        launch(staged: true)
        let resume = element("ap.ocr.resumeRun")
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.click()
        XCTAssertTrue(text(containing: "Recovered catalogue filing for 2 PDFs.").waitForExistence(timeout: 30))
        try assertNoHandoff()
        try assertBackupCopies()
        XCTAssertEqual(try requestRecords(), first)
    }

    func testMissingGeminiSegmentationKeyBlocksStartBeforeAnyRead() throws {
        try preparePhotos(count: 3)
        launch(tagging: "automatic", extra: ["-segmentationApproach", "gemini"])
        let reason = element("ap.ocr.startBlockedReason")
        XCTAssertTrue(reason.waitForExistence(timeout: 10))
        XCTAssertTrue(renderedText(reason).contains("Segmentation: Gemini needs an API key."), reason.debugDescription)
        let button = element("ap.ocr.start")
        revealInCostPanel(reason)
        XCTAssertFalse(button.isEnabled)
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(reason.exists)
        XCTAssertTrue(try requestRecords().isEmpty)
        XCTAssertFalse(element("ap.ocr.resumeRun").exists)
        shot("s032-missing-key-before-ocr")
    }

    func testMissingSegmentationKeyDoesNotBlockModesThatSkipTheWindowStage() throws {
        try preparePhotos(count: 2)
        launch(tagging: "none", extra: ["-segmentationApproach", "gemini"])
        start()
        waitForDone(count: 2)
        XCTAssertEqual(try requestRecords().map(\.route), ["openai", "openai"])
        app.terminate()

        try preparePhotos(count: 2)
        launch(tagging: "automatic", extra: ["-segmentationApproach", "manual"])
        let button = element("ap.ocr.start")
        XCTAssertTrue(button.waitForExistence(timeout: 10) && button.isEnabled, app.debugDescription)
        app.terminate()

        try preparePhotos(count: 2)
        launch(tagging: "automatic", extra: ["-segmentationApproach", "gemini", "-APUITestReceiveScratchPhotos"], staged: true)
        try handOff()
        XCTAssertTrue(button.waitForExistence(timeout: 10) && button.isEnabled, app.debugDescription)
        XCTAssertTrue(try requestRecords().isEmpty)
    }

    /// W49.proc-fix-s026 (S-026): batch scales by the same file-size target as the direct path, so a dense scan over
    /// the standard size goes up reduced in both, not as the original file in batch.
    func testGeminiDirectAndBatchSendTheSameImageSize() throws {
        let directInput = try preparePhotos(count: 1, width: 2000, height: 1500)
        launch(provider: "Gemini")
        start()
        waitForDone(count: 1)
        let direct = try XCTUnwrap(try requestRecords().only)
        XCTAssertEqual(direct.route, "gemini-direct")
        app.terminate()

        let batchInput = try preparePhotos(count: 1, width: 2000, height: 1500)
        XCTAssertEqual(batchInput, directInput, "both runs start from the same JPEG bytes")
        let batch = try batchRequest()
        XCTAssertEqual(batch.model, direct.model)
        XCTAssertEqual(batch.pixels, direct.pixels)
        XCTAssertNotEqual(batch.digest, SHA256.hash(data: directInput).map { String(format: "%02x", $0) }.joined())
        XCTAssertLessThan(batch.bytes, directInput.count)
        let batchWidth = try XCTUnwrap(batch.pixels.split(separator: "x").first.flatMap { Int($0) })
        XCTAssertLessThan(batchWidth, 2000)
        print("[s026] source \(directInput.count) B, direct \(direct), batch \(batch)")
    }

    /// W49.proc-fix-s026: a large photo already under the size target is left at full scale and still capped at
    /// 2,048 px on its long edge in batch.
    func testGeminiBatchKeepsTheLongEdgeCap() throws {
        _ = try preparePhotos(count: 1, width: 4000, height: 3000, noise: false)
        let batch = try batchRequest()
        XCTAssertEqual(batch.pixels, "2048x1536")
        print("[s026] cap: batch \(batch)")
    }

    private func batchRequest() throws -> RequestRecord {
        launch(provider: "Gemini", batch: true)
        XCTAssertTrue(element("ap.ocr.batchTotal").waitForExistence(timeout: 10))
        XCTAssertFalse(element("ap.ocr.institutionalComputeChoose").exists)
        start()
        let deadline = Date().addingTimeInterval(35)
        while try requestRecords().isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let batch = try XCTUnwrap(try requestRecords().only)
        XCTAssertEqual(batch.route, "gemini-batch")
        return batch
    }

    func testStoredBatchFlagOnOpenAIUsesStandardEstimateAndPageReaders() throws {
        let routing = ["-APUITestScratchPageKinds", "-ocrPageKindRouting", "YES"]
        var standardTotals: [String] = []
        for storedBatch in [false, true] {
            try preparePhotos(count: 2)
            launch(batch: storedBatch, extra: routing)

            if storedBatch {
                let settings = app.showSettingsWindow()
                XCTAssertTrue(app.showSettingsPanel("Processing"))
                let toggle = settings.descendants(matching: .any)["ap.settings.batchMode"].firstMatch
                XCTAssertTrue(toggle.waitForExistence(timeout: 5))
                reveal(toggle, in: settings.scrollViews.firstMatch)
                XCTAssertFalse(toggle.isEnabled)
                XCTAssertTrue(text(containing: "OpenAI has no batch API here.").exists)
                shot("s027-openai-batch-disabled")
                app.typeKey("w", modifierFlags: .command)
                XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
            }

            let standard = element("ap.ocr.standardTotal")
            XCTAssertTrue(standard.waitForExistence(timeout: 15))
            let defaultTotal = renderedText(standard)
            let readers = element("ap.ocr.pageKindBatch")
            XCTAssertTrue(readers.exists)
            XCTAssertTrue(element("ap.ocr.institutionalComputeChoose").exists)
            revealInCostPanel(readers)
            readers.click()
            let nano = app.menuItems["OpenAI · GPT-5 nano for every page"].firstMatch
            XCTAssertTrue(nano.waitForExistence(timeout: 5), app.debugDescription)
            nano.click()
            let adjustedTotal = renderedText(standard)
            XCTAssertNotEqual(adjustedTotal, defaultTotal, "the estimate uses the chosen page reader")
            XCTAssertFalse(element("ap.ocr.batchTotal").exists)
            standardTotals += [defaultTotal, adjustedTotal]

            if storedBatch {
                revealInCostPanel(standard)
                shot("s027-openai-standard-estimate")
            }
            start()
            waitForDone(count: 2)
            let requests = try requestRecords()
            XCTAssertEqual(requests.map(\.route), ["openai", "openai"])
            XCTAssertEqual(requests.map(\.model), ["gpt-5-nano", "gpt-5-nano"])
            app.terminate()
        }
        XCTAssertEqual(Array(standardTotals.prefix(2)), Array(standardTotals.suffix(2)))
    }

    func testMonthlyLimitWarnsStopsParallelReadsAndResumesWithoutRepeatingThem() throws {
        try preparePhotos(count: 5)
        // The fixture starts with $1 already in this month's ledger. About $0.0053 per image fits twice.
        launch(extra: ["-APUITestMonthlyLimit", "1.013", "-ocrWorkerCount", "4"])
        start()
        let warning = text(containing: "This run may reach the monthly spending limit")
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(text(containing: "$0.0130").exists)
        shot("monthly-limit-warning")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
        XCTAssertTrue(try requestRecords().isEmpty)

        start()
        app.buttons["Start Within Limit"].firstMatch.click()
        let stop = text(containing: "Stopped at the monthly spending limit")
        XCTAssertTrue(stop.waitForExistence(timeout: 30), app.debugDescription)
        let paid = try requestRecords()
        XCTAssertEqual(paid.count, 2)
        let resume = element("ap.ocr.resumeRun")
        XCTAssertTrue(resume.exists)
        shot("monthly-limit-stopped")
        resume.click()
        XCTAssertTrue(stop.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(try requestRecords(), paid)

        app.terminate()
        launch(extra: ["-APUITestMonthlyLimit", "1.03", "-ocrWorkerCount", "4"])
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.click()
        waitForDone(count: 5)
        let final = try requestRecords()
        XCTAssertEqual(final.count, 5)
        XCTAssertEqual(Set(final.map(\.digest)).count, 5)

        let settings = app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Processing"))
        let setup = settings.buttons["Answer the setup questions…"]
        reveal(setup, in: settings.scrollViews.firstMatch)
        setup.click()
        let sheet = settings.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        let ledger = text(containing: "Process Files and Live Capture count requests as they are sent.")
        XCTAssertTrue(ledger.waitForExistence(timeout: 10))
        reveal(ledger, in: sheet.scrollViews.firstMatch)
        XCTAssertTrue(text(containing: "list-price estimate").exists)
        shot("monthly-paid-request-ledger")
    }

    func testMonthlyLimitRefusesProviderBatchBeforeSubmission() throws {
        try preparePhotos(count: 3)
        launch(provider: "Gemini", batch: true, extra: ["-APUITestMonthlyLimit", "1"])
        start()
        let warning = text(containing: "This run may reach the monthly spending limit")
        XCTAssertTrue(warning.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Start Within Limit"].firstMatch.click()
        let stop = text(containing: "Stopped at the monthly spending limit")
        XCTAssertTrue(stop.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(text(containing: "the provider batch").exists)
        XCTAssertTrue(try requestRecords().isEmpty)
        XCTAssertFalse(element("ap.ocr.resumeRun").exists)
    }

    func testMonthlyLimitStopsBeforeBuyingASecondReader() throws {
        try preparePhotos(count: 1)
        // The first Gemini read fits in $0.035. A second reader would take the estimate over the limit.
        launch(provider: "Gemini", extra: ["-APUITestMonthlyLimit", "1.035", "-APUITestGeminiRefusal"])
        start()
        let stop = text(containing: "Stopped at the monthly spending limit")
        XCTAssertTrue(stop.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(text(containing: "an additional page reading").exists)
        XCTAssertEqual(try requestRecords().map(\.route), ["gemini-direct"])
        XCTAssertTrue(element("ap.ocr.resumeRun").exists)
    }

    private func launch(provider: String = "OpenAI", batch: Bool = false, tagging: String = "none",
                        extra: [String] = [], staged: Bool = false) {
        let out = root.appendingPathComponent("out").path
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode", "-APUITestMoneyJourney", "-APUITestOutputDirectory", out, "-outputDirectory", out,
            "-selectedProvider", provider, "-selectedModelId_OpenAI", "gpt-5.4-mini",
            "-selectedModelId_Gemini", "gemini-3.8-flash", "-batchMode", batch ? "YES" : "NO",
            "-taggingModeRaw", tagging, "-enableCollectionSegmentation", "NO",
            "-rotationModeRaw", "off", "-reviewRotation", "NO", "-reviewDocumentSegmentation", "NO",
            "-outputImageFile", "NO", "-mergeDocuments", "NO", "-sendPreviousImage", "NO",
            "-useInstitutionalComputeImport", "NO", "-skipAlreadyProcessed", "NO", "-preOCRedInput", "NO",
            "-useAppleVision", "NO", "-useLocalAgent", "NO", "-useGateway", "NO",
            "-imageResolutionPercent", "100", "-standardImageSizeMB", "3",
            "-liveProcessingMode", "stageForLater"
        ] + (staged ? [] : ["-APUITestInputImages", root.appendingPathComponent("in").path]) + extra)
        app.launchEnvironment = [
            "ARCHIVEPROC_HEADLESS": "1",
            "ARCHIVEPROC_TEST_BACKUP_ROOT": root.appendingPathComponent("backup").path
        ]
        app.launch()
        XCTAssertTrue(element("ap.mode.picker").waitForExistence(timeout: 15))
    }

    private func openLiveCapture() throws -> XCUIElement {
        let main = app.windows.containing(.any, identifier: "ap.mode.picker").firstMatch
        let live = [main.radioButtons["Live Capture"], main.buttons["Live Capture"]].first { $0.exists }
        try XCTUnwrap(live).click()
        return main
    }

    private func handOff() throws {
        let process = try openLiveCapture().buttons["Process 2 →"]
        XCTAssertTrue(process.waitForExistence(timeout: 10) && process.isEnabled)
        process.click()
        for index in 1...2 {
            XCTAssertTrue(text(containing: String(format: "%06d-doc.jpg", index)).waitForExistence(timeout: 10))
        }
    }

    private func assertNoHandoff() throws {
        let main = try openLiveCapture()
        XCTAssertTrue(text(containing: "0 photos · 0 groups").waitForExistence(timeout: 10))
        XCTAssertFalse(main.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Process ")).allElementsBoundByIndex
            .contains { $0.label.hasSuffix("→") })
    }

    private func assertBackupCopies() throws {
        let backup = root.appendingPathComponent("backup")
        let session = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) })
        for index in 1...2 {
            let original = try Data(contentsOf: root.appendingPathComponent("in/photo-\(index).jpg"))
            let copy = try Data(contentsOf: session.appendingPathComponent(String(format: "%06d-doc.jpg", index)))
            XCTAssertEqual(copy, original)
        }
    }

    private func start() {
        let button = element("ap.ocr.start")
        XCTAssertTrue(button.waitForExistence(timeout: 10) && button.isEnabled, app.debugDescription)
        revealInCostPanel(button)
        button.click()
    }

    private func revealInCostPanel(_ control: XCUIElement) {
        reveal(control, in: app.scrollViews.firstMatch)
        XCTAssertTrue(control.isHittable, control.debugDescription)
    }

    private func reveal(_ control: XCUIElement, in scroll: XCUIElement) {
        func centerIsVisible() -> Bool {
            let frame = control.frame
            return scroll.frame.insetBy(dx: 0, dy: 4).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        // Accessibility reports a partially clipped Start as hittable. Its click is delivered to
        // the center, so scroll far enough for that exact point to be inside the viewport.
        for _ in 0..<12 where !centerIsVisible() { scroll.scroll(byDeltaX: 0, deltaY: -140) }
        XCTAssertTrue(centerIsVisible(), control.debugDescription)
    }

    private func waitForDone(count: Int) {
        let done = text(containing: "Done. \(count) succeeded, 0 failed.")
        XCTAssertTrue(done.waitForExistence(timeout: 45), app.debugDescription)
    }

    @discardableResult
    private func preparePhotos(count: Int, width: Int = 240, height: Int = 320, noise: Bool = true) throws -> Data {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for child in ["in", "out", "backup", "calls", "state"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(child), withIntermediateDirectories: true)
        }
        var jpeg = Data()
        for index in 1...count {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            var value = UInt32(index)
            if !noise { memset(pixels, 200, bitmap.bytesPerRow * height) }
            for offset in 0..<(noise ? bitmap.bytesPerRow * height : 0) {
                value = value &* 1_664_525 &+ 1_013_904_223
                pixels[offset] = UInt8(value >> 24)
            }
            jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]))
            try jpeg.write(to: root.appendingPathComponent("in/photo-\(index).jpg"))
        }
        return jpeg
    }

    private struct RequestRecord: Equatable {
        let route: String
        let model: String
        let pixels: String
        let bytes: Int
        let digest: String
    }

    private func requestRecords() throws -> [RequestRecord] {
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("calls"),
                                                               includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return try files.map {
            let values = try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\t")
            XCTAssertEqual(values.count, 5)
            return RequestRecord(route: values[0], model: values[1], pixels: values[2],
                                 bytes: try XCTUnwrap(Int(values[3])), digest: values[4])
        }.sorted { $0.digest < $1.digest }
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func text(containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment)).firstMatch
    }

    private func renderedText(_ item: XCUIElement) -> String { (item.value as? String) ?? item.label }

    private func shot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = root.appendingPathComponent("\(name).png")
        if (try? screenshot.pngRepresentation.write(to: path)) != nil {
            print("[shot] \(name): wrote \(path.path)")
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
