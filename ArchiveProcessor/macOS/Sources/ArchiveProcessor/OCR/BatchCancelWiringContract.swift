import Foundation

/// **Cancel-path WIRING contract for the paid batch path** (W16.bat2-fu) — headless, $0, no network, no
/// keys. Drives the REAL `OCRProcessor.cancel()` with its two cancel-path seams stubbed, so what is pinned
/// here is not the rule but the *arguments*: which jobs `cancel()` asks to cancel, with which provider's
/// client, which durable journal it is willing to delete, and whether the operator is told.
///
/// Why this exists: `BatchCancelContract` (W16.bat2) proves `performServerBatchCancellation` — the rule that
/// the recovery journal is deleted only on a fully confirmed cancellation. Nothing proved that `cancel()`
/// *feeds that rule the truth*. Five separate mutations to the cancel block left all 189 of those checks
/// green: dropping the status-message assignment (the operator gets no warning that a paid job may still be
/// running), neutering the deleter, hard-coding the provider, changing the chunk-ID derivation (cancels the
/// wrong paid jobs, or none, while the operator is told the batch was stopped), and deleting the whole block.
/// Each of those is a silent money loss, so each gets a check below.
///
/// The named scenarios come first, each chosen because some specific mutation survives without it;
/// `sweepEveryShape` then presses Stop on the whole cross-product (every provider × 0–3 acknowledged
/// chunks × journal-present × each chunk refused in turn — 80 Stops) and demands an exact outcome from
/// each, which is what covers the shapes nobody thought to name (W16.bat2-fu3).
///
/// **How it stays $0 and can never touch the operator's real state.** Every `cancel()` here is driven by
/// `stop(…)`, the only place in this file that cancels anything, and it always replaces BOTH seams before the
/// batch is installed: `makeBatchChunkCanceller` (a recording stub — no client, no request) and
/// `makeBatchJournalDeleter` (records which journal was *asked for*, and deletes a temp fixture instead of the
/// real `pending_batch.json`). Nothing suspends between those assignments and `cancel()`, so no cancellation
/// can start with a default seam installed, and the production deleter — `OCRProcessor.deletePendingBatch()`
/// — is executed by no check here. (Where it IS executed, on purpose and against a redirected path, is
/// section 16: `BatchJournalPathContract`.) `defaultSeamsAreTheLiveOnes` builds one more processor to inspect
/// the *defaults*, but never cancels on it and never invokes the deleter it returns; `theSeamNamesOneJournal`
/// and `theLiveCancellerIsTheBatchsOwnClient` press no Stop at all.
///
/// ⚠️ **SCOPE — read before citing this file.** What is *not* covered, precisely:
///   * This is the wiring, not the rule (that is `BatchCancelContract`) and not the whole Stop path. The
///     poll unwinding alongside `cancel()` used to delete the journal regardless of what `cancel()` had
///     decided, and nothing here could see it — that was **W16.bat3**, now fixed and pinned by
///     `BatchPollCancelContract` (section 17). Cite the two together for the whole Stop path.
///   * **The default deleter's body is run by no check HERE** — every scenario in this file replaces the
///     seam. It is no longer unverified, though: since W16.bat2-fu2 the journal directory is redirectable
///     under test, and `BatchJournalPathContract` (section 16) runs the shipped deleter against a real
///     journal file in the harness's own temp directory.
///   * A confirmed cancellation may delete exactly one durable file, and the seam lets it name only that
///     one (`BatchCancellationJournal` has a single case, tripwired below). A future edit that bolts an
///     *extra*, un-seamed deletion beside it (`deletePendingRun()`, say) is a new defect **this file**
///     cannot see — the seam records what was asked for, not everything the block does. Section 16 is where
///     that is caught instead: it presses Stop with the real deleter installed and asserts the
///     interrupted-run manifest is still byte-identical afterwards.
///   * The kept-journal warning is proven **assigned** here, not **survived**: these scenarios have no live
///     `processingTask`, whereas a real Stop also cancels the run, which writes `statusMessage` of its own
///     on the way out. That the warning is the message left standing afterwards is W16.bat6, pinned by
///     `BatchPollCancelContract` section 5 — the one place that presses Stop with a live `processingTask`.
///   * `cancel()`'s own `checkForPendingBatch()` runs for real. It never deletes either manifest, and since
///     W16.bat2-fu2 it reads the harness's redirected state directory rather than the operator's Application
///     Support state — but it still recomputes two `@Published` banner strings from whatever is there, so the
///     checks below assert only that the refresh *ran*, never what it found.
///
/// Run from `BatchResumeTestDriver` (section 14) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchCancelWiringContract {

    static func run(check: (String, Bool) -> Void) async {
        theSeamNamesOneJournal(check)
        await theLiveCancellerIsTheBatchsOwnClient(check)
        defaultSeamsAreTheLiveOnes(check)
        await anUnconfirmedStop(check)
        await aConfirmedStop(check)
        await aStopWhileTheSubmissionIsStillInFlight(check)
        await aSingleJobProviderStop(check)
        await whichJobsGetCancelled(check)
        await nothingToCancel(check)
        await stopPressedTwice(check)
        await sweepEveryShape(check)
    }

    // MARK: - Fixtures

    /// Everything the stubbed seams recorded during one `cancel()`, plus the fate of the temp file standing
    /// in for the recovery journal. A class so the recording survives the seam's suspension points
    /// unambiguously; MainActor-isolated because that is where the whole cancel path runs.
    @MainActor
    private final class Wiring {
        /// The `BatchContext` values `cancel()` handed the canceller factory (one per cancellation).
        var contexts: [OCRProcessor.BatchContext] = []
        /// Which durable journals `cancel()` asked for a deleter for.
        var journalsAsked: [OCRProcessor.BatchCancellationJournal] = []
        /// Chunk IDs a server-side cancellation was actually attempted for, recorded by the stub client.
        var attempted: [String] = []
        /// How many times the returned deleter ran. Must be 0 or 1 — never twice.
        var deleteCalls = 0
    }

    /// One recorded Stop.
    private struct Stop {
        let wiring: Wiring
        /// Was the journal fixture really on disk before `cancel()`? (A "kept" verdict is worthless if the
        /// file was never written.)
        let fixtureExistedBefore: Bool
        /// Is it still there afterwards?
        let fixtureSurvived: Bool
        /// `statusMessage` after the spawned cancellation task finished.
        let statusMessage: String
        /// Was `activeBatch` already nil the instant `cancel()` returned, before the task ran?
        let batchClearedSynchronously: Bool
        /// Was `activePendingBatch` cleared too?
        let journalStateCleared: Bool
        /// Did `cancel()` spawn a server-side cancellation at all?
        let spawnedCancellation: Bool
        /// Was the resume-banner state recomputed (`checkForPendingBatch()`) by the time the cancellation
        /// finished? Detected with a sentinel, so it holds whether or not the operator has a real journal.
        let bannerRefreshed: Bool
    }

    /// Which batch client each provider's arm of `liveBatchChunkCanceller` must close over — named here,
    /// constructed there, so the comparison is between two independent statements rather than a literal
    /// against itself.
    private static func expectedClientTypeName(_ provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return String(describing: AnthropicBatchClient.self)
        case .mistral: return String(describing: MistralBatchClient.self)
        case .gemini: return String(describing: GeminiBatchClient.self)
        case .openai: return "none"   // no batch path in v1, so no client to build
        }
    }

    /// A synthetic model — never sent anywhere. Built by hand rather than read from `provider.models` so no
    /// check depends on `CustomModelStore`/UserDefaults.
    private static func model(_ provider: LLMProvider) -> LLMModel {
        LLMModel(id: "wiring-\(provider.rawValue.lowercased())",
                 displayName: "Wiring \(provider.rawValue)",
                 provider: provider, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    private static func context(_ provider: LLMProvider, batchId: String) -> OCRProcessor.BatchContext {
        OCRProcessor.BatchContext(batchId: batchId, apiKey: "wiring-not-a-key",
                                  model: model(provider), thinkingLevel: .high, provider: provider)
    }

    /// A v1 paid-batch journal that acknowledges `chunkIds` server-side jobs. `submissionComplete` defaults
    /// to true — a batch that finished submitting — because that is the shape every scenario written before
    /// W16.bat5 assumed; pass `false` for the mid-submit shape, where the acknowledged list may not be the
    /// whole batch.
    private static func journal(_ provider: LLMProvider,
                                batchId: String,
                                chunkIds: [String],
                                submissionComplete: Bool = true) -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: batchId, provider: provider, model: model(provider), thinkingLevel: .high,
            fileURLs: [], outputDirectory: FileManager.default.temporaryDirectory,
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: chunkIds, submissionComplete: submissionComplete)
    }

    private static func ids(_ n: Int) -> [String] { (0..<n).map { "batches/chunk-\($0)" } }

    private static func sameContext(_ recorded: OCRProcessor.BatchContext,
                                   _ expected: OCRProcessor.BatchContext) -> Bool {
        recorded.batchId == expected.batchId && recorded.apiKey == expected.apiKey
            && recorded.model == expected.model && recorded.thinkingLevel == expected.thinkingLevel
            && recorded.provider == expected.provider
    }

    /// Press Stop once (twice when `again` is true) on a processor whose cancel-path seams are stubbed.
    ///
    /// THE ONLY constructor of an `OCRProcessor` in this file: both seams are replaced here, together, so no
    /// scenario can reach the real deleter by forgetting one.
    private static func stop(batch: OCRProcessor.BatchContext?,
                             pendingBatch: OCRProcessor.PendingBatch? = nil,
                             refusing: Set<String> = [],
                             again: Bool = false) async -> Stop {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory
            .appendingPathComponent("APCancelWiring-\(UUID().uuidString).json")
        try? Data(#"{"batchId":"paid-job","fileURLs":[]}"#.utf8).write(to: fixture)
        let existedBefore = fm.fileExists(atPath: fixture.path)

        let wiring = Wiring()
        let processor = OCRProcessor()
        processor.makeBatchChunkCanceller = { context in
            wiring.contexts.append(context)
            // The provider is read off the context on purpose: the rule `cancel()` gets applied has to be
            // the one belonging to the batch it was called for, and this records which that was.
            return OCRProcessor.BatchChunkCanceller(provider: context.provider, cancelChunk: { chunkId in
                wiring.attempted.append(chunkId)
                return !refusing.contains(chunkId)
            }, clientTypeName: "stub")
        }
        processor.makeBatchJournalDeleter = { asked in
            wiring.journalsAsked.append(asked)
            return {
                wiring.deleteCalls += 1
                try? fm.removeItem(at: fixture)
            }
        }
        processor.activeBatch = batch
        processor.activePendingBatch = pendingBatch
        // A sentinel in the resume-banner field. `cancel()`'s cancellation task ends by recomputing it from
        // disk (`checkForPendingBatch()`) — the operator's only on-screen pointer to a paid job that may
        // still be running — so "was it replaced?" detects that refresh without depending on what is on the
        // operator's disk. A Stop with nothing to cancel must leave the sentinel alone.
        let sentinel = "wiring-sentinel-\(UUID().uuidString)"
        processor.pendingBatchInfo = sentinel

        processor.cancel()
        // Sampled BEFORE awaiting: the live batch identity must be dropped synchronously, or a second Stop
        // (or a resume) could act on a batch whose cancellation is already in flight. This sampling is
        // meaningful only because `cancel()` contains no `await` — the spawned task cannot start until it
        // returns. Introduce a suspension point into `cancel()` and these three samples quietly change
        // meaning rather than failing, so read this comment before adding one.
        let batchCleared = processor.activeBatch == nil
        let journalCleared = processor.activePendingBatch == nil
        let spawned = processor.batchCancellationTask != nil
        await processor.batchCancellationTask?.value
        if again {
            processor.cancel()
            await processor.batchCancellationTask?.value
        }

        let survived = fm.fileExists(atPath: fixture.path)
        try? fm.removeItem(at: fixture)
        return Stop(wiring: wiring, fixtureExistedBefore: existedBefore, fixtureSurvived: survived,
                    statusMessage: processor.statusMessage,
                    batchClearedSynchronously: batchCleared, journalStateCleared: journalCleared,
                    spawnedCancellation: spawned,
                    bannerRefreshed: processor.pendingBatchInfo != sentinel)
    }

    // MARK: - The seam's own names (tripwires, no Stop involved)

    private static func theSeamNamesOneJournal(_ check: (String, Bool) -> Void) {
        // If a second journal case is ever added, the claim "a confirmed cancellation may remove exactly one
        // durable file" stops being true and every check below has to be re-read rather than trusted.
        check("wiring: exactly one durable file may be removed by a confirmed cancellation",
              OCRProcessor.BatchCancellationJournal.allCases.count == 1)
        check("wiring: that file is the paid-batch journal — not the interrupted-run manifest",
              OCRProcessor.BatchCancellationJournal.paidBatchJournal.fileName == OCRProcessor.pendingBatchFileName
              && OCRProcessor.pendingBatchFileName != OCRProcessor.pendingRunFileName
              && OCRProcessor.BatchCancellationJournal.paidBatchJournal.fileName != OCRProcessor.pendingRunFileName)

    }

    // MARK: - The live canceller: the right client, not just the right label

    /// The stub factory used by every Stop below bypasses the live one, so pin the live one directly. Both
    /// halves matter and only one of them is cheap: `provider` is passed as a literal at the construction
    /// site, so checking it catches a hard-coded label and nothing else. `clientTypeName` is read off the
    /// client that was really built, so it catches the case that actually costs money — the right label in
    /// front of another provider's client, or an arm short-circuited to always "confirm".
    private static func theLiveCancellerIsTheBatchsOwnClient(_ check: (String, Bool) -> Void) async {
        var labelledCorrectly = true
        var closedOverItsOwnClient = true
        for provider in LLMProvider.allCases {
            let built = OCRProcessor.liveBatchChunkCanceller(for: context(provider, batchId: "batches/x"))
            if built.provider != provider { labelledCorrectly = false }
            if built.clientTypeName != expectedClientTypeName(provider) { closedOverItsOwnClient = false }
        }
        check("wiring: the live canceller is labelled with the batch's OWN provider (all \(LLMProvider.allCases.count))",
              labelledCorrectly)
        check("wiring: and it closes over THAT provider's batch client, not another's (all \(LLMProvider.allCases.count))",
              closedOverItsOwnClient)

        // The only arm whose closure can be run for free: OpenAI has no batch path in v1, so its canceller is
        // a literal `false` — invoking it opens no connection and confirms nothing. Guarded on
        // `supportsBatch` so that if a real OpenAI batch path ever lands, this reddens (demanding a rewrite)
        // instead of quietly making a network call from a $0 suite.
        var refusesWithoutANetwork = false
        if !LLMProvider.openai.supportsBatch {
            let built = OCRProcessor.liveBatchChunkCanceller(for: context(.openai, batchId: "batches/x"))
            refusesWithoutANetwork = await built.cancelChunk("batches/x") == false
        }
        check("wiring: the provider with no batch path confirms nothing, and needs no network to say so",
              !LLMProvider.openai.supportsBatch && refusesWithoutANetwork)
    }

    // MARK: - The seams' DEFAULT values (what production actually gets)

    /// Every Stop below replaces both seams, which leaves their defaults — the values the shipped app uses —
    /// covered by nothing. Half of that is checkable here: the default canceller factory must route to the
    /// live one. The other half is checked in section 16 instead (`BatchJournalPathContract`), which is
    /// where the journal path is redirected; this file asks for a deleter and drops it unrun.
    private static func defaultSeamsAreTheLiveOnes(_ check: (String, Bool) -> Void) {
        // A processor that is never cancelled and never has an `activeBatch`, so no cancellation — and hence
        // no deletion — can start on it.
        let untouched = OCRProcessor()
        var defaultsToTheLiveFactory = true
        for provider in LLMProvider.allCases {
            let built = untouched.makeBatchChunkCanceller(context(provider, batchId: "batches/x"))
            if built.provider != provider
                || built.clientTypeName != expectedClientTypeName(provider) { defaultsToTheLiveFactory = false }
        }
        check("wiring: a processor's DEFAULT canceller factory is the live one, for every provider",
              defaultsToTheLiveFactory)
        // Deliberately no companion check on the default DELETER: the only way to observe what it does is to
        // run it, and this file's whole safety argument is that it never does. That check lives in section
        // 16 (`BatchJournalPathContract`), which redirects the journal directory first (W16.bat2-fu2).
    }

    // MARK: - A Stop the provider did not fully confirm: the journal survives and the operator hears it

    private static func anUnconfirmedStop(_ check: (String, Bool) -> Void) async {
        let chunkIds = ids(3)
        let batch = context(.gemini, batchId: "batches/received-id")
        let stopped = await stop(batch: batch,
                                 pendingBatch: journal(.gemini, batchId: "batches/received-id", chunkIds: chunkIds),
                                 refusing: [chunkIds[1]])

        check("wiring: cancel() hands the canceller factory the live batch's own context, once",
              stopped.wiring.contexts.count == 1
              && stopped.wiring.contexts.first.map { sameContext($0, batch) } == true)
        check("wiring: cancel() asks for a deleter for the paid-batch journal, and only that one",
              stopped.wiring.journalsAsked == [.paidBatchJournal])
        check("wiring: every acknowledged chunk of the batch is attempted",
              stopped.wiring.attempted == chunkIds)
        // The mutation this kills: `deleteJournal: { }`. The deleter is real here (it removes a real temp
        // file), so "not deleted" is a file that is still on disk, not an unexercised closure.
        check("wiring: an unconfirmed cancellation never runs the deleter — the journal file is still there",
              stopped.wiring.deleteCalls == 0 && stopped.fixtureExistedBefore && stopped.fixtureSurvived)
        // The mutation this kills: dropping `if let message = outcome.statusMessage { statusMessage = message }`
        // — the one signal that a paid job may still be running server-side.
        check("wiring: the operator is told the journal was kept, in the shipped words, verbatim",
              stopped.statusMessage == OCRProcessor.batchCancellationNotConfirmedMessage)
        // The kept-journal message is not the only thing the operator needs: the resume banner is what points
        // at the still-live paid job after the message scrolls away. Dropping `checkForPendingBatch()` from
        // the cancellation task would leave it stale until the next relaunch.
        check("wiring: the resume-banner state is recomputed once the cancellation finishes",
              stopped.bannerRefreshed)
    }

    // MARK: - A Stop the provider confirmed: the journal goes, and is never announced as kept

    private static func aConfirmedStop(_ check: (String, Bool) -> Void) async {
        let chunkIds = ids(2)
        let stopped = await stop(batch: context(.gemini, batchId: "batches/received-id"),
                                 pendingBatch: journal(.gemini, batchId: "batches/received-id", chunkIds: chunkIds))

        check("wiring: a confirmed cancellation runs the asked-for deleter exactly once, and the file is gone",
              stopped.wiring.journalsAsked == [.paidBatchJournal]
              && stopped.wiring.deleteCalls == 1
              && stopped.fixtureExistedBefore && !stopped.fixtureSurvived)
        // Not the mirror of the check above: this is what stops a future edit from "fixing" the missing
        // warning by assigning it unconditionally, which would claim a journal was kept that is now gone.
        check("wiring: a confirmed cancellation does not claim the journal was kept",
              !stopped.statusMessage.contains("kept for recovery")
              && stopped.statusMessage != OCRProcessor.batchCancellationNotConfirmedMessage
              && stopped.statusMessage.hasPrefix("Cancelled."))
    }

    // MARK: - A Stop that landed mid-submit: confirmed, and the journal still survives (W16.bat5)

    /// The wiring half of the in-flight guard. `BatchCancelContract` proves the RULE obeys a
    /// `submissionInFlight: true`; nothing there proves `cancel()` ever passes `true`. The mutation this
    /// kills is the whole fix reduced to a no-op: hard-code `submissionInFlight: false` at the call site
    /// (or drop the argument's derivation) and every check in the rule contract stays green while a Stop
    /// mid-submit deletes the journal exactly as it did before.
    ///
    /// The shape is the money one: a Gemini batch whose journal acknowledges three chunks, every one of
    /// which the provider confirms cancelled, and whose `submissionComplete` is still `false` — i.e. the
    /// submit loop had not finished, so a fourth chunk may already have been created and billed. Before
    /// W16.bat5 this deleted the fixture.
    private static func aStopWhileTheSubmissionIsStillInFlight(_ check: (String, Bool) -> Void) async {
        let chunkIds = ids(3)
        let batch = context(.gemini, batchId: "batches/received-id")
        let midSubmit = await stop(
            batch: batch,
            pendingBatch: journal(.gemini, batchId: "batches/received-id", chunkIds: chunkIds,
                                  submissionComplete: false))

        check("wiring: a Stop mid-submit keeps the paid-batch journal even though every known chunk confirmed",
              midSubmit.wiring.journalsAsked == [.paidBatchJournal]
              && midSubmit.wiring.deleteCalls == 0
              && midSubmit.fixtureExistedBefore && midSubmit.fixtureSurvived)
        // The cancellations are not skipped — a guard that returned early would keep the journal by leaving
        // three paid jobs running, which is a worse bug than the one being fixed.
        check("wiring: and it still cancels every chunk the journal had acknowledged",
              midSubmit.wiring.attempted == chunkIds
              && midSubmit.wiring.contexts.count == 1
              && midSubmit.wiring.contexts.first.map { sameContext($0, batch) } == true)
        check("wiring: the operator is told a paid job may exist beyond the ones that were stopped",
              midSubmit.statusMessage == OCRProcessor.batchCancellationSubmissionInFlightMessage
              && midSubmit.bannerRefreshed)

        // Non-vacuity, and the whole regression in one comparison: the SAME Stop with `submissionComplete`
        // true — the only difference — still deletes. Without this pair, "keeps the journal" would also be
        // satisfied by a cancel path that had simply stopped deleting anything.
        let finished = await stop(
            batch: context(.gemini, batchId: "batches/received-id"),
            pendingBatch: journal(.gemini, batchId: "batches/received-id", chunkIds: chunkIds))
        check("wiring: the submission marker is the ONLY thing that changed — the finished twin still deletes",
              finished.wiring.deleteCalls == 1 && finished.fixtureExistedBefore && !finished.fixtureSurvived
              && finished.wiring.attempted == midSubmit.wiring.attempted)

        // `cancel()` must read the in-flight fact from the journal it is about to drop, not re-derive it
        // later: by the time the cancellation task runs, `activePendingBatch` is nil, and the predicate
        // answers "nothing in flight" for want of a journal to read — the deleting direction. Pinned by
        // driving the pure derivation over the same two journals the two Stops above used.
        check("wiring: the in-flight answer comes from the journal's own submission marker",
              OCRProcessor.batchSubmissionIsInFlight(
                  journal(.gemini, batchId: "batches/received-id", chunkIds: chunkIds,
                          submissionComplete: false))
              && !OCRProcessor.batchSubmissionIsInFlight(
                  journal(.gemini, batchId: "batches/received-id", chunkIds: chunkIds)))
    }

    // MARK: - A provider that cancels one server-side job, not several

    /// Every other scenario here is Gemini (the multi-chunk provider). Without this one, a change that gated
    /// the whole cancel block on `batch.provider == .gemini` would leave all of them green while a
    /// single-chunk Anthropic or Mistral batch was silently never cancelled and never warned about.
    private static func aSingleJobProviderStop(_ check: (String, Bool) -> Void) async {
        var wiredForBoth = true
        for provider in [LLMProvider.anthropic, .mistral] {
            let one = ids(1)
            let batch = context(provider, batchId: "batches/received-id")
            let stopped = await stop(batch: batch,
                                     pendingBatch: journal(provider, batchId: "batches/received-id",
                                                           chunkIds: one))
            let wired = stopped.wiring.contexts.count == 1
                && stopped.wiring.contexts.first.map { sameContext($0, batch) } == true
                && stopped.wiring.attempted == one
                && stopped.wiring.journalsAsked == [.paidBatchJournal]
                && stopped.wiring.deleteCalls == 1
                && stopped.fixtureExistedBefore && !stopped.fixtureSurvived
                && stopped.bannerRefreshed
            if !wired { wiredForBoth = false }
        }
        check("wiring: a single-job provider's paid batch is cancelled through the same wiring (anthropic, mistral)",
              wiredForBoth)

        // The shape above is the one that WORKS. This is the one that must fail safe: an Anthropic/Mistral
        // batch whose journal acknowledges SEVERAL server-side jobs. Those clients cancel exactly one, so
        // there is no single ID to cancel and the rule declines to try — which makes the journal the only
        // way back to jobs that are still running and still being paid for. The wiring's job in that shape
        // is to keep it and say so, and it is easy to get wrong in the plausible direction: "cancel the
        // first one" (leaves the rest live while the journal is deleted as confirmed) or "cancel them all"
        // (each request is against a job ID the client's endpoint does not accept). Neither shows up in the
        // single-chunk arm above.
        //
        // Unlike the other named scenarios, this shape IS also inside `sweepEveryShape` (anthropic/mistral
        // × 3 chunks × no refusal, both journal arms), so it is not the only thing standing between the
        // suite and that mutation. It is kept named because the sweep reports one aggregate boolean per
        // invariant: a red here says which shape broke, in the words of what it costs.
        var failedSafeForBoth = true
        for provider in [LLMProvider.anthropic, .mistral] {
            let several = ids(3)
            let batch = context(provider, batchId: "batches/received-id")
            let stopped = await stop(batch: batch,
                                     pendingBatch: journal(provider, batchId: "batches/received-id",
                                                           chunkIds: several))
            let failedSafe = stopped.wiring.attempted.isEmpty
                // The canceller and the deleter are still ASKED for — the wiring runs in full; it is the
                // rule downstream that declines. Pinning that keeps this check about the arguments.
                && stopped.wiring.contexts.count == 1
                && stopped.wiring.contexts.first.map { sameContext($0, batch) } == true
                && stopped.wiring.journalsAsked == [.paidBatchJournal]
                && stopped.wiring.deleteCalls == 0
                && stopped.fixtureExistedBefore && stopped.fixtureSurvived
                && stopped.statusMessage == OCRProcessor.batchCancellationNotConfirmedMessage
                && stopped.bannerRefreshed
            if !failedSafe { failedSafeForBoth = false }
        }
        check("wiring: a single-job provider's MULTI-chunk batch attempts nothing, keeps the journal, and warns (anthropic, mistral)",
              failedSafeForBoth)
    }

    // MARK: - Which paid jobs get cancelled

    private static func whichJobsGetCancelled(_ check: (String, Bool) -> Void) async {
        // A v1 journal is the authority: Gemini creates several paid jobs for one run and only the journal
        // knows their IDs. The batch's own `batchId` here is a decoy that must NOT be what gets cancelled.
        let acknowledged = ["batches/journal-0", "batches/journal-1"]
        let fromJournal = await stop(
            batch: context(.gemini, batchId: "batches/decoy-a,batches/decoy-b"),
            pendingBatch: journal(.gemini, batchId: "batches/decoy-a,batches/decoy-b", chunkIds: acknowledged))
        check("wiring: the journal's acknowledged chunk IDs are what gets cancelled, not the batch's own ID",
              fromJournal.wiring.attempted == acknowledged)

        // No journal (a pre-journal manifest, or Stop before the first save): the comma-joined received ID.
        let legacy = await stop(batch: context(.gemini, batchId: "batches/legacy-x, batches/legacy-y"))
        check("wiring: with no journal, the legacy comma-joined batch ID is what gets cancelled",
              legacy.wiring.attempted == ["batches/legacy-x", "batches/legacy-y"])

        // A legacy journal that IS on disk — `lifecycleVersion == nil`, written by a build before the
        // paid-batch journal existed. Its `submittedChunkIds` is not nil (the decoder back-fills it) but it
        // is not authoritative either, so a cancel path that read that array DIRECTLY instead of going
        // through `effectiveChunkIds` would cancel the wrong jobs on the operator's oldest, most fragile
        // manifests. Distinct from the case above — there the journal is absent; here it is present and
        // disagrees with the batch ID on purpose. The pure derivation covers this shape below; only driving
        // it through `cancel()` proves the cancel path asks the derivation rather than the struct.
        //
        // All THREE sources of a chunk ID disagree here, deliberately, so exactly one of them can produce
        // the expected result: the journal's own (legacy, authoritative) batch ID, the journal's stored
        // chunk list (back-filled, NOT authoritative), and the live `BatchContext`'s batch ID. Giving the
        // context the same ID as the journal — the obvious way to write this — would let `pendingBatch:
        // nil` satisfy the check, i.e. it would stay green for a `cancel()` that ignored the journal
        // entirely.
        var legacyOnDisk = journal(.gemini, batchId: "batches/legacy-p,batches/legacy-q",
                                   chunkIds: ["batches/stale-and-never-submitted"])
        legacyOnDisk.lifecycleVersion = nil
        let fromLegacyJournal = await stop(
            batch: context(.gemini, batchId: "batches/context-only"),
            pendingBatch: legacyOnDisk)
        check("wiring: a legacy journal's batch ID is what gets cancelled, never its non-authoritative chunk list",
              fromLegacyJournal.wiring.attempted == ["batches/legacy-p", "batches/legacy-q"]
              // …and neither of the two decoys, which is what makes the line above about the journal.
              && !fromLegacyJournal.wiring.attempted.contains("batches/stale-and-never-submitted")
              && !fromLegacyJournal.wiring.attempted.contains("batches/context-only")
              // A legacy journal acknowledges every job its batch ID names, so this Stop is a confirmed
              // one: the deleter really ran against a file that was really there.
              && fromLegacyJournal.wiring.deleteCalls == 1
              && fromLegacyJournal.fixtureExistedBefore && !fromLegacyJournal.fixtureSurvived)

        // Stop during a submit that had not acknowledged anything yet. There is nothing to cancel — and
        // falling back to parsing the batch ID here would cancel jobs the journal never claimed. Fail safe:
        // attempt nothing, keep the journal.
        let acknowledgedNothing = await stop(
            batch: context(.gemini, batchId: "batches/decoy-a,batches/decoy-b"),
            pendingBatch: journal(.gemini, batchId: "batches/decoy-a,batches/decoy-b", chunkIds: []))
        check("wiring: a journal that acknowledges no chunks cancels nothing and keeps the journal",
              acknowledgedNothing.wiring.attempted.isEmpty
              && acknowledgedNothing.wiring.deleteCalls == 0
              && acknowledgedNothing.fixtureExistedBefore && acknowledgedNothing.fixtureSurvived)

        // The derivation itself, as a pure function — the same three shapes, stated independently of Stop.
        let v1 = journal(.gemini, batchId: "batches/decoy", chunkIds: acknowledged)
        var legacyJournal = v1
        legacyJournal.lifecycleVersion = nil
        legacyJournal.batchId = "batches/legacy-x,batches/legacy-y"
        check("wiring: the chunk-ID derivation prefers a v1 journal and falls back to parsing the batch ID",
              OCRProcessor.cancellationChunkIds(pendingBatch: v1, batchId: "batches/decoy") == acknowledged
              && OCRProcessor.cancellationChunkIds(pendingBatch: nil, batchId: "batches/a,batches/b")
                  == ["batches/a", "batches/b"]
              && OCRProcessor.cancellationChunkIds(pendingBatch: legacyJournal, batchId: "batches/ignored")
                  == ["batches/legacy-x", "batches/legacy-y"])
    }

    // MARK: - Nothing to cancel

    private static func nothingToCancel(_ check: (String, Bool) -> Void) async {
        // The mutation this kills: deleting the whole `if let batch = activeBatch { … }` block. With no live
        // batch, none of the seams may be touched at all — so a green run here is what makes the counts in
        // every other check attributable to the block itself.
        let nothing = await stop(batch: nil)
        check("wiring: with no live paid batch, cancel() starts no server-side cancellation at all",
              !nothing.spawnedCancellation && nothing.wiring.contexts.isEmpty
              && nothing.wiring.journalsAsked.isEmpty && nothing.wiring.attempted.isEmpty
              && nothing.wiring.deleteCalls == 0
              && nothing.fixtureExistedBefore && nothing.fixtureSurvived
              && nothing.statusMessage.hasPrefix("Cancelled."))
        // The other half of the banner-refresh check: it is the CANCELLATION that recomputes it, so with
        // nothing to cancel the sentinel must still be there. Without this, a `checkForPendingBatch()` moved
        // to the top of `cancel()` would satisfy the refresh check while no longer reflecting the outcome.
        check("wiring: with nothing to cancel, the resume-banner state is not recomputed",
              !nothing.bannerRefreshed)

        // A journal with no live batch context — Stop after a relaunch, before a resume adopted the batch.
        // Nothing can be cancelled (no credentials), so the journal must be left exactly where it is,
        // INCLUDING in memory: `activePendingBatch` is what the journal's own mutations are persisted from
        // (`persistPendingBatchMutation`), and dropping it would discard a paid job's client-side state.
        let orphanJournal = await stop(
            batch: nil, pendingBatch: journal(.gemini, batchId: "batches/x", chunkIds: ids(1)))
        check("wiring: a paid-batch journal with no live batch context is left alone, on disk and in memory",
              !orphanJournal.spawnedCancellation && orphanJournal.wiring.journalsAsked.isEmpty
              && orphanJournal.wiring.deleteCalls == 0 && orphanJournal.fixtureSurvived
              && !orphanJournal.journalStateCleared)
    }

    // MARK: - Stop pressed twice

    private static func stopPressedTwice(_ check: (String, Bool) -> Void) async {
        let chunkIds = ids(2)
        let twice = await stop(batch: context(.gemini, batchId: "batches/received-id"),
                              pendingBatch: journal(.gemini, batchId: "batches/received-id", chunkIds: chunkIds),
                              again: true)
        check("wiring: Stop drops the live batch identity synchronously, before the cancellation finishes",
              twice.batchClearedSynchronously && twice.journalStateCleared)
        // Two paid cancellations for one batch is not merely redundant: each is a request against a job the
        // first one may already have removed, and the second would ask to delete the journal again.
        check("wiring: pressing Stop twice cannot cancel the same paid batch twice",
              twice.wiring.contexts.count == 1 && twice.wiring.attempted == chunkIds
              && twice.wiring.journalsAsked == [.paidBatchJournal] && twice.wiring.deleteCalls == 1)
    }

    // MARK: - The same invariants, swept over every shape a Stop can have

    /// Everything above is a NAMED shape, chosen because a specific mutation survives without it. This is
    /// the complement: press Stop on the whole cross-product — every provider × 0–3 acknowledged chunks ×
    /// journal arm (finished / mid-submit / absent) × no refusal, then each chunk refused in turn — and
    /// demand an exact outcome from all 120. What it buys over the named cases is the shapes nobody thought
    /// to name: a two-chunk Mistral batch, an OpenAI batch that reached the cancel path at all, a Gemini
    /// batch whose *last* chunk is the one the provider declines, a mid-submit Stop at every chunk count.
    ///
    /// Cheap because everything it drives is already stubbed — 120 Stops, no network, no keys, no cent, and
    /// the only file any of them can delete is that trial's own temp fixture (see `stop`). Each Stop does end
    /// in a real `checkForPendingBatch()`, which decodes whatever manifests it finds and re-derives their
    /// fingerprints; before W16.bat2-fu2 those were the operator's own, so a large interrupted run was the
    /// sweep's dominant cost. `test-batch-resume.sh` now points the state directory at its own temp dir, so
    /// that read is of an empty directory and the sweep no longer scales with what the operator happens to
    /// have. Its generous timeout is kept as insurance, not because it is needed.
    private static func sweepEveryShape(_ check: (String, Bool) -> Void) async {
        // A v1 journal must beat the batch's own ID at EVERY shape, so the with-journal arm gives the batch
        // a pair of decoy IDs the journal never acknowledged. No trial may ever attempt one of them —
        // including the count-0 trials, where falling back to the batch ID would cancel two paid jobs that
        // the journal says were never submitted.
        let decoys = ["batches/decoy-a", "batches/decoy-b"]
        let decoyBatchId = decoys.joined(separator: ",")

        var trials = 0, deletions = 0, keeps = 0
        var fixture = Invariant("wiring sweep: a real journal file was on disk before every Stop")
        var askedOnce = Invariant("wiring sweep: one Stop asks for one canceller — built from the batch's own context — and one journal")
        var attemptedIds = Invariant("wiring sweep: the jobs attempted are exactly the ones the derivation names and the provider's rule takes")
        var noDecoy = Invariant("wiring sweep: a chunk ID the v1 journal never acknowledged is never attempted")
        var deletes = Invariant("wiring sweep: the deleter runs on exactly the confirmed shapes, never twice")
        var keptFile = Invariant("wiring sweep: the journal file is still on disk after exactly the unconfirmed shapes")
        var message = Invariant("wiring sweep: the kept-journal warning appears on exactly the shapes that kept the journal")
        var state = Invariant("wiring sweep: every Stop with a live batch clears its state synchronously and refreshes the banner")
        var inFlight = Invariant("wiring sweep: no Stop that landed mid-submit deletes the journal, whatever confirmed")

        // Three journal arms, not two (W16.bat5): a v1 journal that finished submitting, the SAME journal
        // mid-submit, and no journal at all. The no-journal arm has no in-flight twin — with nothing to read
        // there is no submission state, and that `nil ⇒ not in flight` reading is pinned separately in
        // `BatchCancelContract`.
        let arms: [(hasJournal: Bool, inFlight: Bool)] = [(true, false), (true, true), (false, false)]

        for provider in LLMProvider.allCases {
            for count in 0...3 {
                let chunkIds = ids(count)
                for arm in arms {
                    let hasJournal = arm.hasJournal
                    let batchId = hasJournal ? decoyBatchId : chunkIds.joined(separator: ",")
                    let pending = hasJournal
                        ? journal(provider, batchId: batchId, chunkIds: chunkIds,
                                  submissionComplete: !arm.inFlight)
                        : nil
                    // What `cancel()` must hand the rule — taken from the shipped derivation, not from the
                    // loop variables, because "does `cancel()` still ask `cancellationChunkIds`?" is the
                    // wiring question. (That the derivation itself is right is pinned separately, against
                    // literals, in `whichJobsGetCancelled`.)
                    let derived = OCRProcessor.cancellationChunkIds(pendingBatch: pending, batchId: batchId)
                    // …and what the RULE (`performServerBatchCancellation`, pinned by `BatchCancelContract`)
                    // then does with it. Restated BY HAND here, deliberately: it is what lets every trial
                    // demand an exact outcome instead of mere internal consistency — "the warning appears
                    // exactly when the journal survived" is satisfied by a cancel path that confirms
                    // nothing, ever. The cost is that changing the rule reddens this too, which on a money
                    // path is the right trade: a second, independent statement of what Stop does.
                    let willAttempt: [String]
                    switch provider {
                    case .gemini:              willAttempt = derived
                    case .anthropic, .mistral: willAttempt = derived.count == 1 ? derived : []
                    case .openai:              willAttempt = []      // no batch path in v1
                    }

                    // No refusal, then each acknowledged chunk refused in turn.
                    var refusals: [Set<String>] = [[]]
                    refusals += chunkIds.map { Set([$0]) }

                    for refusing in refusals {
                        // A confirmed cancellation needs something to attempt AND no refusal among it.
                        let willConfirm = !willAttempt.isEmpty && refusing.isDisjoint(with: willAttempt)
                        // …and a DELETION needs one more thing since W16.bat5: that the submission had
                        // finished, so the list just confirmed is known to be the whole batch.
                        let willDelete = willConfirm && !arm.inFlight
                        let batch = context(provider, batchId: batchId)
                        let stopped = await stop(batch: batch, pendingBatch: pending, refusing: refusing)
                        trials += 1
                        // Named so a red points at one of 120 trials instead of at a boolean.
                        let shape = "\(provider.rawValue)/\(count) chunk\(count == 1 ? "" : "s")/"
                            + (hasJournal ? (arm.inFlight ? "journal mid-submit" : "journal") : "no journal") + "/"
                            + (refusing.isEmpty ? "none refused" : "refusing \(refusing.sorted().joined(separator: " "))")

                        // Observed, not predicted: what actually happened to a real file on disk.
                        if stopped.wiring.deleteCalls == 1 && !stopped.fixtureSurvived { deletions += 1 }
                        if stopped.wiring.deleteCalls == 0 && stopped.fixtureSurvived { keeps += 1 }

                        fixture.require(stopped.fixtureExistedBefore, shape)
                        askedOnce.require(stopped.wiring.contexts.count == 1
                            && stopped.wiring.contexts.first.map({ sameContext($0, batch) }) == true
                            && stopped.wiring.journalsAsked == [.paidBatchJournal], shape)
                        attemptedIds.require(stopped.wiring.attempted == willAttempt, shape)
                        noDecoy.require(!hasJournal || !stopped.wiring.attempted.contains(where: decoys.contains),
                                        shape)
                        deletes.require((stopped.wiring.deleteCalls == 1) == willDelete
                                        && stopped.wiring.deleteCalls <= 1, shape)
                        keptFile.require(stopped.fixtureSurvived == !willDelete, shape)
                        inFlight.require(!arm.inFlight
                                         || (stopped.wiring.deleteCalls == 0 && stopped.fixtureSurvived),
                                         shape)
                        // Which of the two reasons kept it has to be right, not just that something was
                        // said: telling an operator "server cancellation was not confirmed" about a batch
                        // every known chunk of which WAS confirmed sends them looking for the wrong thing.
                        let expectedWarning: String? = willConfirm
                            ? (arm.inFlight ? OCRProcessor.batchCancellationSubmissionInFlightMessage : nil)
                            : OCRProcessor.batchCancellationNotConfirmedMessage
                        message.require(expectedWarning.map { stopped.statusMessage == $0 }
                                        ?? stopped.statusMessage.hasPrefix("Cancelled."), shape)
                        state.require(stopped.spawnedCancellation && stopped.batchClearedSynchronously
                                      && stopped.journalStateCleared && stopped.bannerRefreshed, shape)
                    }
                }
            }
        }

        check("wiring sweep: every provider × 0–3 chunks × journal arm × refusal shape was stopped (\(trials) trials)",
              trials == 120)
        // Non-vacuity, MEASURED. Not because the invariants above would otherwise hold for free — each is
        // stated against `willConfirm`, which is computed independently of what was observed, so a cancel
        // path that confirmed nothing would redden them. What these literals catch is the two statements
        // degenerating TOGETHER: change the rule and the hand-written table beside it in the same way, and
        // every "exactly when confirmed" invariant becomes "exactly when never", satisfied vacuously by 80
        // trials that all keep. 15 of the 120 shapes are fully confirmable — Gemini with 1–3 chunks and
        // Anthropic/Mistral with exactly 1, each unrefused, once per journal arm — and both counters below
        // are incremented from what happened to a real file, not from the table. Only 10 of those 15 delete:
        // the 5 in the mid-submit arm are exactly the W16.bat5 regression, confirmed cancellations that keep
        // the journal anyway, so the split 10/110 is itself the fix being counted.
        // (A fifth provider would move these numbers; that is a deliberate re-read, not a false alarm.)
        check("wiring sweep: 10 of the \(trials) shapes really deleted a real journal file, and 110 really kept one",
              deletions == 10 && keeps == 110 && deletions + keeps == trials)
        for invariant in [fixture, askedOnce, attemptedIds, noDecoy, deletes, keptFile, message, state, inFlight] {
            check(invariant.label, invariant.held && trials == 120)
        }
    }

    /// One invariant swept across all 120 trials. Collapsing them to plain `Bool`s loses the thing that
    /// makes a red actionable — WHICH shape broke — so the first failing shape rides along in the label.
    private struct Invariant {
        private let name: String
        private(set) var firstBad: String?
        init(_ name: String) { self.name = name }
        /// `shape` is an autoclosure so the 80 × 8 labels that never fail are never built.
        mutating func require(_ ok: Bool, _ shape: @autoclosure () -> String) {
            if !ok && firstBad == nil { firstBad = shape() }
        }
        var held: Bool { firstBad == nil }
        var label: String { firstBad.map { "\(name) [first bad shape: \($0)]" } ?? name }
    }
}
