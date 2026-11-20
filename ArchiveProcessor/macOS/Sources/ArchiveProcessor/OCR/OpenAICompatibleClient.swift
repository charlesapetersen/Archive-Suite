import Foundation
import AppKit

struct OpenAICompatibleClient: Sendable {
    let baseURL: String
    let apiKey: String
    let modelID: String

    /// Token-limit parameter name. Native OpenAI reasoning models use `max_completion_tokens`, which
    /// bounds visible and reasoning tokens; OpenAI-compatible gateways retain `max_tokens`. Defaults to
    /// `max_tokens`, so existing gateway callers build a byte-identical request.
    var maxTokensParam: String = "max_tokens"
    /// Optional OpenAI `reasoning_effort` ("low"/"medium"/"high"), sent only when non-nil (reasoning
    /// models only). Set by the `openAI(model:apiKey:thinkingLevel:)` factory from the caller's
    /// `ThinkingLevel` (see `ThinkingLevel.openAIReasoningEffort`); left nil for gateway callers.
    var reasoningEffort: String? = nil
    /// W41.app-openrouter: the pinned provider, precision and reasoning setting for an OpenRouter model. nil for
    /// every other caller, whose requests stay byte-identical.
    var openRouterRoute: OpenRouterRoute? = nil
    /// W41.app-local-models: a model on this Mac (`LocalModelRoute`): a lower token cap, temperature 0, a long
    /// timeout, reasoning text stripped and a looping reply failed. false for every other caller.
    var localModel = false

