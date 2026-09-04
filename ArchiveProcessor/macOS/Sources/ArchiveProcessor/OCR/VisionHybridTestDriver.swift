import Foundation

/// Headless, $0 contract for the Vision + LLM hybrid. It drives the production
/// `OCRProcessor.applyingVisionTextClassification` → `LLMTextClient` route with NetworkSession's
/// fail-closed test transport, then inspects the actual request body. No source image, API key, or
/// network connection is involved. Gated by `VISIONHYBRID_TEST=1` and writes its report to
/// `VISIONHYBRID_TEST_OUT`.
@MainActor
enum VisionHybridTestDriver {
    private static var didRun = false

    private actor RequestRecorder {
        private var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
        func snapshot() -> [URLRequest] { requests }
    }

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["VISIONHYBRID_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private static func run() async {
        let environment = ProcessInfo.processInfo.environment
        let outputPath = environment["VISIONHYBRID_TEST_OUT"] ?? ""
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("VISIONHYBRID \(ok ? "PASS" : "FAIL"): \(name)")
        }

        // The no-wire transport must be gated by this driver's exact flag before it is installed.
        check("Vision-hybrid test transport is enabled only by its exact flag",
              NetworkSession.visionHybridTestTransportIsEnabled(flag: environment["VISIONHYBRID_TEST"])
              && !NetworkSession.visionHybridTestTransportIsEnabled(flag: "true")
              && !NetworkSession.visionHybridTestTransportIsEnabled(flag: "1 "))
        check("test transport starts dormant", !NetworkSession.testTransportIsActive)

        let recorder = RequestRecorder()
        NetworkSession.testTransport = { request in
            await recorder.record(request)
            let body = Data(#"{"candidates":[{"content":{"parts":[{"text":"[document_start]"}]}}]}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (body, response)
        }
        defer { NetworkSession.testTransport = nil }
        check("test transport is active only with the installed stub", NetworkSession.testTransportIsActive)

        let configuration = LLMTextConfiguration(
            provider: .gemini, model: LLMModel.geminiModels[0], thinkingLevel: nil,
            apiKey: "not-a-real-key")
        let visionResult = OCRResult(
            text: "MEMORANDUM\nTo: Archive Team\nSubject: hybrid routing",
            classification: nil, rotationDegrees: 90, errorMessage: nil, errorCode: nil)
        let classified = await OCRProcessor.applyingVisionTextClassification(
            to: visionResult, previousText: "Prior page ended.", customPrompt: "Prefer a new memo as a new document.",
            configuration: configuration)
        let requests = await recorder.snapshot()
        check("text-only result receives the LLM classification", classified.classification == .documentStart)
        check("text-only classification preserves Vision text and rotation",
              classified.text == visionResult.text && classified.rotationDegrees == 90)
        check("one text request was issued", requests.count == 1)

        let body = requests.first?.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let lowered = body.lowercased()
        check("request contains the Vision transcription and text context",
              body.contains("MEMORANDUM") && body.contains("Prior page ended")
              && body.contains("Prefer a new memo"))
        check("request has no image payload or inline image marker",
              !lowered.contains("inlinedata") && !lowered.contains("image/")
              && !lowered.contains("data:image") && !lowered.contains("base64"))

        let untouched = await OCRProcessor.applyingVisionTextClassification(
            to: visionResult, previousText: nil, customPrompt: nil, configuration: nil)
        check("transcription-only mode makes no judgement request", (await recorder.snapshot()).count == 1
              && untouched.text == visionResult.text && untouched.classification == nil)

        let estimate = CostEstimator.estimate(
            fileCount: 3, model: LLMModel.geminiModels[0], enableTagging: true,
            enableCollectionSegmentation: true, sendPreviousImage: false, contextCharCount: 0,
            rotationMode: .llmSingle, visionTextOnly: true)
        check("hybrid estimate charges text work but never image OCR or rotation",
              estimate.ocrCost == 0 && estimate.batchOcrCost == 0 && estimate.rotationCost == 0
              && estimate.classificationCost > 0 && estimate.taggingCost > 0 && estimate.collectionCost > 0)

        NetworkSession.testTransport = nil
        check("test transport is dormant after teardown", !NetworkSession.testTransportIsActive)
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        if !outputPath.isEmpty { try? Data(report.utf8).write(to: URL(fileURLWithPath: outputPath), options: .atomic) }
        NSLog("VISIONHYBRID \(passed ? "ALL PASS" : "SOME FAILED")")
    }
}
