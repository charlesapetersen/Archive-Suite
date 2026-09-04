import Foundation

/// **Cancel-path journal-retention contract for the paid batch path** (W16.bat2) — headless, $0, no
/// network, no keys. Drives the real seam `OCRProcessor.performServerBatchCancellation` with a stub
/// canceller and a REAL journal file in a temp dir, so every claim below is about a file that either
/// survived or did not.
///
/// Why this exists: cancelling a paid batch is the one place where a wrong answer costs money that cannot
/// be recovered. The recovery journal is the only record of a server-side job the operator has already paid
/// for; delete it while that job is still live and the pages are gone with the money. So `cancel()` deletes
/// it ONLY when every chunk's cancellation was confirmed, and otherwise keeps it and says so. That
/// guarantee shipped with no regression test at all — it was verified by reading the code — and it is
/// exactly the kind of rule a later edit weakens by accident, because the failure is silent: the UI says
/// "kept for recovery" whether or not anything was kept.
///
/// ⚠️ **SCOPE — read before citing this file.** What is pinned here is the RULE, in the seam. It is NOT an
/// end-to-end guarantee about pressing Stop, and no check in THIS file executes `deletePendingBatch()` —
/// the stub deletes a temp fixture. (Section 16, `BatchJournalPathContract`, does execute it, deliberately
/// and against a redirected journal path; that is W16.bat2-fu2, not this file.) Two things stay uncovered:
///   * **The poll unwinding alongside the cancellation** — it used to delete the journal regardless of what
///     `cancel()` had decided (W16.bat3, since fixed and pinned by `BatchPollCancelContract`, section 17).
///     A green run below has never meant Stop is safe end to end; cite section 17 for that half.
///   * **The wiring** — nothing HERE proves `cancel()` passes the paid-batch journal's deleter, the live
///     provider, the journal's chunk IDs, or the in-flight answer. That is `BatchCancelWiringContract`
///     (W16.bat2-fu), which drives
///     the real `cancel()` with both seams stubbed; the two files are complementary and neither substitutes
///     for the other.
///
/// The checks pin four things a future edit must not break:
///   * **iff** — the journal is deleted if and only if the cancellation was confirmed AND no submission was
///     still in flight, over every provider × chunk-count × which-chunk-refused × in-flight shape;
///   * **the in-flight override** (W16.bat5) — a confirmed cancellation is not enough on its own. `chunkIds`
///     is a snapshot taken when Stop landed, so if the run was still creating paid jobs at that instant the
///     snapshot may be incomplete and the journal survives no matter what confirms. The chunks that WERE
///     known are still cancelled (the guard keeps the journal, not the money), and the operator is told, in
///     words distinct from the not-confirmed case;
///   * **the provider rules** — Anthropic and Mistral can confirm only a single-chunk batch and do not
///     even attempt a multi-chunk one; Gemini needs every chunk and treats *no* chunks as a failure,
///     not a vacuous success; OpenAI never confirms (no batch path in v1);
///   * **the words match the disk** — a "journal was kept for recovery" message appears only when the file
///     is still there, never when it was deleted, and names which of the two reasons kept it.
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
        theInFlightFactIsReadOffTheJournal(check)
        await aSubmissionStillInFlight(check)
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
    /// declines — everything else is confirmed. `submissionInFlight` is the W16.bat5 dimension: was the
    /// batch still being submitted when Stop landed, i.e. is `chunkIds` possibly not the whole batch?
    private static func trial(_ provider: LLMProvider,
                              _ chunkIds: [String],
                              refusing: Set<String> = [],
                              submissionInFlight: Bool = false) async -> Trial {
        let fm = FileManager.default
        let journal = fm.temporaryDirectory
            .appendingPathComponent("APCancelContract-\(UUID().uuidString).json")
        try? Data(#"{"batchId":"paid-job","fileURLs":[]}"#.utf8).write(to: journal)
        let existedBefore = fm.fileExists(atPath: journal.path)

        let recorder = Recorder()
        let outcome = await OCRProcessor.performServerBatchCancellation(
            canceller: OCRProcessor.BatchChunkCanceller(provider: provider, cancelChunk: { id in
                recorder.attempted.append(id)
                return !refusing.contains(id)
            }, clientTypeName: "stub"),
            chunkIds: chunkIds,
            submissionInFlight: submissionInFlight,
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

            // Both clients record exactly one submitted chunk (`+OCR.swift:598`, `:604` — only Gemini has
            // a per-chunk callback), so in practice the count here is 0 or 1 and this ≥2 case is reachable
            // only from a corrupt or legacy comma-joined journal. It is pinned anyway because the rule has
            // to fail SAFE there: not reported as cancelled, and not half-cancelled either. The case that
            // actually happens in the field is the zero-chunk one below — Stop pressed after `activeBatch`
            // is set but before the submit returns.
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
        // Tripwire, not a restatement: the rule above is only correct BECAUSE OpenAI has no batch path.
        // If Phase 4 ever lands one, this reddens and the contract has to be rewritten rather than
        // quietly continuing to assert that a real provider can never be cancelled.
        check("openai's no-confirmation rule is still justified — it has no batch path to cancel",
              !LLMProvider.openai.supportsBatch)
    }

    // MARK: - The message and the disk cannot disagree

    private static func messageMatchesTheDisk(_ check: (String, Bool) -> Void) async {
        let kept = await trial(.gemini, ids(2), refusing: ["batches/chunk-1"])
        check("the kept-journal message is the operator-facing promise, verbatim",
              kept.outcome.statusMessage == OCRProcessor.batchCancellationNotConfirmedMessage)
        // Not a tautology over a literal: the promise is read off the outcome of a real trial and matched
        // against the file that trial left behind, so the words and the disk are compared to each other.
        check("the run that promised recovery really did leave the journal there",
              kept.outcome.statusMessage?.contains("kept for recovery") == true
              && kept.journalExistedBefore && kept.journalSurvived)

        let deleted = await trial(.gemini, ids(2))
        check("a deleted journal is never announced as kept",
              deleted.outcome.statusMessage == nil
              && deleted.journalExistedBefore && !deleted.journalSurvived)
    }

    // MARK: - A submission still in flight (W16.bat5): confirmation is not enough

    /// The predicate `cancel()` derives the in-flight answer from, on its own. Pure, so it can be stated
    /// against literals rather than inferred from an outcome — and it is the half that carries the whole
    /// fix's premise: `submissionComplete` is what `performBatchOCR` writes `false` before its first paid
    /// create request and flips true only after its last one.
    private static func theInFlightFactIsReadOffTheJournal(_ check: (String, Bool) -> Void) {
        var midSubmission = journal(chunkIds: ids(2))
        midSubmission.submissionComplete = false
        var finished = midSubmission
        finished.submissionComplete = true

        check("in flight: a journal whose submission never completed reads as in flight",
              OCRProcessor.batchSubmissionIsInFlight(midSubmission))
        check("in flight: a journal whose submission finished does not",
              !OCRProcessor.batchSubmissionIsInFlight(finished))
        // Not in flight, and deliberately so: with no journal there is no submission state to consult, and
        // a legacy comma-joined manifest is written after its single submit. Pinned because the safe-looking
        // alternative (nil ⇒ in flight) would keep the journal on every legacy Stop — a behaviour change
        // this item does not authorize, in a direction nobody asked for.
        check("in flight: with no journal at all there is nothing in flight",
              !OCRProcessor.batchSubmissionIsInFlight(nil))
        // The two fields must not be confused: a batch can have acknowledged every chunk it will ever have
        // and still be mid-submission (the marker write is a separate, later step), and it can have
        // acknowledged none and be finished (a submit that created nothing).
        var noneAcknowledgedButFinished = journal(chunkIds: [])
        noneAcknowledgedButFinished.submissionComplete = true
        check("in flight: the answer comes from the submission marker, not from how many chunks are listed",
              OCRProcessor.batchSubmissionIsInFlight(midSubmission)
              && !OCRProcessor.batchSubmissionIsInFlight(noneAcknowledgedButFinished))
    }

    /// The regression itself. Every one of these shapes deletes the journal on the pre-W16.bat5 rule — the
    /// cancellations all confirm — and the deletion is exactly the loss: the chunk created after the
    /// snapshot is already billed and its ID is written nowhere else.
    private static func aSubmissionStillInFlight(_ check: (String, Bool) -> Void) async {
        let all = ids(3)
        let inFlight = await trial(.gemini, all, submissionInFlight: true)
        check("in flight: every chunk confirmed, but the submission was unfinished → the journal is still there",
              inFlight.outcome.confirmed && !inFlight.outcome.journalDeleted
              && inFlight.journalExistedBefore && inFlight.journalSurvived
              && inFlight.deleteCalls == 0)
        // The cancellations are NOT skipped: the paid jobs that ARE known must still be stopped, or the fix
        // would trade a lost journal for a running bill. This is the half a "just return early" guard breaks.
        check("in flight: the chunks that were known are still cancelled — the guard keeps the journal, not the money",
              inFlight.attempted == all && inFlight.outcome.attemptedChunkIds == all)
        // Distinct words from the not-confirmed case, and they have to be: the operator is deciding whether
        // to press Resume, and "we stopped everything we knew of, and there may be more" is a different
        // situation from "we could not stop it".
        check("in flight: the operator is told a job may exist beyond the ones that were stopped",
              inFlight.outcome.statusMessage == OCRProcessor.batchCancellationSubmissionInFlightMessage
              && inFlight.outcome.statusMessage != OCRProcessor.batchCancellationNotConfirmedMessage
              && inFlight.outcome.statusMessage?.contains("kept for recovery") == true)

        // The single-job providers take the same rule. Without this, gating the guard on `.gemini` — the
        // only provider that creates chunks one at a time, so the tempting narrowing — would stay green.
        //
        // Honest about WHY, because the Gemini justification does not transfer: Anthropic and Mistral make
        // exactly one create call, and confirmation already requires exactly one chunk, so their snapshot
        // provably IS the whole batch and this keep is not buying safety there. It is pinned anyway, as
        // uniformity: a rule with a per-provider carve-out is a rule someone extends to a fourth provider
        // wrongly, and the cost of the extra keep is one Dismiss.
        var heldForBoth = true
        for provider in [LLMProvider.anthropic, .mistral] {
            let one = await trial(provider, ids(1), submissionInFlight: true)
            if !(one.outcome.confirmed && !one.outcome.journalDeleted && one.journalSurvived
                 && one.deleteCalls == 0
                 && one.outcome.statusMessage == OCRProcessor.batchCancellationSubmissionInFlightMessage) {
                heldForBoth = false
            }
        }
        check("in flight: a single-job provider's confirmed Stop keeps the journal too (anthropic, mistral)",
              heldForBoth)

        // The guard must not swallow the OTHER reason to keep the journal, nor change its words: an
        // unconfirmed cancellation is still reported as unconfirmed even when a submit was in flight.
        let bothReasons = await trial(.gemini, all, refusing: [all[1]], submissionInFlight: true)
        check("in flight: an unconfirmed cancellation still says so, in flight or not",
              !bothReasons.outcome.confirmed && !bothReasons.outcome.journalDeleted
              && bothReasons.journalSurvived
              && bothReasons.outcome.statusMessage == OCRProcessor.batchCancellationNotConfirmedMessage)

        // Non-vacuity: the SAME shape with the submission finished still deletes. Without this pair the
        // whole section is satisfied by a rule that never deletes anything, which would be a different bug.
        let finished = await trial(.gemini, all, submissionInFlight: false)
        check("in flight: and the only thing that changed is the in-flight fact — the finished shape still deletes",
              finished.outcome.journalDeleted && !finished.journalSurvived && finished.deleteCalls == 1
              && finished.attempted == inFlight.attempted)
    }

    /// A v1 paid-batch journal, for the pure checks above. Nothing here is written to disk — `trial`'s
    /// fixture is a plain temp file, because the seam under test takes chunk IDs, not a journal.
    private static func journal(chunkIds: [String]) -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: chunkIds.joined(separator: ","), provider: .gemini,
            model: LLMModel(id: "cancel-contract", displayName: "Cancel Contract", provider: .gemini,
                            supportsThinking: false, returnsMd: false,
                            inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0),
            thinkingLevel: nil, fileURLs: [], outputDirectory: FileManager.default.temporaryDirectory,
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: chunkIds)
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
        case .openai, .appleVision: return false
        }
    }

    private static func expectedAttempts(_ provider: LLMProvider, _ chunkIds: [String]) -> [String] {
        switch provider {
        case .anthropic, .mistral: return chunkIds.count == 1 ? chunkIds : []
        case .gemini: return chunkIds
        case .openai, .appleVision: return []
        }
    }

    private static func sweepEveryShape(_ check: (String, Bool) -> Void) async {
        var trials = 0, deletions = 0, deletionsWhileInFlight = 0
        var iffHeld = true          // journal deleted ⟺ confirmed AND no submission in flight
        var ruleHeld = true         // confirmed matches the independent expectation
        var attemptsHeld = true     // nothing is attempted that the provider's rule cannot use
        var messageHeld = true      // message present ⟺ journal survived, and it names the right reason
        var deleteCallsHeld = true  // delete is called once, or not at all
        var fixtureHeld = true      // the journal fixture was really on disk before every trial
        var inFlightHeld = true     // no shape whatsoever deletes while a submission is in flight

        for provider in LLMProvider.allCases {
            for count in 0...6 {
                let chunkIds = ids(count)
                // No refusal, then each chunk refused in turn.
                var scenarios: [Set<String>] = [[]]
                scenarios += chunkIds.map { Set([$0]) }
                if count > 1 { scenarios.append(Set(chunkIds)) }

                for refusing in scenarios {
                    // The W16.bat5 dimension. Every shape is run BOTH ways, so the guard is swept rather
                    // than sampled: the in-flight half is the regression (each of its confirmable shapes
                    // deleted before the fix), and the finished half is what keeps that from being
                    // satisfied by a rule that simply stopped deleting.
                    for submissionInFlight in [false, true] {
                        let t = await trial(provider, chunkIds, refusing: refusing,
                                            submissionInFlight: submissionInFlight)
                        trials += 1
                        let confirmed = t.outcome.confirmed
                        // Stated from the loop variable, not from the outcome: what SHOULD happen to the file.
                        let shouldDelete = confirmed && !submissionInFlight
                        if t.outcome.journalDeleted != shouldDelete { iffHeld = false }
                        if t.journalSurvived != !shouldDelete { iffHeld = false }
                        if submissionInFlight && (t.outcome.journalDeleted || !t.journalSurvived
                                                  || t.deleteCalls != 0) { inFlightHeld = false }
                        if confirmed != expectedConfirmation(provider, chunkIds, refusing) { ruleHeld = false }
                        if t.attempted != expectedAttempts(provider, chunkIds) { attemptsHeld = false }
                        if t.outcome.attemptedChunkIds != t.attempted { attemptsHeld = false }
                        if (t.outcome.statusMessage != nil) != t.journalSurvived { messageHeld = false }
                        // …and the words name WHICH of the two reasons kept it, so the operator is not told
                        // "we could not stop it" about a batch every known chunk of which was stopped.
                        let expectedMessage: String? = shouldDelete
                            ? nil
                            : (confirmed ? OCRProcessor.batchCancellationSubmissionInFlightMessage
                                         : OCRProcessor.batchCancellationNotConfirmedMessage)
                        if t.outcome.statusMessage != expectedMessage { messageHeld = false }
                        if t.deleteCalls != (shouldDelete ? 1 : 0) { deleteCallsHeld = false }
                        // Observed, not predicted: a file that was there and is not any more.
                        if t.deleteCalls == 1 && t.journalExistedBefore && !t.journalSurvived {
                            deletions += 1
                            if submissionInFlight { deletionsWhileInFlight += 1 }
                        }
                        if !t.journalExistedBefore { fixtureHeld = false }
                    }
                }
            }
        }

        check("sweep: every provider × chunk-count × refusal × in-flight shape was exercised (\(trials) trials)",
              trials == 264)
        // Non-vacuity, measured against the file rather than the table: the in-flight invariant below is
        // worthless if nothing in this sweep ever deletes. Only the 132 finished-submission trials can, and
        // 8 of them do — Gemini at 1–6 chunks unrefused (6) plus Anthropic and Mistral at exactly 1 chunk
        // unrefused (1 each). Those same 8 shapes have an in-flight twin, and each twin deleted before
        // W16.bat5 and keeps now; that pairing is the whole regression, counted rather than asserted.
        check("sweep: 8 shapes really deleted a real journal file, and every one of them had finished submitting",
              deletions == 8 && deletionsWhileInFlight == 0)
        check("sweep: NO shape deletes the journal while a submission is in flight (132 in-flight trials)",
              inFlightHeld)
        check("sweep: a real journal file backed every one of those \(trials) trials",
              fixtureHeld)
        check("sweep: the journal is deleted if and only if the cancellation was confirmed AND nothing was in flight",
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