    /// The client for the user's gateway, local or remote.
    static func gateway(_ config: GatewayConfig) -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: config.baseURL, apiKey: config.apiKey, modelID: config.modelID,
                               localModel: config.isLocalModel)
    }

    private var requestTimeout: TimeInterval { localModel ? LocalModelRoute.requestTimeout : 120 }

    private var chatEndpoint: URL? {
        URL(string: "\(GatewayConfig.normalizedBaseURL(baseURL))/chat/completions")
    }

    func ocr(imageURL: URL, previousText: String? = nil, previousImageURL: URL? = nil, customPrompt: String? = nil, imageScale: Double = 1.0) async throws -> OCRResult {
        guard let jpegData = ImageEncoding.loadImageAsJPEG(url: imageURL, scale: imageScale) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()
        let prompt = OCRPrompt.build(previousText: previousText, previousImageIncluded: previousImageURL != nil, customPrompt: customPrompt)

        var contentParts: [[String: Any]] = []

        if let prevURL = previousImageURL, let prevData = ImageEncoding.loadImageAsJPEG(url: prevURL, scale: imageScale) {
            contentParts.append(["type": "image_url", "image_url": imageField(prevData.base64EncodedString())])
        }

        contentParts.append(["type": "image_url", "image_url": imageField(base64)])
        contentParts.append(["type": "text", "text": prompt])

        var body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": contentParts]]
        ]
        body[maxTokensParam] = localModel ? LocalModelRoute.maxTokens : 8192
        if localModel {
            body["temperature"] = 0
            LocalModelRoute.applyReasoningOff(&body)
        }
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        applyOpenRouterRoute(&body)

        // A model on this Mac streams its reply, so a loop is stopped as it starts (W41.app-local-models-fu1).
        if localModel { return try await readLocally(body) }

        let (data, response) = try await sendRequest(body: body, timeoutInterval: requestTimeout)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            // Gemini's refusal of reprinted text can come back as an upstream error naming it: still a refusal.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let refused = makerRefusal(finish: nil, native: nil, content: nil, errorText: Self.providerErrorText(json)) {
                return refused
            }
            let errorMessage = Self.parseErrorResponse(data: data, statusCode: http.statusCode, provider: billingProvider)
            return OCRResult(text: nil, classification: nil, errorMessage: errorMessage, errorCode: "\(http.statusCode)")
        }
        return parseCompletion(data)
    }

    /// The `image_url` object: OpenAI's own endpoint through OpenRouter reads it at `detail: high`, as the bench sent it
    /// (`ocr_cloud.py`); every other caller's stays byte-identical.
    private func imageField(_ base64: String) -> [String: Any] {
        var field: [String: Any] = ["url": "data:image/jpeg;base64,\(base64)"]
        if openRouterRoute?.maker?.provider == .openai { field["detail"] = "high" }
        return field
    }

    /// A whole (unstreamed) chat-completions reply as an OCR result. Also a local server's, when it ignored `stream`.
    private func parseCompletion(_ data: Data) -> OCRResult {
        let whole = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choice = (whole?["choices"] as? [[String: Any]])?.first
        if let refused = makerRefusal(finish: choice?["finish_reason"] as? String,
                                      native: choice?["native_finish_reason"] as? String,
                                      content: (choice?["message"] as? [String: Any])?["content"] as? String,
                                      errorText: whole.flatMap(Self.providerErrorText)) {
            return refused
        }
        guard let json = whole,
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let rawContent = message["content"] as? String else {
            // OpenRouter reports a provider's failure as a 200 with an `error` object in the body.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any] {
                let code = (error["code"] as? Int).map(String.init) ?? (error["code"] as? String)
                let message = error["message"] as? String
                return OCRResult(text: nil, classification: nil,
                                 errorMessage: billingStatusMessage(Int(code ?? "") ?? 0, provider: billingProvider,
                                                                    detail: message) ?? message ?? "Provider error",
                                 errorCode: Self.openRouterRetryCode(code))
            }
            // A reply cut at the token limit before any content (`content: null`) is a cut-off, not unparsable.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               choices.first?["finish_reason"] as? String == "length" {
                return OCRResult.cutOff
            }
            return OCRResult(text: nil, classification: nil, errorMessage: "Malformed response", errorCode: OCRFailureCode.unparsable)
        }
        return completedReply(rawContent, finish: choices.first?["finish_reason"] as? String)
    }

    /// The reply's content and finish reason, streamed or whole, as an OCR result.
    private func completedReply(_ rawContent: String, finish: String?) -> OCRResult {
        // OpenRouter reports a provider failure mid-stream as finish_reason "error", and every OpenAI-compatible
        // endpoint reports a reply cut at the token limit as "length": neither is a transcription (W41.app-openrouter
        // review; the cut reply on every route since W41.app-ocr-cascade). The failure is 503, which
        // `isRetryableError` retries; a cut reply is not retried, since the same budget would cut it again.
        if finish == "length" { return OCRResult.cutOff }
        if openRouterRoute != nil, finish == "error" {
            return OCRResult(text: nil, classification: nil, errorMessage: "The provider failed while answering",
                             errorCode: "503")
        }
        let content = localModel ? LocalModelRoute.strippingReasoning(rawContent) : rawContent
        // A local model that looped but stopped by itself (W41.mac-local-measure) is a failed page like a cut one.
        if localModel, LocalModelRoute.isRepetitionLoop(content) { return LocalModelRoute.loopedReply }
        let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(content)
        // A local reply that was all reasoning (`<think>` only, closed or not) answered nothing: unparsable, so it can
        // escalate. An unclosed block survives the strip, and the lenient parser would keep it as the page's text.
        if localModel, ocrText == nil || content.contains("<think>") {
            return OCRResult(text: nil, classification: nil, errorMessage: "The local model's reply held no transcription",
                             errorCode: OCRFailureCode.unparsable)
        }
        // W40.fix-processor-non-reading-reply: an OpenRouter or OpenAI reply with no classification tag is not a
        // reading (Qwen3.8 Flash answered 3 of 113 photos "The user wants me to identify the object in the image."):
        // unparsable, so the page fails, counts in the failed total and reaches the cascade's second reader, instead
        // of keeping the chatter as page text. A user's gateway keeps the lenient parse: it may serve an OCR model
        // that writes text only (`LocalModelRoute`).
        if keepsPromptFormat, classification == nil {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "The model's reply was not a reading of the page (no classification line)",
                             errorCode: OCRFailureCode.unparsable)
        }
        return OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil, enclosure: OCRPrompt.parseEnclosureFlag(content))
    }

    /// Whether a reply that does not follow the OCR prompt's format fails: the app's own OpenRouter and OpenAI routes,
    /// not a user's gateway.
    private var keepsPromptFormat: Bool {
        !localModel && (openRouterRoute != nil || baseURL == Self.openAIBaseURL)
    }

    /// A model on this Mac (W41.app-local-models-fu1): the reply streamed and closed once it loops, and a page that
    /// looped or reached the cap read once more, with a light repetition penalty, before it fails (and escalates, when
    /// the user allowed it). The failure reason then says it was read twice.
    private func readLocally(_ body: [String: Any]) async throws -> OCRResult {
        let first = try await streamLocally(body)
        guard LocalModelRoute.shouldReadAgain(first) else { return first }
        var again = body
        LocalModelRoute.applyRetryPenalty(&again)
        do {
            return LocalModelRoute.afterSecondReading(first: first, second: try await streamLocally(again))
        } catch {
            // A cancelled run stops here; any other failure leaves the first reading's, which can still escalate.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            return LocalModelRoute.afterFailedSecondReading(first: first, error: error)
        }
    }

    private func streamLocally(_ body: [String: Any]) async throws -> OCRResult {
        var body = body
        body["stream"] = true
        let request = try makeRequest(body: body, timeoutInterval: requestTimeout)
        var reply = LocalModelRoute.StreamedReply()
        let response: URLResponse, stopped: Bool
        do {
            (response, stopped) = try await NetworkSession.streamLines(for: request) { reply.take($0) }
        } catch let error as URLError where error.code == .timedOut {
            // A bigger local model can run past the timeout before reaching the cap, or before its loop is long
            // enough to see. Same failure as a cut reply: not read again (another 10 minutes), escalated when allowed.
            return LocalModelRoute.timedOutReply
        }
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }
        if http.statusCode != 200 {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: Self.parseErrorResponse(data: reply.rawBody, statusCode: http.statusCode, provider: billingProvider),
                             errorCode: "\(http.statusCode)")
        }
        // `take` stops the stream only when the reply loops.
        if stopped { return LocalModelRoute.loopedReply }
        // A server that ignored `stream` sent the whole reply as one JSON body.
        if !reply.sawEvents { return parseCompletion(reply.rawBody) }
        if let error = reply.error {
            return OCRResult(text: nil, classification: nil, errorMessage: error, errorCode: "500")
        }
        if !reply.isComplete { return LocalModelRoute.endedEarlyReply }
        return completedReply(reply.content, finish: reply.finish)
    }

    func textCompletion(prompt: String, maxTokens: Int = 512) async throws -> String {
        var body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]]
        ]
        body[maxTokensParam] = maxTokens
        if localModel {
            body["temperature"] = 0
            LocalModelRoute.applyReasoningOff(&body)
        }
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        applyOpenRouterRoute(&body)

        let (data, response) = try await sendRequest(body: body, timeoutInterval: requestTimeout)

        // A local model's reply with no answer (reasoning it was not switched out of, or cut at the budget) is a
        // failure, never tags or a classification read from its thinking (W41.app-local-models-fu2). A refusal says
        // why (a server that rejected a request field, say), as the OCR stream does.
        if localModel, let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw OCRError.networkError(Self.parseErrorResponse(data: data, statusCode: status, provider: billingProvider))
        }
        if localModel, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choice = (json["choices"] as? [[String: Any]])?.first {
            let message = choice["message"] as? [String: Any]
            guard let answer = LocalModelRoute.textAnswer(message?["content"] as? String,
                                                          finish: choice["finish_reason"] as? String) else {
                throw OCRError.networkError(LocalModelRoute.noTextAnswer)
            }
            return answer
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            if openRouterRoute != nil {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                throw OCRError.networkError(Self.parseErrorResponse(data: data, statusCode: status, provider: billingProvider))
            }
            throw OCRError.networkError("bad response")
        }
        // An OpenRouter reply with no answer (a provider failure, or reasoning that used the budget) is an error,
        // never an empty tag or classification.
        if openRouterRoute != nil,
           (choices.first?["finish_reason"] as? String) == "error"
            || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OCRError.networkError("OpenRouter returned no answer")
        }

        return content
    }

    private func sendRequest(body: [String: Any], timeoutInterval: TimeInterval) async throws -> (Data, URLResponse) {
        try await NetworkSession.data(for: makeRequest(body: body, timeoutInterval: timeoutInterval), policy: .nonIdempotent)
    }

    private func makeRequest(body: [String: Any], timeoutInterval: TimeInterval) throws -> URLRequest {
        guard let endpoint = chatEndpoint else {
            throw OCRError.networkError("Invalid gateway URL: \(baseURL)")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The provider a 402 names, by endpoint: OpenAI or OpenRouter; nil for a gateway or a server on this Mac.
    var billingProvider: LLMProvider? {
        if openRouterRoute != nil || baseURL == Self.openRouterBaseURL { return .openrouter }
        return baseURL == Self.openAIBaseURL ? .openai : nil
    }

    static func parseErrorResponse(data: Data, statusCode: Int, provider: LLMProvider? = nil) -> String {
        // Status-based classification first, independent of body shape — gateways (vLLM/LiteLLM/Ollama
        // shims, CDNs) often return an empty or non-JSON 5xx/429 body.
        if let msg = transientStatusMessage(statusCode) { return msg }
        var message: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Handle the several error shapes arbitrary OpenAI-compatible gateways use.
            message = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["error"] as? String ?? json["detail"] as? String ?? json["message"] as? String
        }
        if let billing = billingStatusMessage(statusCode, provider: provider, detail: message) { return billing }
        return message ?? "API error (\(statusCode))"
    }
}

