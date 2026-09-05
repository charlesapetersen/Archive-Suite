import AppKit
import Foundation
import PDFKit

/// Key-free, no-network regression for W25.retry-backend. It drives the REAL Process Files retry seam
/// against three deliberately conflicting configurations: direct API, gateway and Local Agent. Each retry
/// receives a locked `activeRunConfig`, while the processor's old mutable backend fields are set to a
/// different route (or nil). The injected HTTP transport and committed fake CLI make a regression visible
/// without contacting a provider, touching a corpus, or reading/writing durable run state.
///
/// Run via `scripts/test-retry-backend.sh`.
@MainActor
enum RetryBackendTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["RETRY_BACKEND_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    private actor RequestRecorder {
        private var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
        func last() -> URLRequest? { requests.last }
        func clear() { requests = [] }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "APRetryBackend-\(UUID().uuidString)", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }

        guard let image = makeJPEG(at: root.appendingPathComponent("retry.jpg")) else {
            finish(results + ["FAIL: fixture JPEG could not be created"])
            return
        }

        let recorder = RequestRecorder()
        let dormantTransport = !NetworkSession.testTransportIsActive && NetworkSession.testTransport == nil
        NetworkSession.testTransport = { request in
            await recorder.record(request)
            let host = request.url?.host ?? ""
            let content: String
            if host == "retry-gateway.invalid" {
                content = "[document_start]\\nGATEWAY-RETRY-TOKEN"
            } else {
                content = "[document_start]\\nDIRECT-RETRY-TOKEN"
            }
            let body: String
            if host == "retry-gateway.invalid" {
                body = #"{"choices":[{"message":{"content":"\#(content)"}}]}"#
            } else {
                body = #"{"candidates":[{"content":{"parts":[{"text":"\#(content)"}]}}]}"#
            }
            let url = request.url ?? URL(string: "https://retry.invalid")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
        defer { NetworkSession.testTransport = nil }

        let model = LLMProvider.gemini.models[0]
        let staleGateway = GatewayConfig(baseURL: "https://retry-gateway.invalid/v1", modelID: "stale-model",
                                         displayName: "Stale gateway", inputCostPer1M: 1, outputCostPer1M: 1)

        // Direct retry: the mutable `currentGateway` is deliberately contradictory. The retry must use the
        // direct config snapshot, not whichever backend a later Settings edit left on the processor.
        let direct = OCRProcessor()
        direct.jobs = [OCRJob(sourceURL: image)]
        direct.currentGateway = staleGateway
        direct.activeRunConfig = config(provider: .gemini, model: model, apiKey: "snapshot-direct-key",
                                        output: output, gateway: nil, localAgent: nil)
        _ = await direct.retryOne(index: 0, outputDirectory: output)
        let directRequest = await recorder.last()
        let directPDFText = generatedPDFText(from: direct, for: image)
        check("direct retry ignores a stale gateway and keeps the original provider route",
              direct.jobs.first?.result?.text?.contains("DIRECT-RETRY-TOKEN") == true
                  && directRequest?.url?.host == "generativelanguage.googleapis.com")
        check("direct retry PDF provenance ignores the stale gateway",
              directPDFText.contains("Gemini") && !directPDFText.contains("Stale gateway"))

        // Gateway-only retry: no native-provider key or current gateway is present. The locked gateway must
        // still receive the request; a direct fallback would return the distinct DIRECT token.
        await recorder.clear()
        let gateway = OCRProcessor()
        gateway.jobs = [OCRJob(sourceURL: image)]
        gateway.currentGateway = nil
        gateway.currentLocalAgent = nil
        gateway.activeRunConfig = config(provider: .gemini, model: model, apiKey: "",
                                         output: output, gateway: GatewayConfig(
                                            baseURL: "https://retry-gateway.invalid/v1", modelID: "locked-gateway-model",
                                            displayName: "Locked gateway", inputCostPer1M: 1, outputCostPer1M: 1),
                                         localAgent: nil)
        _ = await gateway.retryOne(index: 0, outputDirectory: output)
        let gatewayRequest = await recorder.last()
        let gatewayPDFText = generatedPDFText(from: gateway, for: image)
        let gatewayBody = gatewayRequest.flatMap { $0.httpBody }.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        check("gateway-only retry stays on the locked gateway without a native-provider key",
              gateway.jobs.first?.result?.text?.contains("GATEWAY-RETRY-TOKEN") == true
                  && gatewayRequest?.url?.host == "retry-gateway.invalid"
                  && gatewayBody?["model"] as? String == "locked-gateway-model")
        check("gateway retry PDF provenance names the locked gateway",
              gatewayPDFText.contains("Locked gateway"))

        // Local Agent retry: the fake CLI emits FAKE-CLI-OCR-TOKEN. If the old direct fallback returns, the
        // injected HTTP transport emits DIRECT-RETRY-TOKEN instead, making this a real route assertion.
        await recorder.clear()
        let fakeCLI = ProcessInfo.processInfo.environment["LOCALAGENT_FAKE_CLI"] ?? ""
        let local = OCRProcessor()
        local.jobs = [OCRJob(sourceURL: image)]
        local.currentGateway = staleGateway
        local.currentLocalAgent = LocalAgentConfig(tool: .codex, binaryPath: fakeCLI,
                                                    modelOverride: "stale CLI model")
        let lockedLocalAgent = LocalAgentConfig(tool: .claude, binaryPath: fakeCLI,
                                                modelOverride: "locked CLI model")
        local.activeRunConfig = config(provider: .gemini, model: model, apiKey: "",
                                       output: output, gateway: nil, localAgent: lockedLocalAgent)
        setenv("LOCALAGENT_FAKE_MODE", "ok", 1)
        _ = await local.retryOne(index: 0, outputDirectory: output)
        unsetenv("LOCALAGENT_FAKE_MODE")
        let localRequest = await recorder.last()
        let localPDFText = generatedPDFText(from: local, for: image)
        check("Local Agent retry stays on the locked subscription CLI rather than falling back to direct API",
              local.jobs.first?.result?.text?.contains("FAKE-CLI-OCR-TOKEN") == true && localRequest == nil)
        check("Local Agent retry PDF provenance names the locked CLI configuration",
              localPDFText.contains(lockedLocalAgent.provenanceDisplayName)
                  && localPDFText.contains(lockedLocalAgent.provenanceModelName)
                  && !localPDFText.contains("stale CLI model"))
        check("the injected transport was dormant before the contract", dormantTransport)

        finish(results)
    }

    private static func config(provider: LLMProvider, model: LLMModel, apiKey: String, output: URL,
                               gateway: GatewayConfig?, localAgent: LocalAgentConfig?) -> SessionProcessingConfig {
        SessionProcessingConfig(
            provider: provider, model: model, thinkingLevel: .low, apiKey: apiKey,
            taggingMode: .none, rotationMode: .off, mergeDocuments: false, outputDirectory: output,
            contextCharCount: 0, sendPreviousImage: false, customOCRPrompt: "", imageScale: 1,
            enableSegmentJSON: false, tagVocabulary: [], gateway: gateway, outputImageFile: false,
            pdfImageMB: 1, exportedImageMB: 1, textColumns: 1, localAgent: localAgent)
    }

    private static func makeJPEG(at url: URL) -> URL? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let data = bitmap?.representation(using: .jpeg, properties: [:]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func generatedPDFText(from processor: OCRProcessor, for source: URL) -> String {
        guard let outputURL = processor.outputURLMap[source], let document = PDFDocument(url: outputURL) else {
            return ""
        }
        return document.string ?? ""
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["RETRY_BACKEND_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-retry-backend.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
