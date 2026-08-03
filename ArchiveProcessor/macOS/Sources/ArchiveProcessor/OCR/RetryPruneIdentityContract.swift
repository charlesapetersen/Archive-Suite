import AppKit
import Foundation

/// **A busy-model retry reads nothing from a file list that moved under it** (W16.bat11) — headless, $0, no
/// network, no keys.
///
/// The bug this pins: `retryHighUseFailures` chose its indices, slept ten seconds, made a network call per
/// file, and then read `jobs[index]` on that bare index — no bounds check, no identity check, and no
/// `Task.isCancelled` between the suspension and the read. The operator can spend that window pressing Stop,
/// then **Clear** (`jobs = []`), re-dropping files and pressing **Start**. Out of range the subscript **TRAPS
/// the app**; in range it pruned the LIVE run's failure entry under a stopped row's filename, so the new
/// run's own "N failed" summary and `.txt` log under-counted. `W16.bat9` closed this class for the completion
/// sweep and `W16.bat10` for every `handleOCRResult` caller's writes; this was the one read neither reached.
///
/// **The fix it pins is a deletion, not a guard**, and that changes what this section can attribute. The
/// retry's prune was redundant: `handleOCRResult` prunes the same name, off the same `(index, jobID)` pair,
/// under the same `result.text != nil` condition, behind the identity guard `W16.bat10` gave it, with nothing
/// observing `failedFiles` in between. So the prune now has one owner and the retry loop reads `jobs` only
/// where it is main-actor-synchronous. §1's honest-prune check is therefore a check on `handleOCRResult`'s
/// prune reached THROUGH the real retry loop — which is exactly the invariant that made the deletion safe,
/// and it reds if that prune ever goes away.
///
/// **This drives the real loop, not a helper.** Both sections install `NetworkSession.testTransport` (the
/// fail-closed seam from `W16.bat7-fu`) and call the shipped `retryHighUseFailures` — real retry selection,
/// real 10-second wait, real `GeminiClient`, real `handleOCRResult` — with the file list mutated *by the stub*,
/// i.e. exactly while the main actor is suspended inside the OCR call. That costs this suite two real
/// 10-second waits, which is the shipped retry's own sleep and the reason the window needed a seam rather
/// than the enqueued-main-actor-task trick that drove bat9 and bat10.
///
/// **What is pinned.**
///   * §1 The list emptied across the OCR call neither traps nor loses the run's bookkeeping: the file
///     retried BEFORE the mutation is still pruned, and the one whose row vanished is left listed.
///   * §2 The list REPLACED across the OCR call (Stop → Clear → re-drop DIFFERENT files → Start) leaves the
///     new run's own failure entry alone. This is the quiet half of the bug — no crash, just a summary that
///     under-counts — and it is the check a bounds-only "fix" fails.
///
/// **What a mutant looks like here.** Three measured 2026-08-03 against the whole 377-check driver:
///   * the unguarded read put back — THE bug — → **no report at all**: it does not FAIL, it **TRAPS this
///     process** (0 of 377 checks written, the `BatchSweepClearedListContract` §21 signature), because §1
///     empties the list across the call and the subscript is then out of range.
///   * the read put back with a BOUNDS check only → **2 RED**, both of §2: the new run's own failure entry for
///     the file now at that index is pruned, and the failure list is no longer what that run left. This is
///     the quiet case, and it is why bounds alone was never the fix.
///   * `handleOCRResult`'s own prune neutered (`failedFiles.removeAll` at `+OCR.swift:1342` deleted) → **1
///     RED**: §1's honest-prune check, and nothing else in 377. That is the measurement the deletion rests
///     on — it says this behaviour has exactly one owner now, that the retry loop still reaches it, and that
///     dropping it would be caught here rather than silently.
///
/// Scope: what the retry loop reads across its OCR call. NOT the loop's `jobs[index].status = .processing`
/// (`:1620`) or `fileURLs[index]` (`:1619`), which the adversarial pass confirmed unreachable rather than
/// merely unguarded: `cancel()` cancels the `processingTask` all three call sites run on, **Clear** is
/// disabled while `isProcessing`, and a row that vanishes mid-call makes `handleOCRResult` return `false`, so
/// the loop exits before the next iteration's write. Production has no path that TRUNCATES `jobs` while
/// keeping the surviving rows' ids — that, and only that, would reach those two — so no fixture here stages
/// one. And NOT what `handleOCRResult` does with a stale identity, which is
/// `StaleRunResultIdentityContract`'s.
///
/// No manifest and no journal is written by any check here: no fixture builds a `PendingRun` or a
/// `PendingBatch`, so `saveResultToPendingRun` takes its both-nil path and returns `true` without touching
/// disk. Every file written is under one temp directory the fixture removes. That is why this section needs
/// no redirect verdict, unlike its siblings.
///
/// Run from `BatchResumeTestDriver` (section 24) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum RetryPruneIdentityContract {

    static func run(check: (String, Bool) -> Void) async {
        let dormantBefore = !NetworkSession.testTransportIsActive && NetworkSession.testTransport == nil

        // MARK: 1. The list emptied across the OCR call — the crash, and the bookkeeping beside it
        //
        // Two retryable files, one real run. The stub answers the first honestly and empties `jobs` while
        // answering the second, so the same loop produces both halves: bookkeeping that must still happen and
        // a read that must not.
        let emptied = await retry(.emptyTheListOnRequest(2))
        check("retry prune: the app survives Clear pressed while a busy-model retry's OCR call is in flight "
              + "— reaching this check at all is most of it, because an unguarded read TRAPS this process "
              + "before any report is written (see this file's header)",
              emptied.mutationLandedDuringTheCall && emptied.listWasEmptyAfterwards)
        check("retry prune: the file retried BEFORE the list was emptied is still pruned from the failure "
              + "list, and both files really went through the provider client — the prune the retry loop "
              + "stopped doing itself is still done, once, by `handleOCRResult`",
              emptied.prunedTheHonestFile && emptied.requests == 2)
        check("retry prune: the file whose row vanished mid-call is left listed — nothing is read from, or "
              + "decided about, a list that no longer has that index",
              emptied.keptTheStaleFile)

        // MARK: 2. The list REPLACED across the OCR call — the quiet half
        //
        // Stop, Clear, re-drop different files, Start: the new run's jobs take the same indices, so a bounds
        // check passes and the stopped row's prune lands on a live file's failure entry instead.
        let replaced = await retry(.replaceTheListOnRequest(1))
        check("retry prune: a run started while the retry was in flight keeps its OWN failure entry — the "
              + "stopped run's retry does not prune the file that now sits at that index",
              replaced.mutationLandedDuringTheCall && replaced.keptTheNewRunsFailure
                  && replaced.requests == 1)
        check("retry prune: ...and prunes nothing else either — the whole failure list is as the new run "
              + "left it",
              replaced.failureListUnchanged)

        check("retry prune: the transport seam was dormant before this section and is dormant again after "
              + "it — no stub outlives the checks that installed it",
              dormantBefore && !NetworkSession.testTransportIsActive
                  && NetworkSession.testTransport == nil)
    }

    // MARK: - The real loop

    /// What the stub does to the file list, and on which request.
    private enum Mutation {
        /// The **Clear** button, verbatim (`jobs = []`), while the Nth OCR call is in flight.
        case emptyTheListOnRequest(Int)
        /// Clear, re-drop DIFFERENT files, Start: same indices, new jobs, new ids.
        case replaceTheListOnRequest(Int)
    }

    /// Everything observable about one real run of `retryHighUseFailures`.
    private struct Retried {
        let requests: Int
        /// The stub really mutated `jobs` from inside a request — i.e. the window was staged, not missed.
        let mutationLandedDuringTheCall: Bool
        /// `jobs` is still empty afterwards (the emptied fixture's half of the same fact).
        let listWasEmptyAfterwards: Bool
        /// The file retried before the mutation is gone from `failedFiles`.
        let prunedTheHonestFile: Bool
        /// The file whose row vanished across its own call is still listed.
        let keptTheStaleFile: Bool
        /// The NEW run's failure entry for the file now at that index is still listed.
        let keptTheNewRunsFailure: Bool
        let failureListUnchanged: Bool
    }

    /// `nonisolated` because the stub closure that interpolates it runs off this actor.
    private nonisolated static let retriedText = "TEXT THE BUSY MODEL RETURNED ON THE RETRY"

    /// One real `retryHighUseFailures` over two retryable files, with the file list mutated from inside the
    /// stubbed transport — i.e. while the main actor is genuinely suspended in the OCR call.
    private static func retry(_ mutation: Mutation) async -> Retried {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("APRetryPrune-\(UUID().uuidString)", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let stoppedRunSources = (0..<2).map { makeJPEG("busy-\($0).jpg", in: dir) }
        let newRunSources = (0..<2).map { makeJPEG("fresh-\($0).jpg", in: dir) }

        let processor = OCRProcessor()
        processor.isProcessing = true
        processor.jobs = stoppedRunSources.map { source in
            var job = OCRJob(sourceURL: source)
            // `retrySlots` is built from the RESULT (`isRetryableError`), not the status, so the 503 below is
            // what puts both files in it; `.failed` is only what the run would have left on screen.
            job.status = .failed
            job.result = OCRResult(text: nil, classification: nil,
                                   errorMessage: "The model is experiencing high demand", errorCode: "503")
            return job
        }
        // What the run recorded before the retry: both busy files failed. `fresh-0.jpg` is a failure the NEW
        // run recorded for itself, and is the entry the quiet half of the bug destroys.
        let failuresBefore = ["busy-0.jpg", "busy-1.jpg", "fresh-0.jpg"]
        processor.failedFiles = failuresBefore

        let transcript = Transcript()
        NetworkSession.testTransport = stub(mutation, on: processor, newRunSources: newRunSources,
                                           transcript: transcript)
        // Deferred rather than assigned after the call: a trap inside the section must not leave a stub
        // installed for whatever runs next.
        defer { NetworkSession.testTransport = nil }
        // The real thing: real retry selection, real 10s wait, real client, real `handleOCRResult`.
        await processor.retryHighUseFailures(
            fileURLs: stoppedRunSources, provider: .gemini, model: model(), thinkingLevel: nil,
            apiKey: "retry-prune-not-a-key", outputDirectory: outDir,
            runConfig: runConfig(outputDirectory: outDir))

        let after = processor.failedFiles
        return Retried(
            requests: transcript.requests,
            mutationLandedDuringTheCall: transcript.mutated,
            listWasEmptyAfterwards: processor.jobs.isEmpty,
            prunedTheHonestFile: !after.contains("busy-0.jpg"),
            keptTheStaleFile: after.contains("busy-1.jpg"),
            keptTheNewRunsFailure: after.contains("fresh-0.jpg"),
            failureListUnchanged: after == failuresBefore)
    }

    /// What the stub was asked for. A MainActor box because the closure runs off this actor and the count is
    /// read back after the call has returned — asserting it is how a check proves the loop really reached the
    /// provider client rather than short-circuiting above it.
    @MainActor private final class Transcript {
        var requests = 0
        /// Set by the stub when it actually replaces the file list, so a check can assert the window was
        /// staged rather than infer it from a green result.
        var mutated = false
    }

    /// The literal Gemini `generateContent` body that stands in for the wire — the smallest shape
    /// `GeminiClient` accepts as one page of text — plus the file-list mutation, performed on the main actor
    /// from inside the request so it lands in the one window that matters.
    private static func stub(_ mutation: Mutation, on processor: OCRProcessor, newRunSources: [URL],
                             transcript: Transcript)
        -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        return { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let n = await MainActor.run { () -> Int in
                transcript.requests += 1
                return transcript.requests
            }
            switch mutation {
            case .emptyTheListOnRequest(let target) where n == target:
                // The **Clear** button's action, verbatim.
                await MainActor.run { processor.jobs = []; transcript.mutated = true }
            case .replaceTheListOnRequest(let target) where n == target:
                await MainActor.run {
                    processor.jobs = newRunSources.map { source in
                        var job = OCRJob(sourceURL: source)
                        job.status = .processing     // exactly what `startProcessing` leaves them in
                        return job
                    }
                    transcript.mutated = true
                }
            default:
                break
            }
            let body = #"{"candidates":[{"content":{"parts":[{"text":"\#(retriedText)"}]}}]}"#
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                 httpVersion: "HTTP/1.1", headerFields: nil) else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
    }

    // MARK: - Fixtures

    /// A synthetic model — never sent anywhere; built by hand so no check depends on `CustomModelStore`.
    private static func model() -> LLMModel {
        LLMModel(id: "retry-prune-gemini", displayName: "Retry Prune Gemini",
                 provider: .gemini, supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// `rotationMode: .off` is the load-bearing field: with the default read from the operator's settings a
    /// run could fire LLM rotation requests through the same seam, and the request counts above are what
    /// prove which OCR call was in flight when the list changed.
    private static func runConfig(outputDirectory: URL) -> SessionProcessingConfig {
        SessionProcessingConfig(
            provider: .gemini, model: model(), thinkingLevel: .low,
            apiKey: "retry-prune-not-a-key", taggingMode: .none, rotationMode: .off,
            mergeDocuments: false, outputDirectory: outputDirectory, contextCharCount: 0,
            sendPreviousImage: false, customOCRPrompt: "", imageScale: 1.0,
            enableSegmentJSON: false, tagVocabulary: [], gateway: nil,
            outputImageFile: false, pdfImageMB: 1.0, exportedImageMB: 1.0, textColumns: 1)
    }

    /// A REAL 64×64 JPEG, so `GeminiClient` has something to encode and `PDFGenerator` behaves as it does in
    /// production — with junk bytes the PDF write can throw and rewrite the job's result instead.
    private static func makeJPEG(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let jpeg = bitmap?.representation(using: .jpeg, properties: [:]) { try? jpeg.write(to: url) }
        return url
    }
}
