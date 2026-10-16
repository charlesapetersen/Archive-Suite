import Foundation

/// W41.app-ocr-default — the second reader for a page Gemini refuses.
///
/// Every Gemini route in the W41 OCR panel failed the same two printed pages (reprinted published text,
/// 1900-1949): AI Studio ends the call with no text — a `RECITATION`/`OTHER` finish, a block reason, or a bare
/// server error — on every try (`segbench-results/W41-answers.md` §2, `ocr-truth.md`). Retrying Gemini does not
/// help, so such a page is read by a second route the user already has, and the result says so in
/// `OCRResult.secondReader`, which the run's `PendingRun.completedResults` persists. When no second route exists
/// or every one fails, the page FAILS with a message naming the refusal — never an empty success.
///
/// Called only through `OCRCascade.resolve` (W41.app-ocr-cascade), on the direct-provider path of
/// `OCRProcessor.performOCRCall` and the batch collection: after the cascade's own route when one is set, and
/// otherwise alone. The gateway and Local Agent backends are the user's explicit single route and are never
/// second-guessed.
enum OCRRefusalFallback {
    /// One route a refused page can be sent to.
    struct Route: Sendable {
        let provider: LLMProvider
        let model: LLMModel
        let apiKey: String
        /// Set for the user's own `claude` (subscription, no key); the direct client otherwise.
        let localAgent: LocalAgentConfig?

        /// The PDF header's provider/model positions for a page this route read (as the run's own backend would).
        var provenanceProvider: String { localAgent?.provenanceDisplayName ?? provider.rawValue }
        var provenanceModel: String { localAgent?.provenanceModelName ?? model.displayName }
        var label: String { "\(provenanceProvider) · \(provenanceModel)" }
    }

    /// The code on a refused page no second reader could read. `isTimeoutError`/`isRetryableError` never retry it:
    /// the message may quote a reader's "timed out" or "overloaded", and a re-run would buy the refusal and every
    /// reader again. The operator's explicit per-item Retry still can.
    static let exhaustedCode = "GeminiRefused"

    /// The OpenRouter model that reads a refused page: Qwen3.6 27B, second on printed pages, which Gemini refuses.
    static let openRouterReaderID = "qwen/qwen3.6-27b"

    /// Test seam: replaces the Keychain/CLI lookup (headless tests have no Keychain). nil in production.
    nonisolated(unsafe) static var routesOverride: (@Sendable () -> [Route])?

    /// A Gemini answer with no text that a second model can plausibly read: a finish/block reason, or HTTP 500
    /// (AI Studio's "error with no tokens"). Not a transport failure (nil code), a timeout, or a 4xx — a bad
    /// key, an exhausted quota or a bad request is the user's to fix, and a second paid reader would hide it.
    static func isRefusal(_ result: OCRResult) -> Bool {
        guard result.text == nil, let code = result.errorCode, !code.isEmpty else { return false }
        if OCRProcessor.isTimeoutError(result) { return false }
        // A reply Gemini sent that held no answer was a plain failure before it had a code (W41.app-ocr-cascade);
        // it stays one here, so it buys no second read unless the user set up a cascade.
        if code == OCRFailureCode.unparsable { return false }
        if code.allSatisfy(\.isNumber) { return code == "500" }
        return true
    }

