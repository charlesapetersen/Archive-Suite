#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import AppKit

extension LiveCaptureRecoveryTestDriver {
    /// Tests 30-32 of `run()`, moved out whole (W46.rotation-majority-fix): with them inside, type-checking and
    /// lowering that one function took a swift-frontend past the heavy job's 10.8 GB memory limit, so no clean
    /// Processor build finished. Each runs only with a scratch backup root (`ARCHIVEPROC_TEST_BACKUP_ROOT`), as
    /// `run()` checks before calling.
    static func runLateDocumentTests(tmp: URL, stubModel: LLMModel, bitmap: NSBitmapImageRep?,
                                     check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        // --- Test 30 (W40.fix-processor-after-finish-not-processed): a document ended AFTER a Finish that
        // filed everything, in the same app run, must still be processed. That Finish moves the spent staging
        // directory to the Trash and leaves the session live; the next segment's PDF and manifest writes went
        // into the missing folder, so it staged with no output and the next Finish blamed the output folder
        // (owner session iphone-1). Driven through the real ingest → finalizeSegment → finalize path, twice. ---
        do {
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            let afOut = tmp.appendingPathComponent("after-finish-out", isDirectory: true)
            // Distinctively named, not `_processed`, so the reclaimed folder can be taken back out of the Trash.
            let afStaging = tmp.appendingPathComponent(
                "APStaging-afterfinish-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
            try? fm.createDirectory(at: afStaging, withIntermediateDirectories: true)
            let afSession = CaptureSession()
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "after finish page", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            afSession._recoveryTestBeginLive(config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: afOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1),
                stagingDir: afStaging)
            let afProc = afSession.liveProcessor
            func afSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func afFinish(_ gid: String) async -> Bool {
                let key = afProc.staged.first { $0.groupId == gid }?.collectionKey ?? "__unfiled__"
                afProc.finalize([LiveCaptureProcessor.CollectionDraft(
                    id: key, finalName: afOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
                    chosenExisting: afOut, segmentCount: 1, photoCount: 1)])
                return await afSettle { !afProc.isFinalizing && !afProc.staged.contains { $0.groupId == gid } }
            }
            func afOutPDFs() -> Int {
                ((try? fm.contentsOfDirectory(at: afOut, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "pdf" }.count
            }

            // 1. PREMISE: the first document stages and files, and that Finish reclaims the staging folder.
            afSession.ingest(jpeg: Data("first document page".utf8), groupId: "AF1", seq: 1,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            afProc.segmentResolved(groupId: "AF1")
            let af1Staged = await afSettle {
                afProc.staged.first { $0.groupId == "AF1" }?.pdfURLs.isEmpty == false
            }
            let af1Filed = af1Staged ? await afFinish("AF1") : false
            check("after-finish premise: the first document filed and its Finish reclaimed the staging folder",
                  af1Staged && af1Filed && afOutPDFs() == 1 && !fm.fileExists(atPath: afStaging.path)
                      && afSession.processingMode == .live)

            // 2. THE FIX: the next document of the same run is processed into a re-created staging folder.
            afSession.ingest(jpeg: Data("second document page".utf8), groupId: "AF2", seq: 2,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            afProc.segmentResolved(groupId: "AF2")
            let af2Staged = await afSettle { afProc.staged.contains { $0.groupId == "AF2" } }
            let af2Record = afProc.staged.first { $0.groupId == "AF2" }
            let af2Manifest = afStaging.appendingPathComponent("staging-manifest.json")
            check("a document ended after a full Finish is processed: its PDF is staged on disk, not failed",
                  af2Staged && af2Record?.pdfURLs.isEmpty == false
                      && af2Record?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true
                      && !afProc.failedGroupIds.contains("AF2")
                      && afProc.statuses.first { $0.id == "AF2" }?.phase != .failed)
            check("...and its staging record is on disk again, so a relaunch could recover it",
                  ((try? Data(contentsOf: af2Manifest)).map { String(decoding: $0, as: UTF8.self) } ?? "")
                      .contains("\"AF2\""))

            // 3. ...and the next Finish files it, with no "could NOT be filed" warning — while a THIRD document
            //    is held mid-processing (finalized, not yet staged). That Finish must keep the staging folder
            //    the held write is about to use, and the held document must then stage onto disk.
            let afGate = TestGate()
            LiveCaptureProcessor._recoveryTestOCRGate = { await afGate.wait() }
            afSession.ingest(jpeg: Data("third document page".utf8), groupId: "AF3", seq: 3,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            LiveCaptureProcessor._recoveryTestOCRGate = nil   // hold THAT page only
            afProc.segmentResolved(groupId: "AF3")
            let af3Parked = await afSettle { afProc.isFinalized("AF3") }
            let af2Filed = af2Staged ? await afFinish("AF2") : false
            check("...and the next Finish files it without a could-not-be-filed warning",
                  af2Filed && afOutPDFs() == 2
                      && afProc.finalizeSummary?.contains("could NOT be filed") == false)
            check("a Finish that files everything keeps the staging folder while a segment is still processing",
                  af3Parked && !afProc.staged.contains { $0.groupId == "AF3" }
                      && fm.fileExists(atPath: afStaging.path)
                      && afProc.finalizeSummary?.contains("still processing") == true)
            afGate.open()
            let af3Staged = await afSettle { afProc.staged.contains { $0.groupId == "AF3" } }
            let af3Record = afProc.staged.first { $0.groupId == "AF3" }
            check("...and that segment then stages its PDF on disk",
                  af3Staged && af3Record?.pdfURLs.isEmpty == false
                      && af3Record?.pdfURLs.allSatisfy { fm.fileExists(atPath: $0.path) } == true)
            // The first Finish's reclaim went to the real Trash (by design); take every copy of this test's
            // uniquely named folder back out. Best-effort: the assertions never depend on it.
            let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
            for item in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
            where item.hasPrefix(afStaging.lastPathComponent) {
                try? fm.removeItem(at: trash.appendingPathComponent(item))
            }

            // 4. A segment that was never processed is named as such at Finish; the output folder is not
            //    blamed for it. Armed directly: one staged record with no PDF, as the bug left behind.
            let unOut = tmp.appendingPathComponent("after-finish-unprocessed-out", isDirectory: true)
            let unStaging = tmp.appendingPathComponent("APStaging-unprocessed", isDirectory: true)
            try? fm.createDirectory(at: unStaging, withIntermediateDirectories: true)
            let unProc = LiveCaptureProcessor(session: afSession)
            unProc._recoveryTestArm(stagingDir: unStaging, config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                taggingMode: .human, rotationMode: .off, mergeDocuments: false, outputDirectory: unOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1),
                staged: [LiveCaptureProcessor.StagedSegment(
                    groupId: "UN", type: CaptureGroupType.document.rawValue, collectionKey: "UN", order: 0,
                    pdfURLs: [], imageURLs: [], jsonURL: nil, boxLabelText: nil, pagesComplete: true)])
            unProc.finalize([LiveCaptureProcessor.CollectionDraft(
                id: "UN", finalName: unOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
                chosenExisting: unOut, segmentCount: 1, photoCount: 1)])
            _ = await afSettle { !unProc.isFinalizing && unProc.finalizeSummary != nil }
            let unSummary = unProc.finalizeSummary ?? ""
            check("Finish names a never-processed segment instead of pointing at the output folder",
                  unSummary.contains("could NOT be filed because processing produced no complete output")
                      && !unSummary.contains("Check the output folder")
                      && fm.fileExists(atPath: unStaging.path) && unProc.staged.map(\.groupId) == ["UN"])
            func seg(_ pdfs: [URL], complete: Bool?) -> LiveCaptureProcessor.StagedSegment {
                LiveCaptureProcessor.StagedSegment(
                    groupId: UUID().uuidString, type: CaptureGroupType.document.rawValue, collectionKey: "K",
                    order: 0, pdfURLs: pdfs, imageURLs: [], jsonURL: nil, boxLabelText: nil, pagesComplete: complete)
            }
            let somePDF = URL(fileURLWithPath: "/nonexistent/x.pdf")
            check("...and only no-output or incomplete segments count as never processed",
                  LiveCaptureProcessor.keptUnprocessedCount([
                      seg([], complete: true), seg([somePDF], complete: false),
                      seg([somePDF], complete: true), seg([somePDF], complete: nil)]) == 2)

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        }

        // --- Test 31 (W40.fix-processor-failed-ocr-filed-image-only): a document whose every page FAILED OCR
        // was labelled image-only, left the retry set and was filed with no text (owner session iphone-1, three
        // pages that each failed with Gemini's 402). A failed page is a failure: the document stays failed,
        // retryable and unfiled. A page that was read and has no text is still filed image-only. Both shapes run
        // through the real ingest → finalizeSegment → finalize path. ---
        do {
            if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
               !testRoot.isEmpty {
                let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                           includingPropertiesForKeys: nil)) ?? []
                for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                    try? fm.removeItem(at: e)
                }
            }
            // A real, decodable JPEG: an undecodable one would be labelled placeholder-image first.
            let foBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0)
            let foJPEG = foBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()
            func foSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            // One three-page document through a fresh live session with `stub` as every page's OCR, then
            // Finish. Returns the processor, the group's source photos and the output folder.
            func foRun(_ name: String, stub: OCRResult) async
                -> (proc: LiveCaptureProcessor, sources: [URL], out: URL, staged: Bool, finished: Bool) {
                let out = tmp.appendingPathComponent("failed-ocr-\(name)-out", isDirectory: true)
                let staging = tmp.appendingPathComponent(
                    "APStaging-failedocr-\(name)-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
                try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let session = CaptureSession()
                LiveCaptureProcessor._recoveryTestOCRStub = stub
                LiveCaptureProcessor._recoveryTestOCRStarts = []
                LiveCaptureProcessor._recoveryTestOCRTasks = [:]
                session._recoveryTestBeginLive(config: SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false, outputDirectory: out,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1),
                    stagingDir: staging)
                let proc = session.liveProcessor
                for seq in [1, 2, 3] {
                    session.ingest(jpeg: foJPEG, groupId: "FO", seq: seq,
                                   type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
                }
                proc.segmentResolved(groupId: "FO")
                let staged = await foSettle { proc.staged.contains { $0.groupId == "FO" } }
                let sources = session.photos.filter { $0.groupId == "FO" }.map(\.url)
                let key = proc.staged.first { $0.groupId == "FO" }?.collectionKey ?? "__unfiled__"
                proc.finalize([LiveCaptureProcessor.CollectionDraft(
                    id: key, finalName: out.lastPathComponent, existingFolders: [], suggestedFolders: [],
                    chosenExisting: out, segmentCount: 1, photoCount: 3)])
                let finished = await foSettle { !proc.isFinalizing && proc.finalizeSummary != nil }
                // A Finish that files everything reclaims staging to the real Trash; take this test's copy out.
                let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
                for item in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
                where item.hasPrefix(staging.lastPathComponent) {
                    try? fm.removeItem(at: trash.appendingPathComponent(item))
                }
                return (proc, sources, out, staged, finished)
            }
            func foOutPDFs(_ out: URL) -> Int {
                ((try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "pdf" }.count
            }

            // 1. THE FIX: every page failed (the session's 402). Failed with the provider's error, offered for
            //    retry, nothing written for it, nothing filed, every source kept.
            let failed = await foRun("402", stub: OCRResult(
                text: nil, classification: nil, errorMessage: "Gemini API error (402): payment required",
                errorCode: "402"))
            let failedStatus = failed.proc.statuses.first { $0.id == "FO" }
            let failedRecord = failed.proc.staged.first { $0.groupId == "FO" }
            check("a document whose every page failed OCR is FAILED with the provider error, in the retry set",
                  failed.staged && failedStatus?.phase == .failed && failedStatus?.failureKind == .provider
                      && failedStatus?.errorCode == "402" && failed.proc.failedGroupIds == ["FO"])
            check("...and Finish files none of it and keeps every source photo",
                  failed.finished && failedRecord?.pdfURLs.isEmpty == true
                      && foOutPDFs(failed.out) == 0 && failed.sources.count == 3
                      && failed.sources.allSatisfy { fm.fileExists(atPath: $0.path) })

            // 1b. W40.fix-processor-failed-ocr-wrapped, end to end (before any run that files, which the
            //     following runs do not stage in this driver): every page a Gemini 500 whose only second reader
            //     answered 402 → failed, nothing filed, every source kept.
            let wrapped = await foRun("wrapped", stub: OCRResult(
                text: nil, classification: nil,
                errorMessage: "Gemini API error (500). Second readers failed too — Anthropic: (402)",
                errorCode: OCRRefusalFallback.exhaustedCode, readingCodes: ["500", "402"]))
            let wrappedStatus = wrapped.proc.statuses.first { $0.id == "FO" }
            check("a document whose pages Gemini 500'd and no second reader read is FAILED and files nothing",
                  wrapped.staged && wrappedStatus?.phase == .failed && wrappedStatus?.failureKind == .provider
                      && wrapped.proc.failedGroupIds == ["FO"] && wrapped.finished && foOutPDFs(wrapped.out) == 0
                      && wrapped.sources.allSatisfy { fm.fileExists(atPath: $0.path) })

            // 2. UNCHANGED: every page was read and has no text — Apple Vision's answer for a blank verso, which
            //    carries an error code and comes back the same on every retry. Image-only, not failed, filed.
            let empty = await foRun("notext", stub: OCRResult(
                text: nil, classification: nil,
                errorMessage: "Apple Vision found no text meeting the confidence threshold.",
                errorCode: "vision_no_text"))
            check("a document whose pages were read with no text is still filed image-only, not failed",
                  empty.staged && empty.finished && foOutPDFs(empty.out) == 3
                      && empty.proc.failedGroupIds.isEmpty
                      && !empty.proc.statuses.contains { $0.id == "FO" && $0.phase == .failed })

            // 3. The predicate both halves share: a request that got no reading fails; a reader's verdict on
            //    the page, any text, or no error at all does not.
            func foFails(_ text: String?, _ message: String?, _ code: String?) -> Bool {
                LiveCaptureProcessor.ocrFailed(OCRResult(text: text, classification: nil,
                                                         errorMessage: message, errorCode: code))
            }
            check("a page fails OCR when the request got no reading: an HTTP status, no code, or a silent CLI",
                  foFails(nil, "x", "402") && foFails("", "x", "503") && foFails(nil, "x", nil)
                      && foFails(nil, "x", "cli_timeout") && foFails(nil, "x", "rate_limit_error")
                      && foFails(nil, "x", "authentication_error"))
            check("...and not when the reader answered: a verdict on the page, any text, or no error",
                  !foFails(nil, "x", "vision_no_text") && !foFails(nil, "x", "SAFETY")
                      && !foFails(nil, "x", "Recitation") && !foFails(nil, "x", "GeminiRefused")
                      && !foFails(nil, "x", "unparsable") && !foFails(nil, "x", "cli_bad_response")
                      && !foFails(nil, "x", "invalid_request_error")
                      && !foFails("read", "x", "402") && !foFails(nil, nil, nil))

            // 4. W40.fix-processor-failed-ocr-wrapped — a page no reader read is judged by every reading's code.
            func foWrapped(_ code: String, _ codes: [String]?) -> Bool {
                LiveCaptureProcessor.ocrFailed(OCRResult(text: nil, classification: nil, errorMessage: "x",
                                                         errorCode: code, readingCodes: codes))
            }
            check("a GeminiRefused or CascadeExhausted page that no reader read fails OCR",
                  foWrapped("GeminiRefused", ["500"]) && foWrapped("GeminiRefused", ["500", "402"])
                      && foWrapped("GeminiRefused", ["500", "", "billing_error"])
                      && foWrapped("CascadeExhausted", ["500", "402"]) && foWrapped("CascadeExhausted", ["api_error", ""]))
            check("...and one with a real refusal or verdict among its readings still files image-only",
                  !foWrapped("GeminiRefused", ["SAFETY", "402"]) && !foWrapped("GeminiRefused", ["Recitation"])
                      && !foWrapped("GeminiRefused", ["500", "invalid_request_error"])
                      && !foWrapped("CascadeExhausted", ["length", "402"]) && !foWrapped("CascadeExhausted", ["500", "length"])
                      && !foWrapped("GeminiRefused", nil) && !foWrapped("CascadeExhausted", []))

            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        }

        // --- Test 32 (W40.fix-processor-live-settings-per-run): a route changed in Settings reaches the NEXT
        // session of the same app run. The snapshot used to be taken once per run, so with the gateway switched
        // on, Retry, Clear, Finish and Start all kept using direct Gemini until a relaunch (owner session
        // iphone-1). `recoveryTestSettings` stands in for Settings; the real ingest → finalize → Clear paths
        // run, and the OCR stub records the route each page would have called. ---
        do {
            let psOut = tmp.appendingPathComponent("per-session-out", isDirectory: true)
            let psStaging = tmp.appendingPathComponent(
                "APStaging-persession-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
            try? fm.createDirectory(at: psStaging, withIntermediateDirectories: true)
            func psConfig(_ gateway: GatewayConfig?) -> SessionProcessingConfig {
                SessionProcessingConfig(
                    provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                    taggingMode: .human, rotationMode: .off, mergeDocuments: false, outputDirectory: psOut,
                    customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                    gateway: gateway, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1)
            }
            let direct = psConfig(nil)
            let viaGateway = psConfig(GatewayConfig(
                baseURL: "https://gateway.invalid/v1", modelID: "test-gateway-model", displayName: "Test Gateway",
                inputCostPer1M: nil, outputCostPer1M: nil))
            LiveCaptureProcessor._recoveryTestOCRStub =
                OCRResult(text: "per-session page", classification: nil, errorMessage: nil, errorCode: nil)
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRRoutes = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
            let psSession = CaptureSession()
            psSession._recoveryTestBeginLive(config: direct, stagingDir: psStaging)
            let psJPEG = bitmap?.representation(using: .jpeg, properties: [:]) ?? Data()
            let psProc = psSession.liveProcessor
            func psSettle(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
                return cond()
            }
            func psIngest(_ gid: String, _ seq: Int) {
                // A real JPEG: a placeholder page keeps its source photo (W23.h5), and a kept photo is a session
                // that is not empty, so Finish would rightly keep the snapshot.
                psSession.ingest(jpeg: psJPEG, groupId: gid, seq: seq,
                                 type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
                psProc.segmentResolved(groupId: gid)
            }
            func psFinish(_ gid: String) async -> Bool {
                guard await psSettle({ psProc.staged.first { $0.groupId == gid }?.pdfURLs.isEmpty == false })
                else { return false }
                let key = psProc.staged.first { $0.groupId == gid }?.collectionKey ?? "__unfiled__"
                psProc.finalize([LiveCaptureProcessor.CollectionDraft(
                    id: key, finalName: psOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
                    chosenExisting: psOut, segmentCount: 1, photoCount: 1)])
                return await psSettle { !psProc.isFinalizing && !psProc.staged.contains { $0.groupId == gid } }
            }
            let directRoute = direct.retryBackendDescription
            let gatewayRoute = viaGateway.retryBackendDescription

            // 1. Session one runs on the route it started with, and its Finish releases the snapshot.
            psIngest("PS1", 1)
            let ps1Filed = await psFinish("PS1")
            check("a Finish that empties the session releases its settings snapshot",
                  ps1Filed && psSession.photos.isEmpty && psSession.processingMode == .undecided
                      && psSession.config == nil && !psSession.settingsLocked
                      && LiveCaptureProcessor._recoveryTestOCRRoutes == [directRoute])

            // 2. Settings change between sessions: the next session's first page snapshots it.
            psSession.recoveryTestSettings = viaGateway
            psIngest("PS2", 2)
            check("the next session in the same run uses the route changed in Settings",
                  psSession.processingMode == .live && psSession.config?.gateway?.modelID == "test-gateway-model"
                      && LiveCaptureProcessor._recoveryTestOCRRoutes.last == gatewayRoute
                      && psSession.config?.summary.hasPrefix("Test Gateway · test-gateway-model") == true)

            // 3. A change while that session still holds pages does NOT reach it (the snapshot is deliberate).
            _ = await psSettle { psProc.staged.contains { $0.groupId == "PS2" } }
            psSession.recoveryTestSettings = direct
            psIngest("PS3", 3)
            _ = await psSettle { psProc.staged.contains { $0.groupId == "PS3" } }
            check("a Settings change mid-session does not reach the running session",
                  psSession.config?.gateway != nil
                      && LiveCaptureProcessor._recoveryTestOCRRoutes.suffix(2) == [gatewayRoute, gatewayRoute])

            // 4. Clear ends the session too: the next page takes the route Settings now hold.
            psProc.clearSession()
            let psCleared = psSession.photos.isEmpty && psSession.processingMode == .undecided
                && psSession.config == nil
            psIngest("PS4", 4)
            check("a Clear releases the snapshot and the next session takes the new route",
                  psCleared && psSession.config?.gateway == nil
                      && LiveCaptureProcessor._recoveryTestOCRRoutes.last == directRoute)

            // 5. A Clear whose LAST capture-manifest write fails keeps its committed marker, so it must keep
            //    the snapshot too: re-activating would read that committed Clear back in `loadStagingManifest`
            //    and finish it again, Trashing the next page (Tier-2 review of this change). The override fails
            //    only the marker-free write `finishPreparedClear` makes; prepare and commit still land.
            _ = await psSettle { psProc.staged.contains { $0.groupId == "PS4" } }
            psSession.manifestWriteOverride = { data, url in
                guard CaptureSession.decodeManifest(data)?.clearPhase != nil else { return false }
                do { try data.write(to: url, options: .atomic); return true } catch { return false }
            }
            psProc.clearSession()
            psSession.manifestWriteOverride = nil
            check("a Clear whose final manifest write failed keeps the session's snapshot",
                  psSession.photos.isEmpty && psSession.clearPhase == "committed"
                      && psSession.processingMode == .live && psSession.config != nil)

            psProc.clearSession()   // tidy: a second Clear with the writes working completes the transaction
            check("...and a Clear that completes then releases it",
                  psSession.clearPhase == nil && psSession.processingMode == .undecided)
            let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
            for item in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
            where item.hasPrefix(psStaging.lastPathComponent) {
                try? fm.removeItem(at: trash.appendingPathComponent(item))
            }
            LiveCaptureProcessor._recoveryTestOCRStub = nil
            LiveCaptureProcessor._recoveryTestOCRStarts = []
            LiveCaptureProcessor._recoveryTestOCRRoutes = []
            LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        }
    }
}

#endif
