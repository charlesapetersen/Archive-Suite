import AppKit
import Foundation
import PDFKit

/// Key-free, no-network contract for W41.app-ocr-cascade. Drives the REAL `OCRProcessor.performOCRCall` through the
/// injected HTTP transport: the cheap first reader answers each page with a canned failure or success, the
/// escalation route answers its own, keys come from `OCRCascade.keyOverride` and Apple Vision's word count from
/// `OCRCascade.visionWordsOverride` instead of the Keychain and a real image. Checks which failures escalate and
/// which never spend a second call, the per-page record, the fall-through to the refusal readers, the opt-in
/// disagreement check, every client's cut-off and unparsable codes, and the run snapshot.
///
/// Run via `scripts/test-ocr-cascade.sh`.
@MainActor
enum OCRCascadeTestDriver {
    nonisolated static let envKey = "OCRCASCADE_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    /// What each fake endpoint answers, by host, and every host called.
    private actor Script {
        var answers: [String: (Int, String)] = [:]
        var hosts: [String] = []
        func set(_ answers: [String: (Int, String)]) { self.answers = answers; hosts = [] }
        func answer(_ request: URLRequest) -> (Int, String) {
            let host = request.url?.host ?? ""
            hosts.append(host)
            for (key, value) in answers where host.contains(key) { return value }
            return (404, "{}")
        }
        func calls() -> [String] { hosts }
    }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APOCRCascade-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var results: [String] = []
        func check(_ name: String, _ condition: Bool) {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }
        guard let image = makeJPEG(at: root.appendingPathComponent("page.jpg")) else {
            finish(["FAIL: fixture JPEG could not be created"])
            return
        }

