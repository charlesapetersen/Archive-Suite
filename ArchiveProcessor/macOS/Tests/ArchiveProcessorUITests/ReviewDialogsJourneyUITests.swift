import PDFKit
import XCTest

// W40.d2 — the Processor's review dialogs driven by hand. The real Process Files window, the real Start, and every
// review the run opens answered with choices that differ from what was proposed, by the keys and clicks a user has;
// then the output is read back to see that it carries those choices and not the proposals.
//
// The reader is a stand-in `claude` CLI on the Local Agent backend (`scripts/fake_local_agent.py`): no key, no money,
// and it proposes the same thing for every photo (New Document, upright), so every difference in the output is the
// test's hand. Apple Vision cannot read in the VM guest (W40.d1), and it could not open these dialogs anyway.
//
// Run A, Automatic tagging with the Manual approach: the Review rotation pass (photo 3 turned 90°), the per-page
// segmentation review (photos 1-2 Box, photo 4 Continuation, photo 5 removed, by keys), the box/folder confirmation
// (photo 2 turned to Folder), and Complete. Run B, Manual tagging (Segment & Tag): photo 1 Box, photo 2 Folder,
// photos 3-4 one document tagged by typing a date, a subject and a quality, photo 5 removed, photo 6 a second
// document with its own date and subject. Rotation is off in B, so its photo 3 is A's photo 3 unturned.
//
// It runs only in `PROCESSOR_JOURNEY=reviews ops/gui/vm-gui-runner.sh processor xcuitest`
// (`ArchiveProcessor/scripts/journey-review-dialogs.sh`), which copies six photos of a rehearsal box into
// TEST_RUNNER_W40D2_DIR/in and the stand-in CLI beside them. Every other run skips it.
@MainActor
final class ReviewDialogsJourneyUITests: XCTestCase {
    private var app: XCUIApplication!
    private var scratchRoot: URL!
    private var dir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        guard let path = ProcessInfo.processInfo.environment["W40D2_DIR"], !path.isEmpty else {
            throw XCTSkip("W40.d2 journey: runs only under PROCESSOR_JOURNEY=reviews")
        }
        dir = URL(fileURLWithPath: path, isDirectory: true)
        // The runner is sandboxed: the output goes where it can read it back; the app is not, and writes there.
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("w40d2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testReviewDialogsByHand() throws {
        let a = try runA()
        let b = try runB()

        // Photo 3 was turned 90° by hand in A and left in B (rotation off): its page 1 is the other way round.
        let a3 = try XCTUnwrap(a[3], "run A wrote photo 3"), b3 = try XCTUnwrap(b[3], "run B wrote photo 3")
        print("[w40d2] photo 3 page 1: A \(a3.size) rot \(a3.rotation), B \(b3.size) rot \(b3.rotation)")
        XCTAssertNotEqual(a3.portrait, b3.portrait, "the 90° chosen in Review rotation is baked into photo 3's PDF")
    }

    // MARK: Run A — rotation review, per-page segmentation review, box/folder confirmation, Complete

