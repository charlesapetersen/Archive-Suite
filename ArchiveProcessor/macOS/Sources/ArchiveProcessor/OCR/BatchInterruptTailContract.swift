import Foundation

/// **The interrupted-paid-batch TAIL contract** (W16.bat4) — headless, $0, no network, no keys. Drives the
/// real `OCRProcessor.finishInterruptedBatchPoll()`, the single tail both paid-batch entry points run when
/// a run is cut short with a server-side job possibly still alive.
///
/// Why this exists: every `batchPollInterrupted` message tells the operator the batch was kept *so they can
/// resume it*, and the Resume control (`OCRView`'s "Pending Batch" box, `:319`) renders only from
/// `pendingBatchInfo` — which is written **only** inside `checkForPendingBatch()`. The first-run path used to
/// end its interruption with `isProcessing = false` and nothing else, so the button the message named did not
/// exist until the operator pressed Start and was refused, and the run's temp JPEGs leaked. The resume path
/// did it correctly. Two tails, one of them wrong; now one tail, called by both.
///
/// So the checks below are about a tail that must do five things and no more: drop the live batch identity,
/// stop the run, delete exactly this run's own temp conversions, recompute the resume banner, and leave
/// everything else — the interruption message, the run's results, the interrupted-run manifest — alone. Each
/// is a mutation someone could plausibly make: dropping `checkForPendingBatch()` restores the original bug;
/// adding a `statusMessage` assignment clobbers the very message that explains the interruption; adding
/// `Self.deletePendingBatch()` "to tidy up" strands a paid job with no way back; clearing `jobs` throws away
/// the results a resume is supposed to reuse.
///
/// **How it stays $0 and cannot touch the operator's state.** Nothing here performs a network call, and the
/// only files any check creates or deletes live under a per-trial temp directory. The one thing that reads
/// durable state is `checkForPendingBatch()` itself, running for real inside the tail: it decodes whatever
/// `pending_batch.json` / `pending_run.json` it finds and recomputes two banner strings from them. Since
/// W16.bat2-fu2 that is the harness's redirected state directory rather than the operator's own, and it
/// deletes neither file in any case (see its own comments — a paid server-side batch must never be
/// stranded); no check below asserts anything about what it *found*, only that it ran.
///
/// ⚠️ **SCOPE — read before citing this file.**
///   * This pins the TAIL, not its two call sites. That the resume path (`resumePendingBatch`) and the
///     first-run path (`processFiles`, after `performBatchOCR`) each reach it — the bug W16.bat4 *was* — is
///     grep-verifiable, not driven here: both entry points require a real paid submission. What makes them
///     safe meanwhile is structural rather than tested: each site is now a bare
///     `finishInterruptedBatchPoll(); return`, so there is no second copy of the tail left to drift.
///   * "Deletes no journal" is proved against decoy files named exactly `pending_batch.json` /
///     `pending_run.json` in the trial's own directory. That covers a tail that deletes by *name*; a tail
///     that called `OCRProcessor.deletePendingBatch()` would delete the journal at whatever the shipped path
///     resolves to, which is not something this contract asserts either way. Section 16
///     (`BatchJournalPathContract`) is where that path, and that deleter, are pinned.
///   * The interruption *messages* are the other half of this bug and are not pinned here — this contract
///     asserts only that the tail leaves `statusMessage` exactly as its caller set it.
///
/// Run from `BatchResumeTestDriver` (section 15) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchInterruptTailContract {

    static func run(check: (String, Bool) -> Void) {
        theResumeControlAppears(check)
        onlyThisRunsTempConversionsAreRemoved(check)
        theInterruptionMessageSurvives(check)
        theRunsOwnResultsSurvive(check)
        runningTheTailTwiceIsSafe(check)
        sweepEveryStartingState(check)
    }

    // MARK: - Fixtures

    /// A synthetic model — never sent anywhere. Built by hand rather than read from `provider.models` so no
    /// check depends on `CustomModelStore`/UserDefaults.
    private static func model(_ provider: LLMProvider = .gemini) -> LLMModel {
        LLMModel(id: "interrupt-tail-\(provider.rawValue.lowercased())",
                 displayName: "Interrupt Tail \(provider.rawValue)",
                 provider: provider, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// The run state a paid batch is interrupted *out of*, and what the tail left of it.
    private struct Interrupted {
        /// The temp PDF→JPEG conversions this run registered. Must all be gone.
        let tempConversions: [URL]
        let tempConversionsExistedBefore: Bool
        let tempConversionsSurvived: [URL]
        /// Unregistered files sitting in the SAME directory — including two named exactly like the durable
        /// recovery manifests. Must all still be there.
        let bystanders: [URL]
        let bystandersExistedBefore: Bool
        let bystandersRemoved: [URL]

        let activeBatchCleared: Bool
        let journalStateCleared: Bool
        let stoppedProcessing: Bool
        let conversionMapEmptied: Bool
        /// Was the resume-banner state recomputed? Detected with a sentinel, so it holds whether or not the
        /// operator has a real journal on disk.
        let bannerRefreshed: Bool
        let runBannerRefreshed: Bool
        /// `statusMessage` afterwards — the caller's interruption message, which the tail must not touch.
        let statusMessage: String

        /// Run state a resume needs, sampled after the tail.
        let jobCount: Int
        let failedFiles: [String]
        let outputURLMap: [URL: URL]
        let exportedImageMap: [URL: URL]
        let progress: Double
        let keptInterruptedRunState: Bool

        var tempConversionsGone: Bool {
            tempConversionsExistedBefore && tempConversionsSurvived.isEmpty
        }
        var bystandersIntact: Bool { bystandersExistedBefore && bystandersRemoved.isEmpty }
    }

    /// Put a processor into the state a paid batch is interrupted out of, run the REAL tail, and record
    /// everything observable.
    ///
    /// THE ONLY caller of `finishInterruptedBatchPoll()` in this file, so no scenario can accidentally run a
    /// tail against files outside its own temp directory.
    private static func interrupt(liveBatch: Bool = true,
                                  journal: Bool = true,
                                  processing: Bool = true,
                                  conversions: Int = 3,
                                  twice: Bool = false) -> Interrupted {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("APInterruptTail-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // This run's own temp PDF→JPEG conversions, keyed by the source PDF they came from — exactly the
        // shape `convertPDFInputs` leaves behind. The sources are bystanders: a resume re-converts from them.
        var sources: [URL] = []
        var temps: [URL] = []
        var map: [URL: URL] = [:]
        for i in 0..<conversions {
            let source = dir.appendingPathComponent("scan-\(i).pdf")
            let temp = dir.appendingPathComponent("scan-\(i)-page.jpg")
            try? Data("source \(i)".utf8).write(to: source)
            try? Data("converted \(i)".utf8).write(to: temp)
            sources.append(source)
            temps.append(temp)
            map[source] = temp
        }

        // Files the tail must not touch, in the same directory so "it deleted the right ones" is a real
        // discrimination rather than a directory it never looked in. The two manifests are named from the
        // shipped constants, so renaming a manifest re-points this check instead of silently orphaning it.
        let output = dir.appendingPathComponent("scan-0.pdf.out.pdf")
        let journalDecoy = dir.appendingPathComponent(OCRProcessor.pendingBatchFileName)
        let runDecoy = dir.appendingPathComponent(OCRProcessor.pendingRunFileName)
        for bystander in [output, journalDecoy, runDecoy] {
            try? Data(#"{"batchId":"paid-job"}"#.utf8).write(to: bystander)
        }
        let bystanders = sources + [output, journalDecoy, runDecoy]

        let processor = OCRProcessor()
        processor.pdfToImageMap = map
        processor.isProcessing = processing
        if liveBatch {
            processor.activeBatch = OCRProcessor.BatchContext(
                batchId: "batches/interrupted", apiKey: "tail-not-a-key",
                model: model(), thinkingLevel: .low, provider: .gemini)
        }
        if journal {
            processor.activePendingBatch = OCRProcessor.PendingBatch(
                batchId: "batches/interrupted", provider: .gemini, model: model(), thinkingLevel: .low,
                fileURLs: sources, outputDirectory: dir, enableTagging: false, sendPreviousImage: false,
                submittedAt: Date(),
                lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
                submittedChunkIds: ["batches/interrupted"])
        }

        // The run's own results, which a resume reuses verbatim — the tail may not discard them.
        processor.jobs = sources.map { OCRJob(sourceURL: $0) }
        processor.failedFiles = ["scan-9.pdf"]
        processor.outputURLMap = sources.isEmpty ? [:] : [sources[0]: output]
        processor.exportedImageMap = sources.isEmpty ? [:] : [sources[0]: temps[0]]
        processor.progress = 0.42

        // A non-batch resume manifest held in memory alongside the batch. `saveResultToPendingRun` branches
        // on which of the two is set, and it is what an interrupted-run resume is persisted from, so a tail
        // that cleared it would discard state belonging to a different recovery path entirely.
        processor.activePendingRun = OCRProcessor.PendingRun(
            provider: .gemini, model: model(), thinkingLevel: nil,
            fileURLs: sources, outputDirectory: dir, enableTagging: false, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
            completedResults: [:], runFingerprint: nil)

        // The interruption message the caller already set — the operator's explanation of what happened.
        let message = "tail-message-\(UUID().uuidString)"
        processor.statusMessage = message
        // Sentinels in the two banner fields. The tail ends in `checkForPendingBatch()`, which recomputes
        // both from disk; "was it replaced?" detects that without depending on what the operator has.
        let batchSentinel = "tail-batch-sentinel-\(UUID().uuidString)"
        let runSentinel = "tail-run-sentinel-\(UUID().uuidString)"
        processor.pendingBatchInfo = batchSentinel
        processor.pendingRunInfo = runSentinel

        let tempsExisted = temps.allSatisfy { fm.fileExists(atPath: $0.path) }
        let bystandersExisted = bystanders.allSatisfy { fm.fileExists(atPath: $0.path) }

        processor.finishInterruptedBatchPoll()
        if twice { processor.finishInterruptedBatchPoll() }

        return Interrupted(
            tempConversions: temps,
            tempConversionsExistedBefore: tempsExisted && (conversions == 0 || !temps.isEmpty),
            tempConversionsSurvived: temps.filter { fm.fileExists(atPath: $0.path) },
            bystanders: bystanders,
            bystandersExistedBefore: bystandersExisted,
            bystandersRemoved: bystanders.filter { !fm.fileExists(atPath: $0.path) },
            activeBatchCleared: processor.activeBatch == nil,
            journalStateCleared: processor.activePendingBatch == nil,
            stoppedProcessing: !processor.isProcessing,
            conversionMapEmptied: processor.pdfToImageMap.isEmpty,
            bannerRefreshed: processor.pendingBatchInfo != batchSentinel,
            runBannerRefreshed: processor.pendingRunInfo != runSentinel,
            statusMessage: processor.statusMessage == message ? "unchanged" : processor.statusMessage,
            jobCount: processor.jobs.count,
            failedFiles: processor.failedFiles,
            outputURLMap: processor.outputURLMap,
            exportedImageMap: processor.exportedImageMap,
            progress: processor.progress,
            keptInterruptedRunState: processor.activePendingRun != nil)
    }

    // MARK: - The bug: the Resume control the interruption message names

    private static func theResumeControlAppears(_ check: (String, Bool) -> Void) {
        let tail = interrupt()

        // THE regression check. The shipped first-run tail was `isProcessing = false; return`, which passes
        // every other assertion in this file and leaves this one red: `pendingBatchInfo` is the only thing
        // `OCRView`'s "Pending Batch" box renders from, and only `checkForPendingBatch()` writes it.
        check("interrupt tail: the resume banner is recomputed, so the Resume control the message names can render",
              tail.bannerRefreshed)
        // `checkForPendingBatch()` refreshes BOTH banners. Without this, a tail that inlined only the
        // paid-batch half would satisfy the check above while leaving a stale interrupted-run banner.
        check("interrupt tail: the interrupted-run banner is recomputed in the same pass",
              tail.runBannerRefreshed)
        check("interrupt tail: the run is stopped and the live batch identity is dropped",
              tail.stoppedProcessing && tail.activeBatchCleared && tail.journalStateCleared)

        // The banner is not merely *different* from the sentinel — it is what a fresh read of the durable
        // state says. A tail that assigned some placeholder of its own would clear the sentinel and still be
        // wrong. Both processors are read back-to-back, so they see the same disk.
        //
        // ⚠️ Honest limit since W16.bat2-fu2: that disk is now the harness's own empty state directory, so
        // both sides are reliably `nil == nil` and this check no longer distinguishes a correct banner from
        // an empty one — it only still catches a placeholder. Before the redirect it was meaningful exactly
        // when the operator happened to have a manifest, i.e. never on purpose. Giving it a journal fixture
        // to find is now possible and is filed as **W16.bat4-fu**.
        let fresh = OCRProcessor()
        fresh.checkForPendingBatch()
        let tailed = OCRProcessor()
        tailed.pendingBatchInfo = "stale"
        tailed.pendingRunInfo = "stale"
        tailed.finishInterruptedBatchPoll()
        check("interrupt tail: the recomputed banners are what checkForPendingBatch() alone produces",
              tailed.pendingBatchInfo == fresh.pendingBatchInfo
              && tailed.pendingRunInfo == fresh.pendingRunInfo)
    }

    // MARK: - What it is allowed to delete

    private static func onlyThisRunsTempConversionsAreRemoved(_ check: (String, Bool) -> Void) {
        let tail = interrupt()

        // The leak half of W16.bat4: the first-run tail never called `cleanupTempFiles()`, so every PDF
        // input's temp JPEG stayed in the temp directory for the rest of the login session.
        check("interrupt tail: this run's temp PDF→JPEG conversions are really deleted, and the map is emptied",
              tail.tempConversionsGone && tail.conversionMapEmptied)
        // The other direction, and the one that costs money if it goes wrong: a tail that deleted by
        // directory, or that "tidied up" the recovery journal, would take these with it. Two of the three
        // are named exactly as the durable manifests are.
        check("interrupt tail: nothing else in the directory is touched — not the sources, the output, or either manifest",
              tail.bystandersIntact)
    }

    // MARK: - What it must leave exactly as it found it

    private static func theInterruptionMessageSurvives(_ check: (String, Bool) -> Void) {
        let tail = interrupt()
        // Each caller sets its own explanation before running the tail ("Batch timed out after N status
        // checks — it's kept so you can resume it", the submission-stopped message, …). A `statusMessage`
        // assignment inside the tail would overwrite all of them with one generic line, and the operator
        // would lose the only account of what actually happened to a paid job.
        check("interrupt tail: the caller's interruption message is left exactly as it was",
              tail.statusMessage == "unchanged")
    }

    private static func theRunsOwnResultsSurvive(_ check: (String, Bool) -> Void) {
        let tail = interrupt()
        // A resume reuses already-materialized results and their source→output associations verbatim
        // (`resolveResumeOutputURLs`). Clearing them here would not lose the paid work — it is journaled —
        // but it would blank the file list under the operator while the batch is still resumable.
        check("interrupt tail: the run's jobs, failures, output associations and progress are untouched",
              tail.jobCount == 3 && tail.failedFiles == ["scan-9.pdf"]
              && tail.outputURLMap.count == 1 && tail.exportedImageMap.count == 1
              && tail.progress == 0.42)
        // The interrupted-run manifest is a different recovery path with a different durable file. The tail
        // is about the paid batch; taking its sibling's in-memory state with it would break a resume that
        // has nothing to do with this interruption.
        check("interrupt tail: the interrupted-RUN manifest state belongs to another path and is left alone",
              tail.keptInterruptedRunState)
    }

    // MARK: - Twice

    private static func runningTheTailTwiceIsSafe(_ check: (String, Bool) -> Void) {
        // Both call sites `return` immediately after the tail, so today it runs once. That is a property of
        // the callers, not of the tail — and one of the five interrupted exits it now covers
        // (`performBatchOCR`'s submission-failure arm) already calls `checkForPendingBatch()` on its own way
        // out, so a second pass over the same state is not hypothetical.
        let tail = interrupt(twice: true)
        check("interrupt tail: running it twice changes nothing and removes nothing extra",
              tail.tempConversionsGone && tail.conversionMapEmptied && tail.bystandersIntact
              && tail.stoppedProcessing && tail.activeBatchCleared && tail.journalStateCleared
              && tail.bannerRefreshed && tail.statusMessage == "unchanged"
              && tail.jobCount == 3 && tail.keptInterruptedRunState)
    }

    // MARK: - The same invariants, from every state an interruption can arrive in

    /// The five interrupted exits arrive here in different states: a journal-save failure has neither a live
    /// batch nor journal state; a submission that stopped part-way has both and has already reset
    /// `isProcessing`; a poll timeout has journal state but its `activeBatch` was cleared on the way out;
    /// a `markBatchSubmissionComplete()` closed out by Stop (W16.bat3-fu) has neither.
    /// The tail's outcome must not depend on which — so drive all of them, plus a run with no PDF inputs at
    /// all (nothing to clean up).
    private static func sweepEveryStartingState(_ check: (String, Bool) -> Void) {
        var trials = 0
        var end = Invariant("interrupt-tail sweep: every start state ends stopped, cleared, and re-bannered")
        var deleted = Invariant("interrupt-tail sweep: exactly this run's conversions are deleted, whatever the start state")
        var kept = Invariant("interrupt-tail sweep: the sources, the output and both manifests always survive")
        var untouched = Invariant("interrupt-tail sweep: the message and the run's results are never disturbed")
        var conversionsRemoved = 0

        for liveBatch in [true, false] {
            for journal in [true, false] {
                for processing in [true, false] {
                    for conversions in [0, 1, 3] {
                        let shape = "batch:\(liveBatch)/journal:\(journal)/processing:\(processing)"
                            + "/\(conversions) conversion\(conversions == 1 ? "" : "s")"
                        let tail = interrupt(liveBatch: liveBatch, journal: journal,
                                             processing: processing, conversions: conversions)
                        trials += 1
                        conversionsRemoved += tail.tempConversions.count - tail.tempConversionsSurvived.count

                        end.require(tail.stoppedProcessing && tail.activeBatchCleared
                                    && tail.journalStateCleared && tail.bannerRefreshed
                                    && tail.runBannerRefreshed && tail.conversionMapEmptied, shape)
                        deleted.require(tail.tempConversionsSurvived.isEmpty, shape)
                        kept.require(tail.bystandersIntact, shape)
                        untouched.require(tail.statusMessage == "unchanged"
                                          && tail.jobCount == conversions
                                          && tail.failedFiles == ["scan-9.pdf"]
                                          && tail.progress == 0.42
                                          && tail.keptInterruptedRunState, shape)
                    }
                }
            }
        }

        check("interrupt-tail sweep: every live-batch × journal × processing × conversion-count start state ran (\(trials) trials)",
              trials == 24)
        // Non-vacuity, measured: 8 of the 24 shapes have no conversions to remove, so a `cleanupTempFiles()`
        // that had been quietly dropped could still satisfy `deleted` on those. 16 shapes do have files
        // (8 × 1 + 8 × 3 = 32), and this counts the ones that really left the disk.
        check("interrupt-tail sweep: 32 real temp files across the \(trials) shapes were really deleted",
              conversionsRemoved == 32)
        for invariant in [end, deleted, kept, untouched] {
            check(invariant.label, invariant.held && trials == 24)
        }
    }

    /// One invariant swept across all 24 trials, carrying the first failing shape so a red is actionable.
    private struct Invariant {
        private let name: String
        private(set) var firstBad: String?
        init(_ name: String) { self.name = name }
        /// `shape` is an autoclosure so the labels that never fail are never built.
        mutating func require(_ ok: Bool, _ shape: @autoclosure () -> String) {
            if !ok && firstBad == nil { firstBad = shape() }
        }
        var held: Bool { firstBad == nil }
        var label: String { firstBad.map { "\(name) [first bad shape: \($0)]" } ?? name }
    }
}
