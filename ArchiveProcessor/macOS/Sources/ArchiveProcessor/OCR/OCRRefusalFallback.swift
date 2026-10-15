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
/// Called only from the direct-Gemini branch of `OCRProcessor.performOCRCall`; the gateway and Local Agent
/// backends are the user's explicit single route and are never second-guessed.
enum OCRRefusalFallback {
    /// One route a refused page can be sent to.
    struct Route: Sendable {
        let provider: LLMProvider
        let model: LLMModel
        let apiKey: String
        /// Set for the user's own `claude` (subscription, no key); the direct client otherwise.
        let localAgent: LocalAgentConfig?

        /// What the run's record names as the page's reader.
        var label: String {
            if let localAgent { return localAgent.provenanceDisplayName }
            return "\(model.displayName) (\(provider.rawValue))"
        }
    }

    /// Test seam: replaces the Keychain/CLI lookup (headless tests have no Keychain). nil in production.
    nonisolated(unsafe) static var routesOverride: (@Sendable () -> [Route])?

    /// A Gemini answer with no text that a second model can plausibly read: a finish/block reason, or HTTP 500
    /// (AI Studio's "error with no tokens"). Not a transport failure (nil code), a timeout, or a 4xx — a bad
    /// key, an exhausted quota or a bad request is the user's to fix, and a second paid reader would hide it.
    static func isRefusal(_ result: OCRResult) -> Bool {
        guard result.text == nil, let code = result.errorCode, !code.isEmpty else { return false }
        if OCRProcessor.isTimeoutError(result) { return false }
        if code.allSatisfy(\.isNumber) { return code == "500" }
        return true
    }

    /// The routes the user has, best first by the W41 panel: Claude (by plan or key, per the user's
    /// `ClaudeRoute`), then an OpenAI key (GPT-5.4 mini, 93.55 NES), then a Mistral key (Mistral OCR, 92.91).
    /// Reads the Keychain, so it runs only once a page has actually been refused.
    static func availableRoutes(_ defaults: UserDefaults = .standard) -> [Route] {
        if let routesOverride { return routesOverride() }
        let available = SegmentationRoutes.current(defaults)
        var routes: [Route] = []
        let anthropicKey = KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? ""
        let claudeModel = LLMModel.anthropicModels[0]
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
        if let key = KeychainHelper.load(account: LLMProvider.openai.rawValue), !key.isEmpty {
            let model = LLMModel.openaiModels.first { $0.id == "gpt-5.4-mini" } ?? LLMModel.openaiModels[0]
            routes.append(Route(provider: .openai, model: model, apiKey: key, localAgent: nil))
        }
        if let key = KeychainHelper.load(account: LLMProvider.mistral.rawValue), !key.isEmpty {
            routes.append(Route(provider: .mistral, model: LLMModel.mistralModels[0], apiKey: key, localAgent: nil))
        }
        return routes
    }

    /// Reads a page Gemini refused with each available route in turn, returning the first that gives text,
    /// marked with `secondReader`. Otherwise a failure carrying Gemini's code and every route's reason.
    static func readRefusedPage(
        _ refused: OCRResult, imageURL: URL, previousText: String?, previousImageURL: URL?,
        customPrompt: String?, imageScale: Double
    ) async -> OCRResult {
        let why = refused.errorMessage ?? "Gemini returned no text (\(refused.errorCode ?? "?"))."
        let routes = availableRoutes()
        guard !routes.isEmpty else {
            NSLog("[OCR] Gemini refused \(imageURL.lastPathComponent) (\(refused.errorCode ?? "?")); no second reader")
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "\(why) No second reader is set up: add an Anthropic, OpenAI or "
                                 + "Mistral key, or install claude, to read pages Gemini refuses.",
                             errorCode: refused.errorCode)
        }
        var reasons: [String] = []
        for route in routes {
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
                let note = "\(route.label) — Gemini returned no text (\(refused.errorCode ?? "?"))"
                NSLog("[OCR] Gemini refused \(imageURL.lastPathComponent); read by \(route.label)")
                return OCRResult(text: result.text, classification: result.classification,
                                 rotationDegrees: result.rotationDegrees, errorMessage: nil, errorCode: nil,
                                 enclosure: result.enclosure, secondReader: note)
            }
            reasons.append("\(route.label): \(result.errorMessage ?? "no text")")
        }
        NSLog("[OCR] Gemini refused \(imageURL.lastPathComponent); every second reader failed")
        return OCRResult(text: nil, classification: nil,
                         errorMessage: "\(why) Second readers failed too — " + reasons.joined(separator: "; "),
                         errorCode: refused.errorCode)
    }

    private static func read(
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
        case .mistral:
            return try await MistralClient(apiKey: route.apiKey, model: route.model).ocr(
                imageURL: imageURL, previousText: previousText, imageScale: imageScale)
        case .gemini, .appleVision:
            // Never a second reader: Gemini is the refuser, and Vision's text is not a transcription.
            return OCRResult(text: nil, classification: nil, errorMessage: "not a second reader", errorCode: nil)
        }
    }
}