// MARK: - Native OpenAI provider

extension OpenAICompatibleClient {
    /// The native OpenAI API base URL used by the first-class `.openai` provider (distinct from the
    /// user-supplied gateway base URL). A custom gateway base URL still covers Azure OpenAI / proxies.
    /// // VERIFY this stays current at build time.
    static let openAIBaseURL = "https://api.openai.com/v1"

    /// Build a client for the first-class `.openai` provider, applying the model-family param adapter
    /// (OpenAI plan, Design decision 3): `max_completion_tokens` is used for reasoning-capable models.
    /// Keyed off `model.supportsThinking`, which the built-in `openaiModels` list tracks per model.
    ///
    /// `reasoning_effort` (W13.oai-2) is likewise gated on `supportsThinking`: it is sent only for
    /// reasoning-capable models and only when the caller passes a `thinkingLevel` (otherwise that model's
    /// default applies). The
    /// `ThinkingLevel → reasoning_effort` string mapping lives on `ThinkingLevel.openAIReasoningEffort`.
    static func openAI(model: LLMModel, apiKey: String, thinkingLevel: ThinkingLevel? = nil) -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            baseURL: openAIBaseURL,
            apiKey: apiKey,
            modelID: model.id,
            maxTokensParam: model.supportsThinking ? "max_completion_tokens" : "max_tokens",
            reasoningEffort: model.supportsThinking ? thinkingLevel?.openAIReasoningEffort : nil
        )
    }
}

