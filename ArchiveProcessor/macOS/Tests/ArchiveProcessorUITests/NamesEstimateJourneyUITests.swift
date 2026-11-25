import AppKit
import XCTest

/// W49.proc-s044-check: independent user-path check, never calls ProcessFilesTestDriver or the old repro script.
/// Opt in: PROCESSOR_JOURNEY=namesestimate ops/gui/vm-gui-runner.sh processor xcuitest
/// A deterministic guest-loopback gateway returns letters. No real keys, corpus, uploads or spend.
@MainActor
final class NamesEstimateJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratch: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["S044_GATEWAY"] == "1" else {
            throw XCTSkip("S-044: runs only under PROCESSOR_JOURNEY=namesestimate")
        }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("s044-user-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws { app?.terminate(); app = nil }

    func testNamesRankedByInterviewAddsEstimatedCall() throws {
        let initialCalls = try gatewayCalls()
        let input = scratch.appendingPathComponent("in"), output = scratch.appendingPathComponent("out")
        for dir in [input, output] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try makeLetter(at: input.appendingPathComponent("letter.png"))
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode", "-APUITestStandInGateway", "-APUITestInputImages", input.path,
            "-APUITestOutputDirectory", output.path, "-outputDirectory", output.path,
            "-useGateway", "YES", "-gatewayLocalModel", "NO", "-useAppleVision", "NO", "-useLocalAgent", "NO",
            "-gatewayBaseURL", "http://127.0.0.1:18472/v1", "-gatewayModelID", "s044-priced",
            "-gatewayUpstreamProvider", "Anthropic",
            "-taggingModeRaw", "automatic", "-enableSegmentJSON", "YES", "-enableCollectionSegmentation", "NO",
            "-segmentationApproach", "manual", "-rotationModeRaw", "off", "-reviewRotation", "NO",
            "-mergeDocuments", "NO", "-batchMode", "NO", "-tagVocabulary", "",
            "-sendPreviousImage", "NO", "-imageResolutionPercent", "100", "-contextCharCount", "0",
            "-skipAlreadyProcessed", "NO", "-preOCRedInput", "NO"
        ])
        app.launchEnvironment = ["ARCHIVEPROC_HEADLESS": "1"]
        app.launch(); app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        if app.descendants(matching: .any)["ap.ocr.resumeRun"].waitForExistence(timeout: 2) {
            app.buttons["Dismiss"].firstMatch.click()
        }
        // Enter numeric prices through their real fields. Launch arguments are strings, while
        // GatewayConfig reads stored numeric values; the earlier driver bypasses that distinction.
        app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Reading"))
        for (label, price) in [("Input $/1M tokens", "2"), ("Output $/1M tokens", "10")] {
            let field = app.settingsWindow.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            for _ in 0..<15 where !field.isHittable {
                app.settingsWindow.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -180)
            }
            field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(price)
            field.typeKey(.tab, modifierFlags: [])
        }
        shot("s044-gateway-prices")
        app.settingsWindow.typeKey("w", modifierFlags: .command)
        shot("s044-launched")
        let before = estimateText()
        print("[s044] estimate before names: \(before)")
        XCTAssertTrue(before.contains("$0.0213"), "OCR uses the entered $2/$10 gateway prices")
        XCTAssertFalse(before.contains("Names:"), "unranked Names adds no estimate row")
        XCTAssertTrue(before.contains("$0.0310"))
        shot("s044-before-names")
        app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Collection"))
        let answer = app.buttons["Answer…"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10)); answer.click()
        let save = app.descendants(matching: .any)["ap.collectionInterview.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        let up = app.buttons["Move Names of people and places up"]
        let scroll = app.sheets.scrollViews.firstMatch
        for _ in 0..<15 where !up.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -180) }
        XCTAssertTrue(up.exists && up.isHittable, "the interview offers ranking Names")
        // The arrow can become hittable while the neighbouring number is still clipped by the Form.
        scroll.scroll(byDeltaX: 0, deltaY: -220)
        // The fresh collection inherits the default three priorities. Establish the control in the UI,
        // rather than assuming that the VM's general settings have never changed.
        let namesWeight = app.textFields["ap.collectionInterview.weight.names"]
        XCTAssertTrue(namesWeight.exists)
        XCTAssertEqual(namesWeight.value as? String, "0", "Names starts unranked")
        XCTAssertFalse(app.buttons["Move Names of people and places down"].isEnabled, "Names starts last")
        print("[s044] control: Names last, weight 0")
        // Include names without dropping one of the three existing priorities when it is moved up.
        shot("s044-names-unranked-in-interview")
        XCTAssertTrue(namesWeight.isHittable)
        namesWeight.click(); app.typeKey("a", modifierFlags: .command); app.typeText("10")
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertEqual(namesWeight.value as? String, "10", "the positive weight was entered by hand")
        for _ in 0..<3 where up.isEnabled { up.click() }
        shot("s044-names-first-in-interview")
        save.click()
        XCTAssertTrue(save.waitForNonExistence(timeout: 10))
        app.settingsWindow.typeKey("w", modifierFlags: .command)
        let after = estimateText()
        print("[s044] estimate after names: \(after)")
        let names = try XCTUnwrap(after.firstIndex(of: "Names:"))
        XCTAssertEqual(after.dropFirst(names + 1).first, "$0.0015",
                       "one estimated document × 157/299 × (925 input at $2 and 100 output at $10 per million)")
        XCTAssertTrue(after.contains("$0.0325"), "the standard total includes the names call")
        XCTAssertEqual(after.filter { !["Names:", "$0.0015", "$0.0325"].contains($0) },
                       before.filter { $0 != "$0.0310" }, "ranking Names changes just its row and the total")
        shot("s044-after-names")
        let start = app.descendants(matching: .any)["ap.ocr.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10) && start.isEnabled, "real Start is enabled")
        start.click()
        let review = app.windows.containing(.staticText, identifier: "Document Segmentation Review").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 120), "manual segmentation opens its review")
        shot("s044-segmentation-review")
        app.typeKey(.return, modifierFlags: [])
        let complete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Complete'")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 180), "the real run reaches final review")
        shot("s044-final-review")
        complete.click()
        let deadline = Date().addingTimeInterval(30)
        var entities = 0
        repeat {
            entities = entitySidecars(output)
            if entities > 0 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        let allCalls = try gatewayCalls()
        XCTAssertEqual(Array(allCalls.prefix(initialCalls.count)), initialCalls, "the stand-in stayed up through this run")
        let calls = Array(allCalls.dropFirst(initialCalls.count))
        let kinds = Dictionary(grouping: calls, by: { $0["kind"] ?? "missing" }).mapValues(\.count)
        print("[s044] calls: \(kinds); sidecars with entities: \(entities)")
        XCTAssertEqual(kinds["ocr"], 1); XCTAssertEqual(kinds["tagging"], 1)
        XCTAssertEqual(kinds["names"], 1, "one real gateway names request for the letter")
        XCTAssertEqual(entities, 1, "the names reply reached a sidecar")
        XCTAssertTrue(calls.filter { $0["kind"] == "names" }.allSatisfy { $0["model"] == "s044-priced" })
        print("[s044] CONFIRMED: collection interview → real Start → one names request; estimate includes Names")
    }

    // S-048 (W49.proc-s048-verify, then W49.proc-s048-check on Claude): one add as the control, then the same photo
    // chosen twice and chosen then dropped from Finder. Each repeated row is the one file in its folder, and the
    // loopback gateway receives the same image bytes once per row. No provider can bill this test.
    func testDuplicateRowsSendTheSamePhotoTwice() throws {
        for (method, expected) in [("once", 1), ("picker", 2), ("Finder drop", 2)] {
            let run = scratch.appendingPathComponent("check-\(UUID().uuidString)")
            let input = run.appendingPathComponent("in"), output = run.appendingPathComponent("out")
            for folder in [input, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let photo = input.appendingPathComponent("check-photo.png")
            try makeLetter(at: photo)
            let before = try gatewayCalls().count, imagesBefore = try gatewayImages().count
            app.launchArguments = UITestLaunch.arguments([
                "-APUITestMode", "-APUITestStandInGateway",
                "-APUITestOutputDirectory", output.path, "-outputDirectory", output.path,
                "-useGateway", "YES", "-gatewayLocalModel", "NO", "-useAppleVision", "NO", "-useLocalAgent", "NO",
                "-gatewayBaseURL", "http://127.0.0.1:18472/v1", "-gatewayModelID", "s048-check",
                "-gatewayUpstreamProvider", "Anthropic", "-taggingModeRaw", "none",
                "-enableCollectionSegmentation", "NO", "-rotationModeRaw", "off", "-reviewRotation", "NO",
                "-outputImageFile", "NO", "-mergeDocuments", "NO", "-batchMode", "NO",
                "-sendPreviousImage", "NO", "-useInstitutionalComputeImport", "NO",
                "-skipAlreadyProcessed", "YES", "-preOCRedInput", "NO"
            ])
            app.launchEnvironment = ["ARCHIVEPROC_HEADLESS": "1"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["ap.ocr.dropZone"].waitForExistence(timeout: 15))
            if app.descendants(matching: .any)["ap.ocr.resumeRun"].exists { app.buttons["Dismiss"].firstMatch.click() }
            let rows = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@",
                                                           photo.lastPathComponent, photo.lastPathComponent))
            addThroughPicker(photo)
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
            XCTAssertEqual(rows.count, 1)
            if method == "picker" { addThroughPicker(photo) }
            if method == "Finder drop" { dragFromFinder(photo, to: rows.firstMatch) }
            XCTAssertEqual(rows.count, expected, "rows before Start")
            shot("s048-check-\(expected)-\(method.replacingOccurrences(of: " ", with: "-"))")
            let inputs = try FileManager.default.contentsOfDirectory(atPath: input.path)
            XCTAssertEqual(inputs, [photo.lastPathComponent], "the only file every row can name")
            app.descendants(matching: .any)["ap.ocr.start"].click()
            // A run ends either Done or with catalogue filing stopped; record whichever and its full wording.
            let finished = app.staticTexts.matching(NSPredicate(format:
                "label BEGINSWITH 'Done.' OR value BEGINSWITH 'Done.' OR label BEGINSWITH 'Catalogue filing' OR value BEGINSWITH 'Catalogue filing'"))
            XCTAssertTrue(finished.firstMatch.waitForExistence(timeout: 90), app.debugDescription)
            let status = finished.firstMatch.label.isEmpty ? "\(finished.firstMatch.value ?? "")" : finished.firstMatch.label
            print("[s048-check] \(method): status=\(status)")
            let ocr = try gatewayCalls().dropFirst(before).filter { $0["kind"] == "ocr" }
            let images = Array(try gatewayImages().dropFirst(imagesBefore))
            let pdfs = try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".pdf") }
            print("[s048-check] \(method): rows=\(expected) input=\(photo.path) inputs=\(inputs) ocr=\(ocr.count) "
                  + "distinctImages=\(Set(images).count) images=\(images.map { $0.prefix(12) }) PDFs=\(pdfs)")
            XCTAssertEqual(ocr.count, expected)
            XCTAssertEqual(images.count, expected)
            XCTAssertEqual(Set(images).count, 1, "each OCR request carried the same photo")
            if expected == 1 { XCTAssertEqual(status, "Done. 1 succeeded, 0 failed.") }
            app.terminate()
        }
    }

    private func addThroughPicker(_ photo: URL) {
        app.buttons["Add Files…"].click()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(photo.path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(open.waitForExistence(timeout: 5) && open.isEnabled, app.debugDescription)
        open.click()
        XCTAssertTrue(open.waitForNonExistence(timeout: 10))
    }

    private func dragFromFinder(_ photo: URL, to row: XCUIElement) {
        let main = app.windows.firstMatch
        let rowFrame = row.frame
        let target = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        finder.typeKey("n", modifierFlags: .command)
        let window = finder.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        defer {
            finder.typeKey("w", modifierFlags: .command)
            app.activate()
        }
        finder.typeKey("g", modifierFlags: [.command, .shift])
        finder.typeText(photo.deletingLastPathComponent().path)
        finder.typeKey(.return, modifierFlags: [])
        finder.typeKey("2", modifierFlags: .command)
        let file = window.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR title == %@ OR value == %@",
            photo.lastPathComponent, photo.lastPathComponent, photo.lastPathComponent
        )).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), finder.debugDescription)
        // Keep the filename in reach while exposing the Processor row to its left.
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
        let distance = max(0, rowFrame.midX + 40 - window.frame.minX)
        if distance > 0 {
            title.click(forDuration: 0.2, thenDragTo: title.withOffset(CGVector(dx: distance, dy: 0)))
        }
        print("[s048] Finder file \(file.frame), Finder window \(window.frame), Processor \(main.frame), row \(rowFrame)")
        file.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(forDuration: 0.2, thenDragTo: target)
    }

    private func makeLetter(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 600, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 400)).fill()
        "12 March 1918\nDear friend,\nAda Lovelace".draw(at: NSPoint(x: 40, y: 100),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func gatewayCalls() throws -> [[String: String]] {
        try XCTUnwrap(try gatewayJSON("calls") as? [[String: String]])
    }

    private func gatewayImages() throws -> [String] {
        try XCTUnwrap(try gatewayJSON("images") as? [String])
    }

    private func gatewayJSON(_ path: String) throws -> Any {
        let request = URLRequest(url: URL(string: "http://127.0.0.1:18472/\(path)")!, timeoutInterval: 5)
        let reply = S044GatewayReply(), done = expectation(description: "guest loopback gateway answers")
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            reply.store(data, response); done.fulfill()
        }
        task.resume()
        guard XCTWaiter.wait(for: [done], timeout: 6) == .completed else {
            task.cancel(); throw URLError(.timedOut)
        }
        let (data, response) = reply.read()
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONSerialization.jsonObject(with: XCTUnwrap(data))
    }

    private func estimateText() -> [String] {
        XCTAssertTrue(app.staticTexts["Cost Estimate"].waitForExistence(timeout: 10))
        let all = app.staticTexts.allElementsBoundByIndex.map { ($0.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? $0.label }
        guard let start = all.firstIndex(of: "Cost Estimate"),
              let end = all[start...].firstIndex(where: { $0.hasPrefix("Estimates based on user-provided pricing") }) else {
            print(app.debugDescription); XCTFail("priced Cost Estimate rows missing"); return []
        }
        let texts = Array(all[start...end])
        XCTAssertTrue(texts.contains(where: { $0.contains("$") }), "the check must see dollar figures, not unknown pricing")
        return texts
    }

    private func entitySidecars(_ output: URL) -> Int {
        let files = FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)
        return (files?.allObjects as? [URL] ?? []).filter { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return json["entities"] != nil
        }.count
    }

    private func shot(_ name: String) {
        let screenshot = app.screenshot(), path = scratch.appendingPathComponent("\(name).png")
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        if (try? screenshot.pngRepresentation.write(to: path)) != nil { print("[shot] \(name): wrote \(path.path)") }
    }
}

/// URLSession calls back off the UI thread; the lock protects the reply across that boundary.
private final class S044GatewayReply: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var response: URLResponse?
    func store(_ data: Data?, _ response: URLResponse?) {
        lock.lock(); defer { lock.unlock() }
        self.data = data; self.response = response
    }
    func read() -> (Data?, URLResponse?) {
        lock.lock(); defer { lock.unlock() }
        return (data, response)
    }
}
