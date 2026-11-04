#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import AppKit

extension LiveCaptureRecoveryTestDriver {
    /// Test 33 (W40.fix-processor-pending-invisible-after-relaunch): after a relaunch, a document that had
    /// failed OCR has its row and Retry at Start, before the phone sends anything. The manifest used to load
    /// only on the first ingest, so the owner (session iphone-1) had nothing to retry until new pages came.
    /// The relaunch is a second `CaptureSession` restoring the first one's folder from the scratch backup
    /// root; the stub OCR fails every page with a 402 and counts each call the relaunch would have bought.
    /// Runs only with a scratch backup root (`ARCHIVEPROC_TEST_BACKUP_ROOT`), as `run()` checks before calling.
    static func runPendingRelaunchTest(tmp: URL, stubModel: LLMModel, jpeg: Data,
                                       check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let prOut = tmp.appendingPathComponent("pending-relaunch-out", isDirectory: true)
        let prStaging = tmp.appendingPathComponent(
            "APStaging-relaunch-\(String(UUID().uuidString.prefix(8)))", isDirectory: true)
        try? fm.createDirectory(at: prStaging, withIntermediateDirectories: true)
        let prConfig = SessionProcessingConfig(
            provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
            taggingMode: .human, rotationMode: .off, mergeDocuments: false, outputDirectory: prOut,
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
            gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1)
        LiveCaptureProcessor._recoveryTestOCRStub = OCRResult(
            text: nil, classification: nil, errorMessage: "Gemini API error (402): payment required",
            errorCode: "402")
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRRoutes = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        func prSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        // Before the relaunch: one document, every page failed, staged as failed.
        let prFirst = CaptureSession()
        prFirst._recoveryTestBeginLive(config: prConfig, stagingDir: prStaging)
        for seq in 1...2 {
            prFirst.ingest(jpeg: jpeg, groupId: "PR1", seq: seq,
                           type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        prFirst.liveProcessor.segmentResolved(groupId: "PR1")
        let prStaged = await prSettle {
            prFirst.liveProcessor.failedGroupIds.contains("PR1")
                && prFirst.liveProcessor.staged.contains { $0.groupId == "PR1" }
        }
        let prStartsBefore = LiveCaptureProcessor._recoveryTestOCRStarts.filter { $0.groupId == "PR1" }.count

        // A page that was never staged would buy a call on resume, so Start leaves that session undecided
        // ("Process N →" stays the explicit choice) and starts nothing.
        prFirst.ingest(jpeg: jpeg, groupId: "PR2", seq: 3,
                       type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        _ = await prSettle { LiveCaptureProcessor._recoveryTestOCRStarts.contains { $0.groupId == "PR2" } }
        let prStartsWithPR2 = LiveCaptureProcessor._recoveryTestOCRStarts.count
        // Every source this test will send to the Trash (PR2 by `removePhoto`, PR1 by Clear), by name, so
        // the tidy-up at the end touches nothing else in the owner's Trash.
        let prSourceStems = Set(prFirst.photos.map { $0.url.deletingPathExtension().lastPathComponent })
        let prWaiting = CaptureSession()
        prWaiting._recoveryTestArmRelaunch(config: prConfig, stagingDir: prStaging)
        prWaiting.resumeRecoveredSessionIfNeeded()
        check("Start does not resume a relaunched session holding a never-staged page, and buys nothing",
              prWaiting.sessionId == prFirst.sessionId && prWaiting.photos.contains { $0.groupId == "PR2" }
                  && prWaiting.processingMode == .undecided
                  && LiveCaptureProcessor._recoveryTestOCRStarts.count == prStartsWithPR2)
        if let pr2 = prFirst.photos.first(where: { $0.groupId == "PR2" }) { prFirst.removePhoto(pr2) }

        // The relaunch, then Start's resume — with no ingest in between.
        let prRelaunched = CaptureSession()
        prRelaunched._recoveryTestArmRelaunch(config: prConfig, stagingDir: prStaging)
        let prRelaunchedProc = prRelaunched.liveProcessor
        let prHiddenBefore = prRelaunched.processingMode == .undecided
            && !prRelaunchedProc.statuses.contains { $0.id == "PR1" }
        check("the relaunch restores the failed document's session with its photos, its row not yet loaded",
              prStaged && prRelaunched.sessionId == prFirst.sessionId
                  && prRelaunched.photos.map(\.groupId) == ["PR1", "PR1"] && prHiddenBefore)
        prRelaunched.resumeRecoveredSessionIfNeeded()   // what Start runs first
        let prRow = prRelaunchedProc.statuses.first { $0.id == "PR1" }
        check("at Start the failed document has its row, marked failed, and is offered for Retry",
              prRelaunched.processingMode == .live && prRow?.phase == .failed && prRow?.pageCount == 2
                  && prRelaunchedProc.failedGroupIds.contains("PR1") && !prRelaunchedProc.stagingRecoveryBlocked)
        check("...and showing it bought no OCR call for the staged document",
              LiveCaptureProcessor._recoveryTestOCRStarts.filter { $0.groupId == "PR1" }.count == prStartsBefore)
        check("...nor calls the document's own pages late arrivals",
              prRelaunched.statusMessage != CaptureSession.filedGroupLatePageMessage)

        // The resume took the Settings snapshot for the operator, so it is provisional until a call is bought
        // on it: a route changed after the relaunch (the owner's 402 key, then the gateway) reaches the first
        // Retry. Once bought on, it is the session's (W40.fix-processor-live-settings-per-run).
        let prViaGateway = SessionProcessingConfig(
            provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
            taggingMode: .human, rotationMode: .off, mergeDocuments: false, outputDirectory: prOut,
            customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
            gateway: GatewayConfig(baseURL: "https://gateway.invalid/v1", modelID: "test-gateway-model",
                                   displayName: "Test Gateway", inputCostPer1M: nil, outputCostPer1M: nil),
            outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0, textColumns: 1)
        let prGatewayRoute = prViaGateway.retryBackendDescription
        let prRoutesBefore = LiveCaptureProcessor._recoveryTestOCRRoutes.count
        prRelaunched.recoveryTestSettings = prViaGateway   // Settings changed after the relaunch
        prRelaunchedProc.retryFailed(groupIds: ["PR1"])
        let prRetried = await prSettle {
            LiveCaptureProcessor._recoveryTestOCRRoutes.count >= prRoutesBefore + 2
                && prRelaunchedProc.staged.contains { $0.groupId == "PR1" }
        }
        check("a Settings change made after the relaunch reaches the first Retry",
              prRetried && prRelaunched.config?.gateway != nil
                  && LiveCaptureProcessor._recoveryTestOCRRoutes.suffix(2) == [prGatewayRoute, prGatewayRoute])
        prRelaunched.recoveryTestSettings = prConfig   // changed again, after a call was bought
        prRelaunchedProc.retryFailed(groupIds: ["PR1"])
        let prRetriedAgain = await prSettle {
            LiveCaptureProcessor._recoveryTestOCRRoutes.count >= prRoutesBefore + 4
                && prRelaunchedProc.staged.contains { $0.groupId == "PR1" }
        }
        check("...and once a call was bought on it, the snapshot is the session's until Finish or Clear",
              prRetriedAgain && prRelaunched.config?.gateway != nil
                  && LiveCaptureProcessor._recoveryTestOCRRoutes.suffix(2) == [prGatewayRoute, prGatewayRoute])
        prRelaunchedProc.clearSession()   // empties the session and releases its snapshot
        let prCleared = prRelaunched.photos.isEmpty && prRelaunched.processingMode == .undecided
        prRelaunched.resumeRecoveredSessionIfNeeded()
        check("Start leaves a session with no photos undecided, so its first page still reads Settings",
              prCleared && prRelaunched.processingMode == .undecided && prRelaunched.config == nil)
        let trash = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        for item in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
        where item.hasPrefix(prStaging.lastPathComponent)
            || prSourceStems.contains(where: { item.hasPrefix($0) }) {   // exact sources; Finder may suffix a copy
            try? fm.removeItem(at: trash.appendingPathComponent(item))
        }
        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRRoutes = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }
}
#endif
