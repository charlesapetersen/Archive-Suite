import AppKit
import Foundation

/// Headless, $0 self-test of the OpenRouter provider (W41.app-openrouter), gated by `OPENROUTER_TEST=1` (does nothing
/// in normal use). Every request goes to the no-wire seam (`NetworkSession.testTransport`), which this flag enables;
/// the driver FAILS at once if the seam is not active after the stub is installed, so nothing can reach OpenRouter.
/// No key (a fake one is passed), no Keychain read, no window, never the corpus. Run by `scripts/test-openrouter.sh`.
///
/// What has to be true:
///   1. The catalog is the bench's: each model's id, pinned provider, precision and price, and no custom models.
///   2. The request on the wire pins the provider (`order`, `allow_fallbacks: false`, `quantizations`, a
///      `max_price` at the pinned price), sends temperature 0 and the bench's reasoning setting, for OCR and text.
///   3. A model the catalog lacks gets no client: an unpinned call is never made.
///   4. OpenRouter's 200-with-an-error reply becomes a failed page with its message, never an empty success.
///   5. The cost estimate is priced at the pinned provider's rates, and is not below what the panel paid.
@MainActor
enum OpenRouterTestDriver {
    nonisolated static let envKey = "OPENROUTER_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { @MainActor in await run() }
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { lines.append("PASS \(name)") } else {
            failures += 1
            lines.append("FAIL \(name) \(detail())")
        }
    }

    private static func eq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        check(name, got == want, "got \(got) want \(want)")
    }

    /// Every request the stub saw, and the reply it gives.
    private final class Wire: @unchecked Sendable {
        var requests: [URLRequest] = []
        var reply = #"{"choices":[{"message":{"content":"[document_start]\nHello archive"}}]}"#
        var status = 200
    }

    static func run() async {
        defer { finish() }
        catalogChecks()

        // The seam must be dormant until the stub is installed, then active; otherwise stop before any call.
        check("0 seam dormant before install", !NetworkSession.testTransportIsActive)
        let wire = Wire()
        NetworkSession.testTransport = { request in
            wire.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: wire.status, httpVersion: nil, headerFields: nil)!
            return (Data(wire.reply.utf8), response)
        }
        defer { NetworkSession.testTransport = nil }
        guard NetworkSession.testTransportIsActive else {
            check("0 the injected transport is active", false, "stopping before any request")
            return
        }

        guard let image = makeImage() else { check("0 test image", false); return }
        defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }

        for route in OpenRouterRoute.catalog {
            wire.requests = []
            guard let client = OpenAICompatibleClient.openRouter(model: route.model, apiKey: "test-key") else {
                check("2 \(route.model.id) has a client", false); continue
            }
            let result = try? await client.ocr(imageURL: image)
            eq("2 \(route.model.id) OCR text parsed", result?.text, "Hello archive")
            eq("2 \(route.model.id) one request", wire.requests.count, 1)
            if let request = wire.requests.first { requestChecks(request, route: route, ocr: true) }

            wire.requests = []
            let text = try? await LLMTextClient.complete(
                prompt: "tag this", provider: .openrouter, model: route.model, thinkingLevel: nil, apiKey: "test-key",
                gatewayConfig: nil, maxTokens: 512, timeout: 60)
            check("2 \(route.model.id) text completion returns content", text?.contains("Hello archive") == true)
            if let request = wire.requests.first { requestChecks(request, route: route, ocr: false) }
            else { check("2 \(route.model.id) text request sent", false) }
        }

        // 3. No unpinned call.
        let stray = LLMModel(id: "qwen/some-other-model", displayName: "Stray", provider: .openrouter,
                             supportsThinking: false, returnsMd: false, inputCostPer1M: 0, outputCostPer1M: 0,
                             batchDiscount: 1)
        check("3 an uncatalogued model gets no client", OpenAICompatibleClient.openRouter(model: stray, apiKey: "k") == nil)
        wire.requests = []
        let strayText = try? await LLMTextClient.complete(
            prompt: "x", provider: .openrouter, model: stray, thinkingLevel: nil, apiKey: "k",
            gatewayConfig: nil, maxTokens: 16, timeout: 10)
        check("3 an uncatalogued model throws and sends nothing", strayText == nil && wire.requests.isEmpty,
              "\(wire.requests.count) requests")

        // 4. A provider failure reported in a 200.
        wire.reply = #"{"error":{"code":502,"message":"Provider returned error"}}"#
        let failed = try? await OpenAICompatibleClient.openRouter(model: OpenRouterRoute.catalog[0].model,
                                                                  apiKey: "k")!.ocr(imageURL: image)
        check("4 200-with-error is a failed page, retried as a 503", failed?.text == nil
              && failed?.errorMessage == "Provider returned error" && failed?.errorCode == "503", "\(String(describing: failed?.errorMessage)) \(String(describing: failed?.errorCode))")
        // A provider failure, or a reply cut at the limit, inside `choices`: a failed page, never a transcription.
        for (finish, code) in [("error", "503"), ("length", "length")] {
            wire.reply = #"{"choices":[{"finish_reason":"\#(finish)","message":{"content":"[document_start]\nHalf a pa"}}]}"#
            let r = try? await OpenAICompatibleClient.openRouter(model: OpenRouterRoute.catalog[0].model,
                                                                 apiKey: "k")!.ocr(imageURL: image)
            check("4 finish_reason \(finish) is a failed page", r?.text == nil && r?.errorCode == code,
                  "\(String(describing: r?.text)) \(String(describing: r?.errorCode))")
        }
        // A text call with no answer throws rather than returning an empty classification or tag list.
        wire.reply = #"{"choices":[{"finish_reason":"length","message":{"content":""}}]}"#
        let empty = try? await LLMTextClient.complete(
            prompt: "x", provider: .openrouter, model: OpenRouterRoute.catalog[2].model, thinkingLevel: nil,
            apiKey: "k", gatewayConfig: nil, maxTokens: 64, timeout: 10)
        check("4 an empty text answer throws", empty == nil, String(describing: empty))
        wire.reply = #"{"error":{"code":402,"message":"Insufficient credits"}}"#
        wire.status = 402
        var message = ""
        do {
            _ = try await LLMTextClient.complete(
                prompt: "x", provider: .openrouter, model: OpenRouterRoute.catalog[0].model, thinkingLevel: nil,
                apiKey: "k", gatewayConfig: nil, maxTokens: 64, timeout: 10)
        } catch { message = error.localizedDescription }
        check("4 a text call's HTTP error keeps OpenRouter's message", message.contains("Insufficient credits"), message)
        wire.status = 200

        // 401, not 429: a 429 is retried with real backoff.
        wire.reply = #"{"error":{"code":401,"message":"No auth credentials found"}}"#
        wire.status = 401
        let limited = try? await OpenAICompatibleClient.openRouter(model: OpenRouterRoute.catalog[0].model,
                                                                   apiKey: "k")!.ocr(imageURL: image)
        eq("4 an HTTP error keeps its status and message", [limited?.errorCode, limited?.errorMessage], ["401", "No auth credentials found"])

        costChecks()
        segmentationChecks()
    }

    /// 6. GLM-5.3 Flash as a segmentation voter: options.json's approach resolves to it, and its window request
    /// is `method_openrouter.py` `request_body`'s (images alone, then the prompt; pinned; temperature 0).
    private static func segmentationChecks() {
        guard let options = try? SegmentationOptions.loadBundled() else {
            check("6 options.json loads", false); return
        }
        eq("6 options.json has no problems", options.problems(), [])
        guard let spec = try? options.spec(for: .glm) else { check("6 the glm approach resolves", false); return }
        eq("6 glm's one voter", spec.voters.map(\.modelID), ["z-ai/glm-5.3-flash"])
        eq("6 glm's level is the one fitted at the 98% bar", spec.level, 0.925)
        let voter = spec.voters[0]
        eq("6 glm voter goes by OpenRouter at minimal, prompt c1", [voter.provider.rawValue, voter.thinkingLevel ?? "", voter.prompt.rawValue],
           ["openrouter", "minimal", "c1"])
        let test = options.approach(.glm)?.figures?.test
        eq("6 glm test figures (cheap-models.md's 98% row)", [test?.pagesExactNoReview.map { ($0 * 1000).rounded() / 10 },
                                                             test.map { ($0.flaggedPer100Pages * 10).rounded() / 10 },
                                                             test.map { ($0.pagesExactAfterReview * 1000).rounded() / 10 }],
           [82.1, 33.1, 98.5])
        let cost = options.approach(.glm)?.cost?.total
        check("6 glm costs $1.16 per 1,000 pages, no batch", cost.map { abs($0.listUSDPer1000Pages - 1.16) < 0.005 } == true
              && cost?.batchUSDPer1000Pages == nil, String(describing: cost))
        let r = WindowRequest(voter: voter, prompt: "PROMPT", images: [Data([1, 2]), Data([3, 4])], pageNumbers: [5, 6])
        guard let request = try? APIWindowTransport.request(r, key: "test-key"),
              let data = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = String(data: data, encoding: .utf8) else {
            check("6 glm window request builds", false); return
        }
        eq("6 window endpoint", request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        eq("6 window bearer", request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        eq("6 window: the images alone in order, then the prompt", content.map { $0["type"] as? String ?? "" },
           ["image_url", "image_url", "text"])
        eq("6 window prompt last", content.last?["text"] as? String, "PROMPT")
        let provider = body["provider"] as? [String: Any]
        eq("6 window provider pinned", provider?["order"] as? [String], ["z-ai"])
        eq("6 window precision", provider?["quantizations"] as? [String], ["fp8"])
        check("6 window fallbacks off", raw.contains(#""allow_fallbacks":false"#))
        eq("6 window max_price", (provider?["max_price"] as? [String: Double])?["completion"], 0.50)
        eq("6 window temperature 0", (body["temperature"] as? NSNumber)?.doubleValue, 0)
        check("6 window reasoning minimal, excluded", (body["reasoning"] as? [String: Any])?["effort"] as? String == "minimal"
              && raw.contains(#""exclude":true"#))
        // A window failure in a 200 is one window's failure, retried by the engine; an empty answer likewise.
        let errorReply = Data(#"{"error":{"code":502,"message":"Provider returned error"}}"#.utf8)
        check("6 a 200-with-error window fails", (try? APIWindowTransport.replyText(.openrouter, data: errorReply, status: 200)) == nil)
        let limited = Data(#"{"error":{"code":429,"message":"Rate limited"}}"#.utf8)
        var stopped = false
        do { _ = try APIWindowTransport.replyText(.openrouter, data: limited, status: 200) }
        catch let e as WindowTransportError { if case .usageLimit = e { stopped = true } } catch {}
        check("6 an in-body 429 stops the run", stopped)
        let ok = Data(#"{"choices":[{"message":{"content":"{\"pages\":[]}"}}]}"#.utf8)
        eq("6 a window answer is read", try? APIWindowTransport.replyText(.openrouter, data: ok, status: 200), #"{"pages":[]}"#)
        let stray = WindowVoter(name: "x", provider: .openrouter, modelID: "z-ai/other", thinkingLevel: nil, prompt: .c1)
        check("6 an unpinned window voter is refused", (try? APIWindowTransport.request(
            WindowRequest(voter: stray, prompt: "p", images: [], pageNumbers: []), key: "k")) == nil)
        var missing = ""
        if case .failure(let m) = WindowStageTransport.make(spec, keys: [:], claudeBinary: nil) { missing = m.description }
        eq("6 the glm route names its key", missing, "GLM-5.3 Flash needs an OpenRouter API key.")
        let routes = SegmentationRoutes(hasOpenRouterKey: true)
        check("6 an OpenRouter key makes glm runnable", routes.canRun(.openrouter) && !SegmentationRoutes().canRun(.openrouter))
    }

    private static func catalogChecks() {
        let c = OpenRouterRoute.catalog
        eq("1 models", c.map(\.model.id), ["qwen/qwen3-vl-235b-a22b-instruct", "qwen/qwen3.6-27b", "z-ai/glm-5.3-flash"])
        eq("1 pinned providers", c.map(\.providerTag), ["deepinfra/fp8", "chutes/fp8", "z-ai"])
        eq("1 precisions", c.map(\.precision), ["fp8", "fp8", "fp8"])
        eq("1 reasoning as the bench sent it", c.map(\.reasoning), [.none, .off, .effort("minimal")])
        // The pinned endpoints' prices: the panel's frozen catalogs, and GLM's from its seg-cheap call log.
        eq("1 input prices", c.map(\.model.inputCostPer1M), [0.20, 0.25, 0.15])
        eq("1 output prices", c.map(\.model.outputCostPer1M), [0.88, 2.00, 0.50])
        check("1 every model is an OpenRouter model", c.allSatisfy { $0.model.provider == .openrouter })
        eq("1 the provider's models are the catalog, no custom ones", LLMProvider.openrouter.models.map(\.id),
           c.map(\.model.id))
        check("1 no batch path", !LLMProvider.openrouter.supportsBatch)
        check("1 names carry provider and precision for the PDF header",
              c.allSatisfy { $0.model.displayName.contains($0.providerTag.split(separator: "/")[0]) && $0.model.displayName.contains($0.precision) },
              c.map(\.model.displayName).joined(separator: ", "))
        check("1 the Settings note names provider, precision and fallbacks",
              c.allSatisfy { $0.settingsNote.contains("fp8") && $0.settingsNote.contains("fallbacks off") })
        check("1 GLM's note says its OCR is unmeasured", c[2].settingsNote.contains("not been measured"))
        check("1 the page guidance sees Qwen3.6 27B", OCRPageGuidance.builtInModelIDs.contains("qwen/qwen3.6-27b"))
        eq("1 the Keychain account is the bench's", LLMProvider.openrouter.rawValue, "OpenRouter")
    }

    private static func requestChecks(_ request: URLRequest, route: OpenRouterRoute, ocr: Bool) {
        let tag = "\(route.model.id) \(ocr ? "OCR" : "text")"
        eq("2 \(tag) endpoint", request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        eq("2 \(tag) bearer", request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        guard let data = request.httpBody,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = String(data: data, encoding: .utf8) else {
            check("2 \(tag) body is JSON", false); return
        }
        eq("2 \(tag) model", body["model"] as? String, route.model.id)
        let provider = body["provider"] as? [String: Any]
        eq("2 \(tag) provider order", provider?["order"] as? [String], [route.providerTag])
        eq("2 \(tag) quantizations", provider?["quantizations"] as? [String], [route.precision])
        // A JSON boolean false, not 0: OpenRouter would read a number as no setting at all.
        check("2 \(tag) allow_fallbacks is JSON false", raw.contains(#""allow_fallbacks":false"#), raw.prefix(400).description)
        let price = provider?["max_price"] as? [String: Double]
        eq("2 \(tag) max_price prompt", price?["prompt"], route.model.inputCostPer1M)
        eq("2 \(tag) max_price completion", price?["completion"], route.model.outputCostPer1M)
        eq("2 \(tag) temperature 0", (body["temperature"] as? NSNumber)?.doubleValue, 0)
        let allowance: Int
        if case .effort = route.reasoning { allowance = 1024 } else { allowance = 0 }
        eq("2 \(tag) max_tokens (plus room for reasoning)", body["max_tokens"] as? Int, (ocr ? 8192 : 512) + allowance)
        check("2 \(tag) no OpenAI reasoning_effort", body["reasoning_effort"] == nil)
        let reasoning = body["reasoning"] as? [String: Any]
        switch route.reasoning {
        case .none: check("2 \(tag) no reasoning field", reasoning == nil)
        case .off: check("2 \(tag) reasoning off", raw.contains(#""enabled":false"#) && reasoning?.count == 1, raw.prefix(400).description)
        case .effort(let level):
            check("2 \(tag) reasoning effort \(level), excluded",
                  reasoning?["effort"] as? String == level && raw.contains(#""exclude":true"#))
        }
        if ocr {
            let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            eq("2 \(tag) image then prompt", content.map { $0["type"] as? String ?? "" }, ["image_url", "text"])
        }
    }

    private static func costChecks() {
        let m = OpenRouterRoute.catalog[0].model
        let e = CostEstimator.estimate(fileCount: 1000, model: m, enableTagging: false, sendPreviousImage: false,
                                       contextCharCount: 0)
        let input = CostEstimator.estimatedPromptTokens + CostEstimator.estimatedImageTokens(for: .openrouter)
        let want = 1000 * (input * 0.20 + CostEstimator.estimatedOutputTokens * 0.88) / 1_000_000
        check("5 priced at the pinned provider's rates", abs(e.ocrCost - want) < 1e-9, "\(e.ocrCost) vs \(want)")
        // The panel paid $1.22 per 1,000 pages on this route (99 calls). The estimate may be above, never below.
        check("5 not below the panel's $1.22 per 1,000 pages, and within 1.5x", e.ocrCost >= 1.22 && e.ocrCost <= 1.83,
              String(format: "$%.2f", e.ocrCost))
        let q = CostEstimator.estimate(fileCount: 1000, model: OpenRouterRoute.catalog[1].model, enableTagging: false,
                                       sendPreviousImage: false, contextCharCount: 0)
        // About 1.57x the panel here: the app assumes 850 output tokens a page (its prompt adds the classification
        // line; the panel's replies averaged ~455), and this model's output is the dearer side of its price.
        check("5 Qwen3.6 27B not below the panel's $1.74, within 1.75x", q.ocrCost >= 1.74 && q.ocrCost <= 3.05,
              String(format: "$%.2f", q.ocrCost))
        eq("5 no batch discount offered", e.batchOcrCost, e.ocrCost)
        eq("5 GLM's minimal reasoning is priced as output", CostEstimator.estimatedThinkingTokens(for: OpenRouterRoute.catalog[2].model), 153)
        eq("5 the time estimate does not count LLM rotation", TimeEstimator.estimate(
            fileCount: 10, model: m, rotationMode: .llmMajority, enableTagging: false).rotationSeconds, 0)
        eq("5 rotation by LLM is not priced (local Vision instead)",
           CostEstimator.estimate(fileCount: 10, model: m, enableTagging: false, sendPreviousImage: false,
                                  contextCharCount: 0, rotationMode: .llmMajority).rotationCost, 0)
    }

    private static func makeImage() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openrouter-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                         samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = dir.appendingPathComponent("page.png")
        return (try? png.write(to: url)) == nil ? nil : url
    }

    private static func finish() {
        lines.append(failures == 0 ? "ALL PASS" : "FAILURES \(failures)")
        let text = lines.joined(separator: "\n") + "\n"
        if let out = ProcessInfo.processInfo.environment["OPENROUTER_TEST_OUT"] {
            try? text.write(toFile: out, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
