#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import Foundation

/// Key-free, no-network contract for W46.rotation-default: the agreement rule's verdicts, which backends escalate to
/// the gateway's model and with what request, the bundled PP-LCNet loading in the app, the unsure page reaching the
/// run's summary and history, and the estimates pricing the gateway's rotation calls. The gateway is answered by the
/// injected HTTP transport; nothing leaves the Mac.
///
/// Run via `scripts/test-rotation-rule.sh`.
@MainActor
enum RotationRuleTestDriver {
    nonisolated static let envKey = "ROTATIONRULE_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    /// The requests the fake gateway saw, and the status and letter it answers with.
    private actor Wire {
        var requests: [URLRequest] = []
        var status = 200
        var letter = "C"
        func set(status: Int, letter: String) { self.status = status; self.letter = letter; requests = [] }
        func answer(_ request: URLRequest) -> (Int, String) {
            requests.append(request)
            return (status, #"{"choices":[{"message":{"content":"\#(letter)"}}]}"#)
        }
        func seen() -> [URLRequest] { requests }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APRotationRule-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }

        // 1. The rule's verdicts.
        typealias V = OCRProcessor.RotationVerdict
        let answers: @Sendable (Int?) -> (@Sendable () async -> Int?) = { value in { value } }
        check("1 agreement settles the page", await OCRProcessor.agreementVerdict(vision: 90, lcnet: 90, cloud: nil) == V(correction: 90))
        check("1 agreement does not call the cloud",
              await OCRProcessor.agreementVerdict(vision: 0, lcnet: 0, cloud: { 270 }) == V(correction: 0))
        check("1 a disagreement with no cloud route is left as it is, unsure",
              await OCRProcessor.agreementVerdict(vision: 90, lcnet: 270, cloud: nil) == V(correction: 0, unsure: true))
        check("1 Vision abstaining with no cloud route is left as it is, unsure",
              await OCRProcessor.agreementVerdict(vision: nil, lcnet: 180, cloud: nil) == V(correction: 0, unsure: true))
        check("1 PP-LCNet answering nothing never settles a page",
              await OCRProcessor.agreementVerdict(vision: 90, lcnet: nil, cloud: nil) == V(correction: 0, unsure: true))
        check("1 a build without PP-LCNet runs Vision alone, every page unsure",
              await OCRProcessor.agreementVerdict(vision: 90, lcnet: nil, cloud: nil, lcnetLoaded: false)
                == V(correction: 90, unsure: true))
        check("1 a disagreement takes the cloud's answer",
              await OCRProcessor.agreementVerdict(vision: 90, lcnet: 270, cloud: answers(180)) == V(correction: 180))
        check("1 a failed cloud call falls back to Vision, unsure",
              await OCRProcessor.agreementVerdict(vision: 90, lcnet: 270, cloud: answers(nil)) == V(correction: 90, unsure: true))
        check("1 a failed cloud call with Vision abstaining is unsure",
              await OCRProcessor.agreementVerdict(vision: nil, lcnet: 270, cloud: answers(nil)) == V(correction: 0, unsure: true))

        // 2. Which backends have a comparative call, and which escalate under the rule.
        let remote = GatewayConfig(baseURL: "https://gateway.invalid/v1", modelID: "gpt-x", displayName: "G")
        var local = remote; local.localModel = true
        check("2 a remote gateway has a rotation route",
              LLMRotationDetector.hasRoute(provider: .anthropic, usesGateway: true, usesLocalAgent: false))
        check("2 a model on this Mac behind the gateway field has none",
              !LLMRotationDetector.hasRoute(provider: .anthropic, usesGateway: true, usesLocalAgent: false, gatewayIsLocal: true))
        check("2 the Local Agent has none",
              !LLMRotationDetector.hasRoute(provider: .gemini, usesGateway: false, usesLocalAgent: true))
        check("2 a direct Gemini key has a route but not a measured one",
              LLMRotationDetector.hasRoute(provider: .gemini, usesGateway: false, usesLocalAgent: false)
                && !LLMRotationDetector.hasMeasuredRoute(usesGateway: false, usesLocalAgent: false, gatewayIsLocal: false))
        check("2 the estimates price gateway calls only where the run makes them",
              LLMRotationDetector.callsGateway(mode: .agreement, gateway: remote, usesLocalAgent: false)
                && LLMRotationDetector.callsGateway(mode: .llmSingle, gateway: remote, usesLocalAgent: false)
                && !LLMRotationDetector.callsGateway(mode: .localVision, gateway: remote, usesLocalAgent: false)
                && !LLMRotationDetector.callsGateway(mode: .agreement, gateway: local, usesLocalAgent: false)
                && !LLMRotationDetector.callsGateway(mode: .agreement, gateway: nil, usesLocalAgent: false))

        // 3. The gateway request, through the injected transport.
        guard let page = makePage(at: root.appendingPathComponent("page.jpg")) else {
            finish(results + ["FAIL: fixture JPEG could not be created"]); return
        }
        let wire = Wire()
        check("3 the HTTP seam is dormant before the contract installs it", !NetworkSession.testTransportIsActive)
        NetworkSession.testTransport = { request in
            let (status, body) = await wire.answer(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x.invalid")!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
        defer { NetworkSession.testTransport = nil }

        await wire.set(status: 200, letter: "C")
        let asked = await LLMRotationDetector.detectCorrection(
            imageURL: page, provider: .anthropic, apiKey: "unused", orderings: 1, gatewayConfig: remote)
        let sent = await wire.seen()
        let body = sent.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let content = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        check("3 one call to the gateway's chat completions",
              sent.count == 1 && sent.first?.url?.absoluteString == "https://gateway.invalid/v1/chat/completions")
        check("3 it asks the measured model with the measured settings, whatever the OCR model",
              body?["model"] as? String == "gemini-3.7-flash" && (body?["temperature"] as? Int) == 0
                && body?["reasoning_effort"] as? String == "minimal" && (body?["max_tokens"] as? Int) == 2048)
        check("3 it sends the four candidates", content.filter { $0["type"] as? String == "image_url" }.count == 4)
        check("3 the gateway's key goes as a bearer token",
              sent.first?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        check("3 the letter maps to its candidate (C in the first ordering = 180)", asked == 180)

        check("3 only a reply that is one label is read",
              LLMRotationDetector.parseLabel("b") == "B" && LLMRotationDetector.parseLabel(" **C**\n") == "C"
                && LLMRotationDetector.parseLabel("Image D.") == "D"
                && LLMRotationDetector.parseLabel("A close look shows D") == nil && LLMRotationDetector.parseLabel("") == nil)

        await wire.set(status: 404, letter: "A")
        let refused = await LLMRotationDetector.detectCorrection(
            imageURL: page, provider: .anthropic, apiKey: "unused", orderings: 1, gatewayConfig: remote)
        check("3 a gateway without the model answers nothing, so the page falls back", refused == nil)

        await wire.set(status: 200, letter: "B")
        _ = await OCRProcessor.detectRotation(imageURL: page, provider: .gemini, apiKey: "k", mode: .agreement,
                                              gatewayConfig: local)
        _ = await OCRProcessor.detectRotation(imageURL: page, provider: .gemini, apiKey: "k", mode: .agreement,
                                              gatewayConfig: nil)
        check("3 the rule never calls out from a model on this Mac or a direct key", await wire.seen().isEmpty)
        _ = await OCRProcessor.detectRotation(imageURL: page, provider: .gemini, apiKey: "k", mode: .agreement,
                                              gatewayConfig: remote)
        let escalated = await wire.seen().count
        check("3 on a remote gateway the rule calls at most once a page", escalated <= 1)

        // 4. The bundled model.
        check("4 the bundled PP-LCNet loads", RotationLCNet.isAvailable)
        let lcnet = await RotationLCNet.detectCorrection(imageURL: page)
        check("4 it answers a correction", lcnet.map { [0, 90, 180, 270].contains($0) } ?? false)

        // 5. The unsure page in the result, the summary and the history.
        let read = OCRResult(text: "t", classification: .documentStart, rotationDegrees: 90, errorMessage: nil, errorCode: nil)
        let unsure = OCRProcessor.mergeRotation(into: read, verdict: V(correction: 0, unsure: true))
        let settled = OCRProcessor.mergeRotation(into: unsure, verdict: V(correction: 270))
        check("5 an unsure verdict leaves the page as it is and marks it",
              unsure.rotationDegrees == 0 && unsure.rotationUnsure == true)
        check("5 the mark survives a reclassification",
              unsure.with(classification: .documentContinuation, rotationDegrees: 0).rotationUnsure == true)
        check("5 a settled verdict clears it", settled.rotationDegrees == 270 && settled.rotationUnsure == nil)
        let failed = OCRResult(text: nil, classification: nil, errorMessage: "x", errorCode: "500")
        check("5 a failed read is not marked", OCRProcessor.mergeRotation(into: failed, verdict: V(correction: 0, unsure: true)).rotationUnsure == nil)
        let coded = try? JSONDecoder().decode(OCRResult.self, from: JSONEncoder().encode(unsure))
        check("5 the mark persists with the run's results", coded?.rotationUnsure == true)

        let model = remote.asLLMModel()
        let snapshot = RunHistorySnapshot(
            startedAt: Date(), provider: .anthropic, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: model, visionTextProvider: nil, visionTextModel: nil, batchMode: false, enableTagging: false,
            enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false, mixedReOCR: false,
            sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .agreement, fileCount: 3)
        check("5 the run's history counts the unsure pages", snapshot.makeRun(succeeded: 3, rotationUnsure: 2).rotationUnsurePages == 2)
        check("5 a run with none records none", snapshot.makeRun(succeeded: 3).rotationUnsurePages == nil)

        // 6. Defaults and estimates.
        let blank = UserDefaults(suiteName: "APRotationRule-\(UUID().uuidString)")!
        check("6 a fresh install runs the agreement rule",
              RotationMode.standard == .agreement && SessionProcessingConfig.defaultRotationMode(blank) == .agreement)
        func cost(_ mode: RotationMode, gateway: Bool) -> Double {
            CostEstimator.estimate(fileCount: 1000, model: model, enableTagging: false, sendPreviousImage: false,
                                   contextCharCount: 0, rotationMode: mode, useGateway: gateway,
                                   gatewayRotation: gateway).rotationCost
        }
        check("6 the rule on the gateway costs the escalated share of a call",
              abs(cost(.agreement, gateway: true) - 1000 * 45.0 / 476.0 * 0.0037) < 1e-9)
        check("6 llmSingle on the gateway costs one call a page", abs(cost(.llmSingle, gateway: true) - 3.7) < 1e-9)
        check("6 the rule costs nothing off the gateway", cost(.agreement, gateway: false) == 0)
        let time = TimeEstimator.estimate(fileCount: 100, model: model, rotationMode: .llmSingle, enableTagging: false,
                                          useGateway: true, gatewayRotation: true)
        check("6 the time estimate counts the gateway's calls", time.rotationSeconds > 0)

        finish(results)
    }

    /// A page of dark text lines on white, upright, big enough for both local detectors to read.
    private static func makePage(at url: URL) -> URL? {
        let size = NSSize(width: 850, height: 1100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
        for line in 0..<30 {
            ("The committee met on the fourth of March to consider the report, line \(line)." as NSString)
                .draw(at: NSPoint(x: 60, y: 1040 - CGFloat(line) * 33), withAttributes: attrs)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["ROTATIONRULE_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-rotation-rule.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
#endif
