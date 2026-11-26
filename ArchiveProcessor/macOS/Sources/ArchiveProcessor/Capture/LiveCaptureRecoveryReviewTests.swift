#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import AppKit
import PDFKit
import ArchiveCore

// Tests 21-29 of LiveCaptureRecoveryTestDriver.run(), one function each (W49.proc-build-memory).
extension LiveCaptureRecoveryTestDriver {
    /// Test 21 (W3.cap-r3-fu7) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest21(tmp: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let rfOut = tmp.appendingPathComponent("fu7out", isDirectory: true)
        let rfStaging = tmp.appendingPathComponent("APStaging-fu7-\(String(UUID().uuidString.prefix(8)))",
                                                  isDirectory: true)
        try? fm.createDirectory(at: rfStaging, withIntermediateDirectories: true)
        let rfSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        rfSession._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` — no document reaches the LLM, so this runs for real, for $0, no network.
                taggingMode: .human, rotationMode: .off,
                // No merge here (unlike Test 20): this section wants the regeneration to SUCCEED, so the
                // per-page PDFs it rewrites may stay exactly where the first write put them.
                mergeDocuments: false,
                outputDirectory: rfOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: rfStaging)
        let rfProc = rfSession.liveProcessor
        func rfSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
        // A real, decodable JPEG: the segment has to reach the plain `.staged` label (a placeholder page
        // would make it `.succeededPlaceholderImage`) and the regeneration has to be able to rewrite it.
        let rfBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)
        let rfJPEG = rfBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()

        // 1. PREMISE. A two-page document stages cleanly, having bought exactly one call per page.
        for seq in [1, 2] {
            rfSession.ingest(jpeg: rfJPEG, groupId: "F1", seq: seq,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        rfProc.segmentResolved(groupId: "F1")
        let rfStagedOK = await rfSettle { rfProc.statuses.first { $0.id == "F1" }?.phase == .staged }
        let rfPaidAfterStage = paidStarts()
        let rfSources = rfSession.photos.filter { $0.groupId == "F1" }.map(\.url)
        check("a two-page document stages cleanly, having bought exactly one paid call per page",
              rfStagedOK && rfPaidAfterStage == 2 && rfSources.count == 2
                  && rfProc.failedGroupIds.isEmpty && rfProc.isFinalized("F1")
                  && rfProc.staged.first { $0.groupId == "F1" }?.pdfURLs.isEmpty == false)
        // W3.cap-r3-fu10 sample A — idle, everything staged: the panel is live, so no scrim.
        let rfScrimIdle = rfProc.isFinishingScrimUp

        // 2. PREMISE. Its pages reach the rotation review, through the real Finish, with the operator's
        //    own "Review rotation" preference restored around the one synchronous call that reads it.
        let rfPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
        UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
        rfProc.finishSession()
        if let rfPriorReview {
            UserDefaults.standard.set(rfPriorReview, forKey: DefaultsKeys.reviewRotation)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
        }
        check("a STAGED segment's pages enter the end-of-session rotation review",
              rfProc.showRotationReview
                  && rfProc.rotationReviewPages.filter { $0.groupId == "F1" }.count == 2)
        // W3.cap-r3-fu10 sample B — the review SHEET is up and is the modality; no scrim behind it.
        // ⚠️ Named honestly: this is a second IDLE-SIDE sample (`isFinalizing` is still false here), so it
        // does not exercise the `!showRotationReview` term at all — 3b's poke is what kills S2. Kept
        // because it is a real driven state on the way in, not because it adds a term.
        let rfScrimReview = rfProc.isFinishingScrimUp

        // 3. PREMISE, and the one that makes the rest non-vacuous: the operator straightens a page, and
        //    the regeneration is PENDING and unpublished — `isFinalizing`, no sheet over the panel (so the
        //    retry affordances are on screen but — `W3.cap-r3-fu10` having decided it — NOT clickable, the
        //    throbber's scrim eating the pointer on purpose; 3b below pins exactly when that scrim is up),
        //    and the record + its file still the pre-write ones. Everything from here to check 5 runs on
        //    this same MainActor turn, so the write cannot land in the middle of it. (Not asserted, per the
        //    ⚠️ above: that the write is *executing*. It is not — it has not even been dispatched.)
        for i in rfProc.rotationReviewPages.indices
        where rfProc.rotationReviewPages[i].groupId == "F1" && rfProc.rotationReviewPages[i].pageIndex == 0 {
            rfProc.rotationReviewPages[i].rotationDegrees = 90
        }
        let rfPDFsBefore = rfProc.staged.first { $0.groupId == "F1" }?.pdfURLs ?? []
        rfProc.applyRotationReviewAndFinalize()
        check("the regeneration is pending and unpublished, with the panel on screen and nothing over it",
              rfProc.isFinalizing && !rfProc.showFinalizeSheet && !rfProc.showRotationReview
                  && !rfPDFsBefore.isEmpty && rfPDFsBefore.allSatisfy { fm.fileExists(atPath: $0.path) })

        // 3b. W3.cap-r3-fu10 — the scrim's COVERAGE: the panel is deliberately blocked for exactly the
        //     window above, and for no other state. This is the half of that decision a headless driver
        //     CAN measure. The other half — that the scrim absorbs the click — it cannot see at all, and
        //     nothing here should be read as claiming it (see the mutant note above check 1's section).
        //
        //     Note what makes this worth a check rather than a tautology: check 3 asserts the state with
        //     the triple written out, and this asserts the PROPERTY THE VIEW ACTUALLY BRANCHES ON. They
        //     were the same expression written twice until this item extracted `isFinishingScrimUp`, and
        //     a driver re-typing the view's condition is a driver that keeps passing while the view
        //     drifts out from under it.
        //
        //     The two sheet states are reached by ASSIGNMENT, not by driving them. Both are `@Published
        //     var`s, both pokes are restored on this same MainActor turn (the regeneration's `Task` is
        //     MainActor-isolated and cannot interleave — see the ⚠️ above), and the last term asserts the
        //     restore actually happened, so a botched one cannot leak into checks 4–8. Deliberately NOT
        //     driven through the real `finalize(_:)`, which is the other way to reach `isFinalizing &&
        //     showFinalizeSheet`: that MOVES staged output into `currentOutputDirectory`, and while
        //     `test-recovery.sh` does set `LIVECAPTURE_TESTOUT` to keep that in a temp dir, the fallback
        //     when it is unset is the operator's real configured output folder. Making a cosmetic mutant's
        //     kill depend on the harness's env for its file safety is a bad trade when an assignment
        //     reaches the same state and writes nothing.
        //     `isFinalizing && showRotationReview` additionally has no reaching path today
        //     (`applyRotationReviewAndFinalize` clears the flag first), so for that term the assignment is
        //     the only way to state the rule at all — recorded as a SPECIFICATION check, not a
        //     reachability claim.
        let rfScrimOpen = rfProc.isFinishingScrimUp
        rfProc.showFinalizeSheet = true
        let rfScrimUnderFinalizeSheet = rfProc.isFinishingScrimUp
        rfProc.showFinalizeSheet = false
        rfProc.showRotationReview = true
        let rfScrimUnderReviewSheet = rfProc.isFinishingScrimUp
        rfProc.showRotationReview = false
        check("the finishing scrim covers exactly the exposed window — up while regenerating, down idle, "
                  + "down under either sheet",
              rfScrimOpen && !rfScrimIdle && !rfScrimReview
                  && !rfScrimUnderFinalizeSheet && !rfScrimUnderReviewSheet
                  && rfProc.isFinishingScrimUp)

        // 4. THE FIX, money half. Both retry entries are refused: the per-item one, and the one the rotation
        //    sheet defers (`onApply` fires whenever the operator gets round to it, so no enabled-ness
        //    computed when the button was drawn can speak for this moment — which is why the refusal has
        //    to live in `retryFailed` and not only in the view).
        rfProc.retryFailed(groupIds: ["F1"])
        rfProc.retryFailed(groupIds: ["F1"], rotation: 180)
        check("a retry mid-regeneration buys NO second OCR — neither entry, rotation or not",
              paidStarts() == rfPaidAfterStage)

        // 5. THE FIX, state half. Nothing the retry would have torn down moved: the staged record, the
        //    `finalizedGroups` entry the late-page branch depends on, `retained`, and the output files the
        //    pending regeneration is about to write over.
        check("...and it tears nothing down under the write: record, finalized entry and files all intact",
              rfProc.staged.contains { $0.groupId == "F1" }
                  && rfProc.isFinalized("F1")
                  && rfProc.retainedText(for: "F1") != nil
                  && rfPDFsBefore.allSatisfy { fm.fileExists(atPath: $0.path) })

        // 6. PREMISE. The regeneration then lands normally — the refusal cost the finish nothing. The
        //    segment is still filable, still unfailed, and both sources are still in the backup folder.
        let rfRegen = await rfSettle { !rfProc.isFinalizing && rfProc.showFinalizeSheet }
        let rfRecord = rfProc.staged.first { $0.groupId == "F1" }
        check("the regeneration lands intact and the segment is still filable",
              // W3.cap-r3-fu10 sample C, folded in here rather than given its own check: the scrim comes
              // back DOWN once the window closes, observed in a state the test DROVE rather than assigned.
              // Check 3b's pokes prove the sheet terms; this proves the window is a window.
              !rfProc.isFinishingScrimUp
                  && rfRegen && rfProc.failedGroupIds.isEmpty
                  && rfRecord?.pagesComplete != false
                  && rfRecord?.pdfURLs.isEmpty == false
                  && rfRecord?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true
                  && rfSources.allSatisfy { fm.fileExists(atPath: $0.path) })

        // 7. THE FIX, UI half — the per-item menu, answering the item's open question with a measurement
        //    rather than a decision note. Every state that offers a retry withholds the whole retry family
        //    while finalizing and keeps the two read-only actions; and the SAME states still offer them
        //    when not, so a gate that withheld unconditionally fails here too.
        let rfGatedStates: [ItemState] = [.failed(.noOutput), .succeededNoText, .succeededPlaceholderImage]
        let rfWithheld = rfGatedStates.allSatisfy { st in
            let gated = SegmentItem.actions(for: st, finalizing: true)
            let ungated = SegmentItem.actions(for: st, finalizing: false)
            return !gated.contains(.retry)
                && !gated.contains(.changeRotation)
                && gated.contains(.viewText) && gated.contains(.revealFiles)
                && ungated.contains(.retry)
        }
        check("the per-item menu withholds the retry family mid-regeneration, and only then",
              rfWithheld
                  && SegmentItem.actions(for: .succeeded, finalizing: true) == [.viewText, .revealFiles])

