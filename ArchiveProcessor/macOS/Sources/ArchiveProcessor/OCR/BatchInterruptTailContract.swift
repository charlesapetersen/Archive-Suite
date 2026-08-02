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
/// **How it stays $0 and cannot touch the operator's state.** Nothing here performs a network call, and
/// almost every file any check creates or deletes lives under a per-trial temp directory. The one thing that
/// reads durable state is `checkForPendingBatch()` itself, running for real inside the tail: it decodes
/// whatever `pending_batch.json` / `pending_run.json` it finds and recomputes two banner strings from them.
/// Since W16.bat2-fu2 that is the harness's redirected state directory rather than the operator's own.
/// ONE section (`theRecomputedBannersAreARealRead`, W16.bat4-fu) also *writes* both journals at that shipped
/// path so there is something to recompute from — it is gated on the driver's `redirectIsInForce` verdict and
/// restores whatever was there byte for byte, and it is the only place in this file that writes outside a
/// temp directory.
///
/// ⚠️ **SCOPE — read before citing this file.**
///   * This pins the TAIL, not its two call sites. That the resume path (`resumePendingBatch`) and the
///     first-run path (`processFiles`, after `performBatchOCR`) each reach it — the bug W16.bat4 *was* — is
///     grep-verifiable, not driven here: both entry points require a real paid submission. What makes them
///     safe meanwhile is structural rather than tested: each site is now a bare
///     `finishInterruptedBatchPoll(); return`, so there is no second copy of the tail left to drift.
///   * "Deletes no journal" is proved twice, and the two halves cover different mutations. Decoy files named
///     exactly `pending_batch.json` / `pending_run.json` in the trial's own directory catch a tail that
///     deletes by *name*; since W16.bat4-fu a real journal at the SHIPPED path catches a tail that called
///     `OCRProcessor.deletePendingBatch()` "to tidy up" — which would strand a paid job. What the shipped
///     deleter itself does, and where that path resolves, stays section 16 (`BatchJournalPathContract`).
///   * The interruption *messages* are the other half of this bug and are not pinned here — this contract
///     asserts only that the tail leaves `statusMessage` exactly as its caller set it.
///
/// Run from `BatchResumeTestDriver` (section 15) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchInterruptTailContract {

    /// `redirected` is `BatchJournalPathContract.redirectIsInForce(_:)`'s verdict, taken by the driver before
    /// any section ran. Only `theRecomputedBannersAreARealRead` needs it: it is the one part of this file that
    /// writes a journal at the path the app really keeps one, and doing that against Application Support
    /// would overwrite the operator's own record of a paid server-side job.
    static func run(check: (String, Bool) -> Void, redirected: Bool) {
        theResumeControlAppears(check)
        if redirected {
            theRecomputedBannersAreARealRead(check)
        } else {
            // THREE checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("interrupt tail: the three checks that give the tail a real journal to recompute from — the "
                  + "banner text, the fresh-read comparison, and \"no journal at the SHIPPED path is removed\" "
                  + "— are SKIPPED (refused: the journal path did not resolve away from Application Support)",
                  false)
        }
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
    }

    // MARK: - What the banners are recomputed FROM (W16.bat4-fu)

    /// The sentinel checks above prove the tail *replaced* both banners. This proves what it replaced them
    /// with: exactly what a fresh `checkForPendingBatch()` reads off the durable journals.
    ///
    /// It used to be a two-line comparison sitting in `theResumeControlAppears`, and W16.bat2-fu2 quietly made
    /// it vacuous. Before the redirect it read the operator's Application Support directory, so it was
    /// meaningful only when they happened to have a manifest — never on purpose; after it, it read the
    /// harness's own *empty* directory, so both sides were reliably `nil == nil && nil == nil`. It still
    /// caught a tail that invented a placeholder of its own, and nothing else: a tail that produced an empty
    /// banner where a real one was due passed it.
    ///
    /// The redirect that broke it is also what fixes it. This writes a real, self-consistent
    /// `pending_batch.json` and `pending_run.json` at the SHIPPED URLs first, so both sides have something to
    /// find and the comparison is between two non-empty strings — and it says out loud what that read
    /// produced, which is the assertion whose absence let the check rot in the first place.
    ///
    /// Only reached when the driver's `redirectIsInForce` verdict is true, so those writes land in the
    /// harness's directory. Whatever the two paths held on the way in is restored byte for byte (or removed
    /// again if they held nothing) on the way out, so sections 16–18 find the directory as they left it.
    private static func theRecomputedBannersAreARealRead(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("APInterruptTailBanner-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("banner-fixture.pdf")
        try? Data("%PDF-1.4\n".utf8).write(to: source)

        let batchURL = OCRProcessor.pendingBatchURL
        let runURL = OCRProcessor.pendingRunURL
        let batchBefore = try? Data(contentsOf: batchURL)
        let runBefore = try? Data(contentsOf: runURL)
        defer {
            restore(batchBefore, to: batchURL)
            restore(runBefore, to: runURL)
            try? fm.removeItem(at: dir)
        }

        // The paid-batch journal goes through the PRODUCTION write path, not a hand-rolled encode: only
        // `savePendingBatch` stamps the lifecycle fingerprint, and `checkForPendingBatch()` renders the
        // healthy banner only for a manifest that passes `pendingBatchIsSelfConsistent`. An unstamped fixture
        // would land in the torn/tampered branch instead and pin the wrong sentence.
        //
        // ⚠️ `runFingerprint` is LOAD-BEARING and is the one field `savePendingBatch` will NOT fill in for
        // you: `fingerprintVersion` defaults to 2, whose arm of the self-consistency check rejects a manifest
        // that has no stored identity outright. The in-memory journals elsewhere in this file never notice,
        // because nothing reads them back off disk. It is computed here from the shipped function with the
        // arguments that arm itself uses (`batchMode: true`, `preserveInputOrder: true`) rather than typed
        // out, so a change to how a run fingerprint is COMPUTED re-points this fixture instead of reddening
        // it. A change to the fingerprint VERSION still reddens — deliberately: the check below carries the
        // rejected banner in its label, so the next reader is told the fixture went stale rather than left
        // to conclude the tail broke.
        let fixtureModel = model()
        let provider = LLMProvider.gemini
        let taggingMode = TaggingMode.automatic
        let batchSaved = OCRProcessor.savePendingBatch(OCRProcessor.PendingBatch(
            batchId: "batches/banner-fixture", provider: provider, model: fixtureModel,
            thinkingLevel: .low, fileURLs: [source], outputDirectory: dir,
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            taggingMode: taggingMode,
            runFingerprint: OCRProcessor.runFingerprint(
                files: [source], outputDirectory: dir, taggingMode: taggingMode,
                enableTagging: false, batchMode: true, preserveInputOrder: true),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: ["batches/banner-fixture"])) != nil
        // Its sibling. `savePendingRun` is private, so this uses the serialization hook the driver already
        // writes manifests with, pointed at the shipped URL — same encoder, same `.atomic` write. A run with
        // no runtime snapshot and no fingerprint is self-consistent by construction
        // (`pendingRunIsSelfConsistent`'s legacy arm), which is all this fixture needs to be.
        let runSaved = OCRProcessor._testWritePendingRun(OCRProcessor.PendingRun(
            provider: provider, model: fixtureModel, thinkingLevel: nil,
            fileURLs: [source], outputDirectory: dir, enableTagging: false, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
            completedResults: [:], runFingerprint: nil), to: runURL)

        let fresh = OCRProcessor()
        fresh.checkForPendingBatch()
        // The fixture is only worth writing if it is FOUND. Both expected fragments are built from the
        // fixture's own fields rather than typed out, so renaming a provider or reshaping a banner re-points
        // this check instead of silently orphaning it. Neither `nil` (nothing on disk) nor the "failed a
        // self-consistency check" line (found but rejected) can satisfy it.
        let batchFragment = "1 files via \(provider.rawValue) \(fixtureModel.displayName)."
        let runFragment = "0/1 files completed via \(provider.rawValue) \(fixtureModel.displayName)."
        let bannersAreTheFixtures = batchSaved && runSaved
            && fresh.pendingBatchInfo?.contains(batchFragment) == true
            && fresh.pendingRunInfo?.contains(runFragment) == true
        // A red here has several causes — either file failing to save, either one written but rejected as
        // self-inconsistent, a reshaped banner — and a bare `false` cannot tell them apart. Carry what
        // actually happened in the label; the two checks after this one are read against it.
        check("interrupt tail: the fixture journal and run manifest are found at the shipped path, so both "
              + "banners carry the fixture's own details"
              + (bannersAreTheFixtures ? "" : " [saved batch:\(batchSaved) run:\(runSaved); "
                 + "batch banner: \(fresh.pendingBatchInfo ?? "nil"); "
                 + "run banner: \(fresh.pendingRunInfo ?? "nil")]"),
              bannersAreTheFixtures)

        // THE comparison, no longer vacuous. Both processors read the same disk back-to-back; the `!= nil`
        // pair is what stops it decaying to `nil == nil` again if a later change empties the directory.
        let tailed = OCRProcessor()
        tailed.pendingBatchInfo = "stale"
        tailed.pendingRunInfo = "stale"
        tailed.finishInterruptedBatchPoll()
        check("interrupt tail: the recomputed banners are what checkForPendingBatch() alone produces, "
              + "compared against a journal that actually exists",
              tailed.pendingBatchInfo != nil && tailed.pendingRunInfo != nil
              && tailed.pendingBatchInfo == fresh.pendingBatchInfo
              && tailed.pendingRunInfo == fresh.pendingRunInfo)

        // The other half of this file's scope note, now assertable. The decoys in `interrupt()` prove the tail
        // deletes nothing NAMED like a journal in the run's own directory; this proves it removes neither
        // journal from where the app actually keeps them — the file a `deletePendingBatch()` added "to tidy
        // up" would take, stranding a paid server-side job with no local record.
        check("interrupt tail: neither durable journal at the SHIPPED path is removed by the tail",
              fm.fileExists(atPath: batchURL.path) && fm.fileExists(atPath: runURL.path))
    }

    /// Put a durable file back as it was found: the same bytes, or removed again if it read as absent.
    ///
    /// ⚠️ "Read as absent" is a `try?`, so an unreadable-for-another-reason file would be REMOVED rather than
    /// restored. That is only tolerable because of where this runs: its single caller is gated on
    /// `redirectIsInForce`, so `url` is always inside the harness's own temp state directory, never the
    /// operator's Application Support. Do not lift this helper out of that gate.
    private static func restore(_ bytes: Data?, to url: URL) {
        if let bytes {
            try? bytes.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
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
