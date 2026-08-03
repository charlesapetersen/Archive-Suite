import AppKit
import Foundation

/// **A poll step that could not PERSIST does not report the batch finished cleanly** (W16.bat7) — headless,
/// $0, no network, no keys.
///
/// The bug this pins: `pollBatchUntilComplete` assigns `batchPollInterrupted = false` on entry, and that one
/// flag is what both callers read to decide whether the paid batch's recovery journal — a server-side job the
/// operator has already paid for, and its only local record — is kept or DELETED
/// (`retirePaidBatchJournalIfPollCompleted` on the first run, `Self.deletePendingBatch()` on a resume). Four
/// of the poll's exits then `return`ed without touching it, so a run unwinding from a step that could not
/// WRITE reported "the poll finished cleanly" and the journal was retired under a live paid job.
///
/// **What is driven here, and what cannot be.** Three of the four exits sit on the far side of a provider
/// call (`guard await processBatchResults(…)` in the Anthropic and Mistral arms, and the `materialized` half
/// of the Gemini arm's guard) — reaching them costs a real paid batch, the same limit
/// `BatchInterruptTailContract` and `BatchPollCancelContract` §3 both record. The FOURTH is the completion
/// sweep, and it is reachable for free because it runs *after* the loop: it was extracted into
/// `sweepJobsWithNoBatchResult` so it could be driven rather than read, and every check below runs that real
/// function, the real `handleOCRResult` under it, the real persistence path under that, and the real
/// first-run tail after it. The other three exits' bodies are one statement, textually identical to the one
/// driven here. **Cite this file for "the poll's persist-failure exit keeps the journal", not for "all four
/// exits are covered by a test."**
///
/// **How the write is made to fail — no stub, and no seam that did not already exist.** A DIRECTORY is
/// created where the interrupted-run manifest goes, so `savePendingRun`'s `Data.write(to:options:.atomic)`
/// throws for real inside `saveResultToPendingRun`. That path is chosen deliberately over the paid-batch
/// journal's: `persistPendingBatchMutation` already reports the interruption itself (W16.bat3-fu), which
/// would set the flag one layer *upstream* of the exit under test and make every check here green before the
/// fix ran — the exact vacuity the grant for this item forbids. `saveResultToPendingRun`'s pending-**run**
/// branch sets `isProcessing`/`processingTask?.cancel()` and does NOT set `batchPollInterrupted`, so the
/// sweep's own assignment is the only thing that can.
///
/// ⚠️ **The state that reaches that branch is REACHABLE in production, and the earlier claim that it was not
/// is withdrawn** (found by this item's adversarial pass, 2026-08-03). It needs `activePendingRun` non-nil
/// *alongside* a live paid batch, and the chain is: a non-batch run's incremental manifest write fails
/// (`saveResultToPendingRun`'s own exit) → it calls `processingTask?.cancel()`, so the run unwinds through
/// `guard !Task.isCancelled else { return }` and never reaches the `activePendingRun = nil` two lines below
/// it → the operator presses **Dismiss** on the interrupted-run banner, and `dismissPendingRun()` deletes the
/// file and clears the banner but leaves the in-memory manifest set → `startProcessing`'s recovery guard now
/// passes (it reads DISK), and the batch branch never assigns `activePendingRun`, so the stale value is still
/// there when the sweep runs. `cancel()` *does* clear it (its "keep the pending run file for resume" block),
/// which is why the chain starts from a write failure rather than a Stop. **That is a separate money bug in
/// its own right** — in that state every paid-batch result is journaled into the stale run manifest instead of
/// `batch.completedResults`, so a relaunch re-fetches chunks already paid for — and it is filed as
/// `W16.bat8` rather than fixed here (this item's grant does not extend to it).
///
/// So the exit these checks drive is live, not merely defensive. It is *also* why the owner authorized all
/// four exits rather than the one narrow arm: the exits were safe only because something upstream happened to
/// report, which is the coupling that broke in W16.bat3-fu. This section pins the exit's own behaviour
/// independently of that upstream, so a change there cannot silently re-open the hole.
///
/// Every check writes and then removes a manifest at the shipped paths, so the whole section is refused
/// unless the harness's redirect is in force (`BatchJournalPathContract.redirectIsInForce`) — blocking
/// `pending_run.json` with a directory is safe in a temp state root and unacceptable in the operator's.
///
/// Run from `BatchResumeTestDriver` (section 20) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchPollPersistFailureContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) async {
        // First, and before any file is touched: the seam that makes the provider-arm sections possible is
        // the one thing in this file that could do harm if it were live in a shipped build, so its refusal
        // directions are pinned before it is ever installed. Needs no redirect — it writes nothing.
        theTransportSeamIsFailClosed(check)
        guard redirected else {
            // FOUR checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("poll persist: the whole section is SKIPPED (refused: the journal path did not resolve away "
                  + "from Application Support, and every check here blocks and restores a real manifest path)",
                  false)
            return
        }
        let blocked = await sweep(blockThePersist: true)
        let wrote = await sweep(blockThePersist: false)

        // MARK: 1. THE regression
        //
        // Revert the four `batchPollInterrupted = true` assignments and this reddens: the sweep returns
        // false, the run stops, and the flag still says the poll completed — so the tail below retires the
        // journal of a paid batch whose failure outputs never landed.
        check("poll persist: a completion sweep that could NOT record a file's failure output reports the "
              + "poll interrupted — it does not hand the caller a flag saying the batch finished cleanly",
              blocked.returnedFalse && blocked.flaggedInterrupted)
        // Proves the sweep actually ran rather than returning early on an empty job list, which would make
        // the check above true for the wrong reason. The synthetic failure is the sweep's own work, and it
        // survives the exit: an interrupted sweep still recorded what it managed to record.
        check("poll persist: and the file it swept is still marked failed with the sweep's own \"no result\" "
              + "reason, so the exit reports the interruption without discarding what it did",
              blocked.sweptTheJob && blocked.stoppedProcessing)

        // MARK: 2. The other direction
        //
        // Without this, an implementation that set `batchPollInterrupted = true` unconditionally — wedging
        // every completed paid batch into a permanent "interrupted", with a Resume banner that never clears
        // — would satisfy section 1 completely.
        check("poll persist: a sweep that CAN record its failure outputs leaves the poll uninterrupted — the "
              + "fix reports a write failure, it does not report every completed batch as interrupted",
              wrote.returnedTrue && !wrote.flaggedInterrupted && wrote.sweptTheJob)

        // MARK: 3. What it costs, in the only unit that matters
        //
        // The flag is a means; the journal file is the end. Both directions are driven through the REAL
        // `retirePaidBatchJournalIfPollCompleted()` against a REAL journal at the shipped (redirected) path,
        // so "kept" is a file that is still there and "retired" is one that is gone.
        check("poll persist: after a sweep that could not persist, the first run's tail leaves the paid "
              + "batch's journal on disk — the server-side job keeps its only local record",
              blocked.journalExistedBefore && blocked.journalSurvived && blocked.batchStillLive)
        check("poll persist: and a sweep that completed still retires it, so a kept journal is a consequence "
              + "of the failure rather than the new default",
              wrote.journalExistedBefore && !wrote.journalSurvived && !wrote.batchStillLive)

        // MARK: 4/5/6. The three exits below the `switch provider` (W16.bat7-fu)
        //
        // Sections 1–3 drive the ONE exit that is reachable for free. These three drive the rest — a real
        // poll through a real provider arm, with the wire replaced. Each provider gets its own pair of
        // directions plus a dormancy re-check; see `aProviderArmThatCouldNotPersist`.
        for provider in [LLMProvider.anthropic, .mistral, .gemini] {
            await aProviderArmThatCouldNotPersist(provider, check)
        }
    }

    // MARK: - 4/5/6. A provider arm whose results could not be PERSISTED

    /// One provider arm's `guard … else { return }`, driven whole (W16.bat7-fu): the real
    /// `pollBatchUntilComplete`, the real batch client, the real status/results parse, the real
    /// `processBatchResults` → `handleOCRResult` → persistence chain, a real journal on disk, and the real
    /// first-run tail — with only the wire replaced by literal provider bodies.
    ///
    /// **The trigger is `handleOCRResult`'s bounds guard, and that is not a contrivance.**
    /// `processBatchResults` admits an entry on `index < fileURLs.count` and then hands it to a guard that
    /// measures `jobs.count`; the two disagree whenever the arrays do, and nothing else in the app reports
    /// that mismatch. Both directions are driven from the SAME fixture, one job apart — which is what makes
    /// the interrupted one meaningful rather than just red: the only difference between "the journal is kept"
    /// and "the journal is retired" is whether `jobs` was long enough to hold the result the provider
    /// returned for index 1.
    ///
    /// **Non-vacuous by construction, not by luck.** The refusal happens at `handleOCRResult`'s ENTRY, before
    /// `saveResultToPendingRun` — so `persistPendingBatchMutation`'s own `reportInterruptedPaidBatch`
    /// (W16.bat3-fu) never runs, and the arm's own `batchPollInterrupted = true` is the only thing in the
    /// process that can set the flag. Measured: reverting that one assignment per arm reddens exactly that
    /// arm's interrupted check and nothing else.
    ///
    /// For Gemini this is specifically the **`materialized`** half of
    /// `guard materialized, markBatchChunkConsumed(…)`. Swift short-circuits the comma, so a false
    /// `materialized` never evaluates `markBatchChunkConsumed` — the half that reports itself is not the half
    /// being driven. The status fixture carries INLINE results, so `resultsSource` resolves the whole chunk
    /// from that one response and no download URL is ever built.
    private static func aProviderArmThatCouldNotPersist(
        _ provider: LLMProvider, _ check: (String, Bool) -> Void
    ) async {
        let dormantBefore = !NetworkSession.testTransportIsActive && NetworkSession.testTransport == nil
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "APPollPersistArm-\(provider.rawValue)-\(UUID().uuidString)", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // Two REAL JPEGs, for the same reason the sweep section uses one: a source the PDF writer cannot
        // read is a second way `handleOCRResult` can rewrite a job, and only the persistence step is the
        // subject here.
        let sources = (0..<2).map { dir.appendingPathComponent("arm-src-\($0).jpg") }
        for url in sources { try? realJPEG()?.write(to: url) }

        /// One whole run of the poll. `jobCount` is the entire variable: at 1, the provider's result for
        /// index 1 arrives for a job that does not exist and the arm unwinds; at 2 it lands.
        func poll(jobCount: Int) async -> (interrupted: Bool, journalExistedBefore: Bool,
                                           journalSurvived: Bool, requests: Int) {
            let chunkId = "batches/w16bat7fu-\(provider.rawValue.lowercased())"
            let saved = OCRProcessor.savePendingBatch(
                OCRProcessor.PendingBatch(
                    batchId: chunkId, provider: provider, model: model(provider), thinkingLevel: .low,
                    fileURLs: sources, outputDirectory: outDir, enableTagging: false,
                    sendPreviousImage: false, submittedAt: Date(), taggingMode: TaggingMode.none,
                    // Spelled `TaggingMode.none` on purpose: the parameter is `TaggingMode?`, so a bare
                    // `.none` is Optional's nil — a DIFFERENT fingerprint from the journal's own mode above.
                    runFingerprint: OCRProcessor.runFingerprint(
                        files: sources, outputDirectory: outDir, taggingMode: TaggingMode.none,
                        enableTagging: false, batchMode: true, preserveInputOrder: true),
                    lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
                    submittedChunkIds: [chunkId]))
            let existed = saved != nil && fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
            // Deferred rather than called at the end: the tail below is *meant* to leave this file on disk
            // in the interrupted case, so removing it has to be the one thing that cannot be skipped.
            defer { OCRProcessor.deletePendingBatch() }

            let processor = OCRProcessor()
            processor.activePendingBatch = saved
            processor.batchPollInterrupted = false
            processor.isProcessing = true
            // `activePendingRun` stays nil, which is what routes `saveResultToPendingRun` to the paid-batch
            // journal. The sweep section above needs the opposite; these arms need this.
            processor.jobs = sources.prefix(jobCount).map { url in
                var job = OCRJob(sourceURL: url)
                // `.processing` is load-bearing here too — the completion sweep after the loop only visits
                // jobs the batch left in flight, and the healthy direction has to reach it.
                job.status = .processing
                return job
            }

            let transcript = Transcript()
            NetworkSession.testTransport = stub(for: provider, chunkId: chunkId, transcript: transcript)
            await processor.pollBatchUntilComplete(
                batchId: chunkId, provider: provider, model: model(provider), thinkingLevel: .low,
                apiKey: "poll-persist-not-a-key", fileURLs: sources, outputDirectory: outDir,
                runConfig: runConfig(provider, outputDirectory: outDir),
                pollInterval: .zero)
            // Uninstalled only once the poll has fully RETURNED: its task group and the detached PDF write
            // are both awaited by then, so no request this run started can still be looking for a stub.
            NetworkSession.testTransport = nil

            // The destructive half of the caller's decision, run for real against the file on disk.
            processor.retirePaidBatchJournalIfPollCompleted()
            return (processor.batchPollInterrupted, existed,
                    fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path), transcript.requests)
        }

        let stopped = await poll(jobCount: 1)
        check("poll persist (\(provider.rawValue) arm): a result the run could not PERSIST reports the poll "
              + "interrupted, and the paid batch's journal is still on disk after the first run's tail",
              stopped.requests > 0 && stopped.journalExistedBefore
                  && stopped.interrupted && stopped.journalSurvived)
        let healthy = await poll(jobCount: 2)
        check("poll persist (\(provider.rawValue) arm): the SAME fixture one job longer persists, leaves the "
              + "poll uninterrupted and still retires the journal — one index apart is the whole difference",
              healthy.requests > 0 && healthy.journalExistedBefore
                  && !healthy.interrupted && !healthy.journalSurvived)
        check("poll persist (\(provider.rawValue) arm): the seam was dormant before this section and is "
              + "dormant again after it — no stub outlives the checks that installed it",
              dormantBefore && !NetworkSession.testTransportIsActive
                  && NetworkSession.testTransport == nil)
    }

    // MARK: - 0. The transport seam cannot be reached by a shipped build

    /// `NetworkSession.testTransport` is what lets the provider-arm sections run a real paid-batch poll for
    /// $0, and it is also the only seam in this suite that decides whether a process talks to a **paid**
    /// endpoint at all. So it is gated exactly like the journal redirect
    /// (`OCRProcessor.pendingStateDirectory`) — an exact `"1"`, nothing approximate — and additionally on a
    /// closure having been installed, which nothing outside this file ever does.
    ///
    /// Both halves are checked, because either one alone would be a weaker gate than it looks:
    ///   * the flag half is swept through the PURE `testTransportIsEnabled(flag:)`, so eleven approximate
    ///     spellings can be refused without mutating this process's environment;
    ///   * the closure half is read LIVE — the flag really is `"1"` here (the driver only runs under it), so
    ///     `testTransportIsActive == false` at this point is the genuine reading that the shipped transport
    ///     is what a request would take right now.
    private static func theTransportSeamIsFailClosed(_ check: (String, Bool) -> Void) {
        let refused = [nil, "", " ", "0", "true", "TRUE", "yes", "1 ", " 1", "01", "11"]
        let allRefused = refused.allSatisfy { !NetworkSession.testTransportIsEnabled(flag: $0) }
        check("poll persist: only an exact \"1\" enables the test transport — \(refused.count) approximate "
              + "spellings are all refused",
              allRefused && NetworkSession.testTransportIsEnabled(flag: "1"))
        check("poll persist: the flag alone diverts nothing — with no closure installed the seam is dormant "
              + "and a request would take the shipped transport",
              !NetworkSession.testTransportIsActive && NetworkSession.testTransport == nil)
    }

    // MARK: - Fixtures

    /// Everything observable about one run of the real completion sweep, plus the real tail after it.
    private struct Swept {
        let returnedFalse: Bool
        let returnedTrue: Bool
        /// `batchPollInterrupted` went from a deliberate `false` to `true` — the keep-on-doubt answer.
        let flaggedInterrupted: Bool
        let stoppedProcessing: Bool
        /// The sweep reached the job and gave it its own synthetic no-result failure. Measured on the job
        /// record rather than on a returned count, so a sweep that skipped the loop cannot satisfy it.
        let sweptTheJob: Bool
        /// A real journal file was at `OCRProcessor.pendingBatchURL` before the tail ran.
        let journalExistedBefore: Bool
        let journalSurvived: Bool
        /// The in-memory journal state the Resume banner is rebuilt from.
        let batchStillLive: Bool
    }

    /// A synthetic model — never sent anywhere. Built by hand rather than read from `provider.models` so no
    /// check depends on `CustomModelStore`/UserDefaults.
    private static func model() -> LLMModel { model(.gemini) }

    private static func model(_ provider: LLMProvider) -> LLMModel {
        LLMModel(id: "poll-persist-\(provider.rawValue.lowercased())",
                 displayName: "Poll Persist \(provider.rawValue)",
                 provider: provider, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// A real 64×64 JPEG. Used wherever a source has to be genuinely decodable so that `PDFGenerator` is not
    /// a second way `handleOCRResult` can rewrite a job's result.
    private static func realJPEG() -> Data? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                         samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .jpeg, properties: [:])
    }

    /// What the stub was asked for. A MainActor box because the stub closure runs off this actor and the
    /// count is read back after the poll has returned — asserting it is how a check proves the arm really
    /// went through its provider client rather than short-circuiting somewhere above the `switch provider`.
    @MainActor private final class Transcript {
        var requests = 0
        var urls: [String] = []
    }

    /// The literal provider bodies that stand in for the wire, dispatched on the request URL. Each is the
    /// smallest shape its REAL parse seam accepts as *one finished chunk carrying one result for index 1* —
    /// the index the interrupted run has no job for. (`BatchParseContract` is what pins these shapes against
    /// the parsers in general; here they only need to be accepted.)
    private static func stub(for provider: LLMProvider, chunkId: String, transcript: Transcript)
        -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        let anthropicResults = "https://api.anthropic.com/v1/messages/batches/\(chunkId)/results"
        return { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let text = url.absoluteString
            await MainActor.run { transcript.requests += 1; transcript.urls.append(text) }
            let body: String
            switch provider {
            case .anthropic:
                body = text.hasSuffix("/results")
                    ? #"{"custom_id":"file-1","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"page one"}]}}}"#
                    : #"{"processing_status":"ended","request_counts":{"processing":0,"succeeded":1,"errored":0,"expired":0,"canceled":0},"results_url":"\#(anthropicResults)"}"#
            case .mistral:
                body = text.hasSuffix("/content")
                    ? #"{"custom_id":"file-1","response":{"status_code":200,"body":{"pages":[{"markdown":"page one"}]}}}"#
                    : #"{"status":"SUCCESS","total_requests":1,"completed_requests":1,"succeeded_requests":1,"failed_requests":0,"output_file":"w16bat7fu-out"}"#
            case .gemini:
                // INLINE results, so the whole chunk resolves from this one response and `resultsSource`
                // never builds a download URL — which is what keeps this to the `materialized` half of the
                // Gemini guard rather than dragging the file-download arm in.
                body = #"{"metadata":{"state":"BATCH_STATE_SUCCEEDED"},"response":{"inlinedResponses":{"inlinedResponses":[{"metadata":{"key":"1"},"response":{"candidates":[{"content":{"parts":[{"text":"page one"}]}}]}}]}}}"#
            case .openai:
                // No stub is ever installed for OpenAI (it does not enter the batch path at all —
                // `supportsBatch == false`). Refuse rather than answer, and with a code
                // `performWithRetry` does NOT treat as retryable, so a mistake here cannot make the suite
                // sit through real backoff.
                throw URLError(.unsupportedURL)
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: "HTTP/1.1", headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
    }

    /// A run configuration with rotation **OFF**. Not cosmetic: `processBatchResults` runs rotation detection
    /// per entry, and any LLM mode would make a real comparative call — through the stub while one is
    /// installed, over the wire if the seam were ever missed. `.off` returns nil before either.
    private static func runConfig(_ provider: LLMProvider, outputDirectory: URL) -> SessionProcessingConfig {
        SessionProcessingConfig(
            provider: provider, model: model(provider), thinkingLevel: .low,
            apiKey: "poll-persist-not-a-key", taggingMode: .none, rotationMode: .off,
            mergeDocuments: false, outputDirectory: outputDirectory, contextCharCount: 0,
            sendPreviousImage: false, customOCRPrompt: "", imageScale: 1.0,
            enableSegmentJSON: false, tagVocabulary: [], gateway: nil,
            outputImageFile: false, pdfImageMB: 1.0, exportedImageMB: 1.0, textColumns: 1)
    }

    /// One run of the real sweep over one job that got no result, followed by the real first-run tail.
    ///
    /// `blockThePersist` is the whole experiment: it puts a directory where `pending_run.json` goes, which
    /// makes the atomic write inside `saveResultToPendingRun` throw. Nothing is stubbed — the failure is a
    /// real `Data.write` error on a real path.
    private static func sweep(blockThePersist: Bool) async -> Swept {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("APPollPersist-\(UUID().uuidString)", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // A REAL 64×64 JPEG, so `PDFGenerator.generate` genuinely succeeds and the only thing that can fail
        // in `handleOCRResult` is the persistence step under test. (With junk bytes the PDF write can throw
        // instead, which rewrites the job's result and would blur what section 1 is measuring.)
        let source = dir.appendingPathComponent("sweep-source.jpg")
        try? realJPEG()?.write(to: source)

        // A real journal on disk AND in memory: this is a paid batch that reached a terminal state, which is
        // the only state the sweep ever runs in.
        let saved = OCRProcessor.savePendingBatch(
            OCRProcessor.PendingBatch(
                batchId: "batches/poll-persist", provider: .gemini, model: model(), thinkingLevel: .low,
                fileURLs: [source], outputDirectory: outDir, enableTagging: false, sendPreviousImage: false,
                submittedAt: Date(),
                lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
                submittedChunkIds: ["batches/poll-persist"]))
        let journalExisted = saved != nil && fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        // Deferred, not called at the end: the tail below is *meant* to leave this file on disk in the
        // interrupted case, so the removal has to be the one thing that cannot be skipped.
        defer { OCRProcessor.deletePendingBatch() }

        let runManifest = OCRProcessor.pendingRunURL
        try? fm.removeItem(at: runManifest)
        if blockThePersist {
            // A directory cannot be replaced by a file rename, so the atomic write throws. Removed on the
            // way out, before the next section sees this path.
            try? fm.createDirectory(at: runManifest, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: runManifest) }

        let processor = OCRProcessor()
        processor.activePendingBatch = saved
        processor.batchPollInterrupted = false
        processor.isProcessing = true
        // `.processing` is load-bearing — `OCRJob` defaults to `.pending`, and the sweep's `where` clause
        // only visits jobs the batch left in flight. A `.pending` fixture makes every check here vacuous.
        var job = OCRJob(sourceURL: source)
        job.status = .processing
        processor.jobs = [job]
        // The shape this section exists to pin: an interrupted-run manifest held alongside the paid batch,
        // which is what routes `saveResultToPendingRun` into the branch that does not report. Reachable in
        // production via a failed non-batch manifest write and a Dismiss — see the ⚠️ note in this file's
        // header, and `W16.bat8` for the separate bug that leaves it behind.
        processor.activePendingRun = OCRProcessor.PendingRun(
            provider: .gemini, model: model(), thinkingLevel: nil,
            fileURLs: [source], outputDirectory: outDir, enableTagging: false, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
            completedResults: [:], runFingerprint: nil)

        // `runConfig: nil` on purpose: the only thing it feeds here is PDF image size / text columns, and
        // the sweep's subject is the persistence result, not the PDF's dimensions.
        let returned = await processor.sweepJobsWithNoBatchResult(
            model: model(), outputDirectory: outDir, runConfig: nil)

        let flagged = processor.batchPollInterrupted
        let swept = processor.jobs.first?.status == .failed
            && processor.jobs.first?.result?.errorCode == "no_result"
            && processor.failedFiles.contains(source.lastPathComponent)
        let stopped = !processor.isProcessing

        // The real first-run tail, reading the flag the sweep just decided.
        processor.retirePaidBatchJournalIfPollCompleted()
        let survived = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        let stillLive = processor.activePendingBatch != nil

        return Swept(returnedFalse: !returned, returnedTrue: returned, flaggedInterrupted: flagged,
                     stoppedProcessing: stopped, sweptTheJob: swept,
                     journalExistedBefore: journalExisted, journalSurvived: survived,
                     batchStillLive: stillLive)
    }
}