    /// The routes the user has, best first by the W41 panel: Claude (by plan or key, per the user's
    /// `ClaudeRoute`), then an OpenRouter key (Qwen3.6 27B, second only to Claude on printed pages, 94.8 —
    /// `ocr-page-guidance.json`; W41.app-openrouter-fu1), then an OpenAI key (GPT-5.4 mini, 93.55 NES), then a
    /// Mistral key (Mistral OCR, 92.91).
    /// Reads the Keychain, so it runs only once a page has actually been refused.
    static func availableRoutes(_ defaults: UserDefaults = .standard) -> [Route] {
        if let routesOverride { return routesOverride() }
        let available = SegmentationRoutes.current(defaults)
        var routes: [Route] = []
        let anthropicKey = KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? ""
        let claudeModel = keyedModels[0]
        if available.claudeByPlan {
            let tool = defaults.string(forKey: DefaultsKeys.localAgentTool).flatMap(LocalAgentTool.init(rawValue:))
            let path = tool == .claude ? (defaults.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? "") : ""
            routes.append(Route(provider: .anthropic, model: claudeModel, apiKey: "",
                                localAgent: LocalAgentConfig(tool: .claude, binaryPath: path)))
        }
        // A user who chose the plan over the key is not charged behind their back when the plan fails.
        if !available.claudeByPlan, !anthropicKey.isEmpty {
            routes.append(Route(provider: .anthropic, model: claudeModel, apiKey: anthropicKey, localAgent: nil))
        }
        if let key = KeychainHelper.load(account: LLMProvider.openrouter.rawValue), !key.isEmpty {
            routes.append(Route(provider: .openrouter, model: keyedModels[1], apiKey: key, localAgent: nil))
        }
        if let key = KeychainHelper.load(account: LLMProvider.openai.rawValue), !key.isEmpty {
            routes.append(Route(provider: .openai, model: keyedModels[2], apiKey: key, localAgent: nil))
        }
        if let key = KeychainHelper.load(account: LLMProvider.mistral.rawValue), !key.isEmpty {
            routes.append(Route(provider: .mistral, model: keyedModels[3], apiKey: key, localAgent: nil))
        }
        return routes
    }

    /// The model each keyed route uses, in `availableRoutes` order: Claude, Qwen3.6 27B, GPT-5.4 mini, Mistral OCR.
    /// Qwen3.6 27B goes through its pinned OpenRouter route (chutes fp8, reasoning off), the one the panel scored.
    static var keyedModels: [LLMModel] {
        [LLMModel.anthropicModels[0],
         OpenRouterRoute.forModel(openRouterReaderID)?.model ?? LLMModel.openrouterModels[0],
         LLMModel.openaiModels.first { $0.id == "gpt-5.4-mini" } ?? LLMModel.openaiModels[0],
         LLMModel.mistralModels[0]]
    }

    /// What one refused page costs a keyed second reader, cheapest to dearest, for the pre-run estimate
    /// (W41.app-ocr-default-fu1). Reads no Keychain, so it can run on every redraw; which route a refused page
    /// actually takes depends on the keys present then, and claude by plan costs nothing.
    static func pageCostRange(imageScale: Double) -> ClosedRange<Double> {
        let costs = keyedModels.map { CostEstimator.secondReaderPageCost(model: $0, imageScale: imageScale) }
        return (costs.min() ?? 0)...(costs.max() ?? 0)
    }