        // 8. …and the refusal is a WINDOW, not a ban: once the regeneration is done, the same per-item
        //    retry works again and buys the segment's pages back. Deliberately last, because it
        //    re-processes the segment.
        //
        //    SCOPE, since the adversarial pass showed the first draft claimed more than this measures.
        //    `beginFinalize` has raised the collection SHEET by the time this runs, so the state exercised
        //    is "finish sheet up, not finalizing" — which is not a state the operator can press either
        //    button in (the sheet is modal). So this is primarily the guard's WIDTH measurement (mutant P5
        //    is 1 RED here), and only secondarily the not-a-ban claim; a check for the affordance as the
        //    operator meets it would have to dismiss the sheet first, and would then lose the width
        //    measurement. ⚠️ It was also flagged as COUPLED to `W3.cap-r3-fu9`: because it asserts the
        //    retry SUCCEEDS under `showFinalizeSheet`, a fu9 fix that refused during the sheet states
        //    would have turned it RED. **fu9 shipped 2026-08-04 and did not** — it holds the FINISH while
        //    a per-item sheet is up (Test 23) instead of refusing the retry, so this check stands
        //    unchanged and the coupling is discharged rather than still pending.
        rfProc.retryFailed(groupIds: ["F1"])
        let rfReStaged = await rfSettle { rfProc.statuses.first { $0.id == "F1" }?.phase == .staged }
        check("after the window closes the retry works again — a window, not a ban",
              rfReStaged && paidStarts() == rfPaidAfterStage + 2
                  && rfProc.staged.contains { $0.groupId == "F1" })

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }

    /// Test 22 (W3.cap-r3-fu11) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest22(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let clOut = tmp.appendingPathComponent("fu11out", isDirectory: true)
        let clSession = CaptureSession()
        let clStaging = clSession.incomingFolder.appendingPathComponent("_processed", isDirectory: true)
        try? fm.createDirectory(at: clStaging, withIntermediateDirectories: true)
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        let clConfig = SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` — no document reaches the LLM, so this runs for real, for $0, no network.
                taggingMode: .human, rotationMode: .off,
                // No merge: the regeneration has to SUCCEED here, so its per-page PDFs may stay exactly
                // where the first write put them (same reasoning as Test 21).
                mergeDocuments: false,
                outputDirectory: clOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1)
        clSession._recoveryTestBeginLive(config: clConfig, stagingDir: clStaging)
        let clProc = clSession.liveProcessor
        func clSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        // A real, decodable JPEG: the segment must reach the plain `.staged` label (a placeholder page
        // would make it `.succeededPlaceholderImage`) and the regeneration must be able to rewrite it.
        let clBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)
        let clJPEG = clBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()

        // 1. PREMISE. A two-page document stages cleanly, with its sources on disk and its output
        //    written — both of the things a mid-window Clear would take away.
        for seq in [1, 2] {
            clSession.ingest(jpeg: clJPEG, groupId: "L1", seq: seq,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        clProc.segmentResolved(groupId: "L1")
        let clStagedOK = await clSettle { clProc.statuses.first { $0.id == "L1" }?.phase == .staged }
        let clSources = clSession.photos.filter { $0.groupId == "L1" }.map(\.url)
        let clPDFsBefore = clProc.staged.first { $0.groupId == "L1" }?.pdfURLs ?? []
        check("a two-page document stages cleanly, its sources on disk and its output written",
              clStagedOK && clSources.count == 2
                  && clSources.allSatisfy { fm.fileExists(atPath: $0.path) }
                  && !clPDFsBefore.isEmpty && clPDFsBefore.allSatisfy { fm.fileExists(atPath: $0.path) }
                  && clProc.isFinalized("L1") && clProc.failedGroupIds.isEmpty)

        // 2. PREMISE. Its pages reach the rotation review, through the real Finish, with the operator's
        //    own "Review rotation" preference restored around the one synchronous call that reads it.
        let clPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
        UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
        clProc.finishSession()
        if let clPriorReview {
            UserDefaults.standard.set(clPriorReview, forKey: DefaultsKeys.reviewRotation)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
        }
        check("a STAGED segment's pages enter the rotation review (fu11)",
              clProc.showRotationReview
                  && clProc.rotationReviewPages.filter { $0.groupId == "L1" }.count == 2)

        // 3. PREMISE, and what makes the rest non-vacuous: the operator straightens a page, and the
        //    regeneration is PENDING and unpublished — `isFinalizing`, no sheet over the panel, the
        //    scrim up. Asserted through `isFinishingScrimUp` (the property the view branches on) as well
        //    as the raw triple, so this cannot keep passing while the view drifts.
        for i in clProc.rotationReviewPages.indices
        where clProc.rotationReviewPages[i].groupId == "L1" && clProc.rotationReviewPages[i].pageIndex == 0 {
            clProc.rotationReviewPages[i].rotationDegrees = 90
        }
        clProc.applyRotationReviewAndFinalize()
        check("the regeneration is pending and unpublished, with the panel frozen and nothing over it",
              clProc.isFinalizing && !clProc.showFinalizeSheet && !clProc.showRotationReview
                  && clProc.isFinishingScrimUp)

        // 4. THE FIX, both halves in one assertion because the fix's claim IS the pair (see the
        //    ⚠️ above). Nothing is Trashed and nothing is torn down: the sources are still on disk AND
        //    still in the Captured pane, and the staged record, its `finalizedGroups` entry, `retained`
        //    and the output files the pending write is about to replace are all where the regeneration
        //    will expect them.
        clProc.clearSession()
        check("a Clear mid-regeneration Trashes nothing and tears nothing down — both halves refuse",
              clSources.allSatisfy { fm.fileExists(atPath: $0.path) }
                  && clSession.photos.filter { $0.groupId == "L1" }.count == 2
                  && clProc.staged.contains { $0.groupId == "L1" }
                  && clProc.isFinalized("L1")
                  && clProc.retainedText(for: "L1") != nil
                  && clPDFsBefore.allSatisfy { fm.fileExists(atPath: $0.path) })

        // 5. The refusal cost the finish nothing: the regeneration lands normally, the segment is still
        //    filable and unfailed, the scrim is back down, and both sources are still in the backup
        //    folder. This is where a Clear that got through is caught for the reason that matters — the
        //    regeneration republishing over inputs that are gone.
        let clRegen = await clSettle { !clProc.isFinalizing && clProc.showFinalizeSheet }
        let clRecord = clProc.staged.first { $0.groupId == "L1" }
        check("the regeneration lands intact and the segment is still filable (fu11)",
              clRegen && !clProc.isFinishingScrimUp && clProc.failedGroupIds.isEmpty
                  && clRecord?.pagesComplete != false
                  && clRecord?.pdfURLs.isEmpty == false
                  && clRecord?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true
                  && clSources.allSatisfy { fm.fileExists(atPath: $0.path) })

        // 6. …and the refusal is a WINDOW, not a ban: the same call, once the window has closed, does
        //    its job in full — both panes empty and the sources really do go to the Trash.
        //
        //    SCOPE, stated as plainly as Test 21's check 8 had to be. `beginFinalize` has raised the
        //    collection SHEET by the time this runs, so the state exercised is "finish sheet up, not
        //    finalizing" — which is NOT a state the operator can press Clear in (the sheet is modal). So
        //    this is primarily the guard's WIDTH measurement and only secondarily the not-a-ban claim;
        //    checking the affordance as the operator meets it would have to dismiss the sheet first and
        //    would lose the width measurement. One artifact of that trade, named rather than hidden: the
        //    sheet is left up over a now-empty session, which is unreachable in production for the same
        //    modality reason and is not asserted either way. Deliberately LAST, because it is
        //    destructive.
        // Model a partial prior finalize: the filed-ID ledger makes an otherwise empty Capture session
        // eligible for restoration, so this exercises the exact inter-manifest crash boundary.
        let filedLedgerReady = clSession.recordFiledGroups(["already-filed"])
        let clearToken = UUID().uuidString
        let clearPrepared = clSession.prepareClear(token: clearToken)
        let stagingEmptied = clearPrepared && clProc._recoveryTestPersistClearManifest(token: clearToken)
        let paidStartsBeforeRecovery = LiveCaptureProcessor._recoveryTestOCRStarts.count
        let resumedClearSession = CaptureSession()   // simulate relaunch at the prepared + empty-staging boundary
        var committedClearBeforeTrash = false
        var failFirstCommit = true
        resumedClearSession.manifestWriteOverride = { data, url in
            let decoded = CaptureSession.decodeManifest(data)
            if decoded?.clearPhase == "committed" && failFirstCommit {
                failFirstCommit = false
                return false
            }
            do { try data.write(to: url, options: .atomic) }
            catch { return false }
            if decoded?.clearPhase == "committed" {
                let stageURL = clStaging.appendingPathComponent("staging-manifest.json")
                let stageData = try? Data(contentsOf: stageURL)
                let stageObject = stageData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let stagedRows = stageObject?["staged"] as? [Any]
                committedClearBeforeTrash = (Set(decoded?.entries.map(\.name) ?? []) == Set(clSources.map(\.lastPathComponent)))
                    && decoded?.filed.contains("already-filed") == true
                    && stagedRows?.isEmpty == true
                    && (stageObject?["clearToken"] as? String) == decoded?.clearToken
                    && clSources.allSatisfy { fm.fileExists(atPath: $0.path) }
            }
            return true
        }
        resumedClearSession.beginLiveSession(config: clConfig)
        resumedClearSession._recoveryTestForceStageForLater()
        let refusedStageLaterIngest = resumedClearSession.ingest(
            jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]), groupId: "after-clear", seq: 99,
            type: .document, quality: nil, year: nil, month: nil, deviceName: nil)
        let captureManifestAfterRefusal = try? Data(contentsOf: clSession.incomingFolder.appendingPathComponent("manifest.json"))
        let captureAfterRefusal = captureManifestAfterRefusal.flatMap { CaptureSession.decodeManifest($0) }
        let preservedJournal = fm.fileExists(atPath: clStaging.appendingPathComponent("staging-manifest.json").path)
            && ((try? fm.contentsOfDirectory(atPath: clStaging.path)) ?? []).allSatisfy {
                !$0.hasPrefix("staging-manifest.corrupt-")
            }
        let stageLaterRefused = refusedStageLaterIngest == nil
            && captureAfterRefusal?.clearPhase == "prepared"
            && !fm.fileExists(atPath: clSession.incomingFolder.appendingPathComponent("00099-after-clear.jpg").path)
        resumedClearSession.manifestWriteOverride = nil
        let retryClearSession = CaptureSession()   // the next launch retries the still-prepared transaction
        retryClearSession.manifestWriteOverride = { data, url in
            do { try data.write(to: url, options: .atomic) }
            catch { return false }
            let decoded = CaptureSession.decodeManifest(data)
            if decoded?.clearPhase == "committed" {
                let stageURL = clStaging.appendingPathComponent("staging-manifest.json")
                let stageData = try? Data(contentsOf: stageURL)
                let stageObject = stageData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let stagedRows = stageObject?["staged"] as? [Any]
                committedClearBeforeTrash = (Set(decoded?.entries.map(\.name) ?? []) == Set(clSources.map(\.lastPathComponent)))
                    && decoded?.filed.contains("already-filed") == true
                    && stagedRows?.isEmpty == true
                    && (stageObject?["clearToken"] as? String) == decoded?.clearToken
                    && clSources.allSatisfy { fm.fileExists(atPath: $0.path) }
            }
            return true
        }
        retryClearSession.beginLiveSession(config: clConfig)
        let resumedClearProc = retryClearSession.liveProcessor
        check("relaunch completes the matching Clear transaction without re-OCR or restoring staging (fu12-fu2)",
              filedLedgerReady && clearPrepared && stagingEmptied && committedClearBeforeTrash
                  && preservedJournal && stageLaterRefused && !failFirstCommit
                  && retryClearSession.photos.isEmpty && retryClearSession.filedGroupIds.contains("already-filed")
                  && resumedClearProc.staged.isEmpty && resumedClearProc.rotationReviewPages.isEmpty
                  && LiveCaptureProcessor._recoveryTestOCRStarts.count == paidStartsBeforeRecovery
                  && clPDFsBefore.allSatisfy { fm.fileExists(atPath: $0.path) }
                  && clSources.allSatisfy { !fm.fileExists(atPath: $0.path) })
        retryClearSession.manifestWriteOverride = nil

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }

    /// Test 23 (W3.cap-r3-fu9) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest23(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let psOut = tmp.appendingPathComponent("fu9out", isDirectory: true)
        let psStaging = tmp.appendingPathComponent("APStaging-fu9-\(String(UUID().uuidString.prefix(8)))",
                                                  isDirectory: true)
        try? fm.createDirectory(at: psStaging, withIntermediateDirectories: true)
        let psSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        psSession._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` — no document reaches the LLM, so this runs for real, for $0, no network.
                taggingMode: .human, rotationMode: .off,
                // No merge: the regeneration has to SUCCEED here (same reasoning as Tests 21/22).
                mergeDocuments: false,
                outputDirectory: psOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: psStaging)
        let psProc = psSession.liveProcessor
        func psSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func psPaidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
        let psBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)
        let psJPEG = psBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()

        // The review preference must stay set across every await in this section — the review here is
        // raised by a BACKGROUND event, not by a synchronous call the driver brackets (Tests 21/22 could
        // restore it immediately because they call `finishSession()` themselves). Restored at the end.
        let psPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
        UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)

        // 1. PREMISE. A two-page document stages cleanly.
        for seq in [1, 2] {
            psSession.ingest(jpeg: psJPEG, groupId: "P1", seq: seq,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        psProc.segmentResolved(groupId: "P1")
        let psStagedOK = await psSettle { psProc.statuses.first { $0.id == "P1" }?.phase == .staged }
        let psPaidAfterStage = psPaidStarts()
        check("a two-page document stages cleanly (fu9)",
              psStagedOK && psProc.isFinalized("P1") && psProc.failedGroupIds.isEmpty
                  && psProc.staged.first { $0.groupId == "P1" }?.pdfURLs.isEmpty == false)

        // 2. PREMISE. The finish goes through the REAL `requestFinish`, not `finishSession` directly
        //    (Tests 21/22 could take that shortcut; this section cannot, because the whole point is the
        //    background entrant). Both of `requestFinish`'s documented jobs are exercised: it
        //    force-completes the still-open doc group — which surfaces that group's Mac tag card, a
        //    thing the shortcut never showed — and it holds the finish while the phone says it still has
        //    a page un-sent.
        psSession.updatePhonePending(1)
        psProc.requestFinish()
        check("a Finish pressed while the phone is still draining goes pending, and surfaces the card",
              psProc.pendingFinish && !psProc.showRotationReview && !psProc.showFinalizeSheet
                  && psSession.phonePendingActive && psSession.pendingTagGroup?.id == "P1")

        // 3. PREMISE, and the ORDER MATTERS — this is the operator-reachable sequence, which the first
        //    draft of this section got wrong. The tag card is the FIRST of the view's five chained
        //    `.sheet` modifiers and it is modal, so the operator cannot open a row's per-item sheet while
        //    it is up. The card is therefore resolved FIRST, leaving the finish held by the draining
        //    phone alone; only then can a per-item sheet be opened.
        psSession.skipMacTags(groupId: "P1")
        check("resolving the card leaves the finish held by the draining phone alone",
              psProc.pendingFinish && psSession.pendingTagGroup == nil
                  && psSession.phonePendingActive && !psProc.showRotationReview)

        // 4. THE FIX. The operator opens a per-item sheet while waiting, and the phone then drains —
        //    entering `proceedToFinishIfReady` through `phoneStatusChanged`. The finish is HELD, not
        //    advanced: no review, no collection sheet, no regeneration.
        //
        //    NON-VACUITY IS THE POINT OF THE LAST FOUR TERMS. Every OTHER term of that guard is asserted
        //    independently false here — card resolved, nothing still processing, phone drained — so the
        //    hold is attributable to the sheet and to nothing else. Without them this check passes on a
        //    finish that is stuck for an unrelated reason, which is exactly what the first run of this
        //    section did: `requestFinish`'s force-completion had left the card outstanding, and the card
        //    term of the same guard was doing all the work.
        //
        //    The negative wait is WALL-CLOCK, not an iteration count: by this point in the run a dozen
        //    earlier `CaptureSession`s are still alive with their own 5 s heal ticks, and under parasitic
        //    CPU load 25 ms sleeps landed ~160 ms apart — an iteration count that looked like 5.5 s
        //    measured 35 s and blew `test-recovery.sh`'s 60 s report wait outright (`W21.recovery-timeout`
        //    carries the numbers). It is deliberately SHORT: an earlier draft waited 5.5 s to "cover a
        //    watchdog period", which an adversarial pass correctly called unbacked — a tick that never
        //    armed is indistinguishable from one that fired and was held, and under M1 the advance is
        //    synchronous inside `updatePhonePending(0)`, so a 0.2 s wait kills it identically. The
        //    watchdog leg is NOT asserted here; nothing in this driver observes it.
        psProc.rotationRetryTarget = .init(groupId: "P1")
        psSession.updatePhonePending(0)
        var psRaisedWhileHeld = false
        let psDeadline = Date().addingTimeInterval(0.75)
        while Date() < psDeadline {
            if psProc.showRotationReview || psProc.showFinalizeSheet || psProc.isFinalizing {
                psRaisedWhileHeld = true
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        check("with a per-item sheet up, a drained Finish is HELD — the review is not raised over it",
              !psRaisedWhileHeld && psProc.pendingFinish && psProc.perItemSheetUp
                  && psSession.pendingTagGroup == nil && !psSession.phonePendingActive
                  && psProc.statuses.first { $0.id == "P1" }?.phase == .staged
                  && psProc.processingCount == 0)

        // 5. The hold is not a refusal — the operator's in-flight action still works. This is the
        //    deferred Apply `W3.cap-r3-fu7` named: it buys the segment's OCR again (2 pages), which is
        //    correct here because no finish is in flight. Then `onApply` clears the target, exactly as
        //    the sheet does.
        psProc.retryFailed(groupIds: ["P1"])
        psProc.rotationRetryTarget = nil
        let psGateAfterClear = psProc.perItemSheetUp   // sampled BEFORE any await; see check 6
        let psReStaged = await psSettle { psProc.statuses.first { $0.id == "P1" }?.phase == .staged }
        check("the deferred Apply is allowed while the finish waits, and re-stages the segment",
              psReStaged && psPaidStarts() == psPaidAfterStage + 2
                  && psProc.retainedText(for: "P1") != nil)

        // 6. THE OTHER HALF OF THE FIX, and the one an adversarial pass had to put here: a cleared target
        //    is NOT the sheet leaving the screen. `.sheet(item:)` and the sheet's own Apply/Cancel/Dismiss
        //    write nil while AppKit is still animating it out (~0.2–0.4 s), so the FIRST version of this
        //    fix — which advanced the finish one MainActor turn after that write — raised the review
        //    DURING the outgoing sheet's teardown, making the concurrent presentation the ORDINARY path
        //    rather than the rare race the item was filed for. `LiveCaptureProcessor.perItemSheetGrace`
        //    is the answer: the gate stays UP for 1.5 s after the last target clears. Asserted as a PAIR,
        //    because either half alone is satisfiable by a mistake — a gate that never drops would hold
        //    the finish forever, and one that drops immediately is the shipped bug.
        try? await Task.sleep(nanoseconds: 1_700_000_000)   // > perItemSheetGrace
        let psGateAfterGrace = psProc.perItemSheetUp
        check("a cleared target keeps the sheet gate up across the teardown, then drops it",
              psGateAfterClear && !psGateAfterGrace)

        // 7. …and the finish resumes by itself. ⚠️ Scoped honestly, because the first draft claimed more:
        //    the pages CANNOT be shown to be the retried ones — pre- and post-retry reviews have the same
        //    two pages, the same `sourceURL`s and the same stub rotation, and under mutant M1 (review
        //    raised BEFORE the retry) this check still passes. What is real here is that the review is not
        //    LOST and the finish is no longer pending. Which entrant delivers it is also named rather than
        //    guessed: `retryFailed`'s trailing `segmentResolved` → `finalizeSegment` →
        //    `proceedToFinishIfReady`, i.e. the segment-staging caller, not the watchdog and not the grace
        //    hop (both of which fire later here).
        let psReview = await psSettle { psProc.showRotationReview }
        check("the held finish resumes and its rotation review is not lost",
              psReview && !psProc.pendingFinish
                  && psProc.rotationReviewPages.filter { $0.groupId == "P1" }.count == 2)

        // 8. THE SECOND LEG the item filed — the operator's rotation edits are APPLIED, not silently
        //    dropped. `applyRotationReviewAndFinalize` only reaches `isFinalizing` when a changed group
        //    survived its `guard var seg = retained[page.groupId]`, so this observable is exactly the
        //    difference between "the edits landed" and "they were discarded on a `retained` a retry had
        //    emptied": a dropped edit leaves `changedGroups` empty and goes straight to `beginFinalize`.
        for i in psProc.rotationReviewPages.indices
        where psProc.rotationReviewPages[i].groupId == "P1" && psProc.rotationReviewPages[i].pageIndex == 0 {
            psProc.rotationReviewPages[i].rotationDegrees = 90
        }
        psProc.applyRotationReviewAndFinalize()
        check("the reviewed rotation is applied, not dropped on a retry-emptied `retained` (fu9)",
              psProc.isFinalizing && psProc.isFinishingScrimUp)

        // 9. And the regeneration lands intact, so the held-then-resumed finish files like any other.
        let psRegen = await psSettle { !psProc.isFinalizing && psProc.showFinalizeSheet }
        let psRecord = psProc.staged.first { $0.groupId == "P1" }
        check("the resumed finish regenerates intact and the segment is still filable (fu9)",
              psRegen && !psProc.isFinishingScrimUp && psProc.failedGroupIds.isEmpty
                  && psRecord?.pagesComplete != false
                  && psRecord?.pdfURLs.isEmpty == false
                  && psRecord?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true)

        if let psPriorReview {
            UserDefaults.standard.set(psPriorReview, forKey: DefaultsKeys.reviewRotation)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
        }
        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }

    /// Test 24 (W3.cap-r3-fu9-fu1) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest24(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        // Prune the throwaway backup root FIRST, exactly as Test 23 does and for a reason this section
        // learned the hard way: `CaptureSession()` recovers orphaned photos out of the session folders
        // left behind by earlier sections, so without this the "session" here starts holding Test 23's
        // two pages as well as its own and check 3's photo count is 4. Every check that matters is about
        // THIS section's two sources, so it starts from an empty root rather than reasoning about which
        // four files it owns.
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let cfOut = tmp.appendingPathComponent("fu9fu1out", isDirectory: true)
        let cfStaging = tmp.appendingPathComponent("APStaging-fu9fu1-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: cfStaging, withIntermediateDirectories: true)
        let cfGate = TestGate()
        let cfSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        LiveCaptureProcessor._recoveryTestOCRGate = { await cfGate.wait() }
        let cfConfig = SessionProcessingConfig(
            provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
            taggingMode: .human, rotationMode: .off, mergeDocuments: false,
            outputDirectory: cfOut,
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
            gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
            textColumns: 1)
        cfSession._recoveryTestBeginLive(config: cfConfig, stagingDir: cfStaging)
        let cfProc = cfSession.liveProcessor
        func cfSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func cfPaidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
        let cfBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)
        let cfJPEG = cfBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()

        // The review must be ON for check 6 to have an observable — `finishSession` with it off goes
        // straight to `beginFinalize`, and "Finish works again" would then be a claim about the finalize
        // sheet instead of the review. Restored at the end (same handling as Test 23).
        let cfPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
        UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)

        // 1. PREMISE. A two-page document is parked MID-OCR at the gate, with both paid calls genuinely
        //    in flight. This is the commonest real hold — the one the pending-finish message calls
        //    "Finishing when processing completes (N left)" — and it is what gives checks 3 and 5 their
        //    money terms: there is paid work outstanding at the moment the operator cancels.
        for seq in [1, 2] {
            cfSession.ingest(jpeg: cfJPEG, groupId: "C1", seq: seq,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        cfProc.segmentResolved(groupId: "C1")
        let cfInOCR = await cfSettle { cfProc.processingCount == 1 }
        let cfPaidInFlight = cfPaidStarts()
        check("a two-page document is held mid-OCR with its paid calls in flight (fu9-fu1)",
              cfInOCR && cfPaidInFlight == 2 && cfProc.staged.isEmpty && !cfProc.isFinalized("C1"))

        // 2. PREMISE. Finish through the REAL `requestFinish`, then resolve the Mac tag card its
        //    force-completion surfaces, so the hold is attributable to the in-flight processing and to
        //    nothing else. Every other term of `proceedToFinishIfReady`'s guard is asserted false here for
        //    the same reason Test 23's check 4 does it: without that, a later check can pass on a finish
        //    that is stuck for an unrelated reason.
        cfProc.requestFinish()
        cfSession.skipMacTags(groupId: "C1")
        check("a Finish pressed mid-OCR goes pending, held by the processing alone (fu9-fu1)",
              cfProc.pendingFinish && cfSession.pendingTagGroup == nil
                  && !cfSession.phonePendingActive && !cfProc.perItemSheetUp
                  && cfProc.processingCount == 1
                  && !cfProc.showRotationReview && !cfProc.showFinalizeSheet && !cfProc.isFinalizing)

        // 3. THE FIX. The operator leaves the wait — and the session is otherwise exactly as it was. The
        //    source-file terms are the point of the whole item: this is the same operator intent that
        //    previously had to be spelled **Clear**, which Trashes every one of these files (Test 22
        //    drives that path). The paid-call term says the same thing about money: cancelling buys
        //    nothing and refunds nothing, it just stops waiting.
        //
        //    ⚠️ THE TASK-HANDLE TERM IS NOT REDUNDANT WITH CHECK 5, and it is here because the obvious
        //    version of the money assertion does not work. A cancel that also cancelled `pageTasks` (the
        //    "cancel means cancel everything" reading, M4) is INVISIBLE to "did the segment stage and did
        //    the paid count stay put": the driver's stub OCR is `Task { await gate?(); return stub }`,
        //    which never consults `Task.isCancelled`, so a cancelled stub still returns its text and the
        //    segment stages exactly as if nothing happened. That was measured, not assumed — M4 was run
        //    against check 5 alone first and came back 0 RED. `pageTasks[key]` and the driver's
        //    `_recoveryTestOCRTasks[key]` are the SAME `Task` object (see the stub branch in `ingest`), so
        //    reading `isCancelled` off the driver's handle is the one place the hazard is observable here.
        //    The count term keeps `allSatisfy` from passing vacuously on an empty dictionary.
        let cfSourcesBefore = cfSession.photos.map(\.url)
        cfProc.cancelPendingFinish()
        let cfSourcesSurvive = cfSourcesBefore.count == 2
            && cfSourcesBefore.allSatisfy { fm.fileExists(atPath: $0.path) }
        let cfTasks = LiveCaptureProcessor._recoveryTestOCRTasks
        check("the operator can leave a pending Finish, and it costs the session nothing (fu9-fu1)",
              !cfProc.pendingFinish && cfSession.photos.count == 2 && cfSourcesSurvive
                  && cfProc.processingCount == 1 && cfPaidStarts() == cfPaidInFlight
                  && cfTasks.count == 2 && cfTasks.values.allSatisfy { !$0.isCancelled }
                  && cfProc.staged.isEmpty
                  && !cfProc.showRotationReview && !cfProc.showFinalizeSheet && !cfProc.isFinalizing
                  && cfSession.statusMessage.contains("Finish cancelled"))

        // 4. The `guard pendingFinish` is real. A cancel with nothing armed must not narrate a finish that
        //    was not happening over whatever the status line was actually saying — the view renders the
        //    button on the same predicate, so this is the model half agreeing with it rather than trusting
        //    it (`W3.cap-r3-fu11`'s shape).
        cfSession.statusMessage = "fu9-fu1 sentinel"
        cfProc.cancelPendingFinish()
        check("cancelling with no finish armed is a true no-op (fu9-fu1)",
              !cfProc.pendingFinish && cfSession.statusMessage == "fu9-fu1 sentinel")

        // 5. IT IS A CANCEL, NOT A DEFERRAL — and it threw nothing away. Opening the gate releases the
        //    hold that the finish was waiting on, which is the exact event that would have advanced it:
        //    `finalizeSegment`'s trailing `proceedToFinishIfReady`. It must find nothing armed. Meanwhile
        //    the two calls that were in flight during the cancel still land — the segment stages, its text
        //    is retained, its PDF exists — with no third call bought.
        //
        //    ⚠️ These terms do NOT catch a cancel that also cancels `pageTasks` (M4); the stub OCR ignores
        //    cancellation, so the segment stages either way. That leg is check 3's task-handle term, and
        //    it lives there rather than here precisely because this check reads as if it covered it.
        //
        //    ⚠️ THE RESUME TERMS ARE SAMPLED ONCE, not polled, and an earlier draft's 0.5 s negative
        //    window is deleted rather than kept for comfort — an adversarial pass showed it could not
        //    discriminate anything. `labelStagedRecord` sets `.staged` and calls `proceedToFinishIfReady`
        //    in the SAME MainActor turn with no suspension between them, so by the time a 25 ms poll can
        //    observe `.staged` at all, the entrant named above has already run: the sample is strictly
        //    after the event. And the only DEFERRED resumers the code has are `perItemSheetDidChange`'s
        //    hop (grace + 0.1 s ≈ 1.6 s) and the 5 s watchdog — both outside 0.5 s, so the window covered
        //    neither. Those two legs are therefore NOT asserted here; both are `guard pendingFinish` on
        //    the same flag this check reads false, and waiting them out would cost 5 s against
        //    `W21.recovery-timeout`'s shrinking headroom for no new information.
        cfGate.open()
        let cfStaged = await cfSettle { cfProc.statuses.first { $0.id == "C1" }?.phase == .staged }
        let cfResumed = cfProc.showRotationReview || cfProc.showFinalizeSheet || cfProc.isFinalizing
            || cfProc.pendingFinish
        let cfRecord = cfProc.staged.first { $0.groupId == "C1" }
        check("a cancelled finish does not resume, and the paid work in flight is not thrown away (fu9-fu1)",
              cfStaged && !cfResumed && cfPaidStarts() == cfPaidInFlight
                  && cfProc.retainedText(for: "C1") != nil
                  && cfRecord?.pdfURLs.isEmpty == false
                  && cfRecord?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true
                  && cfProc.failedGroupIds.isEmpty)

        // 6. …and the escape is not a one-way door. Finish again, with nothing left holding it, and the
        //    session finishes normally. An affordance that un-armed the wait but left the flow wedged
        //    would be strictly worse than the Clear it replaces.
        //
        //    `cfNoReviewBefore` makes this a TRANSITION rather than a level, and it is not padding: an
        //    adversarial pass found the level version green for the wrong reason under M3. `requestFinish`
        //    opens `guard !showRotationReview`, so with a review already up (which is exactly what M3's
        //    spurious resume leaves behind) it returns immediately, `cfSettle` sees the pre-existing
        //    review on its zeroth evaluation, and the check passes without this call having done anything.
        let cfNoReviewBefore = !cfProc.showRotationReview
        cfProc.requestFinish()
        let cfReview = await cfSettle { cfProc.showRotationReview }
        check("Finish still works after a cancel — the escape is not a one-way door (fu9-fu1)",
              cfNoReviewBefore && cfReview && !cfProc.pendingFinish
                  && cfProc.rotationReviewPages.filter { $0.groupId == "C1" }.count == 2)

        cfProc.cancelRotationReview()

        // 7. THE PREMISE OF THE SECOND RENDERER, measured rather than argued. A prior staged segment can
        //    be restored even when its original capture photo is missing, leaving no Captured rows while
        //    staging output remains. The operator can press Finish during a live phone hold in this
        //    recovered state, so the cancel row must still render outside the photo gate.
        //
        //    Non-vacuity is in the last two terms: `staged` is non-empty (the session still holds unfiled
        //    work) and the phone hold is LIVE, so the watchdog re-evaluates and re-holds rather than
        //    healing it.
        //
        //    The missing-source recovery fixture is scratch-only: remove the two stub photos from the
        //    temporary backup folder, then reload the staged manifest into a fresh empty session.
        for photo in cfSession.photos { try? fm.removeItem(at: photo.url) }
        let cfRecoveredSession = CaptureSession()
        cfRecoveredSession._recoveryTestBeginLive(config: cfConfig, stagingDir: cfStaging)
        let cfRecoveredProc = cfRecoveredSession.liveProcessor
        cfRecoveredProc._recoveryTestLoadManifest(stagingDir: cfStaging, config: cfConfig)
        cfRecoveredSession.updatePhonePending(1)
        cfRecoveredProc.requestFinish()
        let cfArmedWithEmptyPane = cfRecoveredProc.pendingFinish
        check("a pending Finish outlives an emptied Captured pane — the state the second renderer exists for (fu9-fu1)",
              cfArmedWithEmptyPane && cfRecoveredSession.photos.isEmpty && cfRecoveredProc.pendingFinish
                  && cfRecoveredProc.staged.contains { $0.groupId == "C1" }
                  && cfRecoveredSession.phonePendingActive)

        // 8. …and the escape works from THERE, which is the point of rendering it there. Same model call,
        //    a state the view previously drew nothing in at all.
        cfRecoveredProc.cancelPendingFinish()
        check("the escape works from the emptied pane, and still costs the session nothing (fu9-fu1)",
              !cfRecoveredProc.pendingFinish && cfRecoveredProc.staged.count == 1
                  && cfRecoveredProc.staged.first?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true
                  && cfRecoveredSession.statusMessage.contains("Finish cancelled"))

        if let cfPriorReview {
            UserDefaults.standard.set(cfPriorReview, forKey: DefaultsKeys.reviewRotation)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
        }
        LiveCaptureProcessor._recoveryTestOCRGate = nil
        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }

    /// Test 25 (W3.cap-r3-fu12) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest25(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        // Prune the throwaway backup root FIRST, for the reason Test 24 records: `CaptureSession()` adopts
        // orphaned photos out of the session folders earlier sections left behind, and check 1's
        // single-page premise must be about THIS section's page.
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let uwOut = tmp.appendingPathComponent("fu12out", isDirectory: true)
        let uwFiled = tmp.appendingPathComponent("fu12filed", isDirectory: true)
        let uwGate = TestGate()
        // Missing-source recovery still needs a durable capture epoch. Without a filed ledger,
        // CaptureSession correctly starts fresh and an explicit old staging override can accidentally
        // attach a different session's output to it. A historical ledger keeps this fixture canonical;
        // the fixed old date proves recovery never succeeds by coinciding within the same clock second.
        let uwEpoch = "2001-01-01T00-00-00Z"
        let uwEpochFolder = CaptureSession.backupRoot.appendingPathComponent(uwEpoch, isDirectory: true)
        do {
            try fm.createDirectory(at: uwEpochFolder, withIntermediateDirectories: true)
            let history = CaptureSession.SessionManifest(photos: [], completedDocGroups: [],
                filedGroupIds: ["previously-filed-fixture-group"])
            try JSONEncoder().encode(history).write(
                to: uwEpochFolder.appendingPathComponent("manifest.json"), options: .atomic)
            check("missing-source fixture's historical capture ledger is durable (W34.recov-flake)", true)
        } catch {
            check("missing-source fixture's historical capture ledger is durable (W34.recov-flake)", false)
        }
        var uwSession = CaptureSession()
        check("missing-source fixture recovers its fixed historical epoch (W34.recov-flake)",
              uwSession.sessionId == uwEpoch)
        let uwStaging = LiveCaptureProcessor.stagingDir(for: uwSession)
        try? fm.createDirectory(at: uwStaging, withIntermediateDirectories: true)
        try? fm.createDirectory(at: uwFiled, withIntermediateDirectories: true)
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        let uwConfig = SessionProcessingConfig(
            provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
            // `.human` — a document only reaches the LLM in `.automatic`, so every finalize below runs
            // for real, for $0, with no network.
            taggingMode: .human, rotationMode: .off, mergeDocuments: false,
            outputDirectory: uwOut,
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
            gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
            textColumns: 1, keepPreservationCopies: false)
        uwSession._recoveryTestBeginLive(config: uwConfig, stagingDir: uwStaging)
        var uwProc = uwSession.liveProcessor
        func uwRecoverWithMissingSources() {
            // Model an interrupted session whose source photos vanished but whose independent staging
            // manifest and PDFs survived. Everything lives under the test's redirected /tmp roots.
            for photo in uwSession.photos { try? fm.removeItem(at: photo.url) }
            uwSession = CaptureSession()
            uwSession._recoveryTestBeginLive(config: uwConfig, stagingDir: uwStaging)
            uwProc = uwSession.liveProcessor
            uwProc._recoveryTestLoadManifest(stagingDir: uwStaging, config: uwConfig)
            check("missing-source recovery keeps the capture and staging epoch together (W34.recov-flake)",
                  uwSession.sessionId == uwEpoch
                      && LiveCaptureProcessor.stagingDir(for: uwSession) == uwStaging)
        }
        func uwCheck(_ name: String, _ terms: [(String, Bool)]) {
            for (term, ok) in terms { check("\(name): \(term)", ok) }
        }
        func uwSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        // A REAL, decodable JPEG: the checks below read the staged PDFs as artifacts that filed, and an
        // undecodable page would route through the placeholder path (`W23.h5`) and withhold its source
        // from retirement — a second story this section is not about.
        let uwBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)
        let uwJPEG = uwBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()
        func uwSend(_ gid: String, _ seq: Int) {
            uwSession.ingest(jpeg: uwJPEG, groupId: gid, seq: seq, type: .document,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        func uwEmptyThePane() { for p in uwSession.photos { uwSession.removePhoto(p) } }
        // The rotation review must be OFF so `finishSession` goes straight to `beginFinalize`: checks 4-5
        // are about whether Finish FILES from the emptied pane, not about the review sheet (Test 24 covers
        // the review path). Restored at the end, same handling as Tests 23 and 24.
        let uwPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
        UserDefaults.standard.set(false, forKey: DefaultsKeys.reviewRotation)

        // 1. PREMISE. A one-page document goes all the way to STAGED — OCR through the stub, tag card
        //    resolved, PDF written into the staging dir — and is not yet filed. This is the work the
        //    emptied pane must not strand.
        uwSend("U1", 1)
        uwProc.segmentResolved(groupId: "U1")
        let u1Staged = await uwSettle { uwProc.staged.contains { $0.groupId == "U1" } }
        let u1PDFs = uwProc.staged.first { $0.groupId == "U1" }?.pdfURLs ?? []
        check("a document is staged, written and unfiled — the work an emptied pane must not strand (fu12)",
              u1Staged && uwSession.photos.count == 1 && !u1PDFs.isEmpty
                  && u1PDFs.allSatisfy { fm.fileExists(atPath: $0.path) }
                  && uwProc.statuses.first { $0.id == "U1" }?.phase == .staged
                  && !uwProc.pendingFinish && uwProc.failedGroupIds.isEmpty)

        // 2. PREMISE — THE RECOVERED EMPTY STATE. The source photo is missing, but the independent staging
        //    manifest and PDF survived. This retains Finish/Clear coverage without implying that an ✕ can
        //    remove a page whose segment is already staged.
        uwRecoverWithMissingSources()
        check("recovery keeps staged work available when its source photo is missing (fu12)",
              uwSession.photos.isEmpty && uwSession.groups.isEmpty
                  && uwProc.staged.count == 1
                  && u1PDFs.allSatisfy { fm.fileExists(atPath: $0.path) }
                  && !uwProc.pendingFinish && !uwSession.phonePendingActive && !uwProc.isFinalizing)

        // 3. THE GATE. `hasUnfiledWork` is the predicate the header's second arm draws on, and the two
        //    terms after it are Finish's own `.disabled` inverted (`statuses.isEmpty || isFinalizing`) —
        //    so this says the cluster's condition holds AND the button inside it would be pressable, which
        //    is the whole model-side claim of the decision. Before this item both were true here and the
        //    view asked `session.photos` anyway.
        //
        //    ⚠️ HONEST LIMIT, added after an adversarial pass called this out: as an assertion about
        //    `hasUnfiledWork` this check DISCRIMINATES NOTHING. `hasUnfiledWork` is `!statuses.isEmpty ||
        //    pendingFinish`, so its first term is implied by the second term of this very check — any
        //    implementation of the shape `!statuses.isEmpty || X` passes, and so does M2's `!staged.isEmpty`
        //    (measured). It is a PREMISE, worth stating because it names the state the header now reads;
        //    all of the gate's discriminating power lives in checks 5 and 6 (the OFF direction), 7 (the
        //    width) and 8 (`canFinish` coming apart from it).
        check("...and the gate the header now draws on is TRUE there, with Finish's own predicate open (fu12)",
              uwProc.hasUnfiledWork && !uwProc.statuses.isEmpty && !uwProc.isFinalizing
                  && uwProc.canFinish)

        // 4. THE DECISION, first half: Finish from the emptied pane REACHES collection naming. The term
        //    worth reading is the premise, not the result — `requestFinish` starts with
        //    `session.completeAllOpenDocGroups()` over a session with no groups at all. It returns true
        //    vacuously (nothing newly completed, so no manifest write to fail), but had it returned false
        //    the finish would have died in its "Could not save session completion" branch and this
        //    decision could not have been implemented at all. Asserted rather than assumed.
        uwProc.requestFinish()
        let u1Draft = uwProc.drafts.first
        check("Finish from an emptied pane reaches collection naming instead of dying in its error branch (fu12)",
              !uwProc.pendingFinish && uwProc.showFinalizeSheet
                  && uwProc.drafts.count == 1 && u1Draft?.segmentCount == 1
                  && !uwSession.statusMessage.contains("Could not save session completion"))

        // 5. …and it FILES — to disk, and the gate turns off behind it. The destination is an explicit
        //    `chosenExisting` under `tmp` (file safety: that is the one path `finalize` takes that never
        //    consults `currentOutputDirectory`, whose non-test fallback is the operator's real output
        //    folder). The last term is the gate's non-vacuity in the direction that matters: a fully
        //    successful finish empties the roster, so the cluster does NOT linger over the green "Session
        //    complete" summary offering to finish a session with nothing left in it.
        uwProc.finalize([LiveCaptureProcessor.CollectionDraft(
            id: u1Draft?.id ?? "__unfiled__", finalName: uwFiled.lastPathComponent,
            existingFolders: [], suggestedFolders: [], chosenExisting: uwFiled,
            segmentCount: 1, photoCount: 1)])
        let u1Filed = await uwSettle { !uwProc.isFinalizing && uwProc.staged.isEmpty }
        let filedPDFs = ((try? fm.contentsOfDirectory(at: uwFiled, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
        check("...and it files for real, after which the gate is OFF — nothing left to finish (fu12)",
              u1Filed && !filedPDFs.isEmpty && uwProc.statuses.isEmpty
                  && uwProc.finalizeSummary != nil && !uwProc.hasUnfiledWork)

        // A successful finalize reclaims _processed. Clear still has to be able to write its empty roster
        // from that normal post-finish state, rather than treating the remembered but absent path as ready.
        let stagingWasReclaimedAfterFinish = !fm.fileExists(atPath: uwStaging.path)
        check("a successful Finish reclaimed its _processed folder before the next Clear (fu12-fu2)",
              stagingWasReclaimedAfterFinish)
        uwProc.clearSession()
        let postFinishClearData = try? Data(contentsOf: uwStaging.appendingPathComponent("staging-manifest.json"))
        let postFinishClear = postFinishClearData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("Clear recreates the reclaimed staging folder after a successful Finish (fu12-fu2)",
              (postFinishClear?["staged"] as? [Any])?.isEmpty == true
                  && (postFinishClear?["clearToken"] as? String) != nil)

        // 6. THE DECISION, second half: Clear abandons from the emptied pane and leaves the processed
        //    output in the visible backup folder. It must also durably invalidate the staging roster before
        //    a relaunch can offer those segments again — particularly because this recovered fixture's
        //    retained source URLs are already missing. Note what Clear costs from THIS state versus the
        //    Clear Test 22 drives: `session.clear()` Trashes `photos`, and `photos` is empty, so it
        //    Trashes nothing whatsoever.
        //
        //    Finish reclaimed the spent staging dir along with the batch (`W3.cap-r6`), so put it back
        //    before staging U2 — same handling as Test 17's re-finalize.
        try? fm.createDirectory(at: uwStaging, withIntermediateDirectories: true)
        uwSend("U2", 1)
        uwProc.segmentResolved(groupId: "U2")
        let u2Staged = await uwSettle { uwProc.staged.contains { $0.groupId == "U2" } }
        let u2PDFs = uwProc.staged.first { $0.groupId == "U2" }?.pdfURLs ?? []
        uwRecoverWithMissingSources()
        uwCheck("recovered Clear fixture (fu12)", [
            ("U2 reached staging", u2Staged),
            ("source roster empty", uwSession.photos.isEmpty),
            ("unfiled work offered", uwProc.hasUnfiledWork),
            ("processed PDFs nonempty", !u2PDFs.isEmpty),
            ("processed PDFs present", u2PDFs.allSatisfy { fm.fileExists(atPath: $0.path) })
        ])
        // Stage-for-later does not activate LiveCaptureProcessor. Drop its selected path to model that
        // relaunch shape while leaving U2's real canonical staging manifest in place.
        check("Stage-for-later Clear targets the recovered session's canonical staging folder (W34.recov-flake)",
              LiveCaptureProcessor.stagingDir(for: uwSession) == uwStaging)
        uwProc._recoveryTestDisarmForStageLaterClear()
        uwProc.clearSession()
        let clearedStageData = try? Data(contentsOf: uwStaging.appendingPathComponent("staging-manifest.json"))
        let clearedStageObject = clearedStageData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let clearedStageRows = clearedStageObject?["staged"] as? [Any]
        uwCheck("Clear abandons an emptied pane's unfiled work (fu12)", [
            ("staged roster empty", uwProc.staged.isEmpty),
            ("status roster empty", uwProc.statuses.isEmpty),
            ("unfiled gate closed", !uwProc.hasUnfiledWork),
            ("no pending finish", !uwProc.pendingFinish),
            ("durable staging roster empty", clearedStageRows?.isEmpty == true),
            ("durable clear token present", (clearedStageObject?["clearToken"] as? String) != nil),
            ("every processed PDF preserved", u2PDFs.allSatisfy { fm.fileExists(atPath: $0.path) })
        ])

        // Clear used to be only an in-memory reset, leaving U2's verified manifest to restore it on launch.
        // With Review Rotation enabled, that made the removed source pages appear in the review, and Apply
        // silently skipped regeneration when it found their paths missing. Reload the same scratch
        // manifest through the real loader, then assert Clear closed that recovery path without deleting
        // the `_processed` PDFs.
        UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
        uwSession = CaptureSession()
        uwSession._recoveryTestBeginLive(config: uwConfig, stagingDir: uwStaging)
        uwProc = uwSession.liveProcessor
        uwProc._recoveryTestLoadManifest(stagingDir: uwStaging, config: uwConfig)
        uwProc.finishSession()
        uwCheck("Clear stays cleared after relaunch (fu12-fu2)", [
            ("staged roster empty", uwProc.staged.isEmpty),
            ("review pages empty", uwProc.rotationReviewPages.isEmpty),
            ("review not shown", !uwProc.showRotationReview),
            ("unfiled gate closed", !uwProc.hasUnfiledWork),
            ("every processed PDF preserved", u2PDFs.allSatisfy { fm.fileExists(atPath: $0.path) })
        ])
        UserDefaults.standard.set(false, forKey: DefaultsKeys.reviewRotation)

        // 7. THE `processingCount` HALF OF THE FIX: the new arm must not be able to draw a "Processing…"
        //    spinner that can never stop. A page parked mid-OCR whose photo is then deleted leaves a
        //    `.ocr` row behind (`photoRemoved` cancels the task and keeps the row), and `session.groups`
        //    is derived from `session.photos` — so with the pane empty EVERY in-flight row is orphaned and
        //    can never resolve. `proceedToFinishIfReady` has always excluded those from the hold; before
        //    this item the property the UI shows did not, and it was survivable only because the cluster
        //    was hidden in exactly this state. The last term is the roster staying non-empty: there is
        //    still something here, so the operator still needs Clear to be offered — the fix narrows the
        //    COUNT without narrowing the gate.
        try? fm.createDirectory(at: uwStaging, withIntermediateDirectories: true)
        LiveCaptureProcessor._recoveryTestOCRGate = { await uwGate.wait() }
        uwSend("U3", 1)
        let u3InOCR = await uwSettle { uwProc.statuses.contains { $0.id == "U3" && $0.phase == .ocr } }
        uwEmptyThePane()
        check("an orphaned in-flight row is not counted as processing — no spinner that can never stop (fu12)",
              u3InOCR && uwSession.groups.isEmpty
                  && uwProc.statuses.contains { $0.id == "U3" && $0.phase == .ocr }
                  && uwProc.processingCount == 0 && uwProc.hasUnfiledWork)

        // 8. …AND FINISH IS NOT OFFERED IN THAT SAME STATE, which is the correction this item's adversarial
        //    pass forced. Check 7 above leaves the app holding a roster of nothing but an orphaned row, and
        //    the first version of this item drew a `.borderedProminent` "Finish session →" there, ENABLED:
        //    `statuses` non-empty, not finalizing. Pressing it did nothing whatsoever — `requestFinish`
        //    arms the flag and spawns a watchdog, `proceedToFinishIfReady` finds every hold open (this
        //    item's own `processingCount` filter is what lets it through), lowers the flag, and
        //    `finishSession` returns on `guard !staged.isEmpty`. No sheet, no status message, no state
        //    change, one orphaned Task per press. The pass's sharpest point was that check 7 did not merely
        //    miss it — it CREATED the state and asserted `hasUnfiledWork`, i.e. it blessed drawing the
        //    cluster there while never pressing the button.
        //
        //    So the two gates must come APART here, and that is what this asserts: `hasUnfiledWork` true
        //    (the operator still needs **Clear** — narrowing the arm instead would have re-stranded them)
        //    while `canFinish` is false (nothing to file, and no group that `completeAllOpenDocGroups`
        //    could recover). The last two terms drive the press anyway and pin that it is inert: the
        //    model-layer refusal is `finishSession`'s guard, and `canFinish` is only the operator-facing
        //    half that stops it being offered — `W3.cap-r3-fu11`'s shape, and the same reason that item put
        //    its load-bearing guard in `clearSession()` rather than in a `.disabled`.
        let u8SummaryBefore = uwProc.finalizeSummary
        uwProc.requestFinish()
        let u8Settled = await uwSettle { !uwProc.pendingFinish }
        uwCheck("Finish is not offered for the orphaned row (fu12)", [
            ("Clear still offered", uwProc.hasUnfiledWork),
            ("Finish predicate closed", !uwProc.canFinish),
            ("pending finish settled", u8Settled),
            ("rotation review not shown", !uwProc.showRotationReview),
            ("finalize sheet not shown", !uwProc.showFinalizeSheet),
            ("not finalizing", !uwProc.isFinalizing),
            ("staged roster empty", uwProc.staged.isEmpty),
            ("summary unchanged", uwProc.finalizeSummary == u8SummaryBefore)
        ])

        uwGate.open()
        LiveCaptureProcessor._recoveryTestOCRGate = nil

        // A required original changes the verdict for an otherwise complete derivative.
        // Restore the exact intake file and finish the original pinned operation.
        var preserveConfig = uwConfig
        preserveConfig.keepPreservationCopies = true
        uwSession = CaptureSession()
        uwSession._recoveryTestBeginLive(config: preserveConfig, stagingDir: uwStaging)
        uwProc = uwSession.liveProcessor
        let preserveDestination = uwOut.appendingPathComponent("Preserve receipt", isDirectory: true)
        try? fm.createDirectory(at: preserveDestination, withIntermediateDirectories: true)
        uwSend("U4", 2)
        uwProc.segmentResolved(groupId: "U4")
        let preserveStaged = await uwSettle { uwProc.staged.contains { $0.groupId == "U4" } }
        if let source = uwSession.photos.first(where: { $0.groupId == "U4" })?.url, preserveStaged {
            let held = uwOut.appendingPathComponent("held-preservation-original.jpg")
            do {
                try fm.moveItem(at: source, to: held)
                defer {
                    if fm.fileExists(atPath: held.path) { try? fm.moveItem(at: held, to: source) }
                }
                func finishPreservation() {
                    uwProc.requestFinish()
                    uwProc.finalize([LiveCaptureProcessor.CollectionDraft(
                        id: uwProc.drafts.first?.id ?? "__unfiled__", finalName: preserveDestination.lastPathComponent,
                        existingFolders: [], suggestedFolders: [], chosenExisting: preserveDestination,
                        segmentCount: 1, photoCount: 1)])
                }
                finishPreservation()
                let refused = await uwSettle {
                    !uwProc.isFinalizing && uwProc.staged.first(where: { $0.groupId == "U4" })?.catalogueDestination != nil
                }
                let contents = try fm.contentsOfDirectory(at: preserveDestination, includingPropertiesForKeys: nil)
                check("a missing required original keeps Live Capture staging and withholds the reading PDF",
                      refused && !uwSession.filedGroupIds.contains("U4")
                          && !contents.contains { $0.pathExtension == "pdf" }
                          && (try? Data(contentsOf: held)) == uwJPEG)

                try fm.moveItem(at: held, to: source)
                finishPreservation()
                let recovered = await uwSettle { !uwProc.isFinalizing && uwProc.staged.isEmpty }
                let sourceDirectory = preserveDestination.appendingPathComponent(PreservationCopy.directoryName)
                let stored = (fm.enumerator(at: sourceDirectory, includingPropertiesForKeys: nil)?.allObjects ?? [])
                    .compactMap { $0 as? URL }.first { $0.pathExtension == source.pathExtension }
                let filedPDF = try fm.contentsOfDirectory(at: preserveDestination, includingPropertiesForKeys: nil)
                    .first { $0.pathExtension == "pdf" }
                let expectedName = filedPDF?.deletingPathExtension().appendingPathExtension(source.pathExtension)
                    .lastPathComponent
                let exact = stored.flatMap { try? Data(contentsOf: $0) } == uwJPEG
                check("Live Capture retries the pinned filing and keeps the exact restored original before retiring staging",
                      recovered && exact && stored?.lastPathComponent == expectedName
                          && !fm.fileExists(atPath: source.path))
            } catch {
                check("Live Capture preservation recovery fixture could be exercised", false)
            }
        } else {
            check("Live Capture preservation recovery fixture stages a real derivative", false)
        }
        if let uwPriorReview {
            UserDefaults.standard.set(uwPriorReview, forKey: DefaultsKeys.reviewRotation)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
        }
        LiveCaptureProcessor._recoveryTestOCRGate = nil
        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }

    /// W3.cap-r3-fu12-fu2 review regression of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest25fu2(check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let journalFolder = CaptureSession.backupRoot
            .appendingPathComponent("9999-12-31T23-59-59Z", isDirectory: true)
        try? fm.createDirectory(at: journalFolder, withIntermediateDirectories: true)
        let source = journalFolder.appendingPathComponent("00001-CLEAR-CRASH.jpg")
        let manifestURL = journalFolder.appendingPathComponent("manifest.json")
        let token = "recovery-test-clear-token"
        let entry = CaptureSession.ManifestEntry(name: source.lastPathComponent, groupId: "CLEAR-CRASH",
                                                 seq: 1, type: CaptureGroupType.document.rawValue,
                                                 quality: nil, year: nil, month: nil)
        let committed = CaptureSession.SessionManifest(photos: [entry], completedDocGroups: [],
                                                       clearPhase: "committed", clearToken: token)
        do {
            try Data("synthetic committed-clear source".utf8).write(to: source, options: .atomic)
            try JSONEncoder().encode(committed).write(to: manifestURL, options: .atomic)
        } catch {
            check("committed Clear crash fixture is writable", false)
        }
        let selected = CaptureSession.latestUnprocessedSession(under: CaptureSession.backupRoot)
        check("a committed Clear without filed groups is selected with its source cleanup journal",
              selected?.folder.standardizedFileURL == journalFolder.standardizedFileURL
                  && selected?.photos.count == 1 && selected?.filed.isEmpty == true
                  && selected?.clearPhase == "committed")

        let resumed = CaptureSession()
        let afterData = try? Data(contentsOf: manifestURL)
        let after = afterData.flatMap { CaptureSession.decodeManifest($0) }
        check("launch completes committed Clear and removes the source from the Captured roster",
              resumed.incomingFolder.standardizedFileURL == journalFolder.standardizedFileURL
                  && resumed.photos.isEmpty && resumed.clearPhase == nil
                  && !fm.fileExists(atPath: source.path) && after?.clearPhase == nil
                  && after?.entries.isEmpty == true)
    }

    /// Test 26 (W3.cap-r3-fu8) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest26to29(tmp: URL, staging: URL, stubModel: LLMModel, bitmap: NSBitmapImageRep?, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let rsOut = tmp.appendingPathComponent("fu8out", isDirectory: true)
        let rsStaging = tmp.appendingPathComponent(
            "APStaging-fu8-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        try? fm.createDirectory(at: rsStaging, withIntermediateDirectories: true)
        let rsConfig = SessionProcessingConfig(
            provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
            // `.human` — no document reaches the tag LLM; all calls below are the $0 OCR stub.
            taggingMode: .human, rotationMode: .off, mergeDocuments: false,
            outputDirectory: rsOut,
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
            gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
            textColumns: 1)
        let rsSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        rsSession._recoveryTestBeginLive(config: rsConfig, stagingDir: rsStaging)
        let rsWriter = rsSession.liveProcessor
        func rsSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }

        // Create the record through the real ingest → OCR → finalize path. The transient write refusal
        // makes `writeSegmentFiles` return an empty record, so the first classifier earns `.noOutput`.
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: rsStaging.path)
        rsSession.ingest(jpeg: Data("synthetic page bytes".utf8), groupId: "R1", seq: 1,
                         type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        rsWriter.segmentResolved(groupId: "R1")
        let rsFailed = await rsSettle { rsWriter.failedGroupIds == ["R1"] }
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: rsStaging.path)
        rsWriter._recoveryTestPersistManifest()
        let rsManifest = rsStaging.appendingPathComponent("staging-manifest.json")
        check("a real no-output segment is persisted as the CURRENT manifest resume fixture (fu8)",
              rsFailed && fm.fileExists(atPath: rsManifest.path)
                  && rsWriter.staged.first { $0.groupId == "R1" }?.pdfURLs.isEmpty == true)

        // A distinct processor is the relaunched app. The seam skips only the unsafe global legacy prune;
        // decode and status reconstruction are the production `loadStagingManifest` implementation.
        let rsStartsBeforeResume = LiveCaptureProcessor._recoveryTestOCRStarts.count
        let rsResumed = LiveCaptureProcessor(session: rsSession)
        rsResumed._recoveryTestLoadManifest(stagingDir: rsStaging, config: rsConfig)
        let rsRow = rsResumed.statuses.first { $0.id == "R1" }
        check("a resumed no-output record returns FAILED, with its reason, and is offered for retry (fu8)",
              rsRow?.phase == .failed && rsRow?.failureKind == .noOutput
                  && rsRow?.pageCount == 1
                  && rsResumed.failedGroupIds == ["R1"] && rsResumed.isFinalized("R1"))
        check("resume itself buys NO replacement OCR — retry remains an operator decision (fu8)",
              LiveCaptureProcessor._recoveryTestOCRStarts.count == rsStartsBeforeResume)

        // Drive the exact no-argument bulk action that reads `failedGroupIds`; passing ["R1"] explicitly
        // would make this green even if resume still hid the segment, and would prove the wrong thing.
        rsResumed.retryFailed()
        let rsRetryStarted = LiveCaptureProcessor._recoveryTestOCRStarts.count == rsStartsBeforeResume + 1
        check("the existing bulk retry buys exactly one replacement call only after the operator asks (fu8)",
              rsRetryStarted)
        let rsRestaged = await rsSettle {
            rsResumed.staged.contains { $0.groupId == "R1" }
                && !rsResumed.failedGroupIds.contains("R1")
        }
        check("the explicitly retried resumed segment re-stages through the ordinary recovery path (fu8)",
              rsRestaged && rsResumed.statuses.first { $0.id == "R1" }?.phase == .succeededPlaceholderImage)

        // --- Test 27 (W17.stg1): recovery must distinguish an absent manifest from an untrustworthy one.
        // A current record is self-identifying (schema + canonical SHA-256 fingerprint); any rejected
        // bytes become a Finder-visible `staging-manifest.corrupt-*.json`, and the normal persistence
        // path stays blocked so it cannot write a new empty manifest over the evidence. All fixtures are
        // inside `tmp`; `integrityArtifact` stands in for a processed PDF that recovery must never touch.
        let integrityDir = tmp.appendingPathComponent("manifest-integrity", isDirectory: true)
        try? fm.createDirectory(at: integrityDir, withIntermediateDirectories: true)
        let integrityArtifact = integrityDir.appendingPathComponent("still-recoverable.pdf")
        try? Data("processed artifact".utf8).write(to: integrityArtifact)
        let integritySegment = LiveCaptureProcessor.StagedSegment(
            groupId: "W17-integrity", type: CaptureGroupType.document.rawValue,
            collectionKey: "__unfiled__", order: 1, pdfURLs: [integrityArtifact], imageURLs: [],
            jsonURL: nil, boxLabelText: nil, pagesComplete: true)
        let integrityWriter = LiveCaptureProcessor(session: rsSession)
        integrityWriter._recoveryTestArm(stagingDir: integrityDir, config: rsConfig, staged: [integritySegment])
        integrityWriter._recoveryTestPersistManifest()
        let integrityManifest = integrityDir.appendingPathComponent("staging-manifest.json")
        let currentData = try? Data(contentsOf: integrityManifest)
        let currentPeek = currentData.flatMap { try? JSONDecoder().decode(ManifestPeek.self, from: $0) }
        let validResume = LiveCaptureProcessor(session: rsSession)
        validResume._recoveryTestLoadManifest(stagingDir: integrityDir, config: rsConfig)
        check("a current staging manifest carries schema + fingerprint and resumes intact (W17.stg1)",
              currentPeek?.schemaVersion == 1 && !(currentPeek?.fingerprint.isEmpty ?? true)
                  && validResume.staged.count == 1
                  && validResume.staged.first?.groupId == integritySegment.groupId
                  && validResume.staged.first?.pdfURLs == [integrityArtifact]
                  && !validResume.stagingRecoveryBlocked)

        func changedCurrentManifest(_ change: (inout [String: Any]) -> Void) -> Data? {
            guard let currentData,
                  var object = (try? JSONSerialization.jsonObject(with: currentData)) as? [String: Any] else {
                return nil
            }
            change(&object)
            return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        func rejectedManifest(_ label: String, _ bytes: Data?) -> Bool {
            guard let bytes else { return false }
            // One directory per rejected body: once one case has quarantined its record, that durable
            // marker is SUPPOSED to block every future launch in that directory. Reusing it would make
            // the next case test the previous marker rather than this case's bytes.
            let caseDir = tmp.appendingPathComponent("manifest-rejection-\(label)", isDirectory: true)
            try? fm.createDirectory(at: caseDir, withIntermediateDirectories: true)
            let caseWriter = LiveCaptureProcessor(session: rsSession)
            caseWriter._recoveryTestArm(stagingDir: caseDir, config: rsConfig, staged: [integritySegment])
            caseWriter._recoveryTestPersistManifest()
            let caseManifest = caseDir.appendingPathComponent("staging-manifest.json")
            let before = Set((try? fm.contentsOfDirectory(at: caseDir, includingPropertiesForKeys: nil))?
                .map(\.lastPathComponent) ?? [])
            try? bytes.write(to: caseManifest, options: .atomic)
            let rejected = LiveCaptureProcessor(session: rsSession)
            rejected._recoveryTestLoadManifest(stagingDir: caseDir, config: rsConfig)
            // This must remain a no-op after the rejected load: no clean `staging-manifest.json` may
            // appear until an operator has recovered the quarantined evidence.
            rejected._recoveryTestPersistManifest()
            let after = (try? fm.contentsOfDirectory(at: caseDir, includingPropertiesForKeys: nil)) ?? []
            guard let quarantined = after.first(where: {
                $0.lastPathComponent.hasPrefix("staging-manifest.corrupt-")
                    && !before.contains($0.lastPathComponent)
            }), let quarantinedData = try? Data(contentsOf: quarantined) else { return false }
            // A fresh process sees the preserved quarantine marker, not an absent-manifest "new session".
            // Its normal persistence path must stay blocked too; this is the restart boundary that the
            // original silent-open loader had no representation for.
            let startsBeforeRestartProbe = LiveCaptureProcessor._recoveryTestOCRStarts.count
            let restarted = LiveCaptureProcessor(session: rsSession)
            restarted._recoveryTestLoadManifest(stagingDir: caseDir, config: rsConfig)
            if let photo = rsSession.photos.first { restarted.photoIngested(photo) }
            restarted._recoveryTestPersistManifest()
            return rejected.stagingRecoveryBlocked && rejected.staged.isEmpty
                && rejected.stagingRecoveryNotice != nil
                && restarted.stagingRecoveryBlocked && restarted.staged.isEmpty
                && restarted.stagingRecoveryNotice != nil
                && LiveCaptureProcessor._recoveryTestOCRStarts.count == startsBeforeRestartProbe
                && !fm.fileExists(atPath: caseManifest.path)
                && quarantinedData == bytes
                && fm.fileExists(atPath: integrityArtifact.path)
        }

        let fingerprintTamper = changedCurrentManifest { object in
            var staged = object["staged"] as? [[String: Any]] ?? []
            if !staged.isEmpty { staged[0]["groupId"] = "W17-tampered" }
            object["staged"] = staged
        }
        check("a fingerprint mismatch quarantines exact bytes and blocks recovery (W17.stg1)",
              rejectedManifest("fingerprint", fingerprintTamper))
        let unknownVersion = changedCurrentManifest { $0["schemaVersion"] = 999 }
        check("an unknown manifest version quarantines rather than resuming (W17.stg1)",
              rejectedManifest("unknown-version", unknownVersion))
        let missingVersion = changedCurrentManifest { $0.removeValue(forKey: "schemaVersion") }
        check("a manifest missing its schema version quarantines rather than resuming (W17.stg1)",
              rejectedManifest("missing-version", missingVersion))
        let missingFingerprint = changedCurrentManifest { $0.removeValue(forKey: "fingerprint") }
        check("a manifest missing its fingerprint quarantines rather than resuming (W17.stg1)",
              rejectedManifest("missing-fingerprint", missingFingerprint))
        let oldUnversioned = try? JSONEncoder().encode([integritySegment])
        check("an old unversioned manifest quarantines rather than resuming (W17.stg1)",
              rejectedManifest("unversioned", oldUnversioned))

        // --- Test 27b (W40.e6): seeded damage to the same current record. A crash or a resumed record that
        // differs from what was written is a failure; resuming the identical record (the damage was only
        // whitespace, say) or quarantining exactly as above is a pass. Seeded, so a failure reproduces.
        func canonical(_ staged: [LiveCaptureProcessor.StagedSegment]) -> Data? {
            let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
            return try? e.encode(staged)
        }
        var fuzzState: UInt64 = 0xE6_57A6
        func fuzzInt(_ n: Int) -> Int {   // SplitMix64, 0..<n
            fuzzState &+= 0x9E37_79B9_7F4A_7C15
            var z = fuzzState
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(max(n, 1)))
        }
        var fuzzResumed = 0, fuzzQuarantined = 0, fuzzBad: [String] = []
        if let currentData, let wantStaged = canonical([integritySegment]) {
            for i in 0..<60 {
                var b = [UInt8](currentData)
                for _ in 0..<(1 + fuzzInt(3)) {
                    let n = b.count
                    guard n > 1 else { break }
                    switch fuzzInt(6) {
                    case 0: b = Array(b.prefix(fuzzInt(n)))                                   // truncate
                    case 1: b[fuzzInt(n)] ^= UInt8(1 << fuzzInt(8))                           // flip a bit
                    case 2: b.insert(Array("{}[]\":,\\0 ".utf8)[fuzzInt(10)], at: fuzzInt(n + 1)) // insert
                    case 3: let a = fuzzInt(n); b.insert(contentsOf: b[a..<min(n, a + 1 + fuzzInt(40))], at: fuzzInt(n + 1))
                    case 4: b = Array("{\"staged\":".utf8) + b + Array("}".utf8)            // nest
                    default:                                                                   // re-space
                        if let at = b.indices.filter({ b[$0] == UInt8(ascii: ",") }).randomElement() {
                            b.insert(contentsOf: Array(" \n\t".utf8), at: at + 1)
                        }
                    }
                }
                let bytes = Data(b)
                let caseDir = tmp.appendingPathComponent("manifest-fuzz-\(i)", isDirectory: true)
                try? fm.createDirectory(at: caseDir, withIntermediateDirectories: true)
                try? bytes.write(to: caseDir.appendingPathComponent("staging-manifest.json"), options: .atomic)
                let loaded = LiveCaptureProcessor(session: rsSession)
                loaded._recoveryTestLoadManifest(stagingDir: caseDir, config: rsConfig)
                let names = (try? fm.contentsOfDirectory(atPath: caseDir.path)) ?? []
                if !loaded.stagingRecoveryBlocked {
                    if canonical(loaded.staged) == wantStaged, names == ["staging-manifest.json"] { fuzzResumed += 1 }
                    else { fuzzBad.append("#\(i) resumed \(loaded.staged.map(\.groupId)) from \(String(decoding: bytes, as: UTF8.self))") }
                } else {
                    let q = names.first { $0.hasPrefix("staging-manifest.corrupt-") }
                    let kept = q.flatMap { try? Data(contentsOf: caseDir.appendingPathComponent($0)) }
                    if kept == bytes, loaded.staged.isEmpty, loaded.stagingRecoveryNotice != nil,
                       !names.contains("staging-manifest.json") { fuzzQuarantined += 1 }
                    else { fuzzBad.append("#\(i) blocked but evidence \(names) not kept byte-for-byte") }
                }
            }
        } else {
            fuzzBad.append("no current manifest to damage")
        }
        if !fuzzBad.isEmpty { NSLog("W40.e6 manifest fuzz: %@", fuzzBad.prefix(5).joined(separator: " | ")) }
        check("60 damaged manifests each resume the exact record or quarantine it byte-for-byte (W40.e6: \(fuzzResumed) resumed, \(fuzzQuarantined) quarantined)",
              fuzzBad.isEmpty && fuzzResumed + fuzzQuarantined == 60 && fuzzQuarantined > 0
                  && fm.fileExists(atPath: integrityArtifact.path))

        // --- Test 28 (W17.det1): detection is a pure scan, not recovery machinery. Only the two
        // session-shaped folders with a nonempty canonical `staged` array count; empty/malformed
        // manifests and a human-named folder do not. Creating a new session reports the same count on
        // its existing status line, while this scratch fixture's bytes remain exactly as written.
        let detectionRoot = CaptureSession.backupRoot
        let beforeDetection = CaptureSession.strandedLiveSessionCount(under: detectionRoot)
        let detectionToken = String(UUID().uuidString.prefix(8))
        let strandedOne = detectionRoot.appendingPathComponent("2099-01-01T00-00-00Z-\(detectionToken)", isDirectory: true)
        let strandedTwo = detectionRoot.appendingPathComponent("2099-01-02T00-00-00Z-\(detectionToken)", isDirectory: true)
        let emptyStaging = detectionRoot.appendingPathComponent("2099-01-03T00-00-00Z-\(detectionToken)", isDirectory: true)
        let operatorFolder = detectionRoot.appendingPathComponent("operator-notes-\(detectionToken)", isDirectory: true)
        let stagedBody = Data("{\"staged\":[{\"groupId\":\"detect\"}]}".utf8)
        let emptyBody = Data("{\"staged\":[]}".utf8)
        for folder in [strandedOne, strandedTwo, emptyStaging, operatorFolder] {
            try? fm.createDirectory(at: folder.appendingPathComponent("_processed", isDirectory: true),
                                    withIntermediateDirectories: true)
        }
        let oneManifest = strandedOne.appendingPathComponent("_processed/staging-manifest.json")
        let twoManifest = strandedTwo.appendingPathComponent("_processed/staging-manifest.json")
        try? stagedBody.write(to: oneManifest, options: .atomic)
        try? stagedBody.write(to: twoManifest, options: .atomic)
        try? emptyBody.write(to: emptyStaging.appendingPathComponent("_processed/staging-manifest.json"), options: .atomic)
        try? stagedBody.write(to: operatorFolder.appendingPathComponent("_processed/staging-manifest.json"), options: .atomic)
        let detected = CaptureSession.strandedLiveSessionCount(under: detectionRoot)
        let detectorSession = CaptureSession()
        check("stranded-session detection counts only nonempty staged session folders (W17.det1)",
              detected == beforeDetection + 2
                  && detectorSession.statusMessage.contains("\(detected) prior")
                  && detectorSession.statusMessage.contains("staged output"))
        check("stranded-session detection is read-only over staged manifests (W17.det1)",
              (try? Data(contentsOf: oneManifest)) == stagedBody
                  && (try? Data(contentsOf: twoManifest)) == stagedBody
                  && fm.fileExists(atPath: operatorFolder.path))

        // --- Test 29 (W22.localagent-provenance): a Local Agent run may retain a selected direct
        // provider for UI compatibility, but that provider and a gateway are never the backend that
        // produced this result. Exercise both durable Live Capture writes: initial staging, then the
        // persisted `RetainedSegment` → manifest reload → rotation regeneration replay. Supplying both
        // a gateway and Local Agent directly is intentional test pressure; normal Settings makes them
        // exclusive, while this proves the local CLI remains the durable record's precedence rule.
        let p29Out = tmp.appendingPathComponent("p29out", isDirectory: true)
        let p29Staging = tmp.appendingPathComponent(
            "APStaging-p29-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        try? fm.createDirectory(at: p29Staging, withIntermediateDirectories: true)
        let p29Agent = LocalAgentConfig(tool: .claude, binaryPath: "/tmp/fake-claude",
                                         modelOverride: "p29-local-model")
        let p29Gateway = GatewayConfig(baseURL: "https://invalid.test", modelID: "gateway-model",
                                        displayName: "P29 Gateway", inputCostPer1M: 0,
                                        outputCostPer1M: 0)
        let p29Config = SessionProcessingConfig(
            provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
            taggingMode: .human, rotationMode: .off, mergeDocuments: false,
            outputDirectory: p29Out,
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
            gateway: p29Gateway, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
            textColumns: 1, localAgent: p29Agent)
        let p29Session = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(
            text: "Local provenance recovery body.", classification: nil,
            errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        p29Session._recoveryTestBeginLive(config: p29Config, stagingDir: p29Staging)
        let p29Writer = p29Session.liveProcessor
        func p29Settle(_ condition: () -> Bool) async -> Bool {
            for _ in 0..<400 {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return condition()
        }
        let p29JPEG = bitmap?.representation(using: .jpeg, properties: [:]) ?? Data()
        p29Session.ingest(jpeg: p29JPEG, groupId: "P29", seq: 1, type: .document,
                          quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        p29Writer.segmentResolved(groupId: "P29")
        let p29Staged = await p29Settle {
            p29Writer.staged.first { $0.groupId == "P29" }?.pdfURLs.count == 1
        }
        let p29InitialURL = p29Writer.staged.first { $0.groupId == "P29" }?.pdfURLs.first
        func p29HasLocalProvenance(_ url: URL?) -> Bool {
            guard let url else { return false }
            let header = PDFDocument(url: url)?.page(at: 1)?.string ?? ""
            let body = PDFTextExtractor.extract(from: url).text ?? ""
            return header.contains("Local CLI Agent (claude) \u{00B7} p29-local-model")
                && !header.contains("P29 Gateway")
                && !header.contains("\n\(stubModel.provider.rawValue) \u{00B7}")
                && body.contains("Local provenance recovery body.")
        }
        check("Live Capture's initial staged PDF credits the Local CLI, not configured fallbacks (W22)",
              p29Staged && p29HasLocalProvenance(p29InitialURL))

        // A fresh processor is the crash/relaunch boundary. The second header check is only meaningful
        // after a changed rotation forces the resumed retained inputs through `writeSegmentFiles` again.
        p29Writer._recoveryTestPersistManifest()
        let p29Resumed = LiveCaptureProcessor(session: p29Session)
        p29Resumed._recoveryTestLoadManifest(stagingDir: p29Staging, config: p29Config)
        let p29Source = p29Session.photos.first { $0.groupId == "P29" }?.url
        let p29ResumedRecord = p29Resumed.staged.first { $0.groupId == "P29" }
        if let p29Source {
            p29Resumed.rotationReviewPages = [
                LiveCaptureProcessor.RotationReviewPage(groupId: "P29", pageIndex: 0, order: 1,
                                                        sourceURL: p29Source, rotationDegrees: 90)
            ]
        }
        p29Resumed.applyRotationReviewAndFinalize()
        let p29RegenerationStarted = p29Resumed.isFinalizing
        let p29Regenerated = await p29Settle { !p29Resumed.isFinalizing }
        let p29RegeneratedURL = p29Resumed.staged.first { $0.groupId == "P29" }?.pdfURLs.first
        check("manifest-resumed rotation regeneration retains Local CLI provenance and parser body (W22)",
              p29ResumedRecord?.pdfURLs.count == 1 && p29Source != nil
                  && p29RegenerationStarted && p29Regenerated
                  && p29HasLocalProvenance(p29RegeneratedURL))

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }
}

#endif