// MARK: - OpenRouter provider (W41.app-openrouter)

extension OpenAICompatibleClient {
    static let openRouterBaseURL = "https://openrouter.ai/api/v1"
    /// Tokens added to max_tokens for a model that reasons: GLM-5.3 Flash averaged 153 at minimal (cheap-models.md).
    static let openRouterReasoningAllowance = 1024

    /// A client for one of `OpenRouterRoute.catalog`'s models, or for a model the listing offers or the user typed
    /// (unpinned, W41.app-openrouter-unmeasured); nil for any other id, which is never called.
    /// `thinkingLevel`: a maker's thinking model reads at the user's High, as its direct client does
    /// (W41.app-openrouter-any); at Low (Process Files' default) or none, at the effort the bench sent, which is low or
    /// below, so the measured figure is the setting sent. An open model keeps the bench's. An unpinned model that
    /// reasons reads at the user's level, and with none sends no reasoning field (the model's default).
    static func openRouter(model: LLMModel, apiKey: String, thinkingLevel: ThinkingLevel? = nil) -> OpenAICompatibleClient? {
        guard var route = OpenRouterRoute.route(for: model) else { return nil }
        if route.maker != nil, route.model.supportsThinking, thinkingLevel == .high {
            route = route.with(reasoning: .effort(ThinkingLevel.high.openAIReasoningEffort))
        }
        if !route.pinned, route.model.supportsThinking, let thinkingLevel {
            route = route.with(reasoning: .effort(thinkingLevel.openAIReasoningEffort))
        }
        return OpenAICompatibleClient(baseURL: openRouterBaseURL, apiKey: apiKey, modelID: route.model.id,
                                      openRouterRoute: route)
    }

