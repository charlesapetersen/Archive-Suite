import XCTest

// W40.d5 — live capture with hand-driven review. The phone side is the real Android companion on a headless
// AVD on the host, driven by `scripts/live-capture-journey-phone.sh`, which injects real Dean Papers photos
// from `Test Files` through the debug inject seam and pairs over LAN to the app this test launches in the VM
// (through `scripts/tcp-relay.py`). This side does what an operator does: the tag cards and Finish, by hand,
// with no LIVECAPTURE_AUTOSKIPTAGS / LIVECAPTURE_AUTOFINALIZE.
//
// It runs only in `PROCESSOR_JOURNEY=livecapture ops/gui/vm-gui-runner.sh processor xcuitest`, which passes
// TEST_RUNNER_W40D5_DIR (a guest directory where the app writes each phase's READY line for the phone leg).
// Every other run skips it, because nothing else starts a phone. Apple Vision OCR, so no key and no money.
//
// Three phases, in this order, each a fresh app launch the phone leg pairs to:
//   live  — 3 photos: card 1 saved with a subject, year and quality; card 2 skipped; card 3 saved with a
//           second subject. Finish, name the collection, finalize. Then the PDFs' Finder tags are decoded and
//           the originals must have left the session folder (moved to the Trash) only with their output there.
//   fail  — 2 photos, the output folder made read-only before finalize: nothing can be filed, so every
//           original must still be in the session folder afterwards.
//   stage — 2 photos with Stage for later: "Process N →" must hand them to Process Files.
@MainActor
final class LiveCaptureJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!
    private var phaseDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        guard let dir = ProcessInfo.processInfo.environment["W40D5_DIR"], !dir.isEmpty else {
            throw XCTSkip("W40.d5 journey: runs only under PROCESSOR_JOURNEY=livecapture (needs the phone leg)")
        }
        phaseDir = URL(fileURLWithPath: dir, isDirectory: true)
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-processor-w40d5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        // The host reads this line from the xcuitest log to collect the run's files for the evidence.
        print("[w40d5] scratch=\(scratchRoot.path)")
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testLiveCaptureByHand() throws {
        try livePhase()
        try failPhase()
        try stagePhase()
    }

    // MARK: Phases

    private func livePhase() throws {
        let (out, backup) = try launchPhase("live", mode: "live")
        // Printed first so the host's file record works even when an assertion below stops the test.
        print("[w40d5] live out=\(out.path) backup=\(backup.path)")
        try handCards([
            .save(subject: "W40d5 Dean Alpha", year: "1973", quality: "2 — Q2"),
            .skip,
            .save(subject: "W40d5 Dean Bravo", year: nil, quality: nil)
        ])
        try finishAndFinalize(staged: 3, collection: "W40d5 Dean live")

        let pdfs = waitForPDFs(in: out, count: 3, timeout: 120)
        XCTAssertEqual(pdfs.count, 3, "three captured photos must file three PDFs; found \(pdfs.map(\.lastPathComponent))")
        var report: [String] = []
        for pdf in pdfs {
            let tags = finderTags(of: pdf)
            report.append("\(pdf.lastPathComponent): \(tags)")
        }
        print("[w40d5] live tags:\n" + report.joined(separator: "\n"))
        let tagSets = pdfs.map { Set(finderTags(of: $0).map { $0.lowercased() }) }
        let alpha = tagSets.filter { $0.contains("w40d5 dean alpha") }
        let bravo = tagSets.filter { $0.contains("w40d5 dean bravo") }
        XCTAssertEqual(alpha.count, 1, "exactly one PDF carries card 1's subject: \(report)")
        XCTAssertEqual(bravo.count, 1, "exactly one PDF carries card 3's subject: \(report)")
        if let a = alpha.first {
            XCTAssertTrue(a.contains("1973"), "card 1's typed year is a Year tag: \(a)")
            XCTAssertTrue(a.contains("q2"), "card 1's quality is the Q2 tag: \(a)")
        }
        XCTAssertEqual(tagSets.filter { !$0.contains("w40d5 dean alpha") && !$0.contains("w40d5 dean bravo") }.count, 1,
                       "the skipped card's PDF carries neither typed subject: \(report)")

        // Originals: gone from the session folder once their output is filed (CaptureSession.clearFiled →
        // trashOrRemove). The host checks the Trash and the timestamps from outside the sandbox.
        let remaining = originals(under: backup)
        XCTAssertTrue(remaining.isEmpty, "every filed original must have left the session folder: \(remaining)")
        attachScreenshot("w40d5-live-finalized")
    }

    private func failPhase() throws {
        let (out, backup) = try launchPhase("fail", mode: "live")
        try handCards([.skip, .skip])
        // Read-only output folder: the file move must fail, and nothing may be trashed for a group that did
        // not land.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: out.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path) }
        let before = originals(under: backup)
        XCTAssertEqual(before.count, 2, "both captured originals are in the session folder before finalize: \(before)")
        try finishAndFinalize(staged: 2, collection: "W40d5 Dean fail")
        // Give finalize the same time the live phase needed to move files and trash originals.
        RunLoop.current.run(until: Date().addingTimeInterval(15))
        attachScreenshot("w40d5-fail-finalized")
        let after = originals(under: backup)
        print("[w40d5] fail out=\(out.path) backup=\(backup.path) originals-after=\(after.map(\.lastPathComponent))")
        XCTAssertEqual(Set(after.map(\.lastPathComponent)), Set(before.map(\.lastPathComponent)),
                       "an unwritable output folder must leave every original in place")
        let outContents = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertTrue(outContents.isEmpty, "nothing can have been written to the read-only output: \(outContents)")
    }

    private func stagePhase() throws {
        _ = try launchPhase("stage", mode: "stage")
        let process = app.buttons["Process 2 →"]
        let deadline = Date().addingTimeInterval(900)
        while !process.exists, Date() < deadline {
            if app.buttons["Skip"].exists { app.buttons["Skip"].click() }   // a stage session may still ask
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(process.exists, "both staged photos must reach the Mac and offer Process 2 →")
        attachScreenshot("w40d5-stage-before-handoff")
        process.click()
        XCTAssertTrue(element("ap.ocr.appleVisionCost").waitForExistence(timeout: 20),
                      "Process Files must receive the staged photos (the Apple Vision cost line needs input files)")
        XCTAssertFalse(element("ap.ocr.dropZone").exists, "the drop zone is replaced once files are loaded")
        attachScreenshot("w40d5-stage-handoff")
    }

    // MARK: Driving

    private enum Card {
        case save(subject: String, year: String?, quality: String?)
        case skip
    }

    /// Launch one phase: fresh scratch output + session folder, the LAN receiver started, and the READY line
    /// written where the phone leg waits for it.
    private func launchPhase(_ name: String, mode: String) throws -> (out: URL, backup: URL) {
        let root = scratchRoot.appendingPathComponent(name, isDirectory: true)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        let inDir = root.appendingPathComponent("IN", isDirectory: true)
        for dir in [out, backup, inDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        app.terminate()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode",
            "-APUITestInputDirectory", inDir.path,
            "-APUITestOutputDirectory", out.path,
            "-liveProcessingMode", mode,
            "-useAppleVision", "YES", "-visionUseLLMJudgment", "NO",
            "-useGateway", "NO", "-useLocalAgent", "NO",
            "-rotationModeRaw", "off", "-reviewRotation", "NO", "-mergeDocuments", "NO",
            "-tagVocabulary", "", "-outputDirectory", out.path
        ])
        app.launchEnvironment = [
            "ARCHIVEPROC_HEADLESS": "1",          // keychain quiet (KeychainHelper); the window still draws
            "ARCHIVEPROC_TEST_BACKUP_ROOT": backup.path,
            "LIVECAPTURE_AUTOSTART": "1",
            "LIVECAPTURE_TRANSPORT": "lan",
            "LIVECAPTURE_READYFILE": phaseDir.appendingPathComponent("ready-\(name).txt").path,
            "LIVECAPTURE_TESTOUT": out.path
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the Processor window must appear")
        print("[w40d5] phase \(name) launched; waiting for the phone")
        return (out, backup)
    }

    private func handCards(_ cards: [Card]) throws {
        for (i, card) in cards.enumerated() {
            let save = app.buttons["Save ▸"]
            // The first card waits on the phone leg's AVD boot, APK build and pairing.
            XCTAssertTrue(save.waitForExistence(timeout: i == 0 ? 1500 : 300), "tag card \(i + 1) must appear")
            RunLoop.current.run(until: Date().addingTimeInterval(1))   // let the sheet settle and focus
            switch card {
            case .skip:
                app.buttons["Skip"].click()
            case let .save(subject, year, quality):
                // The subjects field takes focus on appear; ⏎ on a typed subject adds it as a chip.
                app.typeText(subject)
                app.typeKey(.return, modifierFlags: [])
                if let year {
                    let field = app.textFields["YYYY"]
                    XCTAssertTrue(field.exists, "the card's Year field")
                    field.click()
                    field.typeKey("a", modifierFlags: .command)
                    field.typeText(year)
                }
                if let quality {
                    let picker = app.popUpButtons["Quality"]
                    XCTAssertTrue(picker.exists, "the card's Quality picker")
                    picker.click()
                    let item = app.menuItems[quality]
                    XCTAssertTrue(item.waitForExistence(timeout: 5), "Quality option \(quality)")
                    item.click()
                }
                attachScreenshot("w40d5-card-\(i + 1)-filled")
                save.click()
            }
            // Wait for this card to go; the next one may already be queued behind it.
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
            _ = XCTWaiter.wait(for: [gone], timeout: 5)
        }
    }

    private func finishAndFinalize(staged: Int, collection: String) throws {
        let finish = element("live.finish")
        XCTAssertTrue(finish.waitForExistence(timeout: 60), "Finish appears once photos are in")
        // Wait until every segment is processed (Apple Vision) and staged, so the sheet lists all of them.
        let deadline = Date().addingTimeInterval(600)
        while !(finish.label.contains("(\(staged))") && finish.isEnabled), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTAssertTrue(finish.label.contains("(\(staged))"), "all \(staged) segments staged before Finish: '\(finish.label)'")
        finish.click()
        let finalize = app.buttons["Finalize & move files"]
        XCTAssertTrue(finalize.waitForExistence(timeout: 60), "Finish opens the collection finalize sheet")
        let name = app.textFields["Collection name"]
        if name.exists {
            name.click()
            name.typeKey("a", modifierFlags: .command)
            name.typeText(collection)
        }
        attachScreenshot("w40d5-finalize-sheet-\(staged)")
        XCTAssertTrue(finalize.isEnabled, "Finalize is enabled once the collection has a name")
        finalize.click()
    }

    // MARK: Files

    private func waitForPDFs(in dir: URL, count: Int, timeout: TimeInterval) -> [URL] {
        let deadline = Date().addingTimeInterval(timeout)
        var found: [URL] = []
        repeat {
            found = pdfs(under: dir)
            if found.count >= count { break }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while Date() < deadline
        return found
    }

    private func pdfs(under dir: URL) -> [URL] {
        files(under: dir).filter { $0.pathExtension.lowercased() == "pdf" }
    }

    private func originals(under dir: URL) -> [URL] {
        files(under: dir).filter { ["jpg", "jpeg", "heic", "png"].contains($0.pathExtension.lowercased()) }
    }

    private func files(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }.sorted { $0.path < $1.path }
    }

    /// The Finder tag names, read from the raw xattr (SPEC/tag-format.md: a binary-plist array of
    /// "name\n<colour>" strings).
    private func finderTags(of url: URL) -> [String] {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list.map { $0.components(separatedBy: "\n").first ?? $0 }
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func attachScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = scratchRoot.appendingPathComponent("\(name).png")
        if (try? screenshot.pngRepresentation.write(to: path, options: .atomic)) != nil {
            print("[shot] \(name): wrote \(path.path)")
        }
    }
}
