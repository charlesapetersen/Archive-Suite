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
        var finish = "stop"
        func set(status: Int, letter: String, finish: String = "stop") {
            self.status = status
            self.letter = letter
            self.finish = finish
            requests = []
        }
        func answer(_ request: URLRequest) -> (Int, String) {
            requests.append(request)
            return (status, #"{"choices":[{"finish_reason":"\#(finish)","message":{"content":"\#(letter)"}}]}"#)
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

        // 1. The rule's verdicts: ArchiveProcessorTests/RotationAgreementTests (W49.proc-unit-test-target).
        typealias V = OCRProcessor.RotationVerdict

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
                && !LLMRotationDetector.hasMeasuredRoute(provider: .gemini, usesGateway: false, usesLocalAgent: false, gatewayIsLocal: false))
        check("2 OpenRouter offers the measured model outside the gateway and Local Agent routes",
              LLMRotationDetector.hasRoute(provider: .openrouter, usesGateway: false, usesLocalAgent: false)
                && LLMRotationDetector.hasMeasuredRoute(provider: .openrouter, usesGateway: false,
                                                        usesLocalAgent: false, gatewayIsLocal: false)
                && !LLMRotationDetector.hasMeasuredRoute(provider: .openrouter, usesGateway: true,
                                                         usesLocalAgent: false, gatewayIsLocal: true)
                && !LLMRotationDetector.hasMeasuredRoute(provider: .openrouter, usesGateway: false,
                                                         usesLocalAgent: true, gatewayIsLocal: false))
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
            imageURL: page, provider: .openrouter, apiKey: "unused", orderings: 1, gatewayConfig: remote)
        let sent = await wire.seen()
        let body = sent.first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let content = ((body?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        check("3 the active gateway takes precedence over a stored OpenRouter provider",
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
        check("3 the rule never calls out from a model on this Mac, or a direct key with no OCR model", await wire.seen().isEmpty)
        _ = await OCRProcessor.detectRotation(imageURL: page, provider: .gemini, apiKey: "k", mode: .agreement,
                                              gatewayConfig: remote)
        let escalated = await wire.seen().count
        check("3 on a remote gateway the rule calls at most once a page", escalated <= 1)

        // Use an image without text so Vision abstains and the real agreement path has to ask OpenRouter.
        guard let blankPage = makePage(at: root.appendingPathComponent("blank.jpg"), withText: false) else {
            finish(results + ["FAIL: blank fixture could not be created"]); return
        }
        await wire.set(status: 200, letter: "D")
        let openRouterVerdict = await OpenRouterDataPolicy.$denyDataCollection.withValue(true) {
            await OCRProcessor.detectRotation(imageURL: blankPage, provider: .openrouter, apiKey: "rotation-test",
                                              mode: .agreement, gatewayConfig: nil)
        }
        let openRouterRequests = await wire.seen()
        let request = openRouterRequests.first
        let openRouterBody = request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let routing = openRouterBody?["provider"] as? [String: Any]
        let reasoning = openRouterBody?["reasoning"] as? [String: Any]
        let parts = (openRouterBody?["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        check("3 disagreement sends one authenticated OpenRouter call and uses its correction",
              openRouterRequests.count == 1 && openRouterVerdict == V(correction: 270)
                && request?.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions"
                && request?.value(forHTTPHeaderField: "Authorization") == "Bearer rotation-test")
        check("3 OpenRouter sends four candidates to the same Gemini model at the benchmark settings",
              openRouterBody?["model"] as? String == "google/gemini-3.7-flash"
                && openRouterBody?["temperature"] as? Int == 0 && openRouterBody?["max_tokens"] as? Int == 2048
                && reasoning?["effort"] as? String == "minimal"
                && parts?.filter { $0["type"] as? String == "image_url" }.count == 4)
        check("3 OpenRouter denies data collection and caps the model's price",
              routing?["data_collection"] as? String == "deny" && routing?["require_parameters"] as? Bool == true
                && routing?["max_price"] as? [String: Double] == ["prompt": 0.75, "completion": 3.75])
        await wire.set(status: 200, letter: "D")
        let majority = await OCRProcessor.detectRotation(imageURL: page, provider: .openrouter, apiKey: "rotation-test",
                                                          mode: .llmMajority, gatewayConfig: nil)
        let majorityRequests = await wire.seen()
        let majorityBody = majorityRequests.first?.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        check("3 OpenRouter majority sends three orderings and also denies data collection",
              majorityRequests.count == 3 && majority == V(correction: 270)
                && (majorityBody?["provider"] as? [String: Any])?["data_collection"] as? String == "deny")
        // Owner, 2026-11-24 (W49.proc-pipeline-prune-ok 6): a direct key asks the run's own OCR model, never a
        // separate rotation model.
        let geminiOCR = LLMModel.geminiModels[0]
        await wire.set(status: 200, letter: "D")
        _ = await OCRProcessor.detectRotation(imageURL: blankPage, provider: .gemini, apiKey: "k", mode: .agreement,
                                              gatewayConfig: nil, ocrModel: geminiOCR)
        let direct = await wire.seen()
        check("3 a direct Gemini key's disagreement asks the run's OCR model once",
              direct.count == 1 && direct.first?.url?.absoluteString.contains("/models/\(geminiOCR.id):generateContent") == true)
        // A Gemini 3 model the catalog marks not thinking thinks anyway: it gets the lowest level it accepts and the
        // output ceiling, never an unbounded call (W49.proc-rotation-thinking-price).
        func geminiConfig(_ model: LLMModel) async -> [String: Any]? {
            await wire.set(status: 200, letter: "D")
            _ = await OCRProcessor.detectRotation(imageURL: page, provider: .gemini, apiKey: "k", mode: .llmSingle,
                                                  gatewayConfig: nil, ocrModel: model)
            let body = await wire.seen().first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return body?["generationConfig"] as? [String: Any]
        }
        func catalogGemini(_ id: String) -> LLMModel? { LLMModel.geminiModels.first { $0.id == id } }
        func level(_ config: [String: Any]?) -> String? { (config?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String }
        let ceiling = LLMRotationDetector.geminiUnbudgetedCeiling
        if let pro = catalogGemini("gemini-3.1-pro"), let preview = catalogGemini("gemini-3-flash-preview") {
            let proConfig = await geminiConfig(pro), previewConfig = await geminiConfig(preview)
            check("3 a direct key's Gemini 3.1 Pro comparison thinks at low under the output ceiling",
                  !pro.supportsThinking && level(proConfig) == "low" && proConfig?["maxOutputTokens"] as? Int == ceiling)
            check("3 a direct key's Gemini 3 Flash Preview comparison thinks at minimal under the output ceiling",
                  !preview.supportsThinking && level(previewConfig) == "minimal"
                    && previewConfig?["maxOutputTokens"] as? Int == ceiling)
        } else {
            results.append("SKIP: 3 unbudgeted Gemini thinking: 3.1 Pro or 3 Flash Preview not in the catalog")
        }
        let budgeted = await geminiConfig(geminiOCR)
        check("3 a thinking Gemini model keeps its Low budget and no ceiling",
              !geminiOCR.supportsThinking || ((budgeted?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int
                == LLMRotationDetector.directThinkingTokens && budgeted?["maxOutputTokens"] == nil))
        let older = LLMModel(id: "gemini-2.5-flash-lite", displayName: "", provider: .gemini, supportsThinking: false,
                             returnsMd: false, inputCostPer1M: 0.1, outputCostPer1M: 0.4, batchDiscount: 0.5)
        check("3 a Gemini 2.5 model marked not thinking gets no thinking settings",
              LLMRotationDetector.geminiGenerationConfig(for: older).keys.sorted() == ["temperature"])
        let claudeOCR = LLMModel.anthropicModels[0]
        await wire.set(status: 200, letter: "D")   // each check reads only its own requests
        _ = await OCRProcessor.detectRotation(imageURL: page, provider: .anthropic, apiKey: "k", mode: .llmSingle,
                                              gatewayConfig: nil, ocrModel: claudeOCR)
        let claudeBody = await wire.seen().first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("3 a direct Claude key's comparison asks the run's OCR model", claudeBody?["model"] as? String == claudeOCR.id)
        let openAIOCR = LLMModel.openaiModels[0]
        await wire.set(status: 200, letter: "D")
        _ = await OCRProcessor.detectRotation(imageURL: page, provider: .openai, apiKey: "k", mode: .llmSingle,
                                              gatewayConfig: nil, ocrModel: openAIOCR)
        let openAIBody = await wire.seen().first?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("3 a direct OpenAI key's comparison asks the run's OCR model with its family's parameters",
              openAIBody?["model"] as? String == openAIOCR.id
                && (openAIOCR.supportsThinking ? openAIBody?["max_completion_tokens"] as? Int == LLMRotationDetector.openAIReasoningCeiling
                    : openAIBody?["max_tokens"] as? Int == 8))
        await wire.set(status: 200, letter: "D")
        _ = await OCRProcessor.detectRotation(imageURL: page, provider: .openai, apiKey: "k", mode: .llmSingle,
                                              gatewayConfig: nil, ocrModel: geminiOCR)
        check("3 another provider's model is never sent to a direct key", await wire.seen().isEmpty)

        await wire.set(status: 404, letter: "D")
        let fallback = await OCRProcessor.detectRotation(imageURL: blankPage, provider: .openrouter, apiKey: "rotation-test",
                                                         mode: .agreement, gatewayConfig: nil)
        check("3 an unavailable OpenRouter model leaves a Vision abstention unturned and marked unsure",
              fallback == V(correction: 0, unsure: true))

        await wire.set(status: 200, letter: "D", finish: "error")
        let providerError = await OCRProcessor.detectRotation(
            imageURL: blankPage, provider: .openrouter, apiKey: "rotation-test", mode: .agreement, gatewayConfig: nil)
        check("3 a failed OpenRouter choice cannot vote even if it contains a letter",
              providerError == V(correction: 0, unsure: true))

        let incompleteGateway = UserDefaults(suiteName: "APRotationGateway-\(UUID().uuidString)")!
        incompleteGateway.set(true, forKey: DefaultsKeys.useGateway)
        incompleteGateway.set(true, forKey: DefaultsKeys.gatewayLocalModel)
        incompleteGateway.set(LLMProvider.openrouter.rawValue, forKey: DefaultsKeys.selectedProvider)
        let live = SessionProcessingConfig.fromDefaults(incompleteGateway)
        await wire.set(status: 200, letter: "D")
        _ = await OCRProcessor.detectRotation(imageURL: blankPage, provider: live.provider, apiKey: live.apiKey,
                                              mode: .agreement, gatewayConfig: live.gateway)
        check("3 incomplete gateway settings cannot send a gateway credential via Live Capture's rotation",
              await wire.seen().isEmpty && live.apiKey.isEmpty)

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

        let abstained = OCRProcessor.mergeRotation(into: read, verdict: V(correction: nil, unsure: true, comparativeVoteFailed: true))
        check("5 a failed vote and Vision abstention preserve the OCR rotation and mark it",
              abstained.rotationDegrees == 90 && abstained.rotationUnsure == true && abstained.comparativeRotationFailed == true)
        let turned = OCRProcessor.mergeRotation(into: read, verdict: V(correction: 270, unsure: true, comparativeVoteFailed: true))
        check("5 a failed vote uses Vision's correction and records the failure",
              turned.rotationDegrees == 270 && turned.rotationUnsure == true && turned.comparativeRotationFailed == true)
        let reclassified = turned.with(classification: .documentContinuation, rotationDegrees: turned.rotationDegrees)
        let saved = try? JSONDecoder().decode(OCRResult.self, from: JSONEncoder().encode(reclassified))
        check("5 the failed vote survives reclassification and saved run results", saved?.comparativeRotationFailed == true)
        await wire.set(status: 500, letter: "")
        let localOnly = await OCRProcessor.detectRotation(imageURL: blankPage, provider: .mistral, apiKey: "",
                                                          mode: .llmSingle, gatewayConfig: nil)
        let localOnlyRequests = await wire.seen()
        check("5 a backend without comparative rotation uses Vision without reporting a failed vote",
              localOnly == V(correction: nil) && localOnlyRequests.isEmpty)

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
        check("6 the rule costs nothing off the gateway with an unpriced model", cost(.agreement, gateway: false) == 0)
        let geminiModel = LLMModel.geminiModels[0]
        let perCall = (4 * CostEstimator.estimatedRotationCandidateTokens(for: .gemini) + CostEstimator.estimatedRotationPromptTokens)
            / 1_000_000 * geminiModel.inputCostPer1M
            + (CostEstimator.estimatedRotationOutputTokens
               + (geminiModel.supportsThinking ? Double(LLMRotationDetector.directThinkingTokens) : 0))
              / 1_000_000 * geminiModel.outputCostPer1M
        let directAgreement = CostEstimator.estimate(fileCount: 1000, model: geminiModel, enableTagging: false,
                                                     sendPreviousImage: false, contextCharCount: 0,
                                                     rotationMode: .agreement).rotationCost
        check("6 a direct key's rule prices the escalated share at its OCR model's rates",
              perCall > 0 && abs(directAgreement - 1000 * 45.0 / 476.0 * perCall) < 1e-9)
        let time = TimeEstimator.estimate(fileCount: 100, model: model, rotationMode: .llmSingle, enableTagging: false,
                                          useGateway: true, gatewayRotation: true)
        check("6 the time estimate counts the gateway's calls", time.rotationSeconds > 0)
        // A Gemini 3 model marked not thinking is priced at its whole output ceiling on every call (three under ×3).
        if let pro = LLMModel.geminiModels.first(where: { $0.id == "gemini-3.1-pro" }) {
            let proCall = (4 * CostEstimator.estimatedRotationCandidateTokens(for: .gemini) + CostEstimator.estimatedRotationPromptTokens)
                / 1_000_000 * pro.inputCostPer1M
                + (CostEstimator.estimatedRotationOutputTokens + Double(LLMRotationDetector.geminiUnbudgetedCeiling))
                  / 1_000_000 * pro.outputCostPer1M
            let majority = CostEstimator.estimate(fileCount: 1000, model: pro, enableTagging: false, sendPreviousImage: false,
                                                  contextCharCount: 0, rotationMode: .llmMajority).rotationCost
            check("6 a direct Gemini 3.1 Pro comparison is priced at its output ceiling, three calls under ×3",
                  abs(majority - 1000 * 3 * proCall) < 1e-9)
        } else {
            results.append("SKIP: 6 Gemini 3.1 Pro pricing: not in the catalog")
        }
        // A direct OpenAI reasoning model is priced at its whole completion ceiling (no thinking budget to hold it to).
        if let reasoning = LLMModel.openaiModels.first(where: \.supportsThinking) {
            let openAICall = (4 * CostEstimator.estimatedRotationCandidateTokens(for: .openai) + CostEstimator.estimatedRotationPromptTokens)
                / 1_000_000 * reasoning.inputCostPer1M
                + (CostEstimator.estimatedRotationOutputTokens + Double(LLMRotationDetector.openAIReasoningCeiling))
                  / 1_000_000 * reasoning.outputCostPer1M
            let single = CostEstimator.estimate(fileCount: 1000, model: reasoning, enableTagging: false, sendPreviousImage: false,
                                                contextCharCount: 0, rotationMode: .llmSingle).rotationCost
            check("6 a direct OpenAI reasoning model's comparison is priced at its completion ceiling",
                  abs(single - 1000 * openAICall) < 1e-9)
        } else {
            results.append("SKIP: 6 OpenAI reasoning pricing: no OpenAI model supports thinking")
        }
        let agent = TimeEstimator.estimate(fileCount: 100, model: geminiModel, rotationMode: .agreement, enableTagging: false,
                                           usesLocalAgent: true)
        let directTime = TimeEstimator.estimate(fileCount: 100, model: geminiModel, rotationMode: .agreement, enableTagging: false)
        check("6 the Local Agent makes no rotation call, so its time adds none; a direct key's rule does",
              agent.rotationSeconds == 0 && directTime.rotationSeconds > 0)

        let routerModel = OpenRouterRoute.catalog[0].model
        func openRouterCost(_ mode: RotationMode, preOCRed: Bool = false, useGateway: Bool = false) -> Double {
            CostEstimator.estimate(fileCount: 1000, model: routerModel, enableTagging: false, preOCRedInput: preOCRed,
                                   sendPreviousImage: false, contextCharCount: 0, rotationMode: mode,
                                   useGateway: useGateway).rotationCost
        }
        check("6 OpenRouter prices the estimated agreement calls and one or three comparisons per page",
              abs(openRouterCost(.agreement) - 3.7 * 45.0 / 476.0) < 1e-9
                && abs(openRouterCost(.llmSingle) - 3.7) < 1e-9
                && abs(openRouterCost(.llmMajority) - 11.1) < 1e-9)
        check("6 local, off, pre-OCRed and local gateway paths incur no OpenRouter rotation cost",
              openRouterCost(.localVision) == 0 && openRouterCost(.off) == 0
                && openRouterCost(.agreement, preOCRed: true) == 0 && openRouterCost(.agreement, useGateway: true) == 0)
        let pdfEstimate = CostEstimator.estimateDirectPDFPages(pageCount: 1000, model: routerModel,
                                                               rotationMode: .llmSingle)
        check("6 directly read PDF pages also include OpenRouter rotation", abs(pdfEstimate.rotationCost - 3.7) < 1e-9)
        let routerTime = TimeEstimator.estimate(fileCount: 100, model: routerModel, rotationMode: .llmSingle,
                                                enableTagging: false)
        check("6 the time estimate counts the OpenRouter calls", routerTime.rotationSeconds == time.rotationSeconds)
        check("6 OpenRouter still does not use the app's Batch mode", !routerModel.provider.supportsBatch)

        finish(results)
    }

    /// A blank page or one with upright dark text, big enough for both local detectors to read.
    private static func makePage(at url: URL, withText: Bool = true) -> URL? {
        let size = NSSize(width: 850, height: 1100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        if withText {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
            for line in 0..<30 {
                ("The committee met on the fourth of March to consider the report, line \(line)." as NSString)
                    .draw(at: NSPoint(x: 60, y: 1040 - CGFloat(line) * 33), withAttributes: attrs)
            }
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