    /// Reads a page Gemini refused with each available route in turn, returning the first that gives text,
    /// marked with `secondReader`. Otherwise a failure (`exhaustedCode`) naming Gemini's reason and every route's.
    static func readRefusedPage(
        _ refused: OCRResult, imageURL: URL, previousText: String?, previousImageURL: URL?,
        customPrompt: String?, imageScale: Double, excluding: LLMModel? = nil, failedBefore: String? = nil
    ) async -> OCRResult {
        let why = refused.errorMessage ?? "Gemini returned no text (\(refused.errorCode ?? "?"))."
        // `excluding`: the cascade's route, which has already failed this page (W41.app-ocr-cascade).
        let routes = availableRoutes().filter { route in
            guard let excluding, route.localAgent == nil else { return true }
            return !(route.provider == excluding.provider && route.model.id == excluding.id)
        }
        if routes.isEmpty, let failedBefore {
            // The cascade's route was the only one, and it failed: say so, not "no second reader is set up".
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "\(why) Second readers failed too — \(failedBefore)", errorCode: exhaustedCode)
        }
        guard !routes.isEmpty else {
            NSLog("[OCR] Gemini refused \(imageURL.lastPathComponent) (\(refused.errorCode ?? "?")); no second reader")
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "\(why) No second reader is set up: add an Anthropic, OpenRouter, "
                                 + "OpenAI or Mistral key, or install claude, to read pages Gemini refuses.",
                             errorCode: exhaustedCode)
        }
        var reasons: [String] = failedBefore.map { [$0] } ?? []
        for route in routes {
            // Stopped: spend nothing more. The caller sees the exhausted code and, in a batch, does not persist it.
            if Task.isCancelled { reasons.append("stopped before \(route.label)"); break }
            let result: OCRResult
            do {
                result = try await read(route, imageURL: imageURL, previousText: previousText,
                                        previousImageURL: previousImageURL, customPrompt: customPrompt,
                                        imageScale: imageScale)
            } catch {
                reasons.append("\(route.label): \(error.localizedDescription)")
                continue
            }
            if result.text != nil {
                let cost = route.localAgent == nil
                    ? CostEstimator.secondReaderPageCost(model: route.model, imageScale: imageScale) : 0
                let reader = SecondReader(provider: route.provenanceProvider, model: route.provenanceModel,
                                          firstCode: refused.errorCode ?? "?", estimatedCost: cost)
                NSLog("[OCR] Gemini refused \(imageURL.lastPathComponent); read by \(reader.summary)")
                return OCRResult(text: result.text, classification: result.classification,
                                 rotationDegrees: result.rotationDegrees, errorMessage: nil, errorCode: nil,
                                 enclosure: result.enclosure, secondReader: reader)
            }
            reasons.append("\(route.label): \(result.errorMessage ?? "no text")")
        }
        NSLog("[OCR] Gemini refused \(imageURL.lastPathComponent); every second reader failed")
        return OCRResult(text: nil, classification: nil,
                         errorMessage: "\(why) Second readers failed too — " + reasons.joined(separator: "; "),
                         errorCode: exhaustedCode)
    }

    /// One route's reading of the page. Also the cascade's escalation read (`OCRCascade`), which may be Gemini.
    static func read(
        _ route: Route, imageURL: URL, previousText: String?, previousImageURL: URL?,
        customPrompt: String?, imageScale: Double
    ) async throws -> OCRResult {
        if let localAgent = route.localAgent {
            return try await LocalAgentClient(config: localAgent).ocr(
                imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                customPrompt: customPrompt, imageScale: imageScale)
        }
        switch route.provider {
        case .anthropic:
            return try await AnthropicClient(apiKey: route.apiKey, model: route.model, thinkingLevel: nil).ocr(
                imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                customPrompt: customPrompt, imageScale: imageScale)
        case .openai:
            return try await OpenAICompatibleClient.openAI(model: route.model, apiKey: route.apiKey, thinkingLevel: nil).ocr(
                imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                customPrompt: customPrompt, imageScale: imageScale)
        case .openrouter:
            return try await OpenAICompatibleClient.pinnedOpenRouter(model: route.model, apiKey: route.apiKey).ocr(
                imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                customPrompt: customPrompt, imageScale: imageScale)
        case .mistral:
            return try await MistralClient(apiKey: route.apiKey, model: route.model).ocr(
                imageURL: imageURL, previousText: previousText, imageScale: imageScale)
        case .gemini:
            // Never a refusal route (`availableRoutes` builds none: Gemini is the refuser), but a cascade may
            // escalate a cheaper reader's failure to it.
            return try await GeminiClient(apiKey: route.apiKey, model: route.model, thinkingLevel: nil).ocr(
                imageURL: imageURL, previousText: previousText, previousImageURL: previousImageURL,
                customPrompt: customPrompt, imageScale: imageScale)
        case .appleVision:
            // Never a second reader: Vision's text is not a transcription the panel scored as one.
            return OCRResult(text: nil, classification: nil, errorMessage: "not a second reader", errorCode: nil)
        }
    }
}
