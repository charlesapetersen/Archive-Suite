import AppKit
import Foundation

/// **A result from a stopped run must not land on the run started after it** (W16.bat10) — headless, $0,
/// no network, no keys.
///
/// The bug this pins: `handleOCRResult` bound its `jobs[index]` writes on `guard index >= 0 && index <
/// jobs.count` — bounds, and nothing else. Every caller picks its index *before* a network round-trip, and
/// the operator can spend that round-trip pressing Stop, then **Clear** (`jobs = []`), re-dropping files and
/// pressing **Start**. The new run's jobs take the same indices, so the bounds check passes and the stale
/// result overwrites a LIVE job's status and text with another file's — and, because the output name is
/// derived from `jobs[index].sourceURL`, writes a PDF named after the row it landed on holding the text of
/// the file that was actually OCRed. `W16.bat9` closed this for the completion sweep and for the writes
/// *after* the detached PDF write (`BatchSweepClearedListContract` §4/§5); its §5 is this case one frame up.
///
/// **No seam and no race here, deliberately.** The bat9 window needed a main-actor task enqueued before a
/// suspension, because the array changed *during* the call. This window is earlier and simpler: the caller
/// already holds a stale `(index, jobID)` pair when it calls, so replacing `jobs` and then calling the real
/// production function reproduces it exactly, deterministically, in one shot.
///
/// **Four things are being pinned.**
///   * A stale pair writes NOTHING (§1) — not the row, not the output PDF, not the resume snapshot.
///   * An honest pair still writes everything (§2). Without this a bare `return false` at the top of
///     `handleOCRResult` would satisfy §1.
///   * The identity is the JOB's, not the URL's (§3). `retryOne` legitimately passes a rotated temp JPEG as
///     `url` — the guard the item warns about (`jobs[index].sourceURL == url`) would refuse that honest
///     write, and this is the check that catches it.
///   * The identity is the job INSTANCE's, not the file's (§4). Cleared and re-dropped with the very same
///     file at the very same index, a `sourceURL` comparison — bat9's post-await guard — compares equal and
///     lets the stale result through. A fresh `OCRJob.id` does not.
///   * And what refusing costs, in the only unit that matters (§5): a stale arrival while a new PAID batch
///     is live records nothing in that batch's journal and leaves the journal itself on disk. Refusing is
///     deletion-reducing; it never buys a second paid call, because at the point it refuses no output has
///     been written for a resume to be told about.
///
/// **What a mutant looks like here.** Four measured 2026-08-03, against the whole 371-check driver:
///   * the entry guard back to bounds only — THE bug — → **5 RED**: all three of §1 (the row takes the
///     stopped run's status and text, an output PDF is written under the live run's filename holding it,
///     and the new run's resume snapshot records an index it never OCRed), plus §4 and §5's journal check.
///     §5's second check stays green, which is the honest reading: the stale result is *journaled* into the
///     live paid batch, and it is the tail — not this function — that would then retire that journal.
///   * `jobs[index].sourceURL == url` — the wrong fix the item names — → **2 RED**: §3, because `retryOne`'s
///     rotated temp image is refused an honest write, and §4, because the same file re-dropped compares
///     equal by source.
///   * a bare `return false` at the top → **17 RED**: §2 and §3 here, and fourteen more across sections
///     20/21/22, which drive this same function for real. Refusing everything is not a fix.
///   * the guard refusing but reporting success (`return true`) → **3 RED** (§1's third check, §4, §5's
///     first): a refusal that claims "persisted" lets a caller retire a paid journal as clean.
///
/// Scope: what `handleOCRResult` writes. NOT what its callers do with `false` — every reader of that treats
/// it as an interruption and therefore keeps the paid journal, which is sections 20/21's subject.
///
/// Every fixture writes and then removes a real journal/manifest at the shipped paths, so the whole section
/// is refused unless the harness's redirect is in force (`BatchJournalPathContract.redirectIsInForce`).
///
/// Run from `BatchResumeTestDriver` (section 23) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum StaleRunResultIdentityContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) async {
        guard redirected else {
            // TEN checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("stale identity: the whole section is SKIPPED (refused: the journal path did not resolve "
                  + "away from Application Support, and every fixture writes a real manifest there)",
                  false)
            return
        }
        let newRun = await land(.staleAfterANewRunStarted)
        let honest = await land(.honest)
        let rotated = await land(.honestWithARotatedTempImage)
        let reDropped = await land(.staleAfterTheSameFileWasReDropped)
        let paid = await land(.staleWhileANewPaidBatchIsLive)

        // MARK: 1. THE regression — a stopped run's result arriving after the next run started
        //
        // Bounds-only, all three of these land: the row takes another file's status and text, an output PDF
        // is written under the NEW file's name holding the OLD file's OCR, and the new run's resume snapshot
        // records index 0 as done — so a resume would skip a file that was never OCRed for it.
        check("stale identity: a result from the stopped run does not touch the row the new run put at that "
              + "index — it keeps its file, its status and its empty result",
              newRun.rowIsTheExpectedFile && newRun.rowUntouched)
        check("stale identity: and no output PDF is written under the new run's filename holding the "
              + "stopped run's text",
              !newRun.outputNamedForTheRow && newRun.outputMapEmpty)
        check("stale identity: and the new run's resume snapshot does not record that index as completed — "
              + "a resume must not skip a file this run never OCRed",
              !newRun.manifestRecordedTheIndex && newRun.returnedFalse)

        // MARK: 2. Non-vacuity — the honest write still lands, in full
        //
        // §1 is satisfied by any refusal, including a `return false` bolted to the top of the function. This
        // is what says the guard discriminates rather than just declines.
        check("stale identity: an in-run result still lands on its own row — status, text and all",
              honest.wroteTheResult && honest.rowIsTheExpectedFile)
        check("stale identity: ...and still produces its output PDF and its resume-snapshot entry",
              honest.outputNamedForTheRow && !honest.outputMapEmpty
                  && honest.manifestRecordedTheIndex && !honest.returnedFalse)

        // MARK: 3. The identity is the job's, not the URL's — the wrong fix, caught
        //
        // `retryOne` passes a rotated temp JPEG (or the temp render of a pre-OCRed PDF) as `url`, which is
        // deliberately NOT the job's source. `jobs[index].sourceURL == url` would refuse this honest write;
        // the output is still named for the SOURCE, which is what makes the two distinguishable here.
        check("stale identity: a retry whose OCR input is a rotated temp image is not mistaken for a stale "
              + "arrival — it writes its row and its output, named for the job's own source",
              rotated.wroteTheResult && rotated.outputNamedForTheRow && !rotated.returnedFalse)
        check("stale identity: ...and that temp image did not become the output's name",
              !rotated.outputNamedForTheTempImage)

        // MARK: 4. The identity is the job INSTANCE's, not the file's
        //
        // Clear, then re-drop the SAME file at the SAME index. Bat9's post-await guard compared source URLs,
        // which are equal here; only a per-instance id tells the re-dropped row from the one it replaced.
        check("stale identity: a row refilled with the very same file is still a different row — the "
              + "stopped run's result does not land on it",
              reDropped.rowIsTheExpectedFile && reDropped.rowUntouched && reDropped.returnedFalse)

        // MARK: 5. What refusing costs, on the money path
        //
        // Nothing that exists: at the point it refuses no PDF has been generated, so there is no output for
        // a resume to be told about — the distinction from the post-await bail-out W16.bat9 rejected, where
        // the file HAD been written and skipping the record bought a second paid call.
        check("stale identity: a stale arrival while a new paid batch is live records nothing in that "
              + "batch's journal",
              !paid.batchJournaledTheIndex && paid.returnedFalse)
        check("stale identity: ...and leaves the journal itself on disk — refusing never deletes",
              paid.journalExistedBefore && paid.journalSurvived)
    }

    // MARK: - Fixtures

    /// What the file list looks like by the time the result is handed in.
    private enum Arrival {
        /// Stop, Clear, re-drop, Start: a live new run's jobs at the same indices, all `.processing`.
        case staleAfterANewRunStarted
        /// Nothing happened — the ordinary case, which must be unaffected.
        case honest
        /// Nothing happened, but the OCR input was a temp image that is not the job's source (`retryOne`).
        case honestWithARotatedTempImage
        /// Cleared and re-dropped with the SAME file at the same index: equal by source, not by identity.
        case staleAfterTheSameFileWasReDropped
        /// Stop, Clear, re-drop, Start — into a paid batch, so the journal is what the result would reach.
        case staleWhileANewPaidBatchIsLive
    }

    /// Everything observable about one arrival at the real `handleOCRResult`.
    private struct Landed {
        let returnedFalse: Bool
        /// The row at the index is the file the fixture expects to find there afterwards.
        let rowIsTheExpectedFile: Bool
        /// Untouched: still `.processing`, still no result, still no applied tags.
        let rowUntouched: Bool
        /// The row took this arrival's result, in full.
        let wroteTheResult: Bool
        let outputMapEmpty: Bool
        /// An output PDF exists named for the source of the row at that index.
        let outputNamedForTheRow: Bool
        /// An output PDF exists named for the temp OCR input (it never should be).
        let outputNamedForTheTempImage: Bool
        let manifestRecordedTheIndex: Bool
        let batchJournaledTheIndex: Bool
        let journalExistedBefore: Bool
        let journalSurvived: Bool
    }

    /// The text the stopped run produced — distinctive, so a row that took it is unmistakable.
    private static let arrivingText = "TEXT FROM THE RUN THAT WAS STOPPED"

    /// A synthetic model — never sent anywhere; built by hand so no check depends on `CustomModelStore`.
    private static func model() -> LLMModel {
        LLMModel(id: "stale-identity-gemini", displayName: "Stale Identity Gemini",
                 provider: .gemini, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// A REAL 64×64 JPEG, so `PDFGenerator` behaves as in production and a written output is a real file.
    private static func makeJPEG(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let jpeg = bitmap?.representation(using: .jpeg, properties: [:]) { try? jpeg.write(to: url) }
        return url
    }

    private static func processingJobs(_ sources: [URL]) -> [OCRJob] {
        sources.map { source in
            var job = OCRJob(sourceURL: source)
            job.status = .processing        // exactly what `startProcessing` does
            return job
        }
    }

    private static func pendingRun(over sources: [URL], out: URL) -> OCRProcessor.PendingRun {
        OCRProcessor.PendingRun(
            provider: .gemini, model: model(), thinkingLevel: nil,
            fileURLs: sources, outputDirectory: out, enableTagging: false, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
            completedResults: [:], runFingerprint: nil)
    }

    /// One arrival at the real `handleOCRResult`, with the job list standing wherever this fixture put it.
    private static func land(_ arrival: Arrival) async -> Landed {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("APStaleIdentity-\(UUID().uuidString)", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let stoppedRunSources = (0..<2).map { makeJPEG("stopped-run-\($0).jpg", in: dir) }
        let newRunSources = (0..<2).map { makeJPEG("new-run-\($0).jpg", in: dir) }
        let rotatedTemp = makeJPEG("rotated-temp.jpg", in: dir)

        let runManifest = OCRProcessor.pendingRunURL
        try? fm.removeItem(at: runManifest)
        defer { try? fm.removeItem(at: runManifest) }
        // Deferred, not called at the end: a fixture may legitimately leave this file on disk, so the
        // removal has to be the one thing that cannot be skipped.
        defer { OCRProcessor.deletePendingBatch() }
        try? fm.removeItem(at: OCRProcessor.pendingBatchURL)

        let processor = OCRProcessor()
        processor.isProcessing = true
        // The run that is about to be stopped. `.processing` is what its jobs are left in.
        processor.jobs = processingJobs(stoppedRunSources)
        // The pair the caller is holding: bound at dispatch, i.e. NOW, before anything changes.
        let dispatchedIndex = 0
        let dispatchedJobID = processor.jobs[dispatchedIndex].id

        // Stop, Clear, re-drop, Start — or not, for the two honest arrivals.
        let expectedSourceAtIndex: URL
        var journalExisted = false
        switch arrival {
        case .honest, .honestWithARotatedTempImage:
            expectedSourceAtIndex = stoppedRunSources[dispatchedIndex]
            processor.activePendingRun = pendingRun(over: stoppedRunSources, out: outDir)
        case .staleAfterANewRunStarted:
            expectedSourceAtIndex = newRunSources[dispatchedIndex]
            processor.jobs = processingJobs(newRunSources)
            processor.activePendingRun = pendingRun(over: newRunSources, out: outDir)
        case .staleAfterTheSameFileWasReDropped:
            expectedSourceAtIndex = stoppedRunSources[dispatchedIndex]
            // The SAME files, dropped again: equal by source URL, and a fresh `OCRJob.id` each.
            processor.jobs = processingJobs(stoppedRunSources)
            processor.activePendingRun = pendingRun(over: stoppedRunSources, out: outDir)
        case .staleWhileANewPaidBatchIsLive:
            expectedSourceAtIndex = newRunSources[dispatchedIndex]
            processor.jobs = processingJobs(newRunSources)
            // `saveResultToPendingRun` takes its paid-batch branch only when there is no pending RUN, so
            // this is the arrangement in which the journal is what a stale arrival would reach.
            processor.activePendingRun = nil
            let saved = OCRProcessor.savePendingBatch(
                OCRProcessor.PendingBatch(
                    batchId: "batches/stale-identity", provider: .gemini, model: model(),
                    thinkingLevel: .low, fileURLs: newRunSources, outputDirectory: outDir,
                    enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
                    lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
                    submittedChunkIds: ["batches/stale-identity"]))
            processor.activePendingBatch = saved
            journalExisted = saved != nil && fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        }

        // What the caller hands in. The honest arrivals pass the job that is actually there; the stale ones
        // pass the pair they bound before the list changed under them.
        let handedInJobID: OCRJob.ID
        switch arrival {
        case .honest, .honestWithARotatedTempImage: handedInJobID = processor.jobs[dispatchedIndex].id
        default: handedInJobID = dispatchedJobID
        }
        // `retryOne`'s shape: the OCR input is a temp image, not the job's source.
        let handedInURL = arrival == .honestWithARotatedTempImage
            ? rotatedTemp
            : stoppedRunSources[dispatchedIndex]

        // `runConfig: nil` on purpose: the only thing it feeds here is PDF image size / text columns, and
        // this section's subject is which row is written, not the PDF's dimensions.
        let returned = await processor.handleOCRResult(
            OCRResult(text: arrivingText, classification: nil, errorMessage: nil, errorCode: nil),
            index: dispatchedIndex, jobID: handedInJobID, url: handedInURL,
            model: model(), outputDirectory: outDir, runConfig: nil)

        let row = processor.jobs.indices.contains(dispatchedIndex) ? processor.jobs[dispatchedIndex] : nil
        let rowBase = expectedSourceAtIndex.deletingPathExtension().lastPathComponent
        let survived = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)

        return Landed(
            returnedFalse: !returned,
            rowIsTheExpectedFile: row?.sourceURL == expectedSourceAtIndex,
            rowUntouched: row?.status == .processing && row?.result == nil
                && row?.appliedTags.isEmpty == true,
            wroteTheResult: row?.status == .succeeded && row?.result?.text == arrivingText,
            outputMapEmpty: processor.outputURLMap.isEmpty,
            outputNamedForTheRow: fm.fileExists(
                atPath: outDir.appendingPathComponent("\(rowBase).pdf").path),
            outputNamedForTheTempImage: fm.fileExists(
                atPath: outDir.appendingPathComponent("rotated-temp.pdf").path),
            manifestRecordedTheIndex:
                processor.activePendingRun?.completedResults["\(dispatchedIndex)"] != nil,
            batchJournaledTheIndex:
                processor.activePendingBatch?.completedResults["\(dispatchedIndex)"] != nil,
            journalExistedBefore: journalExisted,
            journalSurvived: survived)
    }
}