    /// W41.app-openrouter-any — a maker's refusal as OpenRouter passes it on, read as the direct client reads it, so
    /// the page goes to its second reader (`OCRRefusalFallback`, Gemini's) or fails, and is never retried as a
    /// transport failure or kept as a transcription: Gemini's own finish reason (`native_finish_reason`) RECITATION,
    /// or a provider error whose text names it (`ocr_pages_export.py` REFUSED), is `Recitation`; a `content_filter`
    /// finish is its native reason (SAFETY, PROHIBITED_CONTENT…) or `content_filter`; Gemini's other non-STOP reason
    /// with no text is that reason (`GeminiClient`). nil for an open model's route and for every other reply.
    func makerRefusal(finish: String?, native: String?, content: String?, errorText: String?) -> OCRResult? {
        guard let maker = openRouterRoute?.maker else { return nil }
        let gemini = maker.provider == .gemini
        if gemini, native == "RECITATION" || errorText?.contains("RECITATION") == true {
            return OCRResult(text: nil, classification: nil,
                             errorMessage: "Gemini refused to OCR this content (Recitation — likely copyrighted material).",
                             errorCode: "Recitation")
        }
        let name = gemini ? "Gemini" : maker.provider.rawValue
        if finish == "content_filter" {
            let code = native.flatMap { $0.isEmpty || $0 == "STOP" ? nil : $0 } ?? "content_filter"
            return OCRResult(text: nil, classification: nil, errorMessage: "\(name) refused this page (\(code)).",
                             errorCode: code)
        }
        let empty = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if gemini, finish != nil || content != nil, empty, let native, !native.isEmpty,
           !["STOP", "MAX_TOKENS"].contains(native) {
            return OCRResult(text: nil, classification: nil, errorMessage: "Gemini returned no text (\(native)).",
                             errorCode: native)
        }
        return nil
    }

    /// A provider's error text in an OpenRouter body: the error's message and the upstream's raw reply, top level or
    /// on the choice.
    static func providerErrorText(_ json: [String: Any]) -> String? {
        let choice = (json["choices"] as? [[String: Any]])?.first
        let errors = [json["error"], choice?["error"]].compactMap { $0 as? [String: Any] }
        let text = errors.flatMap { e in
            [e["message"] as? String, (e["metadata"] as? [String: Any])?["raw"] as? String].compactMap { $0 }
        }
        return text.isEmpty ? nil : text.joined(separator: " ")
    }

    /// OpenRouter's in-body error codes: a provider failure or timeout (502, 503, 408) reads as 503, the code the
    /// pipeline retries (`isRetryableError`); anything else (429, 402, 401…) is kept as sent.
    static func openRouterRetryCode(_ code: String?) -> String? {
        ["502", "503", "408"].contains(code ?? "") ? "503" : code
    }

    /// `openRouter(model:apiKey:)`, throwing for a model with no pinned route (a stale saved selection).
    static func pinnedOpenRouter(model: LLMModel, apiKey: String,
                                 thinkingLevel: ThinkingLevel? = nil) throws -> OpenAICompatibleClient {
        guard let client = openRouter(model: model, apiKey: apiKey, thinkingLevel: thinkingLevel) else {
            throw OCRError.networkError("\(model.id) is not one of the OpenRouter models this app offers. Choose one of the listed OpenRouter models.")
        }
        return client
    }

