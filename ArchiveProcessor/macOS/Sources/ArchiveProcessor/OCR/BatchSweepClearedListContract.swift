import AppKit
import Foundation

/// **Clearing the file list while the paid batch's completion sweep is mid-write must not kill the app —
/// and must not cost a second paid call** (W16.bat9) — headless, $0, no network, no keys.
///
/// The bug this pins: `sweepJobsWithNoBatchResult` iterated `jobs.indices`, snapshotted ONCE, and
/// re-subscripted `jobs[i]` in its `where` clause on every iteration — across the `await` in
/// `handleOCRResult`, which awaits a **detached** task and so goes on running after the run is cancelled.
/// `cancel()` sets `isProcessing = false` synchronously (its own comment: the run "goes on unwinding
/// afterwards"), which un-disables the **Clear** button, whose action is `processor.jobs = []`. One click
/// during that suspension and the next subscript was out of range: SIGTRAP, on the money path. The identical
/// window exists one frame down, at the `jobs[index]` writes `handleOCRResult` performs *after* its detached
/// PDF write — its entry bounds guard was passed seconds earlier and cannot speak for the array now.
///
/// **Three things are being pinned, not one.**
///   * The app SURVIVES (§1, §3) — the loop re-validates each slot against the list the sweep started for.
///   * The durable record survives WITH it (§2, §6). The row on screen is not the money; the journal is.
///     The first shape of this fix bailed out with `false` before `saveResultToPendingRun`, which on the
///     non-batch path is the only thing stopping a resume from OCRing that file a SECOND time, at cost — so
///     §2 drives the real pending-RUN branch and asserts the completed result is in the resume snapshot even
///     though the row it belonged to is gone. A vanished row must not buy a second paid call.
///   * Nothing is written to a row that is no longer this file's (§4, §5). Bounds alone cannot tell a
///     re-dropped list from the honest one, and Stop → Clear → re-drop → Start hands a *live new run* the
///     same indices and the same `.processing` status. §5 is that case: the stale sweep must not mark a
///     running job failed and write failure outputs over it.
///
/// **How the race is reproduced without a GUI.** No seam and no stub: a `Task { @MainActor in … }` is
/// enqueued before the sweep starts, so the main actor can only reach it at the sweep's first real
/// suspension — the detached PDF write inside `handleOCRResult` — which is exactly when a click on Clear
/// lands. Each fixture records whether its mutation really landed *while the sweep was in flight*
/// (`mutationLandedDuringSweep`), and every check ANDs that in; a fixture that failed to reproduce the race
/// fails rather than passing the rest for the wrong reason.
///
/// **What a mutant looks like here.** Two of the four do not print `FAIL` — the driver process TRAPS and
/// writes no report at all, so `test-batch-resume.sh` reports a missing report and exits 1. Measured:
///   * the loop's slot re-validation reduced to the old `where jobs[i].status == .processing` → §3 traps
///     (`Fatal error: Index out of range`, rc=133).
///   * `slotIsStillOurs` removed from `handleOCRResult`'s post-await writes → §1 traps (rc=133).
///   * that guard replaced by an early `return false` (the fix's first shape) → §2 goes RED: the resume
///     snapshot has no record of a file that was fully OCRed and written.
///   * both slot checks reduced to bounds only → §4 and §5 go RED: a stale sweep writes over the file that
///     replaced the one it was sweeping, and over a whole new run's jobs.
///
/// Scope: the crash, the record, and the wrong-row writes. NOT Stop's own semantics — the sweep still has no
/// `Task.isCancelled` check of its own (the poll's two are at `:737`/`:752`), which is deliberate and weighed
/// in the item: aborting the sweep would change what a cancelled paid batch records, leaving jobs
/// `.processing` for good with no failure output. Also NOT the pre-await writes `handleOCRResult` makes on
/// behalf of its OTHER callers, which a stale run can still land on a new one's jobs (filed as `W16.bat10`).
///
/// Every fixture writes and then removes a real journal/manifest at the shipped paths, so the whole section
/// is refused unless the harness's redirect is in force (`BatchJournalPathContract.redirectIsInForce`).
///
/// Run from `BatchResumeTestDriver` (section 21) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchSweepClearedListContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) async {
        guard redirected else {
            // SEVEN checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("sweep cleared: the whole section is SKIPPED (refused: the journal path did not resolve "
                  + "away from Application Support, and every fixture writes a real journal there)",
                  false)
            return
        }
        let cleared = await sweep(.clearTheList)
        let clearedAfterWrite = await sweep(.clearTheListAfterASuccessfulWrite)
        let shrunk = await sweep(.shrinkTheList)
        let replaced = await sweep(.replaceTheListWithAnotherFile)
        let newRun = await sweep(.replaceTheListWithANewRun)

        // MARK: 1. THE regression — the list is emptied while a failure output is being written
        //
        // Reaching this check at all is most of it: with the post-await guard removed the process is gone
        // before any report is written.
        check("sweep cleared: the app survives Clear pressed while the completion sweep is writing a "
              + "failure output — the row it was writing is simply no longer written to",
              cleared.mutationLandedDuringSweep && cleared.emptyAfter)
        // Non-vacuity: proves the sweep really reached the job and did its work, so check 1 is not green
        // because the loop never ran. `failedFiles` is keyed on the file, not the row, so it survives.
        check("sweep cleared: and what it had already recorded before the list went away is still recorded "
              + "— the swept file is in the failed list under its own name",
              cleared.mutationLandedDuringSweep && cleared.recordedTheSweptFile)

        // MARK: 2. The money statement — a vanished row must not buy a second paid call
        //
        // The real pending-RUN branch of `saveResultToPendingRun`, which is what a resume reads to skip
        // files it has already paid for (Tier-2 rule a). The fix's first shape returned `false` before this
        // ran, so the file was fully OCRed, its PDF written to disk, and nothing recorded it: a resume would
        // have sent it again. Reverting to that shape reddens this and nothing else.
        check("sweep cleared: a file whose row is cleared mid-write is still recorded in the resume "
              + "snapshot, with its output path — a vanished row does not buy a second paid OCR call",
              clearedAfterWrite.mutationLandedDuringSweep && clearedAfterWrite.journaledTheResult
                  && clearedAfterWrite.journaledTheOutputPath && clearedAfterWrite.outputRecorded)

        // MARK: 3. The loop's own half — a list that SHRANK under the snapshotted index range
        //
        // The one direction the post-await guard cannot cover: the row being written is still this file's,
        // so `handleOCRResult` returns true and the loop goes on to an index that no longer exists.
        check("sweep cleared: a list that shrinks mid-sweep does not trap the loop that snapshotted its "
              + "slots — the vanished ones are skipped, not subscripted",
              shrunk.mutationLandedDuringSweep && shrunk.returnedTrue && shrunk.oneJobLeft)
        // The other direction, so a fix that reported every sweep as interrupted — wedging every completed
        // paid batch into a permanent Resume banner — cannot satisfy section 3.
        check("sweep cleared: and surviving that is not an interruption — the file that was still there was "
              + "swept to its \"no result\" failure, the flag stays clear, and the tail still retires the "
              + "journal of a batch that finished",
              shrunk.mutationLandedDuringSweep && shrunk.sweptSlotFailedWithNoResult
                  && !shrunk.flaggedInterrupted
                  && shrunk.journalExistedBefore && !shrunk.journalSurvived)

        // MARK: 4. Identity, not just bounds — the quiet version of the same bug
        //
        // Clear, then re-drop a different file: the index is in range again, and a bounds-only guard would
        // write this file's failure onto that one. No trap, no message — just the wrong file marked failed.
        check("sweep cleared: a row refilled with a DIFFERENT file is not written to — the swept file's "
              + "result does not land on the file that replaced it",
              replaced.mutationLandedDuringSweep && replaced.intruderUntouched)

        // MARK: 5. The same thing at run scale — a stale sweep must not sweep a LIVE run
        //
        // Stop, Clear, re-drop, Start. The new run's jobs take the same indices and are set `.processing`,
        // which is exactly what the sweep looks for, and the old sweep is still suspended in a PDF write.
        // Bounds-only, it marks a running job failed and writes a "no result" output over a live run.
        check("sweep cleared: a sweep left over from a stopped run does not sweep the jobs of the run "
              + "started after it — they keep their status, their results and their files",
              newRun.mutationLandedDuringSweep && newRun.newRunUntouched && newRun.returnedTrue)

        // MARK: 6. What it costs, in the only unit that matters
        //
        // The crash was never data loss — the process died before `retirePaidBatchJournalIfPollCompleted()`
        // could run, so the journal survived a SIGTRAP too. This pins that surviving it did not buy that
        // back: the paid batch's own journal recorded the swept file before the tail retired it.
        check("sweep cleared: the paid batch's journal recorded the swept file even though its row was "
              + "gone, and the tail then retired it because the batch really had finished",
              cleared.journalExistedBefore && cleared.journaledTheResult && !cleared.journalSurvived)
    }

    // MARK: - Fixtures

    /// What the file list does while the sweep is suspended on its detached PDF write.
    private enum Mutation {
        /// The **Clear** button, verbatim: `processor.jobs = []`, with the output write failing (which is
        /// the branch that used to trap).
        case clearTheList
        /// The same click, with the output write SUCCEEDING — the shape whose durable record must survive.
        case clearTheListAfterASuccessfulWrite
        /// Cleared and re-dropped short of the original set: the row under the sweep survives, the ones
        /// after it do not. Only the loop's own re-validation stands between this and a trap.
        case shrinkTheList
        /// Cleared and re-dropped with a different file, so the index is valid again but means something
        /// else.
        case replaceTheListWithAnotherFile
        /// Cleared, re-dropped and STARTED: a live run's jobs, at the same indices, all `.processing`.
        case replaceTheListWithANewRun
    }

    /// Everything observable about one run of the real sweep with the list mutated underneath it.
    private struct Swept {
        let returnedTrue: Bool
        let flaggedInterrupted: Bool
        /// The mutation ran while the sweep was in flight — i.e. the race was really reproduced. False here
        /// means the fixture, not the code, is what needs looking at.
        let mutationLandedDuringSweep: Bool
        /// The sweep reached the job and recorded its synthetic failure under the file's own name.
        let recordedTheSweptFile: Bool
        /// The durable record of the swept file, read BEFORE the tail can retire the journal.
        let journaledTheResult: Bool
        let journaledTheOutputPath: Bool
        /// The written PDF is still associated with its source for the tagging/merge phases.
        let outputRecorded: Bool
        let emptyAfter: Bool
        let oneJobLeft: Bool
        let sweptSlotFailedWithNoResult: Bool
        /// The file that replaced the swept one is exactly as it was dropped.
        let intruderUntouched: Bool
        /// Every job of the run started underneath the sweep is untouched by it.
        let newRunUntouched: Bool
        let journalExistedBefore: Bool
        let journalSurvived: Bool
    }

    /// Mutable state shared with the mutation task. A global-actor-isolated class, so it is `Sendable`
    /// without a lock and the ordering it records is the main actor's own.
    @MainActor private final class Signal {
        var sweepInFlight = false
        var landedDuringSweep = false
    }

    /// A synthetic model — never sent anywhere; built by hand so no check depends on `CustomModelStore`.
    private static func model() -> LLMModel {
        LLMModel(id: "sweep-cleared-gemini", displayName: "Sweep Cleared Gemini",
                 provider: .gemini, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// A REAL 64×64 JPEG, so the sweep's readability probe and `PDFGenerator` both behave as in production.
    private static func makeJPEG(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let jpeg = bitmap?.representation(using: .jpeg, properties: [:]) { try? jpeg.write(to: url) }
        return url
    }

    /// One run of the real `sweepJobsWithNoBatchResult` over jobs that got no result, with `jobs` mutated
    /// from another main-actor task while it is suspended, followed by the real first-run tail.
    private static func sweep(_ mutation: Mutation) async -> Swept {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("APSweepCleared-\(UUID().uuidString)", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outDir.path)
            try? fm.removeItem(at: dir)
        }

        // The two fixtures whose subject is the post-await write need that write to FAIL, because the crash
        // is in the branch it takes: a read-only output directory makes `PDFDocument.write(to:)` return
        // false for real, which is the only thing `PDFGenerator.generate` throws on. The others need the
        // opposite — a write that succeeds, so `handleOCRResult` returns true and the LOOP runs on to the
        // slots that changed underneath it.
        let blockTheWrite = mutation == .clearTheList || mutation == .replaceTheListWithAnotherFile
        let sourceCount: Int
        switch mutation {
        case .shrinkTheList: sourceCount = 3
        case .clearTheList, .replaceTheListWithANewRun: sourceCount = 2
        case .clearTheListAfterASuccessfulWrite, .replaceTheListWithAnotherFile: sourceCount = 1
        }
        let sources = (0..<sourceCount).map { makeJPEG("sweep-source-\($0).jpg", in: dir) }
        let intruder = makeJPEG("re-dropped-other.jpg", in: dir)
        let newRunSources = (0..<sourceCount).map { makeJPEG("new-run-\($0).jpg", in: dir) }

        // A real journal on disk AND in memory: a paid batch that reached a terminal state, which is the
        // only state the sweep ever runs in.
        let saved = OCRProcessor.savePendingBatch(
            OCRProcessor.PendingBatch(
                batchId: "batches/sweep-cleared", provider: .gemini, model: model(), thinkingLevel: .low,
                fileURLs: sources, outputDirectory: outDir, enableTagging: false, sendPreviousImage: false,
                submittedAt: Date(),
                lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
                submittedChunkIds: ["batches/sweep-cleared"]))
        let journalExisted = saved != nil && fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        // Deferred, not called at the end: a fixture may legitimately leave this file on disk, so the
        // removal has to be the one thing that cannot be skipped.
        defer { OCRProcessor.deletePendingBatch() }
        let runManifest = OCRProcessor.pendingRunURL
        try? fm.removeItem(at: runManifest)
        defer { try? fm.removeItem(at: runManifest) }

        let processor = OCRProcessor()
        processor.activePendingBatch = saved
        processor.batchPollInterrupted = false
        processor.isProcessing = true
        // `.processing` is load-bearing — `OCRJob` defaults to `.pending`, and the sweep only visits jobs
        // the batch left in flight.
        processor.jobs = sources.map { source in
            var job = OCRJob(sourceURL: source)
            job.status = .processing
            return job
        }
        // §2 asks the NON-batch question — the resume snapshot a paid re-OCR is charged against — so it
        // routes `saveResultToPendingRun` into its pending-RUN branch, which is the one that guards cost.
        // (`saveResultToPendingRun` takes the batch branch only when `activePendingRun` is nil.)
        if mutation == .clearTheListAfterASuccessfulWrite {
            processor.activePendingRun = OCRProcessor.PendingRun(
                provider: .gemini, model: model(), thinkingLevel: nil,
                fileURLs: sources, outputDirectory: outDir, enableTagging: false, enableSegmentJSON: false,
                enableCollectionSegmentation: false, confirmCollectionIDs: false,
                reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
                sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
                completedResults: [:], runFingerprint: nil)
        }

        if blockTheWrite {
            try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outDir.path)
        }

        let signal = Signal()
        // Enqueued BEFORE the sweep starts and never awaited from inside it, so the main actor can only
        // reach it at the sweep's first genuine suspension — the detached PDF write. That is the instant a
        // click on Clear lands in production, and it is why no seam is needed to reproduce this.
        let mutator = Task { @MainActor in
            signal.landedDuringSweep = signal.sweepInFlight
            switch mutation {
            case .clearTheList, .clearTheListAfterASuccessfulWrite:
                processor.jobs = []
            case .shrinkTheList:
                if let first = processor.jobs.first { processor.jobs = [first] }
            case .replaceTheListWithAnotherFile:
                processor.jobs = [OCRJob(sourceURL: intruder)]
            case .replaceTheListWithANewRun:
                processor.jobs = newRunSources.map { source in
                    var job = OCRJob(sourceURL: source)
                    job.status = .processing        // exactly what `startProcessing` does
                    return job
                }
            }
        }

        // `runConfig: nil` on purpose: the only thing it feeds here is PDF image size / text columns, and
        // this section's subject is the job list, not the PDF's dimensions.
        signal.sweepInFlight = true
        let returned = await processor.sweepJobsWithNoBatchResult(
            model: model(), outputDirectory: outDir, runConfig: nil)
        signal.sweepInFlight = false
        await mutator.value

        let flagged = processor.batchPollInterrupted
        let first = processor.jobs.first
        let recorded = processor.failedFiles.contains(sources[0].lastPathComponent)
        let intruderUntouched = first?.sourceURL == intruder && first?.status == .pending
            && first?.result == nil && first?.appliedTags.isEmpty == true
        let newRunUntouched = processor.jobs.count == newRunSources.count
            && zip(processor.jobs, newRunSources).allSatisfy { job, source in
                job.sourceURL == source && job.status == .processing && job.result == nil
            }
            && !processor.failedFiles.contains(newRunSources[0].lastPathComponent)
        // Read BEFORE the tail, which may legitimately delete the journal these came from.
        let journaledResult = processor.activePendingRun?.completedResults["0"] != nil
            || processor.activePendingBatch?.completedResults["0"] != nil
        let journaledPath = processor.activePendingRun?.completedOutputPaths?["0"] != nil
            || processor.activePendingBatch?.completedOutputPaths?["0"] != nil

        // The real first-run tail, reading the flag the sweep just decided.
        processor.retirePaidBatchJournalIfPollCompleted()
        let survived = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)

        return Swept(
            returnedTrue: returned, flaggedInterrupted: flagged,
            mutationLandedDuringSweep: signal.landedDuringSweep,
            recordedTheSweptFile: recorded,
            journaledTheResult: journaledResult, journaledTheOutputPath: journaledPath,
            outputRecorded: processor.outputURLMap[sources[0]] != nil,
            emptyAfter: processor.jobs.isEmpty,
            oneJobLeft: processor.jobs.count == 1,
            sweptSlotFailedWithNoResult: first?.sourceURL == sources[0] && first?.status == .failed
                && first?.result?.errorCode == "no_result",
            intruderUntouched: intruderUntouched,
            newRunUntouched: newRunUntouched,
            journalExistedBefore: journalExisted, journalSurvived: survived)
    }
}
