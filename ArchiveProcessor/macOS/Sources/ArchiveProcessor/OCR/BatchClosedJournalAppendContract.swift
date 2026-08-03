import Foundation

/// **A paid job created as Stop landed still reaches the recovery journal** (W16.bat5-fu) — headless, $0,
/// no network, no keys. Drives the real `OCRProcessor.cancel()` and the real
/// `recordSubmittedBatchChunk(_:)` against a real journal file at the shipped path.
///
/// **Why this exists.** `W16.bat5` stopped `cancel()` deleting the journal while a submission was still in
/// flight, so a Stop pressed mid-submit now leaves a local record and a Resume banner. The record was still
/// short. A Gemini submission creates its server-side jobs one at a time; a chunk created between
/// `cancel()`'s chunk snapshot and the Stop is billed, and by the time its `onJobCreated` callback runs
/// `cancel()` has nil'd `activePendingBatch` — so `recordSubmittedBatchChunk` reached
/// `persistPendingBatchMutation`'s missing-journal guard, reported the interruption, and returned `false`
/// with the ID written **nowhere**. The operator was warned that paid jobs might exist beyond the cancelled
/// ones and sent to the provider console; the app could neither cancel nor collect that job itself.
///
/// **The property, stated once:** while `cancel()`'s journal is still on disk and still that batch's,
/// a late chunk ID is APPENDED to it — and the submission still stops.
///
/// Both halves are load-bearing and this file pins them together:
///   * The ID lands in the file `resumeBatch` reads, so the paid job becomes collectible.
///   * `recordSubmittedBatchChunk` still returns `false`, so the Gemini callback still throws and the submit
///     loop still stops creating paid jobs. A Stop that recorded the ID and then kept spending would be a
///     worse bug than the one being fixed.
///
/// ⚠️ **SCOPE — read before citing this file.**
///   * The append is driven by CALLING `recordSubmittedBatchChunk` after a real `cancel()`, not by a real
///     provider create. Reaching that callback for real needs a paid submission; the same honest limit
///     `BatchMutationReportContract` records for `performBatchOCR`'s own guard lines.
///   * Every section writes a real journal at `OCRProcessor.pendingBatchURL`, so the whole contract is
///     refused unless the state directory has been redirected away from Application Support
///     (`ARCHIVEPROC_TEST_STATE_ROOT`, W16.bat2-fu2). It removes what it writes.
///   * Section 5 pins the owner's ⛔ "Stop must stay instant" constraint by measuring it, not by reading
///     `cancel()` for `await`s.
///
/// Run from `BatchResumeTestDriver` (section 22) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchClosedJournalAppendContract {

    static func run(check: (String, Bool) -> Void, redirected: Bool) async {
        guard redirected else {
            // Every check below is skipped, not silently: this one FAILs in their place.
            check("closed-journal append: the whole contract is SKIPPED (refused: the journal path did not "
                  + "resolve away from Application Support), so nothing is known about whether a job created "
                  + "as Stop landed reaches the journal", false)
            return
        }
        await aLateChunkIdReachesTheJournalStopClosed(check)
        await theAppendIsAdditiveAndNothingElseMoves(check)
        await itRefusesEveryJournalThatIsNotThisOne(check)
        theLiveJournalIsNotItsToWrite(check)
        await theAppendedJournalIsOneResumeAccepts(check)
        await stopStaysInstant(check)
    }

    // MARK: - Fixtures

    /// A synthetic model — never sent anywhere. Built by hand so no check depends on `CustomModelStore`.
    private static func model() -> LLMModel {
        LLMModel(id: "closed-append-gemini", displayName: "Closed Append Gemini",
                 provider: .gemini, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// ⚠️ `submissionComplete: false` is LOAD-BEARING. It is the state the submit loop is really in when a
    /// late create can still happen, and it is what `batchSubmissionIsInFlight` reads to decide the journal
    /// survives the Stop (W16.bat5). A fixture that omitted it (the `init` default is **true**) would have
    /// `cancel()` delete the file, and every section below would be measuring the wrong path.
    private static func journal(chunkIds: [String] = ["batches/chunk-0"],
                                fingerprint: String = "closed-append-fingerprint",
                                submittedAt: Date = Date(),
                                lifecycleVersion: Int? = OCRProcessor.PendingBatch.currentLifecycleVersion)
        -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: chunkIds.first ?? "", provider: .gemini, model: model(), thinkingLevel: .low,
            fileURLs: [URL(fileURLWithPath: "/tmp/closed-append/scan-0.jpg")],
            outputDirectory: URL(fileURLWithPath: "/tmp/closed-append", isDirectory: true),
            enableTagging: false, sendPreviousImage: false, submittedAt: submittedAt,
            runFingerprint: fingerprint,
            lifecycleVersion: lifecycleVersion,
            submittedChunkIds: chunkIds, submissionComplete: false)
    }

    /// The same journal, but with an HONEST immutable fingerprint — the one
    /// `pendingBatchIsSelfConsistent` recomputes from the fields beside it.
    ///
    /// The fixture above carries a made-up fingerprint, which is fine for every check that reads the file
    /// back itself and wrong for the only check that asks the app's own resume guard about it.
    private static func resumableJournal(submittedAt: Date) -> OCRProcessor.PendingBatch {
        let files = [URL(fileURLWithPath: "/tmp/closed-append/scan-0.jpg")]
        let output = URL(fileURLWithPath: "/tmp/closed-append", isDirectory: true)
        return journal(
            fingerprint: OCRProcessor.runFingerprint(
                files: files, outputDirectory: output, taggingMode: .automatic,
                enableTagging: false, batchMode: true, preserveInputOrder: true),
            submittedAt: submittedAt)
    }

    private static func context() -> OCRProcessor.BatchContext {
        OCRProcessor.BatchContext(batchId: "batches/chunk-0", apiKey: "unused-in-a-stub",
                                  model: model(), thinkingLevel: .low, provider: .gemini)
    }

    /// What one post-Stop `recordSubmittedBatchChunk` call did.
    private struct LateChunk {
        let returned: Bool
        /// The journal as it is on disk afterwards — nil when there is no file (or it will not decode).
        let onDisk: OCRProcessor.PendingBatch?
        /// Raw bytes afterwards, for the byte-identical refusals.
        let bytes: Data?
        let journalStillClosedInMemory: Bool
        let flaggedInterrupted: Bool
        let stoppedProcessing: Bool
        let explainedItself: Bool
        /// The post-Stop exit may not cancel `processingTask`: it is nil or a NEWER run's by then.
        let cancelledTheRun: Bool
        let elapsed: TimeInterval
    }

    /// Press Stop for real on a live paid batch, then deliver a chunk ID the way a late create would.
    ///
    /// THE ONLY place this file presses Stop, so no section can accidentally measure an append whose address
    /// was hand-installed rather than left by the real `cancel()`. Both cancel-path seams are stubbed
    /// together (never the real deleter), and `disturb` runs between the Stop and the late chunk so a section
    /// can change what is on disk first.
    private static func stopThenRecord(
        _ chunkId: String,
        journal fixture: OCRProcessor.PendingBatch,
        repeatCall: Bool = false,
        disturb: () -> Void = {}
    ) async -> LateChunk {
        let fm = FileManager.default
        // The real writer, at the shipped (redirected) path — this is the file Resume would read.
        OCRProcessor.savePendingBatch(fixture)

        let processor = OCRProcessor()
        var deleterCalls = 0
        processor.makeBatchChunkCanceller = { _ in
            OCRProcessor.BatchChunkCanceller(provider: .gemini, cancelChunk: { _ in true },
                                             clientTypeName: "stub")
        }
        processor.makeBatchJournalDeleter = { _ in
            { deleterCalls += 1; OCRProcessor.deletePendingBatch() }
        }
        processor.activeBatch = context()
        processor.activePendingBatch = fixture
        processor.batchPollInterrupted = false
        processor.isProcessing = true
        let sentinel = "closed-append-sentinel-\(UUID().uuidString)"
        processor.statusMessage = sentinel
        // A real, live run task so "did it cancel the run?" is measured. `cancel()` cancels it itself; what
        // is being watched is whether the LATE CHUNK's reporter cancels a task it no longer owns.
        let run = Task<Void, Never> { try? await Task.sleep(for: .seconds(30)) }
        processor.processingTask = run

        let started = Date()
        processor.cancel()
        let stopReturned = Date().timeIntervalSince(started)

        disturb()
        // Exactly the shape of a create whose response came back after the Stop: the submit loop is still
        // unwinding on its own task, and calls the same mutator it always calls.
        processor.statusMessage = sentinel
        let cancelledBefore = run.isCancelled
        let returned = processor.recordSubmittedBatchChunk(chunkId)
        if repeatCall { _ = processor.recordSubmittedBatchChunk(chunkId) }
        let message = processor.statusMessage
        let flagged = processor.batchPollInterrupted
        let stopped = !processor.isProcessing
        let closed = processor.activePendingBatch == nil
        // The reporter may not cancel the run task — but `cancel()` already did, so the question is only
        // meaningful as "did it cancel one that was still alive", which this fixture cannot have. Measured
        // against the pre-call state so a future edit that hands the reporter a live task is still caught.
        let cancelledByReporter = run.isCancelled && !cancelledBefore

        await processor.batchCancellationTask?.value
        run.cancel()

        let bytes = try? Data(contentsOf: OCRProcessor.pendingBatchURL)
        let decoded = bytes.flatMap { try? JSONDecoder().decode(OCRProcessor.PendingBatch.self, from: $0) }
        try? fm.removeItem(at: OCRProcessor.pendingBatchURL)
        _ = deleterCalls

        return LateChunk(
            returned: returned, onDisk: decoded, bytes: bytes,
            journalStillClosedInMemory: closed,
            flaggedInterrupted: flagged, stoppedProcessing: stopped,
            explainedItself: message != sentinel && !message.isEmpty,
            cancelledTheRun: cancelledByReporter, elapsed: stopReturned)
    }

    // MARK: - 1. The bug: a job that was paid for, recorded nowhere

    private static func aLateChunkIdReachesTheJournalStopClosed(_ check: (String, Bool) -> Void) async {
        let late = "batches/created-as-stop-landed"
        let result = await stopThenRecord(late, journal: journal())

        // THE regression check. Before W16.bat5-fu the on-disk list was `["batches/chunk-0"]` and this ID
        // existed only in memory, in a count used to warn about it.
        check("closed-journal append: a chunk created as Stop landed is APPENDED to the journal cancel() "
              + "closed — the paid job has a local record instead of only a warning",
              result.onDisk?.submittedChunkIds == ["batches/chunk-0", late])
        // The list is what `resumeBatch` polls from, via `effectiveChunkIds` — pinned through that accessor
        // as well, so an append that landed in a field Resume does not read would not pass.
        check("closed-journal append: and Resume reads it — the ID is in `effectiveChunkIds`, not merely in "
              + "a field nothing polls",
              result.onDisk?.effectiveChunkIds.contains(late) == true)

        // The other half of the property, and the one that costs money if it is ever "fixed": recording the
        // ID must not turn a Stop into a licence to keep submitting.
        check("closed-journal append: it still returns false, so the submit loop still throws and stops "
              + "creating paid jobs — Stop is not answered by continuing to spend",
              !result.returned)
        check("closed-journal append: the run is still reported interrupted, stopped and explained — "
              + "recording the ID did not turn an interruption into a silent success",
              result.flaggedInterrupted && result.stoppedProcessing && result.explainedItself)
        check("closed-journal append: and it neither reopens the journal in memory nor cancels a run task "
              + "that is no longer this run's",
              result.journalStillClosedInMemory && !result.cancelledTheRun)

        // A retried callback must not double-list a job that is already recorded.
        let twice = await stopThenRecord(late, journal: journal(), repeatCall: true)
        check("closed-journal append: recording the same ID twice lists it once — a retried callback does "
              + "not make Resume poll the same paid job twice",
              twice.onDisk?.submittedChunkIds == ["batches/chunk-0", late])
    }

    // MARK: - 2. Additive only (the owner's ⛔): the journal may only ever GAIN

    /// The direction that loses money if it goes wrong. An append that rewrote the journal from the snapshot
    /// `cancel()` held would silently roll back everything the file gained after the Stop — completed
    /// results, consumed chunks — and Resume would re-download and re-pay for pages it already has.
    private static func theAppendIsAdditiveAndNothingElseMoves(_ check: (String, Bool) -> Void) async {
        let fixture = journal(chunkIds: ["batches/chunk-0", "batches/chunk-1"])
        // A second durable file, so "it wrote to exactly one journal" is measured rather than assumed.
        let runManifest = OCRProcessor.pendingRunURL
        let runBytes = Data(#"{"sentinel":"closed-append-run-manifest"}"#.utf8)
        try? runBytes.write(to: runManifest, options: .atomic)

        var before: Data?
        let result = await stopThenRecord("batches/late", journal: fixture) {
            before = try? Data(contentsOf: OCRProcessor.pendingBatchURL)
        }
        let runIntact = (try? Data(contentsOf: runManifest)) == runBytes
        try? FileManager.default.removeItem(at: runManifest)

        // Everything except the appended list and the two values the production writer DERIVES from it (the
        // comma-joined mirror and the lifecycle fingerprint) must be byte-identical.
        let derived: Set<String> = ["submittedChunkIds", "batchId", "lifecycleFingerprint"]
        func stripped(_ data: Data?) -> NSDictionary? {
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return NSDictionary(dictionary: object.filter { !derived.contains($0.key) })
        }
        let unchanged = stripped(before) != nil && stripped(before) == stripped(result.bytes)

        check("closed-journal append: every field the append does not own is byte-identical — a paid batch's "
              + "completed results and consumed chunks cannot be rolled back by a stale snapshot", unchanged)
        check("closed-journal append: the existing IDs keep their order and their place; the late one is "
              + "added at the end",
              result.onDisk?.submittedChunkIds == ["batches/chunk-0", "batches/chunk-1", "batches/late"])
        check("closed-journal append: the submission is still recorded as unfinished, so the journal stays "
              + "the 'may be short' kind Stop must never delete",
              result.onDisk?.submissionComplete == false)
        check("closed-journal append: and the interrupted-RUN manifest is untouched — one journal was "
              + "written, not whatever else was in the directory", runIntact)
    }

    // MARK: - 3. The refusals: what it must NOT write

    private static func itRefusesEveryJournalThatIsNotThisOne(_ check: (String, Bool) -> Void) async {
        let fm = FileManager.default

        // (a) No file. A confirmed cancellation deletes the journal; re-creating it here would put a Resume
        // banner back up for a batch that really was cancelled — and `startProcessing` refuses to start a new
        // run while one exists, so the operator would be locked out by a ghost.
        let deleted = await stopThenRecord("batches/late", journal: journal()) {
            OCRProcessor.deletePendingBatch()
        }
        check("closed-journal append: with no journal on disk it creates none — a cancelled batch does not "
              + "get its Resume banner resurrected",
              deleted.bytes == nil && !fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path))
        check("closed-journal append: and that case still reports the interruption the old way, so a lost ID "
              + "is never a quiet one",
              !deleted.returned && deleted.flaggedInterrupted && deleted.explainedItself)

        // (b) A DIFFERENT batch's journal. After a delete the operator may have started another run; adding a
        // stranger's server job ID to a live batch's journal would have its poll fetch another run's pages.
        let other = journal(chunkIds: ["batches/other-run-0"], fingerprint: "a-different-run",
                            submittedAt: Date(timeIntervalSince1970: 1_000_000))
        var otherBytes: Data?
        let foreign = await stopThenRecord("batches/late", journal: journal()) {
            OCRProcessor.savePendingBatch(other)
            otherBytes = try? Data(contentsOf: OCRProcessor.pendingBatchURL)
        }
        check("closed-journal append: a journal that is NOT this batch's is left byte-identical — a late ID "
              + "is never grafted onto another run's paid batch",
              otherBytes != nil && foreign.bytes == otherBytes
              && foreign.onDisk?.submittedChunkIds == ["batches/other-run-0"])

        // (c) A legacy (pre-lifecycle) journal reads its IDs from the comma-joined `batchId`, so an append to
        // `submittedChunkIds` would be written and never read back. Refuse rather than pretend.
        //
        // ⚠️ The stamp is SHARED with the batch that was stopped, deliberately. Give the legacy journal a
        // `submittedAt` of its own and the identity guard refuses it first — the check then passes without
        // the lifecycle guard existing at all (measured: deleting that guard left this green).
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = journal(chunkIds: ["batches/legacy-0"], submittedAt: stamp, lifecycleVersion: nil)
        var legacyBytes: Data?
        let old = await stopThenRecord("batches/late", journal: journal(submittedAt: stamp)) {
            OCRProcessor.savePendingBatch(legacy)
            legacyBytes = try? Data(contentsOf: OCRProcessor.pendingBatchURL)
        }
        check("closed-journal append: a legacy journal is left byte-identical rather than given an ID it "
              + "would never read back",
              legacyBytes != nil && old.bytes == legacyBytes)
    }

    // MARK: - 4. It is only ever the CLOSED journal's writer

    /// Without this, an append that ignored `activePendingBatch` would satisfy every section above while
    /// writing behind the back of a live run — two writers for one file, and the in-memory journal silently
    /// stale the moment the disk one moved.
    /// ⚠️ Both halves put a MATCHING journal on disk first. Without it the append refuses because the file is
    /// not there, and the two checks stay green with the guard they are named for deleted (the same
    /// wrong-reason trap section 3(c) records).
    private static func theLiveJournalIsNotItsToWrite(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let subject = journal(submittedAt: Date(timeIntervalSince1970: 1_700_000_001))
        func withJournalOnDisk(_ body: (OCRProcessor) -> Bool) -> (refused: Bool, intact: Bool) {
            OCRProcessor.savePendingBatch(subject)
            let before = try? Data(contentsOf: OCRProcessor.pendingBatchURL)
            let refused = !body(OCRProcessor())
            let after = try? Data(contentsOf: OCRProcessor.pendingBatchURL)
            try? fm.removeItem(at: OCRProcessor.pendingBatchURL)
            return (refused, before != nil && before == after)
        }

        let live = withJournalOnDisk { processor in
            processor.activePendingBatch = subject
            processor.closedPaidBatchJournalAddress = OCRProcessor.ClosedPaidBatchJournalAddress(subject)
            return processor.appendChunkIdToClosedPaidBatchJournal("batches/late")
        }
        check("closed-journal append: with a LIVE journal in memory it refuses and writes nothing, address "
              + "or no address — the normal persist path owns that file", live.refused && live.intact)

        let unaddressed = withJournalOnDisk { processor in
            processor.activePendingBatch = nil
            processor.closedPaidBatchJournalAddress = nil
            return processor.appendChunkIdToClosedPaidBatchJournal("batches/late")
        }
        check("closed-journal append: and with no address it refuses too, leaving the journal byte-identical "
              + "— only a real Stop opens this path, not merely a journal lying on disk",
              unaddressed.refused && unaddressed.intact)
    }

    // MARK: - 5. "Resume can pick it up" is the app's own verdict, not this file's

    /// Found by the adversarial pass on the fix, and the gap between "the ID is in the file" and the claim
    /// the operator is actually given. `checkForPendingBatch()` runs every journal it finds through
    /// `pendingBatchIsSelfConsistent`, and an inconsistent one is NOT offered for resume — it raises the
    /// torn/tampered warning instead. So an append that wrote the ID and left the journal's own integrity
    /// fields stale would satisfy every check above and still leave the paid job uncollectable.
    ///
    /// Three of that guard's clauses are ones an append can break: the comma-joined `batchId` mirror must
    /// equal the joined list, the IDs must be duplicate-free, and the lifecycle fingerprint must be the one
    /// recomputed over the journal as a whole. The production writer maintains all three — which is exactly
    /// why the append goes through it instead of encoding the struct itself.
    private static func theAppendedJournalIsOneResumeAccepts(_ check: (String, Bool) -> Void) async {
        let fixture = resumableJournal(submittedAt: Date(timeIntervalSince1970: 1_700_000_002))
        // A fixture whose fingerprint is wrong to begin with would make this vacuous: the guard would fail
        // before and after, or pass for a reason the append cannot affect. Pin the starting point — as the
        // journal is WRITTEN, since the lifecycle fingerprint the guard checks is one the writer computes
        // (an unpersisted struct carries none and is never self-consistent).
        let asWritten = OCRProcessor.preparedPendingBatchForPersistence(fixture)
        check("closed-journal append: (precondition) the fixture is a journal the resume guard accepts "
              + "BEFORE anything is appended",
              asWritten.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false)

        let result = await stopThenRecord("batches/late", journal: fixture)
        let accepted = result.onDisk.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false
        check("closed-journal append: the appended journal still passes the app's own resume guard — the ID "
              + "is not just in the file, the file is still one Resume will offer",
              accepted && result.onDisk?.submittedChunkIds.contains("batches/late") == true)
        check("closed-journal append: and its derived comma-joined mirror was recomputed with it, so the "
              + "journal does not disagree with itself about which jobs were paid for",
              result.onDisk?.batchId == result.onDisk?.submittedChunkIds.joined(separator: ","))
    }

    // MARK: - 6. The owner's ⛔: Stop stays instant

    /// The owner rejected "wait for in-flight submits to quiesce before nilling `activePendingBatch`"
    /// precisely because it makes Stop non-instant — a hung provider request would stall the teardown. This
    /// fix must not reintroduce that by another route, so the constraint is MEASURED rather than argued from
    /// reading `cancel()` for `await`s.
    private static func stopStaysInstant(_ check: (String, Bool) -> Void) async {
        let result = await stopThenRecord("batches/late", journal: journal())
        // Generous by two orders of magnitude on purpose: `cancel()` contains no suspension point, so the
        // real number is microseconds. Anything that awaits a provider request lands in seconds.
        check("closed-journal append: Stop still returns immediately (\(Int(result.elapsed * 1000))ms) — "
              + "keeping the journal addressable added no wait to the teardown",
              result.elapsed < 1.0)
    }
}