    /// The bench's request fields (`ocr_panel.py` `body`, `method_openrouter.py` `request_body`): the provider
    /// pinned with fallbacks off, its precision, a price ceiling at the pinned price (so a provider that raised its
    /// price fails the call instead of billing more than the estimate), temperature 0 and the reasoning setting.
    func applyOpenRouterRoute(_ body: inout [String: Any]) {
        guard let route = openRouterRoute else { return }
        body["provider"] = Self.openRouterProviderField(route)
        // OpenAI's and Anthropic's endpoints take no temperature (`ocr_cloud.py` drops it there: their listing does not
        // advertise it, and `require_parameters` would refuse the endpoint); nor, unpinned, an OpenAI model's.
        let noTemperature = [LLMProvider.openai, .anthropic].contains(route.maker?.provider)
            || (!route.pinned && route.model.id.hasPrefix("openai/"))
        if !noTemperature { body["temperature"] = 0 }
        if let reasoning = route.reasoning.body { body["reasoning"] = reasoning }
        // Excluded reasoning still counts against max_tokens: give a reasoning model room above the answer's
        // budget, or a short call (classification asks for 64) can come back empty. A maker's page read keeps the
        // bench's 8,192 with reasoning in it (`ocr_panel.py`); its short calls get the room too, and the user's High
        // gets the direct clients' high budget on top (`ThinkingLevel.budgetTokens`).
        guard case .effort(let effort) = route.reasoning, let limit = body["max_tokens"] as? Int else { return }
        // An unpinned model gets the open models' room at Low and the makers' High budget at High.
        if effort == ThinkingLevel.high.openAIReasoningEffort, route.maker != nil || !route.pinned, limit >= 8192 {
            body["max_tokens"] = limit + ThinkingLevel.high.budgetTokens(for: .documentOCR)
        } else if route.maker == nil || limit < 8192 {
            body["max_tokens"] = limit + Self.openRouterReasoningAllowance
        }
    }

    /// W46.training-optout-run: while a run whose collection says its pages must not train is going, every request
    /// also carries `data_collection: "deny"`, so OpenRouter refuses an upstream that may keep or train on them; with
    /// the provider pinned and fallbacks off, such a call fails instead of reading.
    static func openRouterProviderField(_ route: OpenRouterRoute,
                                        denyDataCollection: Bool = OpenRouterDataPolicy.denies) -> [String: Any] {
        // W41.app-openrouter-unmeasured: no provider pinned, so OpenRouter chooses and may fall back; it is always told
        // not to use an upstream that may keep or train on the pages, and never to bill above the estimate's price.
        guard route.pinned else {
            var field: [String: Any] = ["data_collection": "deny"]
            if !OpenRouterRoute.isUnpriced(route.model) {
                field["max_price"] = ["prompt": route.model.inputCostPer1M, "completion": route.model.outputCostPer1M]
            }
            return field
        }
        var field: [String: Any] = [
            "order": [route.providerTag],
            "allow_fallbacks": false,
            "max_price": ["prompt": route.model.inputCostPer1M, "completion": route.model.outputCostPer1M]]
        if route.maker == nil {
            field["quantizations"] = [route.precision]
        } else {
            // A maker serves its own weights (no precision to pin), and an endpoint that would drop the reasoning
            // setting is refused rather than read with another (`ocr_cloud.py`).
            field["require_parameters"] = true
        }
        if denyDataCollection { field["data_collection"] = "deny" }
        return field
    }
}

/// W46.training-optout-run: which running jobs need OpenRouter to refuse upstreams that may train. Each job (a Process
/// Files run, a Live Capture session, an Improve OCR job) holds its own entry under its own token, so one job ending
/// never lifts another's. The clients are built deep in the pipeline, some on detached tasks, so the switch is read
/// here when a request is made rather than passed down. A job that never clears its entry only keeps the stricter
/// setting.
enum OpenRouterDataPolicy {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var holders: Set<String> = []

    /// Whether any running job's collection says its pages must not train.
    static var denies: Bool {
        lock.lock(); defer { lock.unlock() }
        return !holders.isEmpty
    }

    /// Set (or clear) `token`'s need.
    static func set(_ deny: Bool, for token: String) {
        lock.lock(); defer { lock.unlock() }
        if deny { holders.insert(token) } else { holders.remove(token) }
    }

    /// The switch as a frozen settings snapshot holds it.
    static func deny(_ values: [String: ResolvedSetting]?) -> Bool {
        values?[SettingsKey.noTraining.rawValue]?.value.bool ?? false
    }
}
