import Foundation

/// **Cancel-path journal-retention contract for the paid batch path** (W16.bat2) — headless, $0, no
/// network, no keys. Drives the real seam `OCRProcessor.performServerBatchCancellation` with a stub
/// canceller and a REAL journal file in a temp dir, so every claim below is about a file that either
/// survived or did not.
///
/// Why this exists: pressing Stop during a paid batch is the one place where a wrong answer costs money
/// that cannot be recovered. The recovery journal is the only record of a server-side job the operator
/// has already paid for; delete it while that job is still live and the pages are gone with the money.
/// So `cancel()` deletes it ONLY when every chunk's cancellation was confirmed, and otherwise keeps it
/// and says so. That guarantee shipped with no regression test at all — it was verified by reading the
/// code — and it is exactly the kind of rule a later edit weakens by accident, because the failure is
/// silent: the UI says "kept for recovery" whether or not anything was kept.
///
/// The checks pin three things a future edit must not break:
///   * **iff** — the journal is deleted if and only if the cancellation was confirmed, over every
///     provider × chunk-count × which-chunk-refused shape;
///   * **the provider rules** — Anthropic and Mistral can confirm only a single-chunk batch and do not
///     even attempt a multi-chunk one; Gemini needs every chunk and treats *no* chunks as a failure,
///     not a vacuous success; OpenAI never confirms (no batch path in v1);
///   * **the words match the disk** — the "journal was kept for recovery" message appears only when the
///     file is still there, and never when it was deleted.
///
/// Run from `BatchResumeTestDriver` (section 13) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum BatchCancelContract {

    static func run(check: (String, Bool) -> Void) async {
        await geminiRules(check)
        await singleJobProviderRules(check)
        await openAIRule(check)
        await messageMatchesTheDisk(check)
        await sweepEveryShape(check)
    }

    // MARK: - Fixture

    /// One recorded run of the seam against a real file standing in for the recovery journal.
    private struct Trial {
        let outcome: OCRProcessor.BatchCancellationOutcome
        /// Was the journal fixture actually on disk *before* the call? (Non-vacuity: a "retained"
        /// verdict means nothing if the file was never written.)
        let journalExistedBefore: Bool
        /// Is it still on disk *after*?
        let journalSurvived: Bool
        /// How many times `deleteJournal` was invoked — must be 0 or 1, never twice.
        let deleteCalls: Int
        /// Which chunk IDs a cancellation was actually attempted for, recorded by the stub itself.
        let attempted: [String]
    }

    /// Mutable state the stubs write to. A reference box rather than captured `var`s so the recording
    /// is unambiguous across the seam's suspension points.
    private final class Recorder {
        var attempted: [String] = []
        var deleteCalls = 0
    }

    /// Run the seam once. `refusing` names the chunk IDs whose server-side cancellation the provider
    /// declines — everything else is confirmed.
    private static func trial(_ provider: LLMProvider,
                              _ chunkIds: [String],
                              refusing: Set<String> = []) async -> Trial {
        let fm = FileManager.default
        let journal = fm.temporaryDirectory
            .appendingPathComponent("APCancelContract-\(UUID().uuidString).json")
        try? Data(#"{"batchId":"paid-job","fileURLs":[]}"#.utf8).write(to: journal)
        let existedBefore = fm.fileExists(atPath: journal.path)

        let recorder = Recorder()
        let outcome = await OCRProcessor.performServerBatchCancellation(
            provider: provider,
            chunkIds: chunkIds,
            cancelChunk: { id in
                recorder.attempted.append(id)
                return !refusing.contains(id)
            },
            deleteJournal: {
                recorder.deleteCalls += 1
                try? fm.removeItem(at: journal)
            })

        let survived = fm.fileExists(atPath: journal.path)
        try? fm.removeItem(at: journal)
        return Trial(outcome: outcome, journalExistedBefore: existedBefore, journalSurvived: survived,
                     deleteCalls: recorder.deleteCalls, attempted: recorder.attempted)
    }

    private static func ids(_ n: Int) -> [String] { (0..<n).map { "batches/chunk-\($0)" } }

    // MARK: - Gemini: every chunk, and no chunks is not success

    private static func geminiRules(_ check: (String, Bool) -> Void) async {
        let all = ids(3)

        let confirmed = await trial(.gemini, all)
        check("gemini: every chunk confirmed → the paid-batch journal is deleted",
              confirmed.outcome.confirmed && confirmed.outcome.journalDeleted
              && confirmed.journalExistedBefore && !confirmed.journalSurvived
              && confirmed.deleteCalls == 1)
        check("gemini: a confirmed cancellation attempts every chunk of the batch",
              confirmed.outcome.attemptedChunkIds == all && confirmed.attempted == all)

        let oneRefused = await trial(.gemini, all, refusing: [all[1]])
        check("gemini: one unconfirmed chunk keeps the journal on disk",
              !oneRefused.outcome.confirmed && !oneRefused.outcome.journalDeleted
              && oneRefused.journalSurvived && oneRefused.deleteCalls == 0)

        let firstRefused = await trial(.gemini, all, refusing: [all[0]])
        check("gemini: a refusal does not abandon the chunks after it — a live chunk is what costs money",
              firstRefused.attempted == all && !firstRefused.outcome.confirmed)

        let allRefused = await trial(.gemini, all, refusing: Set(all))
        check("gemini: every chunk refused → journal kept, all three still attempted",
              !allRefused.outcome.confirmed && allRefused.journalSurvived
              && allRefused.attempted == all)

        let noChunks = await trial(.gemini, [])
        check("gemini: a batch with no chunk IDs is a failure to confirm, not a vacuous success",
              !noChunks.outcome.confirmed && noChunks.journalSurvived
              && noChunks.attempted.isEmpty && noChunks.deleteCalls == 0)
    }

    // MARK: - Anthropic / Mistral: exactly one job, or nothing is attempted

    private static func singleJobProviderRules(_ check: (String, Bool) -> Void) async {
        for provider in [LLMProvider.anthropic, .mistral] {
            let name = provider.rawValue.lowercased()
            let one = ids(1)

            let confirmed = await trial(provider, one)
            check("\(name): the single server job confirmed → journal deleted",
                  confirmed.outcome.confirmed && confirmed.journalExistedBefore
                  && !confirmed.journalSurvived && confirmed.deleteCalls == 1
                  && confirmed.attempted == one)

            let refused = await trial(provider, one, refusing: Set(one))
            check("\(name): the single server job refused → journal kept",
                  !refused.outcome.confirmed && refused.journalSurvived
                  && refused.deleteCalls == 0 && refused.attempted == one)

            // The important one: the client can cancel one ID, so a chunked batch has no single job to
            // cancel. It must not be reported as cancelled, and no half-cancellation may be attempted.
            let chunked = await trial(provider, ids(2))
            check("\(name): a multi-chunk batch cannot be confirmed, so the journal is kept",
                  !chunked.outcome.confirmed && !chunked.outcome.journalDeleted
                  && chunked.journalSurvived && chunked.deleteCalls == 0)
            check("\(name): a multi-chunk batch is not half-cancelled — no chunk is attempted",
                  chunked.attempted.isEmpty && chunked.outcome.attemptedChunkIds.isEmpty)

            let none = await trial(provider, [])
            check("\(name): no chunk IDs → nothing attempted, journal kept",
                  !none.outcome.confirmed && none.journalSurvived && none.attempted.isEmpty)
        }
    }

    // MARK: - OpenAI: no batch path in v1

    private static func openAIRule(_ check: (String, Bool) -> Void) async {
        let single = await trial(.openai, ids(1))
        check("openai: never confirms and never calls a batch endpoint (no batch path in v1)",
              !single.outcome.confirmed && single.attempted.isEmpty
              && single.journalSurvived && single.deleteCalls == 0)
    }

    // MARK: - The message and the disk cannot disagree

    private static func messageMatchesTheDisk(_ check: (String, Bool) -> Void) async {
        let kept = await trial(.gemini, ids(2), refusing: ["batches/chunk-1"])
        check("the kept-journal message is the operator-facing promise, verbatim",
              kept.outcome.statusMessage == OCRProcessor.batchCancellationNotConfirmedMessage)
        check("that promise actually says the journal was kept for recovery",
              OCRProcessor.batchCancellationNotConfirmedMessage.contains("kept for recovery"))

        let deleted = await trial(.gemini, ids(2))
        check("a deleted journal is never announced as kept",
              deleted.outcome.statusMessage == nil && !deleted.journalSurvived)
    }

    // MARK: - The invariant, swept over every shape

    /// An independent statement of the rule, written from the providers' capabilities rather than from
    /// the implementation, so the sweep is a comparison and not an echo.
    private static func expectedConfirmation(_ provider: LLMProvider,
                                             _ chunkIds: [String],
                                             _ refusing: Set<String>) -> Bool {
        let everyChunkAccepted = chunkIds.allSatisfy { !refusing.contains($0) }
        switch provider {
        case .anthropic, .mistral: return chunkIds.count == 1 && everyChunkAccepted
        case .gemini: return !chunkIds.isEmpty && everyChunkAccepted
        case .openai: return false
        }
    }

    private static func expectedAttempts(_ provider: LLMProvider, _ chunkIds: [String]) -> [String] {
        switch provider {
        case .anthropic, .mistral: return chunkIds.count == 1 ? chunkIds : []
        case .gemini: return chunkIds
        case .openai: return []
        }
    }

    private static func sweepEveryShape(_ check: (String, Bool) -> Void) async {
        var trials = 0
        var iffHeld = true          // journal deleted ⟺ confirmed, on disk and in the outcome
        var ruleHeld = true         // confirmed matches the independent expectation
        var attemptsHeld = true     // nothing is attempted that the provider's rule cannot use
        var messageHeld = true      // message present ⟺ journal survived
        var deleteCallsHeld = true  // delete is called once, or not at all
        var fixtureHeld = true      // the journal fixture was really on disk before every trial

        for provider in LLMProvider.allCases {
            for count in 0...6 {
                let chunkIds = ids(count)
                // No refusal, then each chunk refused in turn.
                var scenarios: [Set<String>] = [[]]
                scenarios += chunkIds.map { Set([$0]) }
                if count > 1 { scenarios.append(Set(chunkIds)) }

                for refusing in scenarios {
                    let t = await trial(provider, chunkIds, refusing: refusing)
                    trials += 1
                    let confirmed = t.outcome.confirmed

                    if t.outcome.journalDeleted != confirmed { iffHeld = false }
                    if t.journalSurvived != !confirmed { iffHeld = false }
                    if confirmed != expectedConfirmation(provider, chunkIds, refusing) { ruleHeld = false }
                    if t.attempted != expectedAttempts(provider, chunkIds) { attemptsHeld = false }
                    if t.outcome.attemptedChunkIds != t.attempted { attemptsHeld = false }
                    if (t.outcome.statusMessage != nil) != t.journalSurvived { messageHeld = false }
                    if t.deleteCalls != (confirmed ? 1 : 0) { deleteCallsHeld = false }
                    if !t.journalExistedBefore { fixtureHeld = false }
                }
            }
        }

        check("sweep: every provider × chunk-count × refusal shape was exercised (\(trials) trials)",
              trials == 132)
        check("sweep: a real journal file backed every one of those \(trials) trials",
              fixtureHeld)
        check("sweep: the journal is deleted if and only if the cancellation was confirmed",
              iffHeld)
        check("sweep: confirmation matches the providers' capabilities, independently stated",
              ruleHeld)
        check("sweep: no cancellation is attempted that its provider's rule could not act on",
              attemptsHeld)
        check("sweep: the operator is told the journal was kept exactly when it was",
              messageHeld)
        check("sweep: the journal is deleted at most once, and only on the confirmed path",
              deleteCallsHeld)
    }
}
