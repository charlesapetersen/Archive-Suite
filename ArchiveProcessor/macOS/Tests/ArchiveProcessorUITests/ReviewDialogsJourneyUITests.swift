import AppKit
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
// Run A, Automatic tagging with the Manual approach: the Review rotation pass (photo 3 turned 90°) and the per-page
// segmentation review (photos 1-2 Box, photo 4 Continuation, photo 5 removed), both by their keys as the window opens,
// after a row click and after a radio click (W40.fix-processor-review-keys), the box/folder confirmation
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

    /// Page 2's Classification against the choices made: the reviews' answers reach page 2 as well as the tags
    /// (W40.fix-processor-review-classification-stale; this journey found page 2 keeping the reader's proposal).
    private func expectClassifications(_ files: [Int: Output], _ want: [Int: String], run: String) {
        let wrong = want.keys.sorted().filter { files[$0]?.classification != want[$0] }
        guard !wrong.isEmpty else { return }
        print("[w40d2] run \(run) page-2 Classification differs from the choice for photos \(wrong): "
              + wrong.map { "\($0) is '\(files[$0]?.classification ?? "-")', chose '\(want[$0]!)'" }.joined(separator: "; "))
        for n in wrong { XCTAssertEqual(files[n]?.classification, want[n], "photo \(n)'s page 2 Classification") }
    }

    func testReviewDialogsByHand() throws {
        let a = try runA()
        let b = try runB()

        // Photo 3 was turned 90° by hand in A and left in B (rotation off): its page 1 is the other way round.
        let a3 = try XCTUnwrap(a[3], "run A wrote photo 3"), b3 = try XCTUnwrap(b[3], "run B wrote photo 3")
        // Every page 1 is the same Letter page, so it is the photo inside it that turns: its drawn shape.
        print("[w40d2] photo 3 page 1 image: A \(a3.imageShape), B \(b3.imageShape)")
        let shapeA = a3.imageShape.split(separator: " ").first, shapeB = b3.imageShape.split(separator: " ").first
        XCTAssertNotEqual(shapeA, "unknown")
        XCTAssertNotEqual(shapeA, shapeB, "the 90° chosen in Review rotation is baked into photo 3's PDF")
    }

    /// S-046: compare fresh runs after changing the actual Documents setting. Run off last to restore its default.
    func testFreshProcessFilesDocumentReviewSetting() throws {
        for enabled in [true, false] {
            let name = enabled ? "s046-on" : "s046-off"
            _ = try launch(name, [
                "-taggingModeRaw", "automatic", "-segmentationApproach", "manual",
                "-rotationModeRaw", "off", "-reviewRotation", "NO"
            ], collectionID: true)
            let (settings, label, toggle) = try documentReviewSetting()
            setDocumentReview(toggle, enabled: enabled)
            let target = enabled ? "1" : "0"
            print("[s046] \(name): switch value=\(target)")
            if enabled {
                let help = try XCTUnwrap(settings.buttons.matching(NSPredicate(format: "label == 'Help'"))
                    .allElementsBoundByIndex.first { abs($0.frame.midY - label.frame.midY) < 3 })
                help.click()
                let promise = app.staticTexts.matching(NSPredicate(
                    format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Pause after OCR", "Pause after OCR"
                )).firstMatch
                XCTAssertTrue(promise.waitForExistence(timeout: 5))
                print("[s046] help: \(text(of: promise))")
                shot("s046-help-on")
                help.click()
            } else {
                shot("s046-setting-off")
            }
            settings.typeKey("w", modifierFlags: .command)
            clickStart()

            let review = reviewWindow("Document Segmentation Review", timeout: 120)
            let footer = review.staticTexts.matching(NSPredicate(
                format: "label CONTAINS 'new document' OR value CONTAINS 'new document'")).firstMatch
            XCTAssertTrue(text(of: footer).contains("6 new documents"), "whole-run per-page review")
            shot("\(name)-whole-run")
            // Make the first page a box so the subsequent label confirmation is exercised too.
            press(["3"], footer, reads: "1 box", "mark first page Box")
            app.typeKey(.return, modifierFlags: [])
            waitGone(review, "Return confirms the whole-run review")

            let boxConfirmation = app.sheets.buttons["Confirm"]
            XCTAssertTrue(boxConfirmation.waitForExistence(timeout: 60))
            shot("\(name)-box-folder")
            boxConfirmation.click()

            let complete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Complete'")).firstMatch
            XCTAssertTrue(complete.waitForExistence(timeout: 120))
            shot("\(name)-final-review")
            complete.click()

            let organize = app.sheets.buttons["Confirm and Organize"]
            XCTAssertTrue(organize.waitForExistence(timeout: 60))
            shot("\(name)-collection-names")
            organize.click()

            let done = app.staticTexts.matching(NSPredicate(
                format: "label BEGINSWITH 'Done.' OR value BEGINSWITH 'Done.'")).firstMatch
            let secondReview = app.windows.containing(.staticText, identifier: "Document Segmentation Review").firstMatch
            let deadline = Date().addingTimeInterval(60)
            while !done.exists && !secondReview.exists && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            let sawCollectionReview = secondReview.exists
            if sawCollectionReview {
                shot("\(name)-per-collection")
                app.typeKey(.return, modifierFlags: [])
            }
            print("[s046] \(name): whole-run per-page, box/folder, final tagging, collection names, per-collection=\(sawCollectionReview)")
            waitForDone(name)
        }
    }

    /// S-050: quit with real OCR results saved, relaunch, click Resume Run, and record the gates that open.
    func testOrdinaryResumeReviewGates() throws {
        for enabled in [true, false] {
            let name = enabled ? "s050-review-on" : "s050-review-off"
            let arguments = [
                "-taggingModeRaw", "automatic", "-segmentationApproach", "manual",
                "-rotationModeRaw", "off", "-reviewRotation", "NO", "-preOCRedInput", "NO"
            ]
            _ = try launch(name, arguments, collectionID: true, classificationCycle: true)
            let (settings, _, toggle) = try documentReviewSetting()
            // Exercise an actual settings change, including explicitly turning the review off.
            setDocumentReview(toggle, enabled: !enabled)
            setDocumentReview(toggle, enabled: enabled)
            shot("\(name)-saved-setting")
            settings.typeKey("w", modifierFlags: .command)
            clickStart()

            let firstReview = reviewWindow("Document Segmentation Review", timeout: 120)
            let counts = firstReview.staticTexts.matching(NSPredicate(
                format: "label CONTAINS '1 box' OR value CONTAINS '1 box'")).firstMatch
            XCTAssertTrue(text(of: counts).contains("1 folder"), "the saved OCR must include both label candidates")
            shot("\(name)-before-interruption")
            XCTAssertEqual(try ocrCallCount(name), 6)

            // Terminate while the first review is still open, without answering it. The second launch
            // leaves the app's own recovery record in place and uses the regular Resume Run button.
            _ = try launch(name, arguments, collectionID: true, classificationCycle: true, preservePendingRun: true)
            let resume = app.descendants(matching: .any)["ap.ocr.resumeRun"]
            XCTAssertTrue(resume.waitForExistence(timeout: 20) && resume.isEnabled)
            let saved = app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS '6/6 files completed' OR value CONTAINS '6/6 files completed'")).firstMatch
            XCTAssertTrue(saved.exists, "the interrupted-run box reports all six cached pages")
            // Change the live setting after interruption. The late collection review should follow the
            // original run's saved choice even when the setting now asks for the opposite.
            let (relaunchSettings, _, relaunchToggle) = try documentReviewSetting()
            setDocumentReview(relaunchToggle, enabled: !enabled)
            relaunchSettings.typeKey("w", modifierFlags: .command)
            shot("\(name)-interrupted")
            resume.click()

            let complete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Complete'")).firstMatch
            let boxSheet = app.sheets.containing(.staticText, identifier: "Confirm Box & Folder Labels").firstMatch
            let deadline = Date().addingTimeInterval(90)
            var sawPageReview = false
            var sawBoxReview = false
            while !complete.exists && Date() < deadline {
                if !sawPageReview && firstReview.exists {
                    sawPageReview = true
                    shot("\(name)-resumed-page-review")
                    app.typeKey(.return, modifierFlags: [])
                }
                if !sawBoxReview && boxSheet.exists {
                    sawBoxReview = true
                    shot("\(name)-resumed-label-review")
                    boxSheet.buttons["Confirm"].click()
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            XCTAssertTrue(complete.exists, "the resumed run reaches final tagging review")
            print("[s050] \(name): whole-run page review=\(sawPageReview), box/folder confirmation=\(sawBoxReview), final tagging review=\(complete.exists)")
            shot("\(name)-final-tagging-review")
            complete.click()

            let organize = app.sheets.buttons["Confirm and Organize"]
            XCTAssertTrue(organize.waitForExistence(timeout: 60))
            organize.click()

            let done = app.staticTexts.matching(NSPredicate(
                format: "label BEGINSWITH 'Done.' OR value BEGINSWITH 'Done.'")).firstMatch
            let completionDeadline = Date().addingTimeInterval(60)
            var sawCollectionReview = false
            while !done.exists && Date() < completionDeadline {
                if firstReview.exists {
                    if !sawCollectionReview { shot("\(name)-resumed-collection-review") }
                    sawCollectionReview = true
                    app.typeKey(.return, modifierFlags: [])
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
            XCTAssertTrue(text(of: done).hasPrefix("Done. 6 succeeded, 0 failed."),
                          "the resumed run finishes all six files after its remaining reviews")
            XCTAssertEqual(sawCollectionReview, enabled, "the collection-stage review follows the saved setting")
            XCTAssertEqual(try ocrCallCount(name), 6, "Resume reuses the original six saved readings")
            print("[s050] \(name): per-collection page review=\(sawCollectionReview); \(text(of: done)); OCR calls=6")
        }
    }

    /// Drive both tagging choices through Start, then read each PDF's Finder tags.
    func testCollectionMarkersWithSourceTags() throws {
        let input = dir.appendingPathComponent("tagged-in")
        let photos = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { ["jpg", "jpeg", "png", "tiff", "tif", "heic"].contains($0.pathExtension.lowercased()) }
        XCTAssertEqual(photos.count, 6)
        for photo in photos {
            XCTAssertTrue(Set(finderTags(of: photo)).isSuperset(of: ["Scratch Subject", "1978"]))
        }

        for (mode, title) in [("none", "No tagging"), ("copySource", "Copy source file tags")] {
            let out = try launch("s034-\(mode)", [
                "-rotationModeRaw", "off", "-reviewRotation", "NO",
                "-reviewDocumentSegmentation", "NO", "-outputImageFile", "NO"
            ], collectionID: true, classificationCycle: true, input: input)
            let picker = app.descendants(matching: .any)["ap.ocr.taggingPicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            picker.click()
            let choice = app.menuItems[title]
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.click()
            clickStart()
            confirmLabelReviews()
            let organize = app.sheets.buttons["Confirm and Organize"]
            XCTAssertTrue(organize.waitForExistence(timeout: 90))
            organize.click()
            waitForDone("s034-\(mode)")

            let pdfs = filedPDFs(in: out)
            XCTAssertEqual(pdfs.count, 6)
            let tags = pdfs.map { finderTags(of: $0).sorted() }
            print("[s034] \(mode): \(tags)")
            XCTAssertEqual(tags.filter { $0 == ["Box"] }.count, 1)
            XCTAssertEqual(tags.filter { $0 == ["Folder"] }.count, 1)
            let documentTags = mode == "copySource" ? ["1978", "Scratch Subject"] : []
            XCTAssertEqual(tags.filter { $0 == documentTags }.count, 4)
        }
    }

    /// Exercise the same review that exposed S-036, including clicking while the field is active.
    func testCollectionNameConfirmedByClick() throws {
        try checkCollectionNameConfirmation(submitWithReturn: false)
        try checkCollectionNameConfirmation(submitWithReturn: true)
    }

    private func checkCollectionNameConfirmation(submitWithReturn: Bool) throws {
        let run = submitWithReturn ? "s036-return" : "s036-click"
        let out = try launch(run, [
            "-taggingModeRaw", "automatic", "-segmentationApproach", "manual",
            "-rotationModeRaw", "off", "-reviewRotation", "NO",
            "-reviewDocumentSegmentation", "NO", "-outputImageFile", "NO"
        ], collectionID: true, classificationCycle: true)
        clickStart()
        confirmLabelReviews()
        let complete = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Complete'")).firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 90))
        complete.click()

        let organize = app.sheets.buttons["Confirm and Organize"]
        XCTAssertTrue(organize.waitForExistence(timeout: 60))
        XCTAssertEqual(app.sheets.textFields.count, 1, "one box name to edit")
        let field = app.sheets.textFields.firstMatch
        func type(_ name: String) {
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])
            if !name.isEmpty { field.typeText(name) }
        }

        for invalidName in ["a/b", "", "..", "."] {
            type(invalidName)
            if submitWithReturn { field.typeKey(.return, modifierFlags: []) }
            XCTAssertFalse(organize.isEnabled, "the sheet cannot organize with an invalid name (\(invalidName))")
            XCTAssertTrue(app.sheets.staticTexts["ap.collectionName.invalid"].exists)
            if !invalidName.isEmpty { XCTAssertEqual(field.value as? String, invalidName) }
        }
        shot("\(run)-invalid")

        type(" Scratch RG Papers ")
        if submitWithReturn {
            field.typeKey(.return, modifierFlags: [])
            XCTAssertEqual(field.value as? String, "Scratch RG Papers")
        }
        XCTAssertTrue(organize.isEnabled)
        organize.click()
        waitForDone(run)
        shot("\(run)-done")

        let filed = filedPDFs(in: out)
        XCTAssertEqual(filed.map { relativePath($0, under: out) }, (1...6).map {
            "Scratch RG Papers/" + String(format: "%06d", $0) + " Scratch RG Papers.pdf"
        })
        XCTAssertTrue(filed.allSatisfy {
            FileManager.default.fileExists(atPath: $0.appendingPathExtension("archivesuite.json").path)
        })
        let parent = try FileManager.default.contentsOfDirectory(at: scratchRoot, includingPropertiesForKeys: nil)
        XCTAssertFalse(parent.contains { $0.pathExtension == "pdf" })
    }

    private func confirmLabelReviews() {
        let review = reviewWindow("Document Segmentation Review", timeout: 90)
        let counts = review.staticTexts.matching(NSPredicate(
            format: "label CONTAINS '1 box' OR value CONTAINS '1 box'")).firstMatch
        XCTAssertTrue(text(of: counts).contains("1 folder"))
        app.typeKey(.return, modifierFlags: [])
        waitGone(review, "the page review has been confirmed")

        let boxConfirmation = app.sheets.buttons["Confirm"]
        XCTAssertTrue(boxConfirmation.waitForExistence(timeout: 60))
        boxConfirmation.click()
    }

    /// Relaunch with a completed paid batch on disk and press the actual Resume Batch button.
    func testPaidBatchResumeReviewGates() throws {
        let args = [
            "-APUITestPaidBatch", "-taggingModeRaw", "automatic", "-segmentationApproach", "manual",
            "-rotationModeRaw", "off", "-reviewRotation", "NO", "-outputImageFile", "NO"
        ]
        let out = try launch("s035-paid", args + ["-APUITestSeedPaidBatch"], collectionID: true)
        let legacy = try Dictionary(uniqueKeysWithValues: filedPDFs(in: out).map { ($0, try Data(contentsOf: $0)) })
        XCTAssertEqual(legacy.count, 6)
        let resume = app.buttons["Resume Batch"]
        XCTAssertTrue(resume.waitForExistence(timeout: 30), "the scratch journal was persisted")
        _ = try launch("s035-paid", args, collectionID: true, preservePendingRun: true)
        XCTAssertTrue(resume.waitForExistence(timeout: 30) && resume.isEnabled)
        let pending = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS '6 files via Gemini' OR value CONTAINS '6 files via Gemini'")).firstMatch
        XCTAssertTrue(pending.exists, "the real pending-batch banner recognizes the saved journal")
        shot("s035-paid-resume")
        resume.click()

        let page = app.windows.containing(.staticText, identifier: "Document Segmentation Review").firstMatch
        let boxes = app.sheets.containing(.staticText, identifier: "Confirm Box & Folder Labels").firstMatch
        let tags = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Complete'")).firstMatch
        let names = app.sheets.buttons["Confirm and Organize"]
        let done = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Done.' OR value BEGINSWITH 'Done.'")).firstMatch
        let deadline = Date().addingTimeInterval(140)
        var reviews: [String] = []
        while !done.exists && Date() < deadline {
            if page.exists {
                let stage = reviews.contains("collection names") ? "per-collection pages" : "whole-run pages"
                reviews.append(stage)
                shot("s035-paid-\(slug(stage))")
                app.typeKey(.return, modifierFlags: [])
                waitGone(page, "page review confirms")
            } else if names.exists {
                reviews.append("collection names")
                shot("s035-paid-collection-names")
                names.click()
                waitGone(names, "collection names confirm")
            } else if boxes.exists {
                reviews.append("box and folder labels")
                boxes.buttons["Confirm"].click()
                waitGone(boxes, "box and folder review confirms")
            } else if tags.exists {
                reviews.append("final tagging")
                tags.click()
                waitGone(tags, "final tagging review completes")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("[s035] paid Resume: \(reviews); \(text(of: done))")
        if !done.exists { dump(app, "paid Resume did not finish") }
        XCTAssertTrue(text(of: done).hasPrefix("Done. 6 succeeded, 0 failed."))
        XCTAssertEqual(reviews, ["collection names", "per-collection pages"])
        shot("s035-paid-done")
        for (pdf, original) in legacy {
            XCTAssertEqual(try Data(contentsOf: pdf), original)
        }
        let pdfs = filedPDFs(in: out).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathExtension("archivesuite.json").path)
        }
        XCTAssertEqual(pdfs.count, 6)
        XCTAssertTrue(pdfs.allSatisfy { $0.deletingLastPathComponent().lastPathComponent == "Scratch Papers" })
        XCTAssertTrue(pdfs.allSatisfy { finderTags(of: $0).contains("Unread") })
        XCTAssertEqual(pdfs.filter { finderTags(of: $0).contains("Resume Scratch Subject") }.count, 4)
    }

    private func filedPDFs(in root: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (files?.allObjects.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.path < $1.path }
    }

    private func relativePath(_ file: URL, under root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        return file.standardizedFileURL.pathComponents.dropFirst(rootParts.count).joined(separator: "/")
    }

    private func documentReviewSetting() throws -> (XCUIElement, XCUIElement, XCUIElement) {
        let settings = app.showSettingsWindow()
        XCTAssertTrue(app.showSettingsPanel("Documents"))
        let title = "Review document segmentation"
        let label = settings.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
        let scroll = settings.scrollViews.firstMatch
        for _ in 0..<15 where !label.isHittable {
            scroll.scroll(byDeltaX: 0, deltaY: -180)
        }
        XCTAssertTrue(label.isHittable)
        // The grouped Form exposes the title, help button and switch as sibling AX elements.
        let toggle = try XCTUnwrap(settings.switches.allElementsBoundByIndex.first {
            abs($0.frame.midY - label.frame.midY) < 3
        })
        XCTAssertTrue(toggle.isHittable && toggle.isEnabled)
        return (settings, label, toggle)
    }

    private func setDocumentReview(_ toggle: XCUIElement, enabled: Bool) {
        let target = enabled ? "1" : "0"
        if String(describing: toggle.value ?? "") != target { toggle.click() }
        XCTAssertEqual(String(describing: toggle.value ?? ""), target)
    }

    private func ocrCallCount(_ name: String) throws -> Int {
        let log = scratchRoot.appendingPathComponent("\(name)-agent.log")
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            .filter { $0.hasPrefix("ocr\t") }.count
    }

    // MARK: Run A — rotation review, per-page segmentation review, box/folder confirmation, Complete

    private func runA() throws -> [Int: Output] {
        let out = try launch("a", [
            "-taggingModeRaw", "automatic", "-segmentationApproach", "manual",
            "-rotationModeRaw", "localVision", "-reviewRotation", "YES"
        ])
        clickStart()

        // Review rotation, by the keys the header promises (W40.fix-processor-review-keys), first with no click at all:
        // every photo is proposed upright and photo 3 ends turned 90°. The footer counts the rotated pages.
        let rotation = reviewWindow("Review Rotation", timeout: 300)
        let turned = rotation.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '6 page' OR value BEGINSWITH '6 page'")).firstMatch
        press([.downArrow, .downArrow, "]"], turned, reads: "1 rotated", "rotation, keys as the window opens: ↓ ↓ ] turns photo 3")
        press([.downArrow, .rightArrow], turned, reads: "2 rotated", "rotation: ↓ → turns photo 4")
        press([.upArrow, "["], turned, reads: "1 rotated", "rotation: ↑ [ turns photo 3 back")
        press(["]"], turned, reads: "2 rotated", "rotation: ] turns photo 3 again")
        press([.downArrow, .leftArrow], turned, reads: "1 rotated", "rotation: ↓ ← turns photo 4 back")
        XCTAssertFalse(text(of: turned).contains("2 rotated"))
        shrinkThumbnails(in: rotation)
        // A click on photo 3's 90° radio (already chosen) makes it the row the keys act on.
        let turn = rotation.buttons.matching(NSPredicate(format: "label == '90°'"))
        guard turn.count >= 3 else { dump(rotation, "no 90° radio for photo 3"); return [:] }
        turn.element(boundBy: 2).click()
        press([.downArrow, "]"], turned, reads: "2 rotated", "rotation, keys after a radio click: ↓ ] turns photo 4")
        press(["["], turned, reads: "1 rotated", "rotation: [ turns photo 4 back")
        shot("w40d2-a-rotation-chosen")
        app.typeKey(.return, modifierFlags: [])   // Return confirms, the header says
        waitGone(rotation, "Return confirms the rotation review")

        // Per-page segmentation review, by keys: 3 as the window opens (photo 1 Box), a click on photo 2's row and 3
        // (Box), a click on photo 4's New Document radio and 2 (Continuation), ↓ X (photo 5 removed), ↓ 4 then 1
        // (photo 6 a Folder and back), Escape asks before discarding, Return confirms.
        let review = reviewWindow("Document Segmentation Review", timeout: 120)
        let footer = review.staticTexts.matching(NSPredicate(format: "label CONTAINS 'new document' OR value CONTAINS 'new document'")).firstMatch
        print("[w40d2] segmentation review footer as opened: '\(text(of: footer))'")
        press(["3"], footer, reads: "1 box", "segmentation, keys as the window opens: 3 makes photo 1 a Box")
        shrinkThumbnails(in: review)
        let boxes = review.buttons.matching(NSPredicate(format: "label == '3 Box'"))
        XCTAssertEqual(boxes.count, 6, "every row is drawn at the smallest thumbnail size")
        let names = (ProcessInfo.processInfo.environment["W40D2_PHOTOS"] ?? "").components(separatedBy: "|")
        guard names.count >= 6 else { dump(review, "W40D2_PHOTOS names \(names.count) photos, not six"); return [:] }
        let row2 = review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", names[1], names[1])).firstMatch
        guard row2.exists else { dump(review, "no file name '\(names.first ?? "")…' to click in photo 2's row"); return [:] }
        row2.click()
        press(["3"], footer, reads: "2 boxes", "segmentation, keys after a row click: 3 makes photo 2 a Box")
        review.buttons.matching(NSPredicate(format: "label == '1 New Document'")).element(boundBy: 3).click()
        press(["2"], footer, reads: "1 continuation", "segmentation, keys after a radio click: 2 makes photo 4 a Continuation")
        press([.downArrow, "x"], footer, reads: "1 removed", "segmentation: ↓ X removes photo 5")
        press([.downArrow, "4"], footer, reads: "1 folder", "segmentation: ↓ 4 makes photo 6 a Folder")
        press(["1"], footer, reads: "2 new documents", "segmentation: 1 makes photo 6 a New Document again")
        XCTAssertFalse(text(of: footer).contains("folder"), "photo 6 is no longer a Folder")
        let chosen = text(of: footer)
        shot("w40d2-a-segmentation-chosen")
        print("[w40d2] segmentation review footer as chosen: '\(chosen)'")
        app.typeKey(.escape, modifierFlags: [])   // Escape asks before discarding the run
        let keep = app.buttons["Keep Working"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "Escape asks before discarding the review")
        shot("w40d2-a-segmentation-escape")
        keep.click()
        XCTAssertTrue(review.exists, "Keep Working leaves the review open")
        XCTAssertEqual(text(of: footer), chosen, "and its choices as they were")
        app.typeKey(.return, modifierFlags: [])   // Return confirms, the header says
        waitGone(review, "Return confirms the segmentation review")

        // Box/folder confirmation: both labels arrive as Box; the second is turned to Folder.
        let sheet = app.sheets.firstMatch
        guard sheet.waitForExistence(timeout: 60) else {
            dump(app, "the box/folder confirmation did not open after the review")
            return [:]
        }
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
        // Page 2's Classification: the confirmation's Folder for photo 2, the review's Continuation for photo 4.
        expectClassifications(files, [1: "Box", 2: "Folder", 3: "Document Start", 4: "Continuation", 6: "Document Start"],
                              run: "a")
        XCTAssertTrue(files[1]?.tags.contains("Box") == true, "photo 1 carries the Box item type")
        XCTAssertTrue(files[2]?.tags.contains("Folder") == true, "photo 2 carries the Folder item type")
        XCTAssertFalse(files[2]?.tags.contains("Box") == true, "and not Box")
        // The stand-in's tag reply names these subjects; it answers the separate dating prompt "ok", so the date is
        // Date Uncertain. What matters here is that photo 4, made a Continuation by hand, carries photo 3's tags.
        XCTAssertTrue(files[3]?.tags.contains("War Department") == true, "photo 3's document is tagged")
        XCTAssertEqual(files[4]?.tags, files[3]?.tags, "photo 4 is tagged as part of photo 3's document")
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
        expectClassifications(files, [1: "Box", 2: "Folder", 3: "Document Start", 4: "Continuation", 6: "Document Start"],
                              run: "b")
        for n in [3, 4] {
            let tags = files[n]?.tags ?? []
            for want in ["1917", "3 March", "Day 12", "Signal Corps", "Q2"] {
                XCTAssertTrue(tags.contains(want), "photo \(n) carries the typed \(want): \(tags)")
            }
            XCTAssertFalse(tags.contains("War Department"), "photo \(n): no generated subject reached a manual document")
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

    private func launch(_ name: String, _ settings: [String], collectionID: Bool = false,
                        classificationCycle: Bool = false, preservePendingRun: Bool = false,
                        input: URL? = nil) throws -> URL {
        let out = scratchRoot.appendingPathComponent("\(name)-out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        app.terminate()
        app.launchArguments = UITestLaunch.arguments([
            "-APUITestMode", "-APUITestLocalAgent",
            "-APUITestInputImages", (input ?? dir.appendingPathComponent("in")).path,
            "-APUITestOutputDirectory", out.path, "-outputDirectory", out.path,
            "-localAgentBinaryPath", dir.appendingPathComponent("fake_local_agent.py").path,
            "-useAppleVision", "NO", "-useGateway", "NO", "-batchMode", "NO",
            "-selectedProvider", "Gemini", "-preOCRedInput", "NO",
            "-mergeDocuments", "NO", "-enableCollectionSegmentation", collectionID ? "YES" : "NO",
            "-confirmCollectionIDs", collectionID ? "YES" : "NO", "-enableSegmentJSON", "YES",
            // Keep the journey on its stand-in reader. The separate date and item-field contracts
            // exercise enrichment with offline transports.
            "-macItemFields", "NO", "-tagVocabulary", ""
        ] + settings)
        app.launchEnvironment = [
            "ARCHIVEPROC_HEADLESS": "1",   // keychain quiet; the window still draws
            "FAKE_AGENT_CLASS_CYCLE": classificationCycle ? "1" : "0",
            "FAKE_AGENT_LOG": scratchRoot.appendingPathComponent("\(name)-agent.log").path
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the Processor window must appear")
        // An earlier run killed mid-way leaves an Interrupted Run box that holds Start; a user dismisses it.
        if !preservePendingRun, app.descendants(matching: .any)["ap.ocr.resumeRun"].waitForExistence(timeout: 3) {
            shot("w40d2-\(name)-interrupted-run")
            app.buttons["Dismiss"].firstMatch.click()
        }
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

    /// Presses `keys` one at a time, then waits for `footer` to read `want`: each review key changes the footer's count.
    private func press(_ keys: [KeyOrChar], _ footer: XCUIElement, reads want: String, _ step: String) {
        for key in keys {
            key.type(on: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let deadline = Date().addingTimeInterval(3)
        while !text(of: footer).contains(want), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        print("[w40d2] \(step): footer '\(text(of: footer))'")
        if !text(of: footer).contains(want) { shot("w40d2-fail-\(slug(step))") }
        XCTAssertTrue(text(of: footer).contains(want), "\(step): the footer reads '\(want)'")
    }

    private func waitGone(_ window: XCUIElement, _ why: String) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: window)
        if XCTWaiter.wait(for: [gone], timeout: 10) != .completed { shot("w40d2-fail-\(slug(why))") }
        XCTAssertFalse(window.exists, why)
    }

    private func text(of element: XCUIElement) -> String {
        guard element.exists else { return "(absent)" }
        return (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    private func shrinkThumbnails(in window: XCUIElement) {
        let slider = window.sliders.firstMatch
        // A click at the track's left end, as a user drags it down: `adjust(toNormalizedSliderPosition:)` cannot
        // synthesize its event in the guest (kAXErrorParameterizedAttributeUnsupported, measured 2026-11-19).
        if slider.exists { slider.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5)).click() }
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
        /// "portrait" or "landscape": the bounding box of what is drawn on page 1, i.e. the photo as placed.
        let imageShape: String
    }

    /// Every PDF the run wrote, keyed by its photo's place in the input (1-6), by its file name.
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
            // The output is named for its photo (no collection renaming in this journey).
            let stem = pdf.deletingPathExtension().lastPathComponent
            guard let n = names.firstIndex(where: { !$0.isEmpty && ($0 as NSString).deletingPathExtension == stem }) else {
                XCTFail("\(pdf.lastPathComponent) is named for none of the input photos")
                continue
            }
            print("[w40d2] \(pdf.lastPathComponent) page 2 header: \(text.components(separatedBy: "\n").prefix(6).joined(separator: " / "))")
            let cls = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("Classification:") }
                .map { $0.dropFirst("Classification:".count).trimmingCharacters(in: .whitespaces) } ?? "(none)"
            let box = page1.bounds(for: .mediaBox)
            XCTAssertNil(result[n + 1], "photo \(n + 1) has one output")
            result[n + 1] = Output(pdf: pdf, classification: cls, tags: finderTags(of: pdf), size: box.size,
                                   rotation: page1.rotation, imageShape: drawnShape(of: page1))
        }
        return result
    }

    /// The shape of the non-white area of a page rendered small: a photo fitted into a Letter page fills its height
    /// when it is portrait and its width, with white bands above and below, when it is landscape.
    private func drawnShape(of page: PDFPage) -> String {
        let image = page.thumbnail(of: NSSize(width: 153, height: 198), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return "unknown" }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.5, c.redComponent + c.greenComponent + c.blueComponent < 2.85 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return "unknown" }
        let w = maxX - minX, h = maxY - minY
        return h > w ? "portrait \(w)x\(h)" : "landscape \(w)x\(h)"
    }

    private func report(_ name: String, _ files: [Int: Output]) {
        for n in files.keys.sorted() {
            let f = files[n]!
            print("[w40d2] run \(name) photo \(n): \(f.pdf.lastPathComponent) | \(f.classification) | tags \(f.tags) | "
                  + "page 1 \(Int(f.size.width))x\(Int(f.size.height)) rot \(f.rotation), photo \(f.imageShape)")
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
    static let upArrow = KeyOrChar.key(.upArrow)
    static let leftArrow = KeyOrChar.key(.leftArrow)
    static let rightArrow = KeyOrChar.key(.rightArrow)
    init(stringLiteral value: String) { self = .char(value) }
    @MainActor func type(on app: XCUIApplication) {
        switch self {
        case .char(let c): app.typeKey(c, modifierFlags: [])
        case .key(let k): app.typeKey(k, modifierFlags: [])
        }
    }
}
