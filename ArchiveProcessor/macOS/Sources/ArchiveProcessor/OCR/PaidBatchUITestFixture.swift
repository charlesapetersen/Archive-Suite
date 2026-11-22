#if DEBUG
import Foundation

/// Provides an already-read batch for the UI journey. Resume still loads and consumes the
/// real journal. Every OCR-family network request from this launch is intercepted in-process.
enum PaidBatchUITestFixture {
    static let isActive = ProcessInfo.processInfo.environment["ARCHIVEPROC_HEADLESS"] == "1"
        && ProcessorUITestConfiguration.isActive
        && ProcessInfo.processInfo.arguments.contains("-APUITestPaidBatch")
    static let dummyKey = "scratch-no-wire"

    static var stateDirectory: URL { scratchLocations.state }

    private static var scratchLocations: (output: URL, state: URL) {
        // Unlike the normal journal path, this belongs to this test. The second app launch
        // uses the same disposable output directory and therefore finds the same journal.
        guard isActive, let output = ProcessorUITestConfiguration.outputDirectory else {
            preconditionFailure("Paid-batch UI test requires a scratch output directory")
        }
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath()
        let name = parent.lastPathComponent
        let temporary = parent.deletingLastPathComponent()
        guard temporary.path.hasSuffix("/Library/Containers/com.archiveprocessor.uitests.xctrunner/Data/tmp"),
              name.hasPrefix("w40d2-"), UUID(uuidString: String(name.dropFirst("w40d2-".count))) != nil,
              output.lastPathComponent == "s035-paid-out" else {
            preconditionFailure("Paid-batch UI test output must be in its own temporary directory")
        }
        let outputChild = parent.appendingPathComponent(output.lastPathComponent, isDirectory: true)
        let stateChild = parent.appendingPathComponent("paid-batch-state", isDirectory: true)
        guard outputChild.resolvingSymlinksInPath().path == outputChild.path,
              stateChild.resolvingSymlinksInPath().path == stateChild.path else {
            preconditionFailure("Paid-batch UI test directories must not be symlinks")
        }
        return (outputChild, stateChild)
    }

    @MainActor static func seedIfRequested() throws {
        guard isActive, ProcessInfo.processInfo.arguments.contains("-APUITestSeedPaidBatch") else { return }
        guard let files = ProcessorUITestConfiguration.droppedImages, files.count == 6 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let (output, state) = scratchLocations
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
        let model = LLMModel.geminiModels[0]
        let classes: [DocumentClassification] = [
            .boxLabel, .folderLabel, .documentStart, .documentContinuation, .documentStart, .documentStart
        ]
        var results: [String: OCRResult] = [:]
        var outputPaths: [String: String] = [:]
        for (index, file) in files.enumerated() {
            let pdf = output.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".pdf")
            let result = OCRResult(text: "Review journey scratch page \(index + 1), dated 12 March 1978.",
                                   classification: classes[index], errorMessage: nil, errorCode: nil)
            try PDFGenerator().generate(imageURL: file, result: result, model: model,
                                        outputURL: pdf, textLayer: nil)
            results[String(index)] = result
            outputPaths[String(index)] = pdf.path
        }
        let id = "batches/scratch-paid-ui"
        let fingerprint = OCRProcessor.runFingerprint(
            files: files, outputDirectory: output, taggingMode: .automatic,
            enableTagging: true, batchMode: true, preserveInputOrder: true
        )
        let journal = OCRProcessor.PendingBatch(
            batchId: id, provider: .gemini, model: model, thinkingLevel: nil,
            fileURLs: files, outputDirectory: output, enableTagging: true,
            enableCollectionSegmentation: true, sendPreviousImage: false, submittedAt: Date(),
            enableSegmentJSON: false, confirmCollectionIDs: true, reviewDocumentSegmentation: true,
            runFingerprint: fingerprint, exportOriginals: false,
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            consumedChunkIds: [id], completedResults: results, completedOutputPaths: outputPaths
        )
        guard let saved = OCRProcessor.savePendingBatch(journal),
              OCRProcessor.pendingBatchIsSelfConsistent(saved) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        // A consumed batch must never poll, download, submit, or re-read any source. The only
        // expected requests are model completions for tags, dates, or collection/label text.
        guard let url = request.url, url.host == "generativelanguage.googleapis.com",
              url.path.hasSuffix(":generateContent"), request.httpMethod == "POST" else {
            preconditionFailure("Unexpected request in consumed paid-batch UI fixture")
        }
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let reply = if body.contains("subject_tags") {
            #"{"year":"1978","month":"3","day":"12","subject_tags":["Resume Scratch Subject"],"format":"Letter"}"#
        } else {
            "Scratch Papers"
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": reply]]], "finishReason": "STOP"]]
        ])
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}
#endif
