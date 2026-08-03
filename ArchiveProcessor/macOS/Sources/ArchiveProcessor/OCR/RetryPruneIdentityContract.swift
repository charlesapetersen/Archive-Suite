import AppKit
import Foundation

/// **A busy-model retry prunes the job it was dispatched for, or nothing** (W16.bat11) — headless, $0, no
/// network, no keys.
///
/// The bug this pins: `retryHighUseFailures` chose its indices, slept ten seconds, made a network call per
/// file, and then read `jobs[index]` on that bare index — no bounds check, no identity check, and no
/// `Task.isCancelled` between the suspension and the read. The operator can spend that window pressing Stop,
/// then **Clear** (`jobs = []`), re-dropping files and pressing **Start**. Out of range the subscript **TRAPS
/// the app**; in range it prunes the LIVE run's failure entry under a stopped row's filename, so the new
/// run's own "N failed" summary and `.txt` log under-count. `W16.bat9` closed this class for the completion
/// sweep and `W16.bat10` for every `handleOCRResult` caller's writes; this is the one read neither reached.
///
/// **This drives the real loop, not just the guard.** The two sections below install
/// `NetworkSession.testTransport` (the fail-closed seam from `W16.bat7-fu`) and call the shipped
/// `retryHighUseFailures` — real retry selection, real 10-second wait, real `GeminiClient`, real
/// `handleOCRResult` — with the file list mutated *by the stub*, i.e. exactly while the main actor is
/// suspended inside the OCR call. That costs this suite two 10-second sleeps, and buys the one thing a
/// guard-only section cannot have: the CALL SITE is under test too. A mutant that keeps the guard but hands
/// it a freshly-read `jobs[index].id` instead of the snapshotted `slot.jobID` reds §2 (the live row's id
/// matches, so the wrong file is pruned) and traps in §1.
///
/// **What is pinned.**
///   * §1 The list emptied across the OCR call neither traps nor prunes — and the file that WAS retried
///     honestly is still pruned in the same run, so the section cannot be satisfied by refusing everything.
///   * §2 The list REPLACED across the OCR call (Stop → Clear → re-drop → Start, different files) leaves the
///     new run's own failure entry alone. This is the quiet half of the bug: no crash, just a summary that
///     under-counts.
///   * §3 Three things the guard itself decides, driven directly because no timing is involved: the identity
///     is the job INSTANCE's and not the file's (the same file re-dropped compares equal by `sourceURL`,
///     which is the wrong fix `W16.bat9` shipped first), an honest pair still prunes, and a negative index is
///     refused (`jobs.indices.contains` rather than `index < jobs.count`).
///
/// **What a mutant looks like here.** ⚠️ NOT YET MEASURED — the list below is what this section is BUILT to
/// catch, and the commit that follows replaces it with what each mutant actually reddened:
///   * the guard removed entirely — THE bug — → §1 does not FAIL, it **TRAPS this process** and no report is
///     written at all (the `BatchSweepClearedListContract` §21 signature), so the suite goes RED with no
///     output rather than with a FAIL line.
///   * bounds only (`jobs.indices.contains(index)`) → **1 RED**: §2, the quiet case — in range, wrong row.
///   * `jobs[index].sourceURL == fileURLs[index]` instead of the id → **1 RED**: §3's first check.
///   * a bare `return` at the top of the guard → **2 RED**: §1's honest prune and §3's non-vacuity check.
///   * `index < jobs.count` instead of `jobs.indices.contains(index)` → **1 RED**: §3's negative index.
///
/// Scope: the retry loop's prune. NOT the loop's other unguarded read (`jobs[index].status = .processing`),
/// which is main-actor-synchronous with the cancellation guard above it — nothing can land in between — and
/// NOT what `handleOCRResult` does with the same identity, which is `StaleRunResultIdentityContract`'s.
///
/// No manifest and no journal is written by any check here: no fixture builds a `PendingRun` or a
/// `PendingBatch`, so `saveResultToPendingRun` takes its `activePendingRun == nil, activePendingBatch == nil`
/// path and returns `true` without touching disk. Every file this section writes is under one temp directory
/// it removes. That is why it needs no redirect verdict, unlike its siblings.
///
/// Run from `BatchResumeTestDriver` (section 24) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`.
@MainActor
enum RetryPruneIdentityContract {

