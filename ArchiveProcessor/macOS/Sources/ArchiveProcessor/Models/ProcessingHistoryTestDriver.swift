import Foundation

/// Headless, $0 self-test of the processing-history feature (cost + run log), gated by
/// `PROCESSING_HISTORY_TEST=1` (does nothing in normal use). No OCR, no network, no cost, no GUI — it
/// exercises `RunHistorySnapshot.makeRun`, the estimator-derived cost, and `ProcessingHistoryStore`'s
/// record / newest-first / bounded-trim / persistence / clear behavior.
///
/// SAFETY: runs against a THROWAWAY `UserDefaults(suiteName:)`, never `.standard`, so it can never read
/// or clobber the operator's real processing history. Writes a PASS/FAIL report to
/// `PROCESSING_HISTORY_TEST_OUT` (or a temp file) + NSLog. Test scaffolding only.
@MainActor
enum ProcessingHistoryTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["PROCESSING_HISTORY_TEST"] == "1" else { return }
        didRun = true
        run()
    }

    static func run() {
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("HISTORYTEST \(ok ? "PASS" : "FAIL"): \(name)")
        }

        let suiteName = "APHistoryTest-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            try? "SOME FAILED\nFAIL: could not create isolated UserDefaults suite\n"
                .write(toFile: outPath(), atomically: true, encoding: .utf8)
            return
        }

        let model = LLMProvider.gemini.models[0]
        // Build a snapshot with the estimator's DEFAULT knobs (scale 1.0 / rotation off / no gateway) so the
        // recorded cost is directly comparable to a plain CostEstimator.estimate(...) call below.
        func snapshot(fileCount: Int, batch: Bool = false, preOCRed: Bool = false, reOCR: Bool = false) -> RunHistorySnapshot {
            RunHistorySnapshot(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                provider: .gemini, gatewayConfig: nil, imageTokenProvider: nil,
                model: model, batchMode: batch, enableTagging: true,
                enableCollectionSegmentation: false, preOCRedInput: preOCRed,
                reOCRMultiPagePDF: reOCR, sendPreviousImage: false, contextCharCount: 0,
                imageScale: 1.0, rotationMode: .off, fileCount: fileCount)
        }

        // --- makeRun: counts + clamps ---
        let s = snapshot(fileCount: 10)
        let r = s.makeRun(succeeded: 7)
        check("makeRun records succeeded/failed/fileCount", r.succeeded == 7 && r.failed == 3 && r.fileCount == 10)
        let over = s.makeRun(succeeded: 999)
        check("makeRun clamps over-count", over.succeeded == 10 && over.failed == 0)
        let neg = s.makeRun(succeeded: -5)
        check("makeRun clamps negative", neg.succeeded == 0 && neg.failed == 10)

        // --- cost matches the pre-run estimator's math ---
        let expected = CostEstimator.estimate(
            fileCount: 10, model: model, enableTagging: true,
            sendPreviousImage: false, contextCharCount: 0).totalStandard
        check("standard cost > 0 and equals the estimator", r.cost > 0 && abs(r.cost - expected) < 1e-9)

        // --- modeLabel + batch cost branch ---
        check("standard modeLabel", snapshot(fileCount: 3).makeRun(succeeded: 3).modeLabel == "Standard")
        let batchRun = snapshot(fileCount: 10, batch: true).makeRun(succeeded: 10)
        check("batch modeLabel", batchRun.modeLabel == "Batch")
        check("batch cost uses the discounted batch total (< standard, > 0)", batchRun.cost > 0 && batchRun.cost < r.cost)
        check("preOCRed modeLabel", snapshot(fileCount: 2, preOCRed: true).makeRun(succeeded: 2).modeLabel == "Pre-OCRed")
        check("reOCR modeLabel", snapshot(fileCount: 2, reOCR: true).makeRun(succeeded: 2).modeLabel == "Re-OCR PDF")
        check("providerLabel is the provider (no gateway)", r.providerLabel == LLMProvider.gemini.rawValue)

        // --- store: record / newest-first / totals ---
        let store = ProcessingHistoryStore(defaults: suite)
        check("fresh isolated store is empty", store.runs.isEmpty)
        store.record(snapshot(fileCount: 1).makeRun(succeeded: 1))
        store.record(snapshot(fileCount: 2).makeRun(succeeded: 2))
        store.record(snapshot(fileCount: 4).makeRun(succeeded: 4))
        check("record inserts newest-first", store.runs.count == 3 && store.runs[0].fileCount == 4 && store.runs[2].fileCount == 1)
        check("totalFiles sums", store.totalFiles == 7)
        check("totalCost sums the runs", store.totalCost > 0 && abs(store.totalCost - store.runs.reduce(0) { $0 + $1.cost }) < 1e-9)

        // --- bounded log: oldest drop off past maxRuns ---
        let extra = ProcessingHistoryStore.maxRuns + 10
        for i in 0..<extra { store.record(snapshot(fileCount: 100 + i).makeRun(succeeded: 0)) }
        check("log is bounded to maxRuns", store.runs.count == ProcessingHistoryStore.maxRuns)
        check("newest survives the trim", store.runs[0].fileCount == 100 + extra - 1)

        // --- persistence round-trip on the same suite ---
        let reloaded = ProcessingHistoryStore(defaults: suite)
        check("persisted runs reload identically",
              reloaded.runs.count == ProcessingHistoryStore.maxRuns && reloaded.runs[0].fileCount == store.runs[0].fileCount)

        // --- clear ---
        store.clear()
        check("clear empties in memory", store.runs.isEmpty)
        check("clear persists an empty log", ProcessingHistoryStore(defaults: suite).runs.isEmpty)

        suite.removePersistentDomain(forName: suiteName)   // leave no throwaway plist behind

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        try? report.write(toFile: outPath(), atomically: true, encoding: .utf8)
        NSLog("HISTORYTEST DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath())")
    }

    private static func outPath() -> String {
        ProcessInfo.processInfo.environment["PROCESSING_HISTORY_TEST_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("APHistoryTest-RESULT.txt").path
    }
}
