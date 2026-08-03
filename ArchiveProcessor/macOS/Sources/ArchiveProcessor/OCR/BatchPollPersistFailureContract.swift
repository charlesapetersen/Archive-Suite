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
    private static func model() -> LLMModel {
        LLMModel(id: "poll-persist-gemini", displayName: "Poll Persist Gemini",
                 provider: .gemini, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
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
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let jpeg = bitmap?.representation(using: .jpeg, properties: [:]) { try? jpeg.write(to: source) }

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
