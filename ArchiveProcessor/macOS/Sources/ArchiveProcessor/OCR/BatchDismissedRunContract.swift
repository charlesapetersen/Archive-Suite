import Foundation

/// **Dismissing an interrupted run cannot divert paid-batch results** (W16.bat8) — headless, $0, no
/// network, no keys.
///
/// A failed non-batch manifest write cancels its task before its normal cleanup clears
/// `activePendingRun`. The operator can then dismiss the run banner, which removes the on-disk manifest.
/// A subsequent batch deliberately does not assign `activePendingRun`; therefore its materialized results
/// must take the existing `activePendingRun == nil` route to the paid-batch journal. This contract puts the
/// processor in that reachable stale state, drives the real Dismiss action, then drives the real result
/// persistence method and reads the real redirected journal back from disk.
///
/// The state-root redirect is mandatory: this test creates and dismisses both shipped manifest names. It
/// refuses to touch either path unless `BatchJournalPathContract` has already established that they resolve
/// into the harness's scratch directory.
@MainActor
enum BatchDismissedRunContract {
    static func run(check: (String, Bool) -> Void, redirected: Bool) {
        guard redirected else {
            check("dismissed run: refused because the journal path did not resolve into the scratch state root",
                  false)
            return
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            "APDismissedRun-\(UUID().uuidString)", isDirectory: true)
        let outDir = dir.appendingPathComponent("out", isDirectory: true)
        let source = dir.appendingPathComponent("source.jpg")
        let output = outDir.appendingPathComponent("source.pdf")
        defer {
            OCRProcessor.deletePendingBatch()
            try? fm.removeItem(at: OCRProcessor.pendingRunURL)
            try? fm.removeItem(at: dir)
        }
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? Data("source".utf8).write(to: source)

        let model = LLMModel(id: "dismissed-run-contract", displayName: "Dismissed Run Contract",
                             provider: .gemini, supportsThinking: false, returnsMd: false,
                             inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
        let result = OCRResult(text: "already paid for", classification: nil, rotationDegrees: 0,
                               errorMessage: nil, errorCode: nil)
        let run = OCRProcessor.PendingRun(
            provider: .gemini, model: model, thinkingLevel: nil, fileURLs: [source],
            outputDirectory: outDir, enableTagging: false, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
            completedResults: [:])
        let batch = OCRProcessor.PendingBatch(
            batchId: "batches/w16-bat8", provider: .gemini, model: model, thinkingLevel: nil,
            fileURLs: [source], outputDirectory: outDir, enableTagging: false,
            sendPreviousImage: false, submittedAt: Date(), taggingMode: .none,
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: ["batches/w16-bat8"])

        let runSaved = OCRProcessor._testWritePendingRun(run, to: OCRProcessor.pendingRunURL)
        let savedBatch = OCRProcessor.savePendingBatch(batch)
        guard runSaved, let savedBatch else {
            check("dismissed run: scratch manifests are constructible", false)
            return
        }

        let processor = OCRProcessor()
        processor.activePendingRun = run
        processor.activePendingBatch = savedBatch
        processor.pendingRunInfo = "Interrupted run"

        processor.dismissPendingRun()
        let dismissed = processor.activePendingRun == nil
            && processor.pendingRunInfo == nil
            && !fm.fileExists(atPath: OCRProcessor.pendingRunURL.path)
        check("dismissed run: Dismiss clears the in-memory snapshot with its banner and disk manifest",
              dismissed)

        let saved = processor.saveResultToPendingRun(index: 0, result: result, outputURL: output)
        let journal = OCRProcessor._testReadPendingBatch(from: OCRProcessor.pendingBatchURL)
        check("dismissed run: the next paid-batch result is journaled to its own durable batch record",
              dismissed && saved
                  && journal?.completedResults["0"]?.text == result.text
                  && journal?.completedOutputPaths?["0"] == output.path
                  && !fm.fileExists(atPath: OCRProcessor.pendingRunURL.path)
                  && processor.activePendingRun == nil)
    }
}
