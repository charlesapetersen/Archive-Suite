#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import Foundation

/// W49.proc-suspects-filing (S-035): which review gates a resumed paid batch raises. A finished Gemini batch journal
/// (every chunk consumed, every page's result and output PDF on disk) is saved into a scratch state directory, and the
/// real `resumeBatch` (the pending-batch Resume button's call) runs it under Automatic tagging, the wire stubbed (tag
/// calls get a fixed tag JSON; nothing else is expected). An autopilot answers every review gate the way Process Files'
/// sheets would and records it. Gated by `RESUME_GATES_TEST=1`; $0, no network, scratch only. Writes the gates, the
/// requests and the run's status to `RESUME_GATES_TEST_OUT`.
@MainActor
enum ResumeReviewGatesProbe {
    nonisolated static let envKey = "RESUME_GATES_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    @MainActor private final class Progress { var gates: [String] = []; var finished = false }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String] = []
        func add(_ s: String) { lock.withLock { _urls.append(s) } }
        var urls: [String] { lock.withLock { _urls } }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APResumeGates-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        var out: [String] = []

        // The journal goes to scratch, never the operator's Application Support (the RunQuitResumeContract pattern).
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let saved = ["BATCHRESUME_TEST", "ARCHIVEPROC_TEST_STATE_ROOT"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("BATCHRESUME_TEST", "1", 1)
        setenv("ARCHIVEPROC_TEST_STATE_ROOT", stateRoot.path, 1)
        defer { for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
        guard OCRProcessor.pendingBatchURL.deletingLastPathComponent().standardizedFileURL
                == stateRoot.standardizedFileURL else {
            finish(["FAIL: the batch journal is not redirected into scratch — \(OCRProcessor.pendingBatchURL.path)"])
            return
        }
        try? fm.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        // Six photos read as box label, folder label, a two-page letter and two documents; each page's PDF on disk.
        let input = root.appendingPathComponent("input", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try? fm.createDirectory(at: input, withIntermediateDirectories: true)
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        let classes: [DocumentClassification] = [.boxLabel, .folderLabel, .documentStart, .documentContinuation,
                                                 .documentStart, .documentStart]
        var files: [URL] = []
        var results: [String: OCRResult] = [:]
        var paths: [String: String] = [:]
        for (i, cls) in classes.enumerated() {
            let photo = input.appendingPathComponent(String(format: "p%02d.jpg", i + 1))
            let pdf = output.appendingPathComponent(String(format: "p%02d.pdf", i + 1))
            guard writeJPEG(photo, shade: 0.15 * Double(i + 1)), writeFixturePDF(pdf) else {
                finish(["FAIL: fixture files could not be written"])
                return
            }
            files.append(photo)
            results[String(i)] = OCRResult(text: "Probe page \(i + 1) text.", classification: cls,
                                           errorMessage: nil, errorCode: nil)
            paths[String(i)] = pdf.path
        }
        let model = LLMProvider.gemini.models[0]
        let journal = OCRProcessor.savePendingBatch(OCRProcessor.PendingBatch(
            batchId: "batches/probe-0", provider: .gemini, model: model, thinkingLevel: nil, fileURLs: files,
            outputDirectory: output, enableTagging: true, sendPreviousImage: false, submittedAt: Date(),
            taggingMode: .automatic,
            runFingerprint: OCRProcessor.runFingerprint(files: files, outputDirectory: output, taggingMode: .automatic,
                                                        enableTagging: true, batchMode: true, preserveInputOrder: true),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: ["batches/probe-0"], consumedChunkIds: ["batches/probe-0"],
            completedResults: results, completedOutputPaths: paths))
        guard let journal, OCRProcessor.pendingBatchIsSelfConsistent(journal) else {
            finish(["FAIL: the finished journal is not one resumeBatch accepts"])
            return
        }

        let requests = Requests()
        NetworkSession.testTransport = { request in
            let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let kind = body.contains("subject_tags") ? "tags" : "other"
            requests.add("\(kind) \(request.httpMethod ?? "?") \(request.url?.path ?? "")")
            let text = kind == "tags"
                ? #"{"year": "1918", "month": "3", "day": "12", "date_uncertain": false, "subject_tags": ["Probe"], "format": "Letter"}"#
                : "no"
            let reply: [String: Any] = [
                "candidates": [["content": ["parts": [["text": text]], "role": "model"], "finishReason": "STOP"]],
                "usageMetadata": ["promptTokenCount": 10, "candidatesTokenCount": 10, "totalTokenCount": 20]]
            let data = try JSONSerialization.data(withJSONObject: reply)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (data, response)
        }
        defer { NetworkSession.testTransport = nil }

        let processor = OCRProcessor()
        let progress = Progress()
        let run = Task { @MainActor in
            await processor.resumeBatch(apiKey: "resume-gates-not-a-key")
            progress.finished = true
        }
        let start = Date()
        while !progress.finished && Date().timeIntervalSince(start) < 150 {
            if processor.awaitingRetryDecision { progress.gates.append("retry"); processor.continueWithoutRetry() }
            else if processor.awaitingDocumentReview { progress.gates.append("documentReview"); processor.confirmDocumentReview() }
            else if processor.awaitingBoxFolderConfirmation {
                progress.gates.append("boxFolderConfirmation"); processor.confirmBoxFolderReview()
            }
            else if processor.awaitingCollectionConfirmation {
                progress.gates.append("collectionConfirmation"); processor.confirmCollectionReview()
            }
            else if processor.awaitingFinalReview { progress.gates.append("finalReview"); processor.confirmFinalReview() }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !progress.finished { run.cancel(); out.append("FAIL: the resumed batch did not finish in 150 s") }
        await run.value
        let tagged = files.indices.filter { i in
            guard let pdf = paths[String(i)] else { return false }
            return !((try? URL(fileURLWithPath: pdf).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []).isEmpty
        }.count
        out.append("gates\t\(progress.gates.isEmpty ? "(none)" : progress.gates.joined(separator: ","))")
        out.append("segments\t\(processor.segments.count)")
        out.append("tagged_outputs\t\(tagged) of \(files.count)")
        out.append("requests\t\(requests.urls.isEmpty ? "(none)" : requests.urls.joined(separator: "; "))")
        out.append("status\t\(processor.statusMessage)")
        OCRProcessor.deletePendingBatch()
        out.append("DONE")
        finish(out)
    }

    private static func writeJPEG(_ url: URL, shade: Double) -> Bool {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                            samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let pixels = bitmap.bitmapData,
              let data = { memset(pixels, Int32(shade * 255), bitmap.bytesPerRow * bitmap.pixelsHigh)
                  return bitmap.representation(using: .jpeg, properties: [:]) }() else { return false }
        return (try? data.write(to: url)) != nil
    }

    private static func writeFixturePDF(_ url: URL) -> Bool {
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 140)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return false }
        context.beginPDFPage(nil)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func finish(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        NSLog("RESUMEGATES \(text)")
        let path = ProcessInfo.processInfo.environment["RESUME_GATES_TEST_OUT"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("resume-gates.txt")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
