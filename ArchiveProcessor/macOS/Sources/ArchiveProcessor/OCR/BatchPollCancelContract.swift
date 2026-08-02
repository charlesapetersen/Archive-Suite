import Foundation

/// **What pressing Stop during a paid batch POLL does to the recovery journal** (W16.bat3) — headless, $0,
/// no network, no keys.
///
/// The bug this pins: `pollBatchUntilComplete`'s two `guard !Task.isCancelled else { return }` exits used to
/// return *silently*. Every other interrupted exit sets `batchPollInterrupted`, and both callers read that
/// flag to decide whether the paid batch's recovery journal — the only local record of a server-side job the
/// operator has already paid for — is deleted. So a Stop mid-poll deleted it: on the first run through
/// `performBatchOCR`'s tail, and on a resume through `resumeBatch`'s. Meanwhile `cancel()` had just told the
/// operator *"the paid-batch journal was kept for recovery"* whenever the server-side cancellation was not
/// confirmed. The message and the disk disagreed, on the one path in the app that spends real money.
///
/// Why it needs its own section rather than an assertion in 13/14: `BatchCancelContract` proves the *rule*
/// `cancel()` applies and `BatchCancelWiringContract` proves the arguments it feeds that rule — both were
/// green while this bug shipped, because the deletion happens **downstream** of the seam either of them can
/// see, in the poll's own unwinding. The only way to catch it is to run the poll.
///
/// **How that is possible without a cent.** A cancelled poll never reaches a provider call: both guards sit
/// before the `switch provider`, and the wait between status checks is a `Task.sleep` that returns early on
/// cancellation. So every check here drives the REAL `pollBatchUntilComplete` (and, in section 4, the real
/// `resumeBatch`) with a task that is cancelled, and no request is ever made — the API keys below are
/// deliberate nonsense.
///
/// ⚠️ **SCOPE — read before citing this file.**
///   * Sections 1–2 pin the poll's two cancellation exits. Section 3 pins what the FIRST RUN's tail does with
///     the flag, driven through `retirePaidBatchJournalIfPollCompleted()` — the surrounding
///     `performBatchOCR` needs a real paid submission, so its tail was extracted to make this drivable.
///     Section 4 drives the RESUME path whole (`resumeBatch` → poll → tail) against a real journal file.
///   * What is still not driven end to end is the first run's *own* call into the poll, for the same reason
///     `BatchInterruptTailContract` cannot drive its two call sites: reaching it costs a paid submission.
///     Both halves of that path are pinned here separately, and the seam between them is one statement.
///   * Sections 1–4 say nothing about whether the operator SEES the kept-journal warning. **Section 5 is
///     where that lives** (W16.bat6): it is the only place in the suite that presses Stop with a LIVE
///     `processingTask`, and it asserts the warning is the message still on screen once the cancelled run
///     has finished unwinding — not merely that `cancel()` assigned it at some point.
///   * **Which checks are the regression, measured.** Revert the two `batchPollInterrupted = true`
///     assignments and 4 checks redden: both of section 1–2's, and both of section 4's — including the
///     journal file itself disappearing from disk. Section 3 stays green either way *by design*: it sets the
///     flag by hand to pin what the tail does with it, and the tail's rule did not change. Cite sections 1,
///     2 and 4 for "a Stop mid-poll keeps the journal", and section 3 only for "the tail obeys the flag,
///     both ways". Section 5 has its own measured regression, against a different change: remove
///     `cancel()`'s `await interruptedRun?.value` and 2 of its 3 checks redden (the second and third — the
///     first describes the setup, and holds either way by design).
///
/// Sections 3–4 write to, and delete from, whatever `OCRProcessor.pendingBatchURL` resolves to, so they run
/// only when the harness's redirect is in force (`BatchJournalPathContract.redirectIsInForce`, taken by the
/// driver before any section) — otherwise the subject would be the operator's own live journal. Sections 1–2
/// touch no file at all.
///
/// Run from `BatchResumeTestDriver` (section 17) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchPollCancelContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) async {
        await aStopBeforeTheFirstStatusCheck(check)
        await aStopDuringTheWaitBetweenChecks(check)
        // Stubs both cancel-path seams and writes no journal, so it needs no redirect (see its header).
        await theKeptJournalWarningOutlivesTheUnwindingRun(check)
        // Everything past here writes a real journal at the shipped path and deletes it again.
        guard redirected else {
            // Two checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("poll cancel: the two checks that write a real journal — the first run's tail and a whole "
                  + "resumed Stop — are SKIPPED (refused: the journal path did not resolve away from "
                  + "Application Support)", false)
            return
        }
        theFirstRunsTailKeepsAnInterruptedJournal(check)
        await aStopDuringAResumedPollKeepsTheJournal(check)
    }

    // MARK: - 1. Stop before the first status check

    /// The top-of-loop guard. A task cancelled before it ever runs takes this exit on its first iteration,
    /// which makes it the one cancellation exit that is reachable with no timing at all.
    ///
    /// Non-vacuous by construction: `pollBatchUntilComplete` *assigns* `batchPollInterrupted = false` on
    /// entry, so starting from `false` and ending at `true` cannot be satisfied by a poll that never ran.
    private static func aStopBeforeTheFirstStatusCheck(_ check: (String, Bool) -> Void) async {
        var interruptedEverywhere = true
        var firstBad: String?
        var trials = 0
        // Both guards sit above the `switch provider`, so the answer must not depend on the provider — and
        // sweeping them proves no future per-provider early return re-opens the hole for one of them.
        // `allCases` rather than a written-out list: a provider added later is swept automatically instead
        // of quietly sitting outside a check that still says it covered them all.
        for provider in LLMProvider.allCases {
            let processor = OCRProcessor()
            processor.batchPollInterrupted = false
            let journalState = journal(chunkIds: ["batches/never-checked"], files: [])
            processor.activePendingBatch = journalState
            let task = Task { @MainActor in
                await processor.pollBatchUntilComplete(
                    batchId: "batches/never-checked", provider: provider, model: model(provider),
                    thinkingLevel: nil, apiKey: "poll-cancel-not-a-key",
                    fileURLs: [], outputDirectory: FileManager.default.temporaryDirectory)
            }
            // Cancelled before the first suspension point, so it starts cancelled: no sleep, no request.
            task.cancel()
            await task.value
            trials += 1
            if !processor.batchPollInterrupted {
                interruptedEverywhere = false
                if firstBad == nil { firstBad = provider.rawValue }
            }
            // The poll decides nothing about the journal itself — that is its callers' job, and one of them
            // must still be able to see which batch was live. A poll that cleared this would blank the
            // resume state before the tail that keeps it ever ran.
            if processor.activePendingBatch == nil {
                interruptedEverywhere = false
                if firstBad == nil { firstBad = "\(provider.rawValue) (cleared the journal state)" }
            }
        }
        check("poll cancel: a poll cancelled before its first status check reports itself interrupted, for "
              + "all \(trials) providers"
              + (firstBad.map { " [first bad: \($0)]" } ?? ""),
              interruptedEverywhere && trials == LLMProvider.allCases.count && trials > 0)
    }

    // MARK: - 2. Stop during the wait between status checks

    /// The guard nearly every real Stop leaves through: the operator presses it while the poll is asleep
    /// between status checks, `Task.sleep` throws `CancellationError` immediately, `try?` swallows it, and
    /// the poll falls into the second cancellation guard.
    ///
    /// The poll is started UNCANCELLED and handed the MainActor (8 yields, then a real 50 ms sleep) before
    /// Stop arrives: it cannot have left through the top-of-loop guard, because nothing has cancelled it
    /// yet, and it cannot have reached a provider call, because that is on the far side of a 30-second
    /// sleep. The elapsed time then shows the cancellation aborted that sleep rather than waiting it out.
    ///
    /// ⚠️ **Honest limit.** "It has not returned" cannot distinguish *asleep in the wait* from *never
    /// scheduled at all*. If the child task had somehow not started, the Stop would land on the top-of-loop
    /// guard instead and both checks below would still pass — this section would silently become a second
    /// copy of section 1. Yielding the MainActor and then sleeping on it makes that vanishingly unlikely,
    /// but nothing before the sleep is observable from outside the poll, so it is a strong likelihood
    /// rather than a proof. It fails in the harmless direction: never a false red, only a weaker green.
    private static func aStopDuringTheWaitBetweenChecks(_ check: (String, Bool) -> Void) async {
        let processor = OCRProcessor()
        processor.batchPollInterrupted = false
        let completion = PollCompletion()
        let task = Task { @MainActor in
            await processor.pollBatchUntilComplete(
                batchId: "batches/sleeping", provider: .gemini, model: model(.gemini),
                thinkingLevel: nil, apiKey: "poll-cancel-not-a-key",
                fileURLs: [], outputDirectory: FileManager.default.temporaryDirectory)
            completion.finished = true
        }
        // Hand the MainActor over until the poll has run as far as it can get on its own.
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        let reachedTheWait = !completion.finished

        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await task.value
        let elapsed = clock.now - start

        check("poll cancel: the poll has not returned when Stop arrives, and nothing had cancelled it — so "
              + "it is in the wait between status checks", reachedTheWait)
        check("poll cancel: a Stop during that wait aborts it at once and reports the poll interrupted",
              processor.batchPollInterrupted && elapsed < .seconds(5))
    }

    // MARK: - 3. What the first run's tail does with the flag

    /// `performBatchOCR` ends in `retirePaidBatchJournalIfPollCompleted()`, against a REAL journal file at the
    /// shipped path. Both directions are checked: an interrupted poll's journal survives (the money-critical
    /// one — a live server-side job's only local record), and a completed poll's is still retired, so the fix
    /// cannot be satisfied by never deleting anything and leaving a stale resume banner up forever.
    private static func theFirstRunsTailKeepsAnInterruptedJournal(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let source = fm.temporaryDirectory
            .appendingPathComponent("APPollCancel-first-run-\(UUID().uuidString).jpg")
        try? Data("source".utf8).write(to: source)
        defer { try? fm.removeItem(at: source) }

        /// One run of the tail, from a real journal on disk.
        func tail(interrupted: Bool) -> (existedBefore: Bool, survived: Bool, keptInMemory: Bool) {
            let saved = OCRProcessor.savePendingBatch(
                journal(chunkIds: ["batches/first-run"], files: [source]))
            let existed = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
            let processor = OCRProcessor()
            processor.activePendingBatch = saved
            processor.batchPollInterrupted = interrupted
            processor.retirePaidBatchJournalIfPollCompleted()
            let survived = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
            let kept = processor.activePendingBatch != nil
            OCRProcessor.deletePendingBatch()
            return (existed && saved != nil, survived, kept)
        }

        let stopped = tail(interrupted: true)
        check("first run: an interrupted poll's paid-batch journal is still on disk after the run's tail, "
              + "and the batch is still the live one",
              stopped.existedBefore && stopped.survived && stopped.keptInMemory)
        let completed = tail(interrupted: false)
        check("first run: a poll that ran to completion still retires its journal (the fix keeps the "
              + "journal, it does not stop deleting)",
              completed.existedBefore && !completed.survived && !completed.keptInMemory)
    }

    // MARK: - 4. A whole resumed Stop, end to end

    /// The resume path driven whole: a real journal on disk, the real `resumeBatch`, a cancelled task, and
    /// the file afterwards. This is the check that fails on the pre-W16.bat3 code — `resumeBatch`'s
    /// `Self.deletePendingBatch()` sits *above* its own `guard !Task.isCancelled`, so the silent poll exit
    /// walked straight into it and removed the journal of a batch that may still be running server-side.
    ///
    /// No request is made: the poll is cancelled before its first status check, exactly as in section 1.
    private static func aStopDuringAResumedPollKeepsTheJournal(_ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("APPollCancel-resume-\(UUID().uuidString)", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // A .jpg, so `convertPDFInputs` has nothing to convert and the resume touches no other file.
        let source = dir.appendingPathComponent("resume-source.jpg")
        try? Data("source".utf8).write(to: source)

        // A v2 identity, so the journal passes the self-consistency guard `resumeBatch` opens with — a
        // fingerprint-less fixture is silently ignored there, and every assertion below would be vacuous.
        // (The `resumable` flag is what caught exactly that while this check was being written.)
        let saved = OCRProcessor.savePendingBatch(
            OCRProcessor.PendingBatch(
                batchId: "batches/resume-0", provider: .gemini, model: model(.gemini),
                thinkingLevel: .low, fileURLs: [source], outputDirectory: outDir,
                enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
                taggingMode: .automatic,
                runFingerprint: OCRProcessor.runFingerprint(
                    files: [source], outputDirectory: outDir, taggingMode: .automatic,
                    enableTagging: false, batchMode: true, preserveInputOrder: true),
                lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
                submittedChunkIds: ["batches/resume-0"]))
        let existedBefore = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        // `resumeBatch` ignores a journal that fails this guard, which would make everything below vacuous.
        let resumable = saved.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false

        let processor = OCRProcessor()
        let task = Task { @MainActor in await processor.resumeBatch(apiKey: "poll-cancel-not-a-key") }
        task.cancel()
        await task.value

        let survived = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        let offersResume = processor.pendingBatchInfo != nil
        let stoppedProcessing = !processor.isProcessing
        OCRProcessor.deletePendingBatch()

        check("resumed poll: Stop during a RESUMED paid batch leaves its journal on disk",
              existedBefore && resumable && survived)
        // The other half of the promise: a kept journal is only useful if the operator is offered the way
        // back to it. `finishInterruptedBatchPoll()` is what recomputes that banner.
        check("resumed poll: the run stops and the Resume control is re-rendered from the kept journal",
              stoppedProcessing && offersResume)
    }

    // MARK: - 5. The kept-journal warning outlives the run that Stop cancelled

    /// **W16.bat6.** Sections 1–4 are about the journal on disk; this one is about the sentence that tells
    /// the operator it is there. When a server-side cancellation is not confirmed, `cancel()` says *"the
    /// paid-batch journal was kept for recovery"* — the only signal that a job they have already paid for
    /// may still be running. It used to be assigned from a task that raced the cancelled run's own unwinding,
    /// and the run writes `statusMessage` too (a status check still in flight when Stop landed resolves into
    /// `"Batch processing… n/m complete"` or `"Error checking batch… Retrying…"`). Whichever wrote last won.
    ///
    /// **Why it has to be here and not in `BatchCancelWiringContract`.** Every scenario there presses Stop
    /// with no `processingTask` at all, so there is nothing to race and the warning trivially survives; that
    /// file's header says so. This is the one check in the suite that presses Stop with a LIVE one.
    ///
    /// **The stand-in, and what it costs in honesty.** `processingTask` here is not a real poll — reaching
    /// the window where a poll writes after a Stop means being *inside* a provider call when it arrives
    /// (both cancellation guards sit above the `switch provider`, which is what keeps sections 1–2 free), and
    /// that is a paid request. So the task installed below is a faithful model of the unwinding rather than
    /// the unwinding itself: live and suspended when Stop lands, cancelled by the real `cancel()`, and then
    /// writing one of the poll's own status lines verbatim on its way out. What is real is everything the
    /// fix touches — the real `cancel()`, the real cancellation task, the real ordering between them.
    ///
    /// It writes late on purpose. The stubbed canceller returns instantly, so without the ordering fix the
    /// warning is up long before the run's write lands on top of it; the delay is a non-cancellable timer
    /// (`Task.sleep` would abort on the very cancellation being tested) and makes the losing order the
    /// certain one rather than the likely one. $0: both cancel-path seams are stubbed, so no client is built
    /// and no journal is touched.
    private static func theKeptJournalWarningOutlivesTheUnwindingRun(_ check: (String, Bool) -> Void) async {
        // One of the poll's real status lines, from the arm that resolves *after* a Stop: `checkStatus`
        // throws the cancellation, the catch reports a retry the poll will never make, and the loop's next
        // top-of-loop guard returns. Copied as text rather than called, so this section needs no provider.
        let runsOwnStatusLine = "Error checking batch: cancelled. Retrying… (attempt 1)"

        let tail = RunTail()
        let processor = OCRProcessor()
        // Both seams replaced before the batch is installed, exactly as `BatchCancelWiringContract.stop`
        // does: no live client is ever constructed and the shipped journal deleter is never reached.
        // `refused` is what makes the outcome UNCONFIRMED, which is the only outcome that warns at all.
        processor.makeBatchChunkCanceller = { context in
            OCRProcessor.BatchChunkCanceller(provider: context.provider,
                                             cancelChunk: { _ in false }, clientTypeName: "stub")
        }
        processor.makeBatchJournalDeleter = { _ in { tail.journalDeleterRan = true } }
        processor.activeBatch = OCRProcessor.BatchContext(
            batchId: "batches/warning-race", apiKey: "poll-cancel-not-a-key", model: model(.gemini),
            thinkingLevel: .low, provider: .gemini)
        processor.activePendingBatch = journal(chunkIds: ["batches/warning-race"], files: [])

        let run = Task { @MainActor in
            // Suspended, and not yet cancelled, when Stop arrives — the state a real poll is in.
            while !Task.isCancelled { await Task.yield() }
            // Deliberately NOT `Task.sleep`: this task is cancelled by now, so `Task.sleep` would return
            // instantly and the write would land before the cancellation task ever got going.
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { resume.resume() }
            }
            processor.statusMessage = runsOwnStatusLine
            tail.wroteItsOwnStatus = true
        }
        processor.processingTask = run
        // Hand the MainActor over so the run is genuinely parked before Stop, not merely created.
        for _ in 0..<8 { await Task.yield() }
        let runWasLive = !tail.wroteItsOwnStatus

        processor.cancel()
        await processor.batchCancellationTask?.value
        // `cancel()` drops the handle, so keep our own: the run must be given every chance to write after
        // the cancellation task finished. If the ordering fix is in place it has already finished, and this
        // returns at once; if it is not, this is where the clobber lands.
        await run.value
        let finalMessage = processor.statusMessage

        check("kept-journal warning: the run cancelled by Stop was still live and unwinding when the "
              + "warning was raised, and it did write its own status line",
              runWasLive && tail.wroteItsOwnStatus)
        // THE regression. Delete `cancel()`'s `await interruptedRun?.value` and this reddens: the warning
        // goes up first and the unwinding run overwrites it 80 ms later.
        check("kept-journal warning: it is still the message on screen after the cancelled run has finished "
              + "unwinding — the run's own status line cannot overwrite it",
              finalMessage == OCRProcessor.batchCancellationNotConfirmedMessage)
        // Guards the check above against passing for the wrong reason. If the unconfirmed cancellation ever
        // stopped warning at all, or started deleting the journal it just said it kept, `finalMessage` could
        // still be "not the run's line" while the operator is left with nothing.
        check("kept-journal warning: the warning was raised because the cancellation was NOT confirmed, and "
              + "no journal deletion was asked for",
              finalMessage != runsOwnStatusLine && !tail.journalDeleterRan)
    }

    // MARK: - Fixtures

    /// Whether the poll task has returned yet. A MainActor box rather than a captured `var`: the poll runs in
    /// its own task, and section 2's whole discrimination is "has it finished, right now?".
    @MainActor private final class PollCompletion {
        var finished = false
    }

    /// What section 5's stand-in run, and the journal seam it must not reach, actually did. A MainActor box
    /// for the same reason as `PollCompletion`: it is written from another task and read after it.
    @MainActor private final class RunTail {
        var wroteItsOwnStatus = false
        var journalDeleterRan = false
    }

    /// A synthetic model — never sent anywhere, and built by hand so no check depends on `CustomModelStore`.
    private static func model(_ provider: LLMProvider) -> LLMModel {
        LLMModel(id: "poll-cancel-\(provider.rawValue.lowercased())",
                 displayName: "Poll Cancel \(provider.rawValue)",
                 provider: provider, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// A v1 paid-batch journal. `savePendingBatch` derives its `batchId` from `submittedChunkIds`, so the
    /// value passed here is the one the persistence path is allowed to overwrite.
    private static func journal(chunkIds: [String], files: [URL]) -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: chunkIds.joined(separator: ","), provider: .gemini, model: model(.gemini),
            thinkingLevel: .low, fileURLs: files,
            outputDirectory: FileManager.default.temporaryDirectory,
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: chunkIds)
    }
}