    static func run(check: (String, Bool) -> Void) async {
        let dormantBefore = !NetworkSession.testTransportIsActive && NetworkSession.testTransport == nil

        // MARK: 1. The list emptied across the OCR call — the crash, and the honest prune beside it
        //
        // Two retryable files, one real run. The stub answers the first honestly and empties `jobs` while
        // answering the second, so the same loop produces both halves: a prune that must happen and a read
        // that must not.
        let emptied = await retry(.emptyTheListOnRequest(2))
        check("retry prune: the app survives Clear pressed while a busy-model retry's OCR call is in flight "
              + "— reaching this check at all is most of it, because an unguarded read TRAPS this process "
              + "before any report is written (see this file's header)",
              emptied.mutationLandedDuringTheCall && emptied.listWasEmptyAfterwards)
        check("retry prune: the file that was retried BEFORE the list was emptied is still pruned from the "
              + "failure list, and both files really went through the provider client",
              emptied.prunedTheHonestFile && emptied.requests == 2)
        check("retry prune: the file whose row vanished mid-call is NOT pruned — nothing is read from a list "
              + "that no longer has that index",
              emptied.keptTheStaleFile)

        // MARK: 2. The list REPLACED across the OCR call — the quiet half
        //
        // Stop, Clear, re-drop different files, Start: the new run's jobs take the same indices, so a bounds
        // check passes and the stale row's prune lands on a live file's failure entry instead.
        let replaced = await retry(.replaceTheListOnRequest(1))
        check("retry prune: a run started while the retry was in flight keeps its OWN failure entry — the "
              + "stopped run's retry does not prune the file that now sits at that index",
              replaced.mutationLandedDuringTheCall && replaced.keptTheNewRunsFailure
                  && replaced.requests == 1)
        check("retry prune: ...and prunes nothing else either — the whole failure list is as the new run "
              + "left it",
              replaced.failureListUnchanged)

        // MARK: 3. What the guard itself decides
        //
        // No suspension is involved in any of these, so they are driven straight at the shipped guard.
        check("retry prune: a row refilled with the very same file is still a different row — its identity "
              + "is the job's id, so the new run's own failure entry for that filename survives",
              !prune(.theSameFileReDropped))
        check("retry prune: ...while the run's own live job still gets its failure entry pruned",
              prune(.honest))
        check("retry prune: a negative index is refused rather than trapped — the bounds half is "
              + "`jobs.indices.contains`, not `index < jobs.count`",
              !prune(.negativeIndex))

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
        /// The file retried before the mutation is gone from `failedFiles` (§1's non-vacuity).
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
            // `retrySlots` is built from the RESULT (`isRetryableError`), not the status, so the 503 below
            // is what puts both files in it; `.failed` is only what the run would have left on screen.
            job.status = .failed
            job.result = OCRResult(text: nil, classification: nil,
                                   errorMessage: "The model is experiencing high demand", errorCode: "503")
            return job
        }
        // What the run recorded before the retry: both busy files failed. `fresh-0.jpg` is a failure the
        // NEW run recorded for itself, and is the entry the quiet half of the bug destroys.
        let failuresBefore = ["busy-0.jpg", "busy-1.jpg", "fresh-0.jpg"]
        processor.failedFiles = failuresBefore

        let transcript = Transcript()
        NetworkSession.testTransport = stub(mutation, on: processor, newRunSources: newRunSources,
                                           transcript: transcript)
        // The real thing: real retry selection, real 10s wait, real client, real `handleOCRResult`.
        await processor.retryHighUseFailures(
            fileURLs: stoppedRunSources, provider: .gemini, model: model(), thinkingLevel: nil,
            apiKey: "retry-prune-not-a-key", outputDirectory: outDir,
            runConfig: runConfig(outputDirectory: outDir))
        // Uninstalled only once the call has fully RETURNED, so no request it started is still looking for
        // a stub.
        NetworkSession.testTransport = nil

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
    /// `GeminiClient.parseResponse` accepts as one page of text — plus the file-list mutation, performed on
    /// the main actor from inside the request so it lands in the one window that matters.
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

    // MARK: - The guard itself

    private enum Handed: Equatable {
        /// The pair the loop holds for its own live job.
        case honest
        /// Cleared and re-dropped with the SAME file at the same index: equal by source, not by identity.
        case theSameFileReDropped
        /// Not reachable from `retrySlots` (which is built from `jobs.indices`), and pinned anyway: it is the
        /// difference between the two ways of spelling the bounds half.
        case negativeIndex
    }

    /// Whether the name was pruned. No file is created: the guard reads `sourceURL.lastPathComponent` and
    /// nothing else, so a path that never existed is the honest fixture here.
    private static func prune(_ handed: Handed) -> Bool {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("APRetryPruneGuard-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("busy-0.jpg")
        let processor = OCRProcessor()
        processor.jobs = [OCRJob(sourceURL: source)]
        // The pair bound at dispatch, before anything changed under it.
        let dispatchedJobID = processor.jobs[0].id

        switch handed {
        case .honest, .negativeIndex:
            break
        case .theSameFileReDropped:
            // The SAME file, dropped again: a fresh `OCRJob.id`, an identical `sourceURL`. `failedFiles` now
            // holds THIS run's own failure for it, which is what a source-equality guard would destroy.
            processor.jobs = [OCRJob(sourceURL: source)]
        }
        processor.failedFiles = ["busy-0.jpg"]
        processor.clearFailedFile(forRetriedJobAt: handed == .negativeIndex ? -1 : 0,
                                 jobID: handed == .honest ? processor.jobs[0].id : dispatchedJobID)
        return !processor.failedFiles.contains("busy-0.jpg")
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
