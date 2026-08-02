import Foundation

/// **What an interrupted paid submission TELLS the operator** (W16.bat3-fu2) — headless, $0, no network,
/// no keys. Section 18 pins that a failed journal mutation says *something*; this pins that the sentence
/// the operator then reads is true.
///
/// **Why this exists.** `performBatchOCR`'s catch block used to compute
/// `let acknowledged = activePendingBatch?.submittedChunkIds.count ?? 0` and branch on it. But `cancel()`
/// nils `activePendingBatch`, and a Stop pressed mid-submit is *the* way that catch is reached — the chunk
/// callback throws the moment `recordSubmittedBatchChunk` finds the journal closed. So on the one path that
/// spends money, `acknowledged` read **0** with paid jobs already created and journaled, and the operator
/// was told:
///
/// > Batch submission outcome is uncertain. No server ID was received; the recovery journal was kept.
///
/// Both halves could be wrong at once — server IDs *were* received, and the journal's fate was asserted
/// without looking at the file — and that is the sentence someone decides whether to re-submit from. It
/// also overwrote `pendingBatchJournalClosedMessage`, so W16.bat3-fu's careful explanation of the cause was
/// true at the mutator and gone by the time it reached the screen.
///
/// **The property, stated once:** every clause of the interruption message is a measurement.
///   * the job count comes from `paidJobsCreatedThisSubmission`, appended where a created job is FIRST
///     known and never cleared by `cancel()` — so it cannot be understated by a Stop;
///   * "the recovery journal was kept" is said only about a file that is on disk;
///   * jobs created but missing from the journal — the one shape Resume cannot reach — are named;
///   * a cause a mutator already reported leads the sentence instead of being replaced by it.
///
/// ⚠️ **SCOPE — read before citing this file.**
///   * Sections 1–3 need nothing on disk. Section 4 drives the real exit against a real journal at the
///     shipped path, so it runs only under the `ARCHIVEPROC_TEST_STATE_ROOT` redirect (same gate as
///     sections 16–18) and removes what it wrote.
///   * `performBatchOCR`'s four-line catch is still not driven — reaching it needs a real paid submission.
///     What it now contains is one call to `reportInterruptedBatchSubmission()`, and section 4 drives that
///     whole method, so the undriven residue is the `catch` keyword and an NSLog.
///
/// Run from `BatchResumeTestDriver` (section 19) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchSubmissionMessageContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) {
        theCountSurvivesTheStopThatClosedTheJournal(check)
        theReporterKeepsItsCause(check)
        everyClauseIsAMeasurement(check)
        guard redirected else {
            // Skipped LOUDLY, in the idiom of section 18: one FAIL in their place, so a refused run reports
            // SOME FAILED rather than a shorter green one.
            check("submission message: the checks that drive the real exit against a real journal are "
                  + "SKIPPED (refused: the journal path did not resolve away from Application Support)",
                  false)
            return
        }
        theWholeExitAgainstARealJournal(check)
    }

    // MARK: - Fixtures

    private static func model() -> LLMModel {
        LLMModel(id: "submission-message-gemini", displayName: "Submission Message Gemini",
                 provider: .gemini, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// A journal in the state the submit loop is really in: chunks acknowledged, submission NOT finished.
    private static func journal(chunkIds: [String]) -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: chunkIds.first ?? "", provider: .gemini, model: model(), thinkingLevel: .low,
            fileURLs: [URL(fileURLWithPath: "/tmp/submission-message/scan-0.jpg")],
            outputDirectory: URL(fileURLWithPath: "/tmp/submission-message", isDirectory: true),
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: chunkIds, submissionComplete: false)
    }

    private static func state(onDisk: Bool, acknowledged: Int) -> OCRProcessor.PaidBatchJournalState {
        OCRProcessor.PaidBatchJournalState(onDisk: onDisk, acknowledgedChunkCount: acknowledged)
    }

    // MARK: - 1. The bug, at the seam that caused it

    /// The whole defect in two expressions read off the same processor: after Stop has closed the journal,
    /// the OLD source of the count answers 0 and the new one answers the truth.
    private static func theCountSurvivesTheStopThatClosedTheJournal(_ check: (String, Bool) -> Void) {
        let processor = OCRProcessor()
        // Exactly what `cancel()` leaves behind while a Gemini submit loop is still running.
        processor.activePendingBatch = nil
        processor.paidJobsCreatedThisSubmission = []

        let recorded = processor.recordSubmittedBatchChunk("batches/paid-chunk-1")
        let oldSource = processor.activePendingBatch?.submittedChunkIds.count ?? 0
        check("submission message: a chunk created after Stop closed the journal is COUNTED even though the "
              + "journal could not record it — the old expression reads 0 here, which is the bug",
              !recorded && oldSource == 0 && processor.paidJobsCreatedThisSubmission == ["batches/paid-chunk-1"])

        // An ID the validation guard rejects is still a job the provider created and billed.
        let blank = OCRProcessor()
        blank.activePendingBatch = journal(chunkIds: [])
        let acceptedBlank = blank.recordSubmittedBatchChunk("   ")
        check("submission message: a created job whose ID is unusable is counted too — the guard rejects the "
              + "name, not the charge",
              !acceptedBlank && blank.paidJobsCreatedThisSubmission.count == 1)

        // ...and the count is of JOBS, so the same ID arriving twice is not two of them.
        let repeated = OCRProcessor()
        repeated.activePendingBatch = nil
        _ = repeated.recordSubmittedBatchChunk("batches/paid-chunk-1")
        _ = repeated.recordSubmittedBatchChunk("batches/paid-chunk-1")
        check("submission message: the same chunk ID recorded twice counts once — the tally is jobs created, "
              + "not calls made",
              repeated.paidJobsCreatedThisSubmission.count == 1)
    }

    // MARK: - 2. The cause survives to be read

    private static func theReporterKeepsItsCause(_ check: (String, Bool) -> Void) {
        let processor = OCRProcessor()
        check("submission message: a processor that has not been interrupted has no cause to report",
              processor.lastPaidBatchInterruptionReport == nil)

        // The real post-Stop shape: `persistPendingBatchMutation`'s missing-journal guard reporting through
        // the one funnel, without cancelling a `processingTask` that is nil-or-a-newer-run's.
        processor.activePendingBatch = nil
        _ = processor.markBatchSubmissionComplete()
        check("submission message: the mutator's own explanation is retained, not just displayed — the "
              + "summary that follows can lead with the cause instead of erasing it",
              processor.lastPaidBatchInterruptionReport == OCRProcessor.pendingBatchJournalClosedMessage)
    }

    // MARK: - 3. Every clause is a measurement

    private static func everyClauseIsAMeasurement(_ check: (String, Bool) -> Void) {
        let uncertain = OCRProcessor.interruptedSubmissionMessage(
            createdJobCount: 0, journal: state(onDisk: true, acknowledged: 0), priorReport: nil)
        check("submission message: nothing created and the journal on disk — the outcome is still called "
              + "uncertain (a create whose reply was lost may have landed) and the journal is called kept",
              uncertain.contains("uncertain") && uncertain.contains("The recovery journal was kept")
              && !uncertain.contains("missing from it"))

        let stopped = OCRProcessor.interruptedSubmissionMessage(
            createdJobCount: 3, journal: state(onDisk: true, acknowledged: 3), priorReport: nil)
        check("submission message: three created and all three journaled — the count is the created one and "
              + "no shortfall is invented",
              stopped.contains("3 server jobs had been created")
              && stopped.contains("Resume can pick the batch up") && !stopped.contains("missing from it"))

        let shortfall = OCRProcessor.interruptedSubmissionMessage(
            createdJobCount: 3, journal: state(onDisk: true, acknowledged: 1), priorReport: nil)
        check("submission message: created-but-unrecorded jobs are NAMED — the one shape Resume cannot "
              + "reach, which \"the journal was kept\" alone would hide",
              shortfall.contains("3 server jobs had been created")
              && shortfall.contains("2 server jobs are missing from it")
              && shortfall.contains("Resume will not reach them"))

        let gone = OCRProcessor.interruptedSubmissionMessage(
            createdJobCount: 2, journal: state(onDisk: false, acknowledged: 0), priorReport: nil)
        check("submission message: with no journal on disk it does not claim one was kept, and says the app "
              + "has no local record of the jobs",
              !gone.contains("kept") && gone.contains("No recovery journal is on disk")
              && gone.contains("no local record of those jobs"))

        let singular = OCRProcessor.interruptedSubmissionMessage(
            createdJobCount: 1, journal: state(onDisk: true, acknowledged: 0), priorReport: nil)
        check("submission message: one job reads as one job in both clauses",
              singular.contains("1 server job had been created")
              && singular.contains("1 server job is missing from it")
              && singular.contains("Resume will not reach it"))

        let led = OCRProcessor.interruptedSubmissionMessage(
            createdJobCount: 1, journal: state(onDisk: true, acknowledged: 1),
            priorReport: OCRProcessor.pendingBatchJournalClosedMessage)
        check("submission message: a cause the mutator already reported LEADS the summary — this is the "
              + "sentence W16.bat3-fu wrote and this catch used to overwrite",
              led.hasPrefix(OCRProcessor.pendingBatchJournalClosedMessage)
              && led.contains("1 server job had been created"))

        // The two invariants, swept rather than sampled, so a future rewording cannot quietly break them.
        var keptOnlyWhenOnDisk = true
        var countNeverUnderstated = true
        for created in 0...4 {
            for acknowledged in 0...4 {
                for onDisk in [true, false] {
                    for prior in [nil, "cause."] as [String?] {
                        let message = OCRProcessor.interruptedSubmissionMessage(
                            createdJobCount: created,
                            journal: state(onDisk: onDisk, acknowledged: acknowledged),
                            priorReport: prior)
                        if message.contains("recovery journal was kept") && !onDisk {
                            keptOnlyWhenOnDisk = false
                        }
                        if created > 0 && !message.contains("\(created) server job") {
                            countNeverUnderstated = false
                        }
                    }
                }
            }
        }
        check("submission message: across every created × acknowledged × on-disk × cause combination, "
              + "\"the recovery journal was kept\" is said only when the file is on disk",
              keptOnlyWhenOnDisk)
        check("submission message: and the number the operator reads is always the number of jobs CREATED — "
              + "never the journal's, which a Stop can leave at zero",
              countNeverUnderstated)
    }

    // MARK: - 4. The whole exit, against a real journal

    /// Sections 1–3 test the parts. This drives `reportInterruptedBatchSubmission()` — everything
    /// `performBatchOCR`'s catch now does — against a real file at the shipped (redirected) path, so
    /// "the journal was kept" is checked against a journal that is really there, and then against one
    /// that really is not.
    private static func theWholeExitAgainstARealJournal(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let url = OCRProcessor.pendingBatchURL
        let written = OCRProcessor._testWritePendingBatch(journal(chunkIds: ["batches/paid-chunk-1"]), to: url)
        let bytesBefore = try? Data(contentsOf: url)
        guard written != nil, bytesBefore != nil else {
            check("submission message: a real journal fixture is written at the shipped path", false)
            return
        }

        let processor = OCRProcessor()
        // Two jobs created, only the first journaled — a Stop that landed between the second create and its
        // record. `activePendingBatch` is nil because that is what `cancel()` left.
        processor.activePendingBatch = nil
        processor.paidJobsCreatedThisSubmission = ["batches/paid-chunk-1", "batches/paid-chunk-2"]
        processor.lastPaidBatchInterruptionReport = OCRProcessor.pendingBatchJournalClosedMessage
        processor.batchPollInterrupted = false
        processor.isProcessing = true
        let banner = "submission-message-banner-\(UUID().uuidString)"
        processor.pendingBatchInfo = banner
        // A real run task: this exit runs ON that task, so it must not cancel it.
        let run = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        processor.processingTask = run

        processor.reportInterruptedBatchSubmission()
        let cancelled = run.isCancelled
        run.cancel()
        let kept = processor.statusMessage
        let bytesAfter = try? Data(contentsOf: url)

        check("submission message: driven end to end, the exit reads the journal that is really on disk — "
              + "two jobs created, one of them recorded, and it says exactly that",
              kept.hasPrefix(OCRProcessor.pendingBatchJournalClosedMessage)
              && kept.contains("2 server jobs had been created")
              && kept.contains("The recovery journal was kept")
              && kept.contains("1 server job is missing from it"))
        check("submission message: and it flags the interruption, ends the run, refreshes the Resume banner, "
              + "and does not cancel the task it is running on",
              processor.batchPollInterrupted && !processor.isProcessing
              && processor.pendingBatchInfo != nil && processor.pendingBatchInfo != banner && !cancelled)
        check("submission message: reporting the interruption leaves the paid-batch journal byte-identical — "
              + "the server-side job keeps its only local record",
              bytesAfter == bytesBefore)

        // Now the other direction, with the file really gone. Nothing here may say it was kept.
        OCRProcessor.deletePendingBatch()
        let orphaned = OCRProcessor()
        orphaned.activePendingBatch = nil
        orphaned.paidJobsCreatedThisSubmission = ["batches/paid-chunk-1"]
        orphaned.isProcessing = true
        orphaned.reportInterruptedBatchSubmission()
        check("submission message: with the journal genuinely gone the exit says so — no \"kept\", and the "
              + "operator is told the app has no local record of the job it created",
              !fm.fileExists(atPath: url.path)
              && !orphaned.statusMessage.contains("kept")
              && orphaned.statusMessage.contains("No recovery journal is on disk")
              && orphaned.statusMessage.contains("no local record of that job"))

        try? fm.removeItem(at: url)
    }
}