        let script = Script()
        check("the HTTP seam is dormant before the contract installs it", !NetworkSession.testTransportIsActive)
        NetworkSession.testTransport = { request in
            let (status, body) = await script.answer(request)
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x.invalid")!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
        // Keys for every provider but Mistral, so "no key" can be checked against it.
        OCRCascade.keyOverride = { $0 == .mistral ? nil : "test-\($0.rawValue)" }
        OCRRefusalFallback.routesOverride = { [] }
        defer {
            NetworkSession.testTransport = nil; OCRCascade.keyOverride = nil
            OCRCascade.visionWordsOverride = nil; OCRRefusalFallback.routesOverride = nil
        }

        // The cheap first reader: Qwen3.6 27B on OpenRouter. The escalation route: Claude.
        guard let qwen = OpenRouterRoute.forModel("qwen/qwen3.6-27b")?.model,
              let gpt = LLMModel.openaiModels.first(where: { $0.id == "gpt-5.4-mini" }) else {
            finish(["FAIL: catalog models missing"])
            return
        }
        let claude = LLMModel.anthropicModels[0]
        let flash = LLMModel.geminiModels[0]
        let toClaude = OCRCascade(routeID: OCRCascade.routeID(for: claude))
        func ocr(_ provider: LLMProvider = .openrouter, _ model: LLMModel? = nil, cascade: OCRCascade,
                 gateway: GatewayConfig? = nil) async -> OCRResult {
            await OCRProcessor.performOCRCall(
                imageURL: image, provider: provider, model: model ?? qwen, thinkingLevel: nil, apiKey: "test-first",
                previousText: nil, previousImageURL: nil, gatewayConfig: gateway, rotationMode: .off,
                standardImageMB: 4, cascade: cascade)
        }

        let qwenText = #"{"choices":[{"finish_reason":"stop","message":{"content":"[document_start]\nQWEN-TEXT one two three"}}]}"#
        let qwenCut = #"{"choices":[{"finish_reason":"length","message":{"content":"[document_start]\nloop loop loop"}}]}"#
        let claudeText = #"{"content":[{"type":"text","text":"[document_start]\nCLAUDE-TEXT"}],"stop_reason":"end_turn"}"#
        let gptText = #"{"choices":[{"finish_reason":"stop","message":{"content":"[document_start]\nGPT-TEXT"}}]}"#
        let geminiText = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[document_start]\nGEMINI-TEXT"}]}}]}"#
        let recitation = #"{"candidates":[{"finishReason":"RECITATION"}]}"#
        let badKey = #"{"error":{"message":"bad key"}}"#

        // 1. Off by default: a cut-off reply fails the page and spends nothing more.
        check("the cascade is off by default, and a routeID naming no built-in model is off too",
              !OCRCascade.off.isOn && !OCRCascade(routeID: "Anthropic|no-such-model").isOn && toClaude.isOn)
        await script.set(["openrouter": (200, qwenCut), "anthropic": (200, claudeText)])
        var r = await ocr(cascade: .off)
        var calls = await script.calls()
        check("cascade off: a reply cut off at the token limit fails as `length`, with no second call",
              r.text == nil && r.errorCode == OCRFailureCode.cutOff && calls.count == 1)

        // 2. On: the cut-off page goes to Claude, and the page records it.
        r = await ocr(cascade: toClaude)
        calls = await script.calls()
        check("a cut-off reply is escalated: Claude's text is kept", r.text?.contains("CLAUDE-TEXT") == true
              && calls.first?.contains("openrouter") == true && calls.contains { $0.contains("anthropic") })
        check("the page records the reader, why, and the first reader",
              r.secondReader?.provider == "Anthropic" && r.secondReader?.model == claude.displayName
              && r.secondReader?.trigger == .failure && r.secondReader?.firstCode == "length"
              && r.secondReader?.firstReader == "OpenRouter · \(qwen.displayName)")
        let claudePage = CostEstimator.secondReaderPageCost(model: claude, imageScale: 1)
        check("the escalated page carries the route's estimated cost, which the pre-run line shows",
              claudePage > 0 && r.secondReader?.estimatedCost.map { abs($0 - claudePage) < 1e-12 } == true
              && toClaude.pageCost(imageScale: 1).map { abs($0 - claudePage) < 1e-12 } == true)
        check("an escalated page is a success, no error left on it", r.errorMessage == nil && r.errorCode == nil)
        check("the summary names the escalation", r.secondReader?.summary.contains("failed (length)") == true)
        if let data = try? JSONEncoder().encode(r), let back = try? JSONDecoder().decode(OCRResult.self, from: data) {
            check("the record round-trips through the run record's Codable", back.secondReader == r.secondReader)
        } else {
            check("the record round-trips through the run record's Codable", false)
        }
        let pdfURL = root.appendingPathComponent("page.pdf")
        _ = try? PDFGenerator().generate(imageURL: image, result: r, model: qwen, outputURL: pdfURL)
        let header = PDFDocument(url: pdfURL)?.page(at: 1)?.string ?? ""
        check("the PDF header credits the escalation route, not the first reader",
              header.contains("Anthropic \u{00B7} \(claude.displayName)") && !header.contains(qwen.displayName))

        // 3. Which failures escalate.
        await script.set(["openrouter": (200, "not json"), "anthropic": (200, claudeText)])
        r = await ocr(cascade: toClaude)
        check("an unparsable reply is escalated", r.text?.contains("CLAUDE-TEXT") == true
              && r.secondReader?.firstCode == OCRFailureCode.unparsable)
        await script.set(["openrouter": (500, #"{"error":{"message":"internal"}}"#), "anthropic": (200, claudeText)])
        r = await ocr(cascade: toClaude)
        check("a server error (500) is escalated", r.text?.contains("CLAUDE-TEXT") == true)
        for (status, label) in [(401, "a key error (401)"), (403, "a forbidden key (403)"), (429, "a rate limit (429)"),
                                (503, "an overload (503)"), (504, "a gateway timeout (504)")] {
            await script.set(["openrouter": (status, badKey), "anthropic": (200, claudeText)])
            r = await ocr(cascade: toClaude)
            calls = await script.calls()
            check("\(label) is never escalated", r.text == nil && r.errorCode == "\(status)"
                  && !calls.contains { $0.contains("anthropic") })
        }
        check("a transport failure (no code) is never escalated", !OCRCascade.isEscalatable(
            OCRResult(text: nil, classification: nil, errorMessage: "offline", errorCode: nil), provider: .openrouter))
        check("a non-Gemini provider's other text codes are not escalated (Anthropic's key error)",
              !OCRCascade.isEscalatable(OCRResult(text: nil, classification: nil, errorMessage: "x",
                                                  errorCode: "authentication_error"), provider: .anthropic)
              && OCRCascade.isEscalatable(OCRResult(text: nil, classification: nil, errorMessage: "x",
                                                    errorCode: "api_error"), provider: .anthropic))
        await script.set(["openrouter": (200, qwenText), "anthropic": (200, claudeText)])
        r = await ocr(cascade: toClaude)
        calls = await script.calls()
        check("a success is kept and the escalation route is never called",
              r.text?.contains("QWEN-TEXT") == true && r.secondReader == nil && calls.count == 1)

        // 4. Never a silent failure.
        await script.set(["openrouter": (200, qwenCut), "anthropic": (401, badKey)])
        r = await ocr(cascade: toClaude)
        check("the escalation route failing too fails the page, naming both reasons",
              r.text == nil && r.errorCode == OCRCascade.exhaustedCode
              && r.errorMessage?.contains("cut off") == true && r.errorMessage?.contains("bad key") == true)
        check("an exhausted cascade is never auto-retried, even when its reason says \"timed out\"",
              !OCRProcessor.isTimeoutError(OCRResult(text: nil, classification: nil, errorMessage: "x: timed out",
                                                     errorCode: OCRCascade.exhaustedCode))
              && !OCRCascade.isEscalatable(OCRResult(text: nil, classification: nil, errorMessage: "x",
                                                     errorCode: OCRCascade.exhaustedCode), provider: .gemini))
        let toMistral = OCRCascade(routeID: OCRCascade.routeID(for: LLMModel.mistralModels[0]))
        await script.set(["openrouter": (200, qwenCut)])
        r = await ocr(cascade: toMistral)
        calls = await script.calls()
        check("an escalation route with no key fails the page and says so, calling nothing more",
              r.errorCode == OCRCascade.exhaustedCode && r.errorMessage?.contains("no API key") == true
              && calls.count == 1)

        // 5. Where it never applies.
        let toQwen = OCRCascade(routeID: OCRCascade.routeID(for: qwen))
        await script.set(["openrouter": (200, qwenCut)])
        r = await ocr(cascade: toQwen)
        calls = await script.calls()
        check("escalating to the run's own model does nothing", r.errorCode == OCRFailureCode.cutOff && calls.count == 1
              && !toQwen.applies(to: .openrouter, model: qwen))
        let gateway = GatewayConfig(baseURL: "https://cascade-gateway.invalid/v1", modelID: "gw", displayName: "GW",
                                    inputCostPer1M: 1, outputCostPer1M: 1)
        await script.set(["cascade-gateway": (200, qwenCut), "anthropic": (200, claudeText)])
        r = await ocr(.openai, gpt, cascade: toClaude, gateway: gateway)
        calls = await script.calls()
        check("the gateway is the user's single route: its cut-off page fails as `length` and is not escalated",
              r.errorCode == OCRFailureCode.cutOff && !calls.contains { $0.contains("anthropic") })
        check("Apple Vision is never a first reader the cascade escalates",
              !toClaude.applies(to: .appleVision, model: LLMModel.appleVisionModels[0]))
        await script.set(["openrouter": (200, qwenCut), "anthropic": (200, claudeText)])
        r = await OCRProcessor.performResolutionTestCall(
            imageURL: image, provider: .openrouter, model: qwen, thinkingLevel: nil, apiKey: "k", imageScale: 1,
            rotationMode: .off, standardImageMB: 4)
        calls = await script.calls()
        check("the Tools resolution test measures the chosen model: no escalation",
              r.errorCode == OCRFailureCode.cutOff && !calls.contains { $0.contains("anthropic") })

        // 6. Gemini first: the cascade's route comes first, then the refusal readers, never the same one twice.
        let toGPT = OCRCascade(routeID: OCRCascade.routeID(for: gpt))
        await script.set(["generativelanguage": (200, recitation), "openai": (200, gptText), "anthropic": (200, claudeText)])
        r = await ocr(.gemini, flash, cascade: toGPT)
        check("a Gemini refusal goes to the cascade's route first, recorded as a refusal",
              r.text?.contains("GPT-TEXT") == true && r.secondReader?.trigger == .refusal
              && r.secondReader?.firstCode == "Recitation")
        let claudeRoute = OCRRefusalFallback.Route(provider: .anthropic, model: claude, apiKey: "a", localAgent: nil)
        let gptRoute = OCRRefusalFallback.Route(provider: .openai, model: gpt, apiKey: "o", localAgent: nil)
        OCRRefusalFallback.routesOverride = { [gptRoute, claudeRoute] }
        await script.set(["generativelanguage": (200, recitation), "openai": (401, badKey), "anthropic": (200, claudeText)])
        r = await ocr(.gemini, flash, cascade: toGPT)
        calls = await script.calls()
        check("when the cascade's route fails a refused page, the refusal readers read it, skipping that route",
              r.text?.contains("CLAUDE-TEXT") == true && calls.filter { $0.contains("openai") }.count == 1)
        OCRRefusalFallback.routesOverride = { [] }
        // A cheap reader escalating to Gemini (the bench's Qwen3.8 Flash → Gemini 3.8 Flash shape).
        let toFlash = OCRCascade(routeID: OCRCascade.routeID(for: flash))
        await script.set(["openrouter": (200, qwenCut), "generativelanguage": (200, geminiText)])
        r = await ocr(cascade: toFlash)
        check("Gemini can be the escalation route", r.text?.contains("GEMINI-TEXT") == true
              && r.secondReader?.provider == "Gemini")

        // 7. The opt-in disagreement check, against Apple Vision's word count.
        check("word counts: one more than half again the other disagrees",
              OCRCascade.disagrees(words: 10, visionWords: 100) && OCRCascade.disagrees(words: 100, visionWords: 10)
              && !OCRCascade.disagrees(words: 100, visionWords: 120) && !OCRCascade.disagrees(words: 0, visionWords: 0)
              && OCRCascade.wordCount("a  b\nc\td") == 4)
        let withCheck = OCRCascade(routeID: OCRCascade.routeID(for: claude), onDisagreement: true)
        OCRCascade.visionWordsOverride = { _ in 100 }
        await script.set(["openrouter": (200, qwenText), "anthropic": (200, claudeText)])
        r = await ocr(cascade: toClaude)
        calls = await script.calls()
        check("the disagreement check is off unless chosen", r.text?.contains("QWEN-TEXT") == true && calls.count == 1)
        r = await ocr(cascade: withCheck)
        check("on: a reading with far fewer words than Vision's is escalated, recorded as a disagreement",
              r.text?.contains("CLAUDE-TEXT") == true && r.secondReader?.trigger == .disagreement
              && r.secondReader?.firstCode == "4 words, Vision 100")
        OCRCascade.visionWordsOverride = { _ in 6 }
        await script.set(["openrouter": (200, qwenText), "anthropic": (200, claudeText)])
        r = await ocr(cascade: withCheck)
        calls = await script.calls()
        check("on: an agreeing reading is kept, with no second call", r.text?.contains("QWEN-TEXT") == true
              && calls.count == 1)
        OCRCascade.visionWordsOverride = { _ in 100 }
        await script.set(["openrouter": (200, qwenText), "anthropic": (401, badKey)])
        r = await ocr(cascade: withCheck)
        check("a disagreement whose escalation fails keeps the first reading", r.text?.contains("QWEN-TEXT") == true
              && r.errorCode == nil && r.secondReader == nil)
        OCRCascade.visionWordsOverride = nil

        // 8. A Stop: nothing more is bought.
        await script.set(["openrouter": (200, qwenCut), "anthropic": (200, claudeText)])
        let stopped = Task {
            await OCRCascade.resolve(OCRResult.cutOff, cascade: toClaude, provider: .openrouter, model: qwen,
                                     refusalFallback: true, imageURL: image, previousText: nil, previousImageURL: nil,
                                     customPrompt: nil, imageScale: 1, visionSettings: .default)
        }
        stopped.cancel()
        r = await stopped.value
        calls = await script.calls()
        check("a Stop before the escalation spends nothing and leaves the exhausted verdict the batch refuses to persist",
              r.text == nil && r.errorCode == OCRCascade.exhaustedCode && calls.isEmpty)

        // 9. Every client names a cut-off and an unparsable reply the same way.
        await script.set(["generativelanguage": (200, #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"[document_start]\nloop loop"}]}}]}"#)])
        r = await ocr(.gemini, flash, cascade: .off)
        // Gemini's cut-off is one of its no-text answers, so with no cascade it goes on to the refusal readers (none
        // here), as an empty MAX_TOKENS finish already did.
        check("Gemini: MAX_TOKENS with text is a cut-off, not a transcription (on to the refusal readers)",
              r.text == nil && r.errorCode == OCRRefusalFallback.exhaustedCode
              && r.errorMessage?.contains("cut off at the token limit") == true)
        await script.set(["anthropic": (200, #"{"content":[{"type":"text","text":"[document_start]\nloop"}],"stop_reason":"max_tokens"}"#)])
        r = await ocr(.anthropic, claude, cascade: .off)
        check("Anthropic: stop_reason max_tokens is a cut-off", r.text == nil && r.errorCode == "length")
        await script.set(["openai": (200, #"{"choices":[{"finish_reason":"length","message":{"content":"loop"}}]}"#)])
        r = await ocr(.openai, gpt, cascade: .off)
        check("OpenAI: finish_reason length is a cut-off", r.text == nil && r.errorCode == "length")
        await script.set(["openai": (200, #"{"choices":[{"finish_reason":"length","message":{"content":null}}]}"#)])
        r = await ocr(.openai, gpt, cascade: .off)
        check("OpenAI: a reply cut off before any content is a cut-off, not unparsable", r.text == nil && r.errorCode == "length")
        await script.set(["anthropic": (200, "{}"), "openai": (200, "{}")])
        let anthropicMalformed = await ocr(.anthropic, claude, cascade: .off)
        let openAIMalformed = await ocr(.openai, gpt, cascade: .off)
        check("Anthropic and OpenAI: a reply with no answer is unparsable",
              anthropicMalformed.errorCode == OCRFailureCode.unparsable && openAIMalformed.errorCode == OCRFailureCode.unparsable)
        let batchCut = GeminiBatchClient.parseSingleResponse(
            ["candidates": [["finishReason": "MAX_TOKENS", "content": ["parts": [["text": "loop"]]]]]])
        let batchNone = GeminiBatchClient.parseSingleResponse(["candidates": [[String: Any]]()])
        check("Gemini batch: MAX_TOKENS with text is a cut-off; no candidates is unparsable",
              batchCut.errorCode == "length" && batchCut.text == nil && batchNone.errorCode == OCRFailureCode.unparsable)
        let anthropicBatch = AnthropicBatchClient.parseResultsJSONL(#"""
        {"custom_id":"file-0","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"loop"}],"stop_reason":"max_tokens"}}}
        {"custom_id":"file-1","result":{"type":"succeeded","message":{"content":[{"type":"text","text":"[document_start]\nOK"}],"stop_reason":"end_turn"}}}
        """#)
        check("Anthropic batch: a max_tokens page is a cut-off, its neighbour is kept",
              anthropicBatch["file-0"]?.errorCode == "length" && anthropicBatch["file-1"]?.text == "OK")

        // 9b. W41.app-ocr-cascade review M2: with the cascade off, Gemini's reply that held no answer (now coded
        // `unparsable`) still buys no second read, as before it had a code.
        OCRRefusalFallback.routesOverride = { [claudeRoute] }
        await script.set(["generativelanguage": (200, #"{"candidates":[]}"#), "anthropic": (200, claudeText)])
        r = await ocr(.gemini, flash, cascade: .off)
        calls = await script.calls()
        check("cascade off: Gemini's unparsable reply fails plainly, no second reader called",
              r.errorCode == OCRFailureCode.unparsable && !calls.contains { $0.contains("anthropic") })
        // L1: the cascade's route was the only reader and it failed: the message says so.
        OCRRefusalFallback.routesOverride = { [gptRoute] }
        await script.set(["generativelanguage": (200, recitation), "openai": (401, badKey)])
        r = await ocr(.gemini, flash, cascade: toGPT)
        check("a refused page whose only reader was the cascade's route names that failure, not \"no second reader\"",
              r.errorCode == OCRRefusalFallback.exhaustedCode && r.errorMessage?.contains("bad key") == true
              && r.errorMessage?.contains("No second reader") == false)
        OCRRefusalFallback.routesOverride = { [] }
        // L2: Gemini's cut-off is a failure in the record, not a refusal.
        await script.set(["generativelanguage": (200, #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"loop"}]}}]}"#),
                          "anthropic": (200, claudeText)])
        r = await ocr(.gemini, flash, cascade: toClaude)
        check("a Gemini cut-off escalated by the cascade is recorded as a failure", r.secondReader?.trigger == .failure
              && r.secondReader?.firstCode == "length")

        // 9c. Review M3: the breaker. A fresh run's cascade; every page fails the same way.
        let runCascade = OCRCascade(routeID: OCRCascade.routeID(for: claude))
        await script.set(["anthropic": (200, claudeText)])
        var escalatedPages = 0
        var last = OCRResult.cutOff
        for _ in 0..<(OCRCascade.Breaker.freeEscalations + 1) {
            last = await OCRCascade.resolve(OCRResult.cutOff, cascade: runCascade, provider: .openrouter, model: qwen,
                                            refusalFallback: true, imageURL: image, previousText: nil,
                                            previousImageURL: nil, customPrompt: nil, imageScale: 1,
                                            visionSettings: .default)
            if last.secondReader != nil { escalatedPages += 1 }
        }
        calls = await script.calls()
        check("the breaker lets the first 20 escalations go, then stops a run where every page fails",
              escalatedPages == OCRCascade.Breaker.freeEscalations && calls.count == OCRCascade.Breaker.freeEscalations
              && last.errorCode == OCRFailureCode.cutOff && last.errorMessage?.contains("Not escalated: 20") == true)
        let copy = runCascade
        let more = await OCRCascade.resolve(OCRResult.cutOff, cascade: copy, provider: .openrouter, model: qwen,
                                            refusalFallback: true, imageURL: image, previousText: nil,
                                            previousImageURL: nil, customPrompt: nil, imageScale: 1,
                                            visionSettings: .default)
        check("a copy of the run's config shares its count, and the breaker is not part of equality or Codable",
              more.secondReader == nil && copy == OCRCascade(routeID: OCRCascade.routeID(for: claude))
              && (try? JSONEncoder().encode(copy)).flatMap { String(data: $0, encoding: .utf8) }?.contains("breaker") == false)
        let healthy = OCRCascade(routeID: OCRCascade.routeID(for: claude))
        for i in 0..<100 { healthy.breaker.notePage(URL(fileURLWithPath: "/scratch/page-\(i).jpg")) }
        let admits = (0..<26).map { _ in healthy.breaker.admit().allowed }
        check("a run whose pages mostly read fine keeps escalating up to a quarter of them",
              admits.prefix(25).allSatisfy { $0 } && admits[25] == false)

        // 10. The run snapshot.
        let suite = "APOCRCascade-\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            check("Settings off reads as off", OCRCascade.fromDefaults(d) == .off)
            d.set(OCRCascade.routeID(for: claude), forKey: DefaultsKeys.ocrCascadeRoute)
            d.set(true, forKey: DefaultsKeys.ocrCascadeOnDisagreement)
            check("Settings read into the run's cascade", OCRCascade.fromDefaults(d) == withCheck)
            d.removePersistentDomain(forName: suite)
        }
        // Review M1: a resumed paid batch escalates to the route it was submitted with, never to today's Settings.
        if let d = UserDefaults(suiteName: suite + "-batch") {
            d.set(OCRCascade.routeID(for: gpt), forKey: DefaultsKeys.ocrCascadeRoute)
            var pending = OCRProcessor.PendingBatch(
                batchId: "b", provider: .gemini, model: flash, thinkingLevel: nil, fileURLs: [],
                outputDirectory: URL(fileURLWithPath: "/tmp"), enableTagging: false, sendPreviousImage: false,
                submittedAt: Date())
            let legacy = OCRProcessor().makePendingBatchResumeConfig(pending, apiKey: "k", defaults: d)
            pending.cascade = withCheck
            let resumed = OCRProcessor().makePendingBatchResumeConfig(pending, apiKey: "k", defaults: d)
            let back = (try? JSONEncoder().encode(pending)).flatMap {
                try? JSONDecoder().decode(OCRProcessor.PendingBatch.self, from: $0) }
            check("a resumed batch keeps its submitted cascade; a journal without one escalates nothing",
                  resumed.cascade == withCheck && legacy.cascade == .off && back?.cascade == withCheck)
            d.removePersistentDomain(forName: suite + "-batch")
        }
        var runtime = OCRProcessor().makePendingRunRuntimeConfig(imageScale: 1, gatewayConfig: nil)
        runtime.cascade = withCheck
        if let data = try? JSONEncoder().encode(runtime),
           let back = try? JSONDecoder().decode(OCRProcessor.PendingRunRuntimeConfig.self, from: data) {
            check("a resumed run keeps the cascade it began with", back.cascade == withCheck)
        } else {
            check("a resumed run keeps the cascade it began with", false)
        }
        let partial = try? JSONDecoder().decode(OCRCascade.self, from: Data(#"{"routeID":"x|y"}"#.utf8))
        let empty = try? JSONDecoder().decode(OCRCascade.self, from: Data("{}".utf8))
        check("a cascade record missing a key decodes, with the missing parts off",
              partial == OCRCascade(routeID: "x|y") && empty == .off)
        let retried = OCRCascade(routeID: OCRCascade.routeID(for: claude))
        for _ in 0..<100 { retried.breaker.notePage(URL(fileURLWithPath: "/scratch/same-page.jpg")) }
        let retriedAdmits = (0..<21).map { _ in retried.breaker.admit().allowed }
        check("the breaker counts a page read again as one page, not one per attempt",
              retriedAdmits.prefix(20).allSatisfy { $0 } && retriedAdmits[20] == false)
        let readers = [SecondReader(provider: "Anthropic", model: "m", firstCode: "length", estimatedCost: 0.02,
                                    trigger: .failure, firstReader: "OpenRouter · q")]
        let snapshot = RunHistorySnapshot(
            startedAt: Date(), provider: .openrouter, gatewayConfig: nil, localAgent: nil, imageTokenProvider: nil,
            model: qwen, visionTextProvider: nil, visionTextModel: nil, batchMode: false, enableTagging: false,
            enableCollectionSegmentation: false, preOCRedInput: false, reOCRMultiPagePDF: false, mixedReOCR: false,
            sendPreviousImage: false, contextCharCount: 0, imageScale: 1, rotationMode: .off, fileCount: 2)
        let recorded = snapshot.makeRun(succeeded: 2, secondReaders: readers)
        check("the run's history counts escalated pages and adds their cost",
              recorded.secondReaderPages == 1 && abs(recorded.cost - (snapshot.estimatedCost + 0.02)) < 1e-12)

        finish(results)
    }

    private static func makeJPEG(at url: URL) -> URL? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                      bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let data = bitmap?.representation(using: .jpeg, properties: [:]) else { return nil }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func finish(_ results: [String]) {
        let passed = !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["OCRCASCADE_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-ocr-cascade.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}
