import Foundation
import AppKit
import PDFKit

/// Headless, $0 self-test of the processing-history feature (cost + run log), gated by
/// `PROCESSING_HISTORY_TEST=1` (does nothing in normal use). No OCR, no network, no cost, no GUI — it
/// exercises `RunHistorySnapshot.makeRun`, the estimator-derived cost, the Local Agent's durable
/// PDF/run-history provenance, and `ProcessingHistoryStore`'s record / newest-first / bounded-trim /
/// persistence / clear behavior.
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
        func snapshot(fileCount: Int, batch: Bool = false, preOCRed: Bool = false, reOCR: Bool = false,
                      localAgent: LocalAgentConfig? = nil) -> RunHistorySnapshot {
            RunHistorySnapshot(
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                provider: .gemini, gatewayConfig: nil, localAgent: localAgent, imageTokenProvider: nil,
                model: model, visionTextProvider: nil, visionTextModel: nil,
                batchMode: batch, enableTagging: true,
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

        // Local Agent calls do not use the selected API provider or its price. Persist the actual CLI plus
        // its override/default marker, and generate a real scratch PDF to prove the shared header parser
        // still strips the new free-form provenance line correctly.
        let localAgent = LocalAgentConfig(tool: .claude, binaryPath: "/tmp/fake-claude",
                                          modelOverride: "claude-sonnet-4-6")
        let localRun = snapshot(fileCount: 3, localAgent: localAgent).makeRun(succeeded: 3)
        check("Local Agent history records the CLI and $0 rather than its selected API fallback",
              localRun.providerLabel == "Local CLI Agent (claude)"
                  && localRun.modelName == "claude-sonnet-4-6" && localRun.cost == 0)
        let multilineAgent = LocalAgentConfig(tool: .codex, modelOverride: "codex-main\nClassification:")
        check("Local Agent provenance model stays a single durable-header line",
              multilineAgent.provenanceModelName == "codex-main Classification:")
        let provenanceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("APProvenanceTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: provenanceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: provenanceDir) }
        let source = provenanceDir.appendingPathComponent("source.jpg")
        let output = provenanceDir.appendingPathComponent("output.pdf")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let bitmap { try? bitmap.representation(using: .jpeg, properties: [:])?.write(to: source) }
        let pdfResult = try? PDFGenerator().generate(
            imageURL: source, result: OCRResult(text: "Provenance body.", classification: nil,
                                                 errorMessage: nil, errorCode: nil),
            model: model, outputURL: output, originalFileName: source.lastPathComponent,
            localAgentDisplayName: localAgent.provenanceDisplayName,
            localAgentModelName: localAgent.provenanceModelName
        )
        let pdfText = PDFDocument(url: output)?.page(at: 1)?.string ?? ""
        let extractedText = PDFTextExtractor.extract(from: output).text
        check("Local Agent PDF provenance names the CLI and still round-trips its body",
              pdfResult == .embedded
                  && pdfText.contains("Local CLI Agent (claude) \u{00B7} claude-sonnet-4-6")
                  && !pdfText.contains("\n\(model.provider.rawValue) \u{00B7}")
                  && extractedText?.contains("Provenance body.") == true)

        // A Vision hybrid has free on-device image OCR and a separately billed text-only LLM. History
        // must retain that distinction rather than presenting a $0 Vision run or pricing cloud images.
        let visionModel = LLMProvider.appleVision.models[0]
        let hybridSnapshot = RunHistorySnapshot(
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            provider: .appleVision, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil, model: visionModel,
            visionTextProvider: .gemini, visionTextModel: model, batchMode: false,
            enableTagging: true, enableCollectionSegmentation: false, preOCRedInput: false,
            reOCRMultiPagePDF: false, sendPreviousImage: false, contextCharCount: 0,
            imageScale: 1.0, rotationMode: .llmSingle, fileCount: 10)
        let hybridRun = hybridSnapshot.makeRun(succeeded: 10)
        let hybridExpected = CostEstimator.estimate(
            fileCount: 10, model: model, enableTagging: true,
            sendPreviousImage: false, contextCharCount: 0, rotationMode: .llmSingle,
            visionTextOnly: true).totalStandard
        check("Vision hybrid history prices only text work and labels both backends",
              hybridRun.cost > 0 && abs(hybridRun.cost - hybridExpected) < 1e-9
              && hybridRun.providerLabel == "Apple Vision + \(LLMProvider.gemini.rawValue)"
              && hybridRun.modelName == "Vision + \(model.displayName)")

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