    private func runA() throws -> [Int: Output] {
        let out = try launch("a", [
            "-taggingModeRaw", "automatic", "-segmentationApproach", "manual",
            "-rotationModeRaw", "localVision", "-reviewRotation", "YES"
        ])
        clickStart()

        // Review rotation: every photo proposed upright; photo 3 turned 90° by its radio.
        let rotation = reviewWindow("Review Rotation", timeout: 300)
        shrinkThumbnails(in: rotation)
        let turn = rotation.buttons.matching(NSPredicate(format: "label == '90°'"))
        guard turn.count >= 3 else { dump(rotation, "no 90° radio for photo 3"); return [:] }
        turn.element(boundBy: 2).click()
        shot("w40d2-a-rotation-chosen")
        rotation.buttons["Confirm"].click()

        // Per-page segmentation review, by keys from the first row: 3 Box, ↓ 3 Box, ↓ (New Document), ↓ 2
        // Continuation, ↓ X remove, ↓ (New Document), Return confirms.
        let review = reviewWindow("Document Segmentation Review", timeout: 120)
        shrinkThumbnails(in: review)
        review.staticTexts["Document Segmentation Review"].click()   // the window is key; the list has focus
        for key in ["3", .downArrow, "3", .downArrow, .downArrow, "2", .downArrow, "x"] as [KeyOrChar] {
            key.type(on: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        shot("w40d2-a-segmentation-chosen")
        XCTAssertTrue(review.buttons.matching(NSPredicate(format: "label == '3 Box'")).count >= 2, "the rows are drawn")
        app.typeKey(.return, modifierFlags: [])

        // Box/folder confirmation: both labels arrive as Box; the second is turned to Folder.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 60), "the box/folder confirmation opens after the review")
        let folders = sheet.radioButtons.matching(NSPredicate(format: "label == 'Folder' OR title == 'Folder'"))
        guard folders.count == 2 else { dump(sheet, "expected two rows with a Folder radio, found \(folders.count)"); return [:] }
        folders.element(boundBy: 1).click()
        shot("w40d2-a-boxfolder-chosen")
        sheet.buttons["Confirm"].click()

        // Automatic tagging, then the final review in the main window: Complete.
        let complete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Complete'")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 300), "the final review offers Complete")
        shot("w40d2-a-final-review")
        complete.click()
        waitForDone("a")

        let files = outputs(in: out)
        report("a", files)
        XCTAssertEqual(files.count, 5, "five PDFs: photo 5 was removed in the review")
        XCTAssertNil(files[5], "photo 5, removed by hand, has no output")
        XCTAssertEqual(files[1]?.classification, "Box")
        XCTAssertEqual(files[2]?.classification, "Folder", "the confirmation's answer, not the review's Box")
        XCTAssertEqual(files[3]?.classification, "Document Start")
        XCTAssertEqual(files[4]?.classification, "Continuation", "the 2 pressed in the review")
        XCTAssertEqual(files[6]?.classification, "Document Start")
        XCTAssertTrue(files[1]?.tags.contains("Box") == true, "photo 1 carries the Box item type")
        XCTAssertTrue(files[2]?.tags.contains("Folder") == true, "photo 2 carries the Folder item type")
        XCTAssertFalse(files[2]?.tags.contains("Box") == true, "and not Box")
        XCTAssertTrue(files[3]?.tags.contains("1918") == true, "photo 3's document is tagged")
        return files
    }

    // MARK: Run B — Segment & Tag, typed by hand

    private func runB() throws -> [Int: Output] {
        let out = try launch("b", [
            "-taggingModeRaw", "human", "-segmentationApproach", "manual",
            "-rotationModeRaw", "off", "-reviewRotation", "NO"
        ])
        clickStart()

        let window = reviewWindow("Segment & Tag", timeout: 300)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).click()   // the canvas takes the keys
        for key in ["b", .rightArrow, "f", .rightArrow, .rightArrow] as [KeyOrChar] {
            key.type(on: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        shot("w40d2-b-marked")
        app.typeKey(.return, modifierFlags: [])   // end the document at photo 4: photos 3-4
        fillCard(in: window, date: "12 March 1917", subject: "Signal Corps", quality: "2 — Q2", name: "b-card-1")

        // Back on the canvas at photo 5: remove it, then photo 6 is a document of its own.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).click()
        for key in ["x", .rightArrow] as [KeyOrChar] {
            key.type(on: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        app.typeKey(.return, modifierFlags: [])
        fillCard(in: window, date: "1919", subject: "Aviation", quality: nil, name: "b-card-2")

        let finish = window.buttons["Finish ▸"]
        if finish.exists, finish.isEnabled { finish.click() }
        waitForDone("b")

        let files = outputs(in: out)
        report("b", files)
        XCTAssertEqual(files.count, 5, "five PDFs: photo 5 was removed on the canvas")
        XCTAssertNil(files[5], "photo 5, removed by hand, has no output")
        XCTAssertEqual(files[1]?.classification, "Box")
        XCTAssertEqual(files[2]?.classification, "Folder")
        XCTAssertEqual(files[3]?.classification, "Document Start")
        XCTAssertEqual(files[4]?.classification, "Continuation", "photos 3-4 are one document")
        XCTAssertEqual(files[6]?.classification, "Document Start")
        for n in [3, 4] {
            let tags = files[n]?.tags ?? []
            for want in ["1917", "March", "12", "Signal Corps", "Q2"] {
                XCTAssertTrue(tags.contains(want), "photo \(n) carries the typed \(want): \(tags)")
            }
            XCTAssertFalse(tags.contains("1918"), "photo \(n): the proposal never reached a manual document")
        }
        let six = files[6]?.tags ?? []
        XCTAssertTrue(six.contains("1919") && six.contains("Aviation"), "photo 6 carries its own typed tags: \(six)")
        XCTAssertFalse(six.contains("1917") || six.contains("Signal Corps"), "and not the first document's: \(six)")
        XCTAssertTrue(files[1]?.tags.contains("Box") == true && files[2]?.tags.contains("Folder") == true)
        return files
    }

    private func fillCard(in window: XCUIElement, date: String, subject: String, quality: String?, name: String) {
        let save = window.buttons["Save ▸"]
        XCTAssertTrue(save.waitForExistence(timeout: 30), "the tag card opens")
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // let the card settle and focus its date field
        let dateField = window.textFields["ap.date.own"]
        XCTAssertTrue(dateField.exists, "the card's Date field")
        dateField.click()
        dateField.typeKey("a", modifierFlags: .command)
        dateField.typeText(date)
        let subjects = window.textFields.matching(NSPredicate(format: "placeholderValue == 'Add subject…'")).firstMatch
        guard subjects.exists else { dump(window, "no subject field on the card"); return }
        subjects.click()
        subjects.typeText(subject)
        subjects.typeKey(.return, modifierFlags: [])   // adds the subject; a second Return would save
        if let quality {
            let picker = window.popUpButtons.matching(NSPredicate(
                format: "label == 'Quality' OR value CONTAINS 'Unrated' OR value BEGINSWITH '0 '")).firstMatch
            guard picker.exists else { dump(window, "no Quality picker on the card"); return }
            picker.click()
            let item = app.menuItems[quality]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Quality option \(quality)")
            item.click()
        }
        shot("w40d2-\(name)-filled")
        XCTAssertTrue(save.isEnabled, "Save is enabled once the date reads")
        save.click()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)
        _ = XCTWaiter.wait(for: [gone], timeout: 10)
    }

    // MARK: Launch and waiting

    private func launch(_ name: String, _ settings: [String]) throws -> URL {
        let out = scratchRoot.appendingPathComponent("\(name)-out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        app.terminate()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode", "-APUITestLocalAgent",
            "-APUITestInputImages", dir.appendingPathComponent("in").path,
            "-APUITestOutputDirectory", out.path, "-outputDirectory", out.path,
            "-localAgentBinaryPath", dir.appendingPathComponent("fake_local_agent.py").path,
            "-useAppleVision", "NO", "-useGateway", "NO", "-batchMode", "NO",
            "-mergeDocuments", "NO", "-enableCollectionSegmentation", "NO", "-enableSegmentJSON", "YES",
            "-tagVocabulary", ""
        ] + settings)
        app.launchEnvironment = [
            "ARCHIVEPROC_HEADLESS": "1",   // keychain quiet; the window still draws
            "FAKE_AGENT_LOG": scratchRoot.appendingPathComponent("\(name)-agent.log").path
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the Processor window must appear")
        print("[w40d2] run \(name) launched; out=\(out.path)")
        return out
    }

    private func clickStart() {
        let start = app.descendants(matching: .any)["ap.ocr.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 30), "Start")
        let deadline = Date().addingTimeInterval(30)
        while !start.isEnabled, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        if !start.isEnabled {
            let why = app.descendants(matching: .any)["ap.ocr.startBlockedReason"]
            shot("w40d2-start-disabled")
            XCTFail("Start stays disabled: \(why.exists ? why.label : "(no reason shown)")")
        }
        shot("w40d2-before-start")
        start.click()
    }

    /// The review windows are bare windows titled like the main one; find the one showing `heading`.
    private func reviewWindow(_ heading: String, timeout: TimeInterval) -> XCUIElement {
        let window = app.windows.containing(.staticText, identifier: heading).firstMatch
        let byLabel = app.windows.containing(NSPredicate(format: "label == %@ OR value == %@", heading, heading)).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if window.exists { break }
            if byLabel.exists { shot("w40d2-\(slug(heading))"); return byLabel }
            if app.sheets.firstMatch.exists, app.sheets.buttons["Retry"].exists || app.staticTexts["Some files failed"].exists {
                dump(app.sheets.firstMatch, "a failure sheet opened instead of \(heading)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if !window.exists { shot("w40d2-missing-\(slug(heading))"); XCTFail("the \(heading) window must open") }
        shot("w40d2-\(slug(heading))")
        return window
    }

    private func shrinkThumbnails(in window: XCUIElement) {
        let slider = window.sliders.firstMatch
        if slider.exists { slider.adjust(toNormalizedSliderPosition: 0) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    private func waitForDone(_ name: String) {
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Done.' OR value BEGINSWITH 'Done.'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 300), "run \(name) ends with Done.")
        let text = (done.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? done.label
        print("[w40d2] run \(name): \(text)")
        shot("w40d2-\(name)-done")
        let log = (try? String(contentsOf: scratchRoot.appendingPathComponent("\(name)-agent.log"), encoding: .utf8)) ?? ""
        let kinds = Dictionary(grouping: log.split(separator: "\n"), by: { $0.split(separator: "\t").first.map(String.init) ?? "" })
        print("[w40d2] run \(name) stand-in calls: \(kinds.mapValues(\.count).sorted { $0.key < $1.key })")
    }

    // MARK: Output

    struct Output {
        let pdf: URL
        let classification: String
        let tags: [String]
        let size: CGSize
        let rotation: Int
        var portrait: Bool { (rotation % 180 == 0) == (size.height > size.width) }
    }

    /// Every PDF the run wrote, keyed by its photo's place in the input (1-6), read from the page-2 source line.
    private func outputs(in out: URL) -> [Int: Output] {
        var result: [Int: Output] = [:]
        let e = FileManager.default.enumerator(at: out, includingPropertiesForKeys: nil)
        let pdfs = (e?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension.lowercased() == "pdf" }
        let names = (ProcessInfo.processInfo.environment["W40D2_PHOTOS"] ?? "").components(separatedBy: "|")
        for pdf in pdfs {
            guard let doc = PDFDocument(url: pdf), doc.pageCount == 2, let page1 = doc.page(at: 0),
                  let text = doc.page(at: 1)?.string?.replacingOccurrences(of: "\u{00A0}", with: " ") else {
                XCTFail("\(pdf.lastPathComponent) is not a readable two-page PDF")
                continue
            }
            guard let n = names.firstIndex(where: { !$0.isEmpty && text.contains($0) }) else {
                XCTFail("\(pdf.lastPathComponent): page 2 names none of the input photos")
                continue
            }
            let cls = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("Classification:") }
                .map { $0.dropFirst("Classification:".count).trimmingCharacters(in: .whitespaces) } ?? "(none)"
            let box = page1.bounds(for: .mediaBox)
            XCTAssertNil(result[n + 1], "photo \(n + 1) has one output")
            result[n + 1] = Output(pdf: pdf, classification: cls, tags: finderTags(of: pdf), size: box.size,
                                   rotation: page1.rotation)
        }
        return result
    }

    private func report(_ name: String, _ files: [Int: Output]) {
        for n in files.keys.sorted() {
            let f = files[n]!
            print("[w40d2] run \(name) photo \(n): \(f.pdf.lastPathComponent) | \(f.classification) | tags \(f.tags) | "
                  + "page 1 \(Int(f.size.width))x\(Int(f.size.height)) rot \(f.rotation)")
        }
    }

    /// The Finder tag names, read from the raw xattr (SPEC/tag-format.md: a binary-plist array of "name\n<colour>").
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

    // MARK: Evidence

    private func dump(_ element: XCUIElement, _ why: String) {
        shot("w40d2-fail-\(slug(why))")
        print("[w40d2] \(why); tree:\n\(element.debugDescription)")
        XCTFail(why)
    }

    private func slug(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
    }

    private func shot(_ name: String) {
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

/// A key the journey presses: a character, or one of the arrow keys.
private enum KeyOrChar: ExpressibleByStringLiteral {
    case char(String)
    case key(XCUIKeyboardKey)
    static let downArrow = KeyOrChar.key(.downArrow)
    static let rightArrow = KeyOrChar.key(.rightArrow)
    init(stringLiteral value: String) { self = .char(value) }
    @MainActor func type(on app: XCUIApplication) {
        switch self {
        case .char(let c): app.typeKey(c, modifierFlags: [])
        case .key(let k): app.typeKey(k, modifierFlags: [])
        }
    }
}
