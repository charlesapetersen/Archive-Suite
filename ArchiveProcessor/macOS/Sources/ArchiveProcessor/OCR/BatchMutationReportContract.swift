import Foundation

/// **No paid-batch journal mutation fails in silence** (W16.bat3-fu) — headless, $0, no network, no keys.
/// Drives the real `OCRProcessor.markBatchSubmissionComplete()` / `recordSubmittedBatchChunk(_:)` /
/// `markBatchChunkConsumed(_:)`, the three mutators every paid-batch run advances its recovery journal
/// through, and pins that a failure from any of them is *reported* rather than swallowed.
///
/// **Why this exists.** `performBatchOCR`'s fifth interrupted exit is
/// `guard markBatchSubmissionComplete() else { return }`, and W16.bat4's tail comment claimed to cover "all
/// four" of them. The save-failure half was in fact covered — `persistPendingBatchMutation` sets
/// `batchPollInterrupted` on its way out, so `processFiles` runs the tail — but its *other* failure exit,
/// the missing-`activePendingBatch` guard, returned `false` without a word. That is not a hypothetical
/// shape: `cancel()` nils `activePendingBatch` (`+Pipeline.swift`, the `if let batch = activeBatch` block)
/// while a Gemini submit loop may still be running, so a Stop pressed mid-submit lands in exactly it.
///
/// A silent `false` there is worse than it looks, because **nothing resets `batchPollInterrupted` at the
/// start of a run** — the only `= false` in the app is inside `pollBatchUntilComplete`, which this exit
/// never reaches. So the run's fate was decided by whatever the PREVIOUS run happened to leave in the flag:
/// a stale `false` falls through the interruption branch on a paid batch with no results, and the operator
/// is given no message at all about a job that may still be running server-side.
///
/// **The property, stated once:** a mutator that returns `false` *because the journal could not be advanced*
/// has ALWAYS set `batchPollInterrupted`, stopped the run and told the operator something — and a mutator
/// that returns `true` has done none of those. Two deliberate carve-outs, so the sentence stays true:
///   * `recordSubmittedBatchChunk`'s **input validation** (`guard !normalized.isEmpty, !normalized.contains(",")`)
///     still returns `false` in silence. It never reaches the journal, and both call sites turn it into a
///     `throw` whose catch sets the flag — so it is covered, one layer up, and is not pinned here.
///   * The post-Stop exit reports WITHOUT cancelling the run task (`cancelRun: false`). `processingTask` is
///     nil-or-a-newer-run's by then; see `reportInterruptedPaidBatch`'s doc.
///
/// `true` is the keep-on-doubt direction: every reader of the flag
/// (`retirePaidBatchJournalIfPollCompleted`, `resumePendingBatch`, `processFiles`) treats it as "the journal
/// survives", and not one of them deletes on it. So this contract can only ever move the app toward keeping
/// a paid batch's only local record, never away from it.
///
/// ⚠️ **SCOPE — read before citing this file.**
///   * This pins the three mutators and the shared helper under them, NOT `performBatchOCR:647` itself.
///     Reaching that line needs a real paid submission, so the call site's own explicit
///     `batchPollInterrupted = true` is structural (a bare four-line guard body) rather than driven here —
///     the same honest limit `BatchInterruptTailContract` records for the tail's two call sites.
///   * The `savePendingBatch`-failed exit is not driven either. Forcing a write to fail would mean making
///     the redirected state directory unwritable mid-run, which every other section shares; that exit's
///     reporting is the pre-existing behaviour this item did not change, and sections 1–3 below pin the
///     helper both of them now route through.
///   * Sections 3 and 4 write a real journal at the shipped path, so they run only under the redirect.
///
/// Run from `BatchResumeTestDriver` (section 18) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchMutationReportContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) {
        everyMutatorReportsAClosedJournal(check)
        whoTheReporterIsAllowedToCancel(check)
        // Sections 3 and 4 persist a journal at `OCRProcessor.pendingBatchURL` and remove it again.
        guard redirected else {
            // FOUR checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("mutation report: the four checks that write a real journal — a HEALTHY mutation reporting "
                  + "nothing, and a report deleting nothing — are SKIPPED (refused: the journal path did not "
                  + "resolve away from Application Support)", false)
            return
        }
        aHealthyMutationReportsNothing(check)
        reportingRemovesNothingFromDisk(check)
    }

    // MARK: - Fixtures

    /// A synthetic model — never sent anywhere. Built by hand rather than read from `provider.models` so no
    /// check depends on `CustomModelStore`/UserDefaults.
    private static func model() -> LLMModel {
        LLMModel(id: "mutation-report-gemini", displayName: "Mutation Report Gemini",
                 provider: .gemini, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// ⚠️ `submissionComplete: false` is LOAD-BEARING, not tidiness. `PendingBatch.init` defaults it to
    /// **true**, so a fixture that omits it makes section 2's "the marker was persisted" assertion true
    /// before the mutator ever runs — neuter `markBatchSubmissionComplete`'s mutation closure to `{ _ in }`
    /// and both of its checks stay green. Start from the state the real submit path is actually in.
    private static func journal(chunkIds: [String]) -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: chunkIds.first ?? "", provider: .gemini, model: model(), thinkingLevel: .low,
            fileURLs: [URL(fileURLWithPath: "/tmp/mutation-report/scan-0.jpg")],
            outputDirectory: URL(fileURLWithPath: "/tmp/mutation-report", isDirectory: true),
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: chunkIds, submissionComplete: false)
    }

    /// Everything observable about one mutator call.
    private struct Reported {
        let returnedFalse: Bool
        /// `batchPollInterrupted` went from a deliberate `false` to `true` — the keep-on-doubt answer.
        let flaggedInterrupted: Bool
        let stoppedProcessing: Bool
        /// `statusMessage` is no longer the sentinel, and is not empty.
        let explainedItself: Bool
        /// Was the run task cancelled? Observed on a REAL task rather than assumed. On the post-Stop exit
        /// this must be FALSE — `processingTask` is nil-or-a-newer-run's by then.
        let cancelledTheRun: Bool
        /// Reporting is not acting: the run's jobs and the resume banner are left exactly as they were.
        /// The banner half is the load-bearing one — a reporter that "helpfully" ran `checkForPendingBatch()`
        /// would be doing `finishInterruptedBatchPoll()`'s job at the wrong layer, and this catches it.
        let leftTheRunAlone: Bool
    }

    /// Call one mutator on a processor whose journal has already been closed by Stop, and record everything.
    ///
    /// THE ONLY place this file builds that state, so no check can accidentally run a mutator against a
    /// processor that still holds a journal — which is a different question with a different answer.
    private static func withClosedJournal(_ mutate: (OCRProcessor) -> Bool) -> Reported {
        let processor = OCRProcessor()
        // Exactly what `cancel()` leaves behind: `activeBatch` and `activePendingBatch` both nil, while the
        // submit loop that is about to call a mutator is still unwinding on its own task.
        processor.activePendingBatch = nil
        processor.batchPollInterrupted = false
        processor.isProcessing = true
        let sentinel = "mutation-report-sentinel-\(UUID().uuidString)"
        processor.statusMessage = sentinel
        let source = URL(fileURLWithPath: "/tmp/mutation-report/scan-0.jpg")
        processor.jobs = [OCRJob(sourceURL: source)]
        // A sentinel in the resume banner. Only `checkForPendingBatch()` writes this, so "was it replaced?"
        // detects a reporter that started acting on the interruption instead of merely reporting it.
        let banner = "mutation-report-banner-\(UUID().uuidString)"
        processor.pendingBatchInfo = banner

        // A real, live run task, so "did it cancel the run?" is measured rather than assumed — in BOTH
        // directions: this state is the post-Stop one, where the correct answer is that it does not.
        let run = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        processor.processingTask = run

        let returned = mutate(processor)
        let cancelled = run.isCancelled
        run.cancel()

        return Reported(
            returnedFalse: !returned,
            flaggedInterrupted: processor.batchPollInterrupted,
            stoppedProcessing: !processor.isProcessing,
            explainedItself: processor.statusMessage != sentinel && !processor.statusMessage.isEmpty,
            cancelledTheRun: cancelled,
            leftTheRunAlone: processor.pendingBatchInfo == banner && processor.jobs.count == 1
                && processor.jobs[0].sourceURL == source)
    }

    // MARK: - 1. The bug: a mutator that fails without saying so

    private static func everyMutatorReportsAClosedJournal(_ check: (String, Bool) -> Void) {
        // THE regression check. `markBatchSubmissionComplete()` is what `performBatchOCR`'s fifth
        // interrupted exit guards on; before W16.bat3-fu it returned `false` here having set nothing, and
        // the exit's bare `return` handed the run's verdict to the previous run's flag.
        let submission = withClosedJournal { $0.markBatchSubmissionComplete() }
        check("mutation report: markBatchSubmissionComplete on a journal Stop already closed reports the "
              + "interruption — it does not return false in silence",
              submission.returnedFalse && submission.flaggedInterrupted
              && submission.stoppedProcessing && submission.explainedItself)

        // The same helper serves all three mutators, and the other two reach it from the poll loop, where a
        // silent `false` is worse still: `pollBatchUntilComplete` has just assigned `batchPollInterrupted =
        // false`, so an unreported failure there returns a flag that says "the poll completed" and the
        // caller RETIRES the journal of a batch whose results never landed.
        let recorded = withClosedJournal { $0.recordSubmittedBatchChunk("batches/paid-chunk-1") }
        check("mutation report: recordSubmittedBatchChunk reports it too — a chunk that is already billed "
              + "must not fail to journal quietly",
              recorded.returnedFalse && recorded.flaggedInterrupted
              && recorded.stoppedProcessing && recorded.explainedItself)

        let consumed = withClosedJournal { $0.markBatchChunkConsumed("batches/paid-chunk-1") }
        check("mutation report: markBatchChunkConsumed reports it too, so the poll cannot return a "
              + "\"completed\" flag on a chunk it failed to record",
              consumed.returnedFalse && consumed.flaggedInterrupted
              && consumed.stoppedProcessing && consumed.explainedItself)

        // The two halves the three checks above do not name individually, swept across all three mutators.
        // FIRST: none of them cancels `processingTask`. This state is post-Stop by construction, so that
        // handle is either already nil or the NEXT run's — a confirmed cancellation deletes the journal
        // `startProcessing` refuses on, and this run can still be resolving a 30–120s provider request when
        // the operator starts another. Cancelling here would kill the wrong run.
        let all = [submission, recorded, consumed]
        check("mutation report: none of the three cancels the run task — post-Stop, that handle belongs to "
              + "the next run, not this one",
              all.count == 3 && all.allSatisfy { !$0.cancelledTheRun })
        // SECOND: reporting stays reporting. Acting on the interruption — recomputing the resume banner,
        // clearing state — is `finishInterruptedBatchPoll()`'s job, at the caller, once.
        check("mutation report: and none of them touches the resume banner or the run's jobs — reporting an "
              + "interruption is not acting on one",
              all.allSatisfy { $0.leftTheRunAlone })
    }

    // MARK: - 2. Who the reporter is allowed to cancel

    /// Section 1 pins that the post-Stop exit does NOT cancel. This pins the other direction on the same
    /// seam, so "never cancels" cannot quietly become the whole behaviour: a LIVE run that has just found it
    /// cannot persist its journal must still be stopped, or the submit loop keeps spending money after the
    /// app has decided the run is over. Drives `reportInterruptedPaidBatch` directly — it is the only way to
    /// reach the `cancelRun: true` side without forcing a real disk-write failure.
    private static func whoTheReporterIsAllowedToCancel(_ check: (String, Bool) -> Void) {
        func report(cancelRun: Bool) -> (cancelled: Bool, flagged: Bool, stopped: Bool, said: Bool) {
            let processor = OCRProcessor()
            processor.batchPollInterrupted = false
            processor.isProcessing = true
            let run = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
            processor.processingTask = run
            processor.reportInterruptedPaidBatch("reporter-\(UUID().uuidString)", cancelRun: cancelRun)
            let cancelled = run.isCancelled
            run.cancel()
            return (cancelled, processor.batchPollInterrupted, !processor.isProcessing,
                    !processor.statusMessage.isEmpty)
        }

        let live = report(cancelRun: true)
        let unwinding = report(cancelRun: false)
        check("mutation report: a LIVE run that cannot persist its journal is really cancelled — the submit "
              + "loop does not keep going after the app gave up on the run",
              live.cancelled && live.flagged && live.stopped && live.said)
        check("mutation report: and the same reporter leaves the task alone when told to, so the two cases "
              + "are one seam with one switch — not two behaviours that can drift",
              !unwinding.cancelled && unwinding.flagged && unwinding.stopped && unwinding.said)
    }

    // MARK: - 3. The other direction, so the property is not "always report"

    /// Without this, an implementation that called `reportInterruptedPaidBatch` unconditionally — wedging
    /// every healthy paid batch into a permanent "interrupted" — would satisfy section 1 completely.
    private static func aHealthyMutationReportsNothing(_ check: (String, Bool) -> Void) {
        let processor = OCRProcessor()
        processor.activePendingBatch = journal(chunkIds: ["batches/healthy-0"])
        processor.batchPollInterrupted = false
        processor.isProcessing = true
        let sentinel = "mutation-report-healthy-\(UUID().uuidString)"
        processor.statusMessage = sentinel
        let run = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        processor.processingTask = run

        let returned = processor.markBatchSubmissionComplete()
        let cancelled = run.isCancelled
        run.cancel()
        // Read back through the production write path's own result rather than the file, so a mutation that
        // reported success without persisting anything is still caught.
        let persisted = processor.activePendingBatch?.submissionComplete == true
        OCRProcessor.deletePendingBatch()

        check("mutation report: a HEALTHY markBatchSubmissionComplete persists the marker and returns true",
              returned && persisted)
        check("mutation report: and it reports nothing — the run keeps going, unflagged, with its message "
              + "and its task intact",
              !processor.batchPollInterrupted && processor.isProcessing
              && processor.statusMessage == sentinel && !cancelled)
    }

    // MARK: - 4. Reporting an interruption removes nothing

    /// The direction that costs money if it goes wrong. `reportInterruptedPaidBatch` is called on the exact
    /// path where a paid server-side job may still be alive, so a "tidy up the journal" line added to it
    /// would strand that job with no local record — the same failure `finishInterruptedBatchPoll()` is
    /// pinned against, one layer down.
    private static func reportingRemovesNothingFromDisk(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let bytes = Data(#"{"batchId":"batches/paid-job"}"#.utf8)
        try? bytes.write(to: OCRProcessor.pendingBatchURL, options: .atomic)
        let runManifest = OCRProcessor.pendingRunURL
        let runBytes = Data(#"{"sentinel":"interrupted-run-manifest"}"#.utf8)
        try? runBytes.write(to: runManifest, options: .atomic)
        let bothExisted = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
            && fm.fileExists(atPath: runManifest.path)

        // In-memory journal closed, durable journal still on disk — precisely the state a Stop mid-submit
        // leaves when the cancellation could not confirm every chunk, and the one in which the file is the
        // operator's only way back to a paid job.
        let reported = withClosedJournal { $0.markBatchSubmissionComplete() }

        let batchIntact = (try? Data(contentsOf: OCRProcessor.pendingBatchURL)) == bytes
        let runIntact = (try? Data(contentsOf: runManifest)) == runBytes
        try? fm.removeItem(at: OCRProcessor.pendingBatchURL)
        try? fm.removeItem(at: runManifest)

        check("mutation report: reporting the interruption leaves the paid-batch journal byte-identical on "
              + "disk — the server-side job keeps its only local record",
              bothExisted && reported.returnedFalse && batchIntact)
        check("mutation report: and it leaves the interrupted-run manifest alone as well", runIntact)
    }
}
