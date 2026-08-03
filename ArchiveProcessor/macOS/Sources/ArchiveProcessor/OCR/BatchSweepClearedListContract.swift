import AppKit
import Foundation

/// **Clearing the file list while the paid batch's completion sweep is mid-write must not kill the app**
/// (W16.bat9) — headless, $0, no network, no keys.
///
/// The bug this pins: `sweepJobsWithNoBatchResult` iterates `jobs.indices`, snapshotted ONCE, and
/// re-subscripts `jobs[i]` in its `where` clause on every iteration — across the `await` in
/// `handleOCRResult`, which awaits a **detached** task and so goes on running after the run is cancelled.
/// `cancel()` sets `isProcessing = false` synchronously (its own comment: the run "goes on unwinding
/// afterwards"), which un-disables the **Clear** button, whose action is `processor.jobs = []`. One click
/// during that suspension and the next subscript is out of range: SIGTRAP, on the money path. The identical
/// window exists one frame down, at the three `jobs[index]` mutations `handleOCRResult` performs *after* its
/// detached PDF write — its entry bounds guard was passed seconds earlier and cannot speak for the array now.
///
/// **How the crash is reproduced without a GUI.** No seam and no stub: a `Task { @MainActor in … }` is
/// enqueued before the sweep starts, so the main actor can only reach it at the sweep's first real
/// suspension — the detached PDF write inside `handleOCRResult` — which is exactly when a click on Clear
/// lands. Each fixture records whether its mutation really landed *while the sweep was in flight*
/// (`mutationLandedDuringSweep`); a fixture that failed to reproduce the race FAILS a check of its own
/// rather than passing the rest for the wrong reason.
///
/// **What a mutant looks like here, and why it is not a FAIL line.** Revert either half of the fix and this
/// section does not print `FAIL` — the driver process TRAPS and writes no report at all, so
/// `test-batch-resume.sh` times out on a missing report and exits 1 with the app log. Measured, both
/// directions:
///   * `where jobs.indices.contains(i) &&` removed → §2 traps (`EXC_BREAKPOINT`, index 1 of 1).
///   * the post-await `guard index < jobs.count, jobs[index].sourceURL == sourceURL` removed → §1 traps.
///   * that guard reduced to bounds only (`index < jobs.count`) → §3 goes RED normally: the result of the
///     file that was swept is written onto the *different* file now sitting in that slot.
///
/// Scope: the crash and what the run reports after surviving it. It is NOT a claim about Stop's own
/// semantics — the sweep still has no `Task.isCancelled` check of its own (the poll's two are at `:737`
/// and `:752`), which is deliberate and weighed in the item: aborting the sweep would change what a
/// cancelled paid batch records, leaving jobs `.processing` forever with no failure output.
///
/// §1 and §3 write and then remove a real journal at the shipped path, so the whole section is refused
/// unless the harness's redirect is in force (`BatchJournalPathContract.redirectIsInForce`).
///
/// Run from `BatchResumeTestDriver` (section 21) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchSweepClearedListContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) async {
        guard redirected else {
            // SIX checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("sweep cleared: the whole section is SKIPPED (refused: the journal path did not resolve "
                  + "away from Application Support, and two of its checks write a real journal there)",
                  false)
            return
        }
        let cleared = await sweep(.clearTheList)
        let shrunk = await sweep(.shrinkTheList)
        let replaced = await sweep(.replaceTheListWithAnotherFile)

        // MARK: 1. THE regression — the list is emptied while a failure output is being written
        //
        // Reaching this check at all is most of it: with the post-await guard removed the process is gone
        // before any report is written. What it then asserts is the answer the run gives once it survives —
        // the same `false` the entry bounds guard already gives to "that index is not this file's job any
        // more", which is what keeps the paid batch's journal.
        check("sweep cleared: the app survives Clear pressed while the completion sweep is writing a "
              + "failure output — and the sweep reports the interruption rather than a clean finish",
              cleared.mutationLandedDuringSweep && cleared.returnedFalse && cleared.flaggedInterrupted)
        // Non-vacuity: proves the sweep really reached the job and did its work before the list went away,
        // so check 1 is not green because the loop never ran.
        check("sweep cleared: and what it had already recorded before the list went away is still recorded "
              + "— the swept file is in the failed list under its own name",
              cleared.mutationLandedDuringSweep && cleared.recordedTheSweptFile && cleared.emptyAfter)

        // MARK: 2. The bounds half, on its own — a list that SHRANK under the snapshotted index range
        //
        // The one direction the post-await guard cannot cover: the slot being written is still this file's,
        // so `handleOCRResult` returns true and the loop goes on to an index that no longer exists.
        check("sweep cleared: a list that shrinks mid-sweep does not trap the loop that snapshotted its "
              + "indices — the vanished slots are skipped, not subscripted",
              shrunk.mutationLandedDuringSweep && shrunk.returnedTrue && shrunk.oneJobLeft)
        // The other direction, so a fix that reported every sweep as interrupted — wedging every completed
        // paid batch into a permanent Resume banner — cannot satisfy section 2.
        check("sweep cleared: and surviving that is not an interruption — the file that was still there was "
              + "swept to its \"no result\" failure, the flag stays clear, and the tail still retires the "
              + "journal of a batch that finished",
              shrunk.mutationLandedDuringSweep && shrunk.sweptSlotFailedWithNoResult
                  && !shrunk.flaggedInterrupted
                  && shrunk.journalExistedBefore && !shrunk.journalSurvived)

        // MARK: 3. Identity, not just bounds — the quiet version of the same bug
        //
        // Clear, then re-drop a different file: the index is in range again, and a bounds-only guard would
        // write this file's failure onto that one. No trap, no message — just the wrong file marked failed.
        check("sweep cleared: a slot refilled with a DIFFERENT file is not written to — the swept file's "
              + "result does not land on the file that replaced it",
              replaced.mutationLandedDuringSweep && replaced.intruderUntouched
                  && replaced.returnedFalse && replaced.flaggedInterrupted)

        // MARK: 4. What it costs, in the only unit that matters
        //
        // The crash was never data loss — the process died before `retirePaidBatchJournalIfPollCompleted()`
        // could run, so the journal survived a SIGTRAP too. This pins that surviving the crash did not buy
        // the survival back: the same journal is still on disk, and the Resume banner still has its batch.
        check("sweep cleared: after the list is cleared mid-sweep the paid batch's journal is still on disk "
              + "and still live in memory — the server-side job keeps its only local record",
              cleared.journalExistedBefore && cleared.journalSurvived && cleared.batchStillLive)
    }

    // MARK: - Fixtures

    /// What the file list does while the sweep is suspended on its detached PDF write.
    private enum Mutation {
        /// The **Clear** button, verbatim: `processor.jobs = []`.
        case clearTheList
        /// Cleared and re-dropped short of the original set — the slot under the sweep survives, the ones
        /// after it do not. This is the shape the sweep's own `where` clause is the only guard against.
        case shrinkTheList
        /// Cleared and re-dropped with a different file, so the index is valid again but means something
        /// else. Bounds alone cannot tell this from the honest case.
        case replaceTheListWithAnotherFile
    }

    /// Everything observable about one run of the real sweep with the list mutated underneath it.
    private struct Swept {
        let returnedFalse: Bool
        let returnedTrue: Bool
        let flaggedInterrupted: Bool
        /// The mutation ran while the sweep was in flight — i.e. the race was really reproduced. False here
        /// means the fixture, not the code, is what needs looking at.
        let mutationLandedDuringSweep: Bool
        /// The sweep reached the job and recorded its synthetic failure before the list changed.
        let recordedTheSweptFile: Bool
        let emptyAfter: Bool
        let oneJobLeft: Bool
        let sweptSlotFailedWithNoResult: Bool
        /// The file that replaced the swept one is exactly as it was dropped.
        let intruderUntouched: Bool
        let journalExistedBefore: Bool
        let journalSurvived: Bool
        let batchStillLive: Bool
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

        // `.clearTheList` and `.replaceTheListWithAnotherFile` need the write to FAIL, because the crash
        // they reproduce is at the `jobs[index]` mutations in `handleOCRResult`'s failure branch — the ones
        // past its detached write. A read-only output directory makes `PDFDocument.write(to:)` return false
        // for real, which is the only thing `PDFGenerator.generate` throws on. `.shrinkTheList` needs the
        // opposite (a write that succeeds, so `handleOCRResult` returns true and the LOOP runs on to the
        // index that no longer exists), so it leaves the directory writable.
        let blockTheWrite = mutation != .shrinkTheList
        let sourceCount = mutation == .shrinkTheList ? 3 : (mutation == .clearTheList ? 2 : 1)
        let sources = (0..<sourceCount).map { makeJPEG("sweep-source-\($0).jpg", in: dir) }
        let intruder = makeJPEG("re-dropped-other.jpg", in: dir)

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
        // Deferred, not called at the end: §1 is *meant* to leave this file on disk, so the removal has to
        // be the one thing that cannot be skipped.
        defer { OCRProcessor.deletePendingBatch() }

        let processor = OCRProcessor()
        processor.activePendingBatch = saved
        processor.batchPollInterrupted = false
        processor.isProcessing = true
        // `.processing` is load-bearing — `OCRJob` defaults to `.pending`, and the sweep's `where` clause
        // only visits jobs the batch left in flight.
        processor.jobs = sources.map { source in
            var job = OCRJob(sourceURL: source)
            job.status = .processing
            return job
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
            case .clearTheList:
                processor.jobs = []
            case .shrinkTheList:
                if let first = processor.jobs.first { processor.jobs = [first] }
            case .replaceTheListWithAnotherFile:
                processor.jobs = [OCRJob(sourceURL: intruder)]
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

        // The real first-run tail, reading the flag the sweep just decided.
        processor.retirePaidBatchJournalIfPollCompleted()
        let survived = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)

        return Swept(
            returnedFalse: !returned, returnedTrue: returned, flaggedInterrupted: flagged,
            mutationLandedDuringSweep: signal.landedDuringSweep,
            recordedTheSweptFile: recorded,
            emptyAfter: processor.jobs.isEmpty,
            oneJobLeft: processor.jobs.count == 1,
            sweptSlotFailedWithNoResult: first?.sourceURL == sources[0] && first?.status == .failed
                && first?.result?.errorCode == "no_result",
            intruderUntouched: intruderUntouched,
            journalExistedBefore: journalExisted, journalSurvived: survived,
            batchStillLive: processor.activePendingBatch != nil)
    }
}
