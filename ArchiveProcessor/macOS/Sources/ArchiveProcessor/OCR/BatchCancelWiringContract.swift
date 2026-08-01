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
/// **How it stays $0 and can never touch the operator's real state.** Every `cancel()` here is driven by
/// `stop(…)`, the only place in this file that cancels anything, and it always replaces BOTH seams before the
/// batch is installed: `makeBatchChunkCanceller` (a recording stub — no client, no request) and
/// `makeBatchJournalDeleter` (records which journal was *asked for*, and deletes a temp fixture instead of the
/// real `pending_batch.json`). Nothing suspends between those assignments and `cancel()`, so no cancellation
/// can start with a default seam installed, and the production deleter —
/// `OCRProcessor.deletePendingBatch()`, which removes the operator's actual paid-batch journal from
/// Application Support — is executed by no check here. `defaultSeamsAreTheLiveOnes` builds one more processor
/// to inspect the *defaults*, but never cancels on it and never invokes the deleter it returns.
///
/// ⚠️ **SCOPE — read before citing this file.** What is *not* covered, precisely:
///   * This is the wiring, not the rule (that is `BatchCancelContract`) and not the whole Stop path:
///     **W16.bat3 is open and owner-gated** — the poll's `guard !Task.isCancelled` returns without setting
///     `batchPollInterrupted`, so `performBatchOCR` deletes the journal regardless of what `cancel()`
///     decided. A green section here does not make pressing Stop safe end to end.
///   * **The default deleter's body is the one line no check can run** (running it would delete the
///     operator's journal). That the default is `{ OCRProcessor.deletePendingBatch() }` is grep-verifiable,
///     not test-verifiable, until the journal path itself is redirectable under test (W16.bat2-fu2).
///   * A confirmed cancellation may delete exactly one durable file, and the seam lets it name only that
///     one (`BatchCancellationJournal` has a single case, tripwired below). A future edit that bolts an
///     *extra*, un-seamed deletion beside it (`deletePendingRun()`, say) is a new defect this file cannot
///     see — the seam records what was asked for, not everything the block does. Worse, it would make
///     *running this suite* the thing that deletes a real journal; that is the other half of W16.bat2-fu2.
///   * The kept-journal warning is proven **assigned**, not **survived**: these scenarios have no live
///     `processingTask`, whereas a real Stop also cancels the poll, which can write `statusMessage` after
///     the cancellation task did (W16.bat6).
///   * `cancel()`'s own `checkForPendingBatch()` runs for real. It never deletes either manifest, but it does
///     read the operator's Application Support state (and `pendingBatchURL` creates that directory) and
///     recomputes two `@Published` banner strings from it — so the checks below assert only that the refresh
///     *ran*, never what it found.
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
        await aSingleJobProviderStop(check)
        await whichJobsGetCancelled(check)
        await nothingToCancel(check)
        await stopPressedTwice(check)
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

    /// A v1 paid-batch journal that acknowledges `chunkIds` server-side jobs.
    private static func journal(_ provider: LLMProvider,
                                batchId: String,
                                chunkIds: [String]) -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: batchId, provider: provider, model: model(provider), thinkingLevel: .high,
            fileURLs: [], outputDirectory: FileManager.default.temporaryDirectory,
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: chunkIds)
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
        // (or a resume) could act on a batch whose cancellation is already in flight.
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
    /// live one. The other half is not, and is scoped in the header: running the default *deleter* would
    /// delete the operator's real journal, so this asks for one and drops it unrun.
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
        // run it, and running it deletes the operator's real `pending_batch.json`. See the header — that gap
        // closes when the journal path becomes redirectable under test (W16.bat2-fu2), not before.
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
}
