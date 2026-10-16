import Foundation
import AppKit

struct OpenAICompatibleClient {
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
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(base)/chat/completions")
    }

    func ocr(imageURL: URL, previousText: String? = nil, previousImageURL: URL? = nil, customPrompt: String? = nil, imageScale: Double = 1.0) async throws -> OCRResult {
        guard let jpegData = ImageEncoding.loadImageAsJPEG(url: imageURL, scale: imageScale) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()
        let prompt = OCRPrompt.build(previousText: previousText, previousImageIncluded: previousImageURL != nil, customPrompt: customPrompt)

        var contentParts: [[String: Any]] = []

        if let prevURL = previousImageURL, let prevData = ImageEncoding.loadImageAsJPEG(url: prevURL, scale: imageScale) {
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(prevData.base64EncodedString())"]
            ])
        }

        contentParts.append([
            "type": "image_url",
            "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
        ])
        contentParts.append(["type": "text", "text": prompt])

        var body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": contentParts]]
        ]
        body[maxTokensParam] = localModel ? LocalModelRoute.maxTokens : 8192
        if localModel { body["temperature"] = 0 }
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        applyOpenRouterRoute(&body)

        let (data, response) = try await sendRequest(body: body, timeoutInterval: requestTimeout)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorMessage = Self.parseErrorResponse(data: data, statusCode: http.statusCode)
            return OCRResult(text: nil, classification: nil, errorMessage: errorMessage, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let rawContent = message["content"] as? String else {
            // OpenRouter reports a provider's failure as a 200 with an `error` object in the body.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any] {
                let code = (error["code"] as? Int).map(String.init) ?? (error["code"] as? String)
                return OCRResult(text: nil, classification: nil,
                                 errorMessage: (error["message"] as? String) ?? "Provider error",
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

        // OpenRouter reports a provider failure mid-stream as finish_reason "error", and every OpenAI-compatible
        // endpoint reports a reply cut at the token limit as "length": neither is a transcription (W41.app-openrouter
        // review; the cut reply on every route since W41.app-ocr-cascade). The failure is 503, which
        // `isRetryableError` retries; a cut reply is not retried, since the same budget would cut it again.
        let finish = choices.first?["finish_reason"] as? String
        if finish == "length" { return OCRResult.cutOff }
        if openRouterRoute != nil, finish == "error" {
            return OCRResult(text: nil, classification: nil, errorMessage: "The provider failed while answering",
                             errorCode: "503")
        }
        let content = localModel ? LocalModelRoute.strippingReasoning(rawContent) : rawContent
        // A local model that looped but stopped by itself (W41.mac-local-measure) is a failed page like a cut one.
        if localModel, LocalModelRoute.isRepetitionLoop(content) { return LocalModelRoute.loopedReply }
        let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(content)
        return OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil, enclosure: OCRPrompt.parseEnclosureFlag(content))
    }

    func textCompletion(prompt: String, maxTokens: Int = 512) async throws -> String {
        var body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]]
        ]
        body[maxTokensParam] = maxTokens
        if localModel { body["temperature"] = 0 }
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        applyOpenRouterRoute(&body)

        let (data, response) = try await sendRequest(body: body, timeoutInterval: requestTimeout)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            if openRouterRoute != nil {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                throw OCRError.networkError(Self.parseErrorResponse(data: data, statusCode: status))
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

        return localModel ? LocalModelRoute.strippingReasoning(content) : content
    }

    private func sendRequest(body: [String: Any], timeoutInterval: TimeInterval) async throws -> (Data, URLResponse) {
        guard let endpoint = chatEndpoint else {
            throw OCRError.networkError("Invalid gateway URL: \(baseURL)")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await NetworkSession.data(for: request, policy: .nonIdempotent)
    }

    static func parseErrorResponse(data: Data, statusCode: Int) -> String {
        // Status-based classification first, independent of body shape — gateways (vLLM/LiteLLM/Ollama
        // shims, CDNs) often return an empty or non-JSON 5xx/429 body.
        if let msg = transientStatusMessage(statusCode) { return msg }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Handle the several error shapes arbitrary OpenAI-compatible gateways use.
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = json["error"] as? String { return error }
            if let detail = json["detail"] as? String { return detail }
            if let message = json["message"] as? String { return message }
        }
        return "API error (\(statusCode))"
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

    /// A client for one of `OpenRouterRoute.catalog`'s models, or nil for a model the catalog lacks: an unpinned
    /// OpenRouter call would read with weights and at a price the bench never measured, so there is none.
    static func openRouter(model: LLMModel, apiKey: String) -> OpenAICompatibleClient? {
        guard let route = OpenRouterRoute.forModel(model.id) else { return nil }
        return OpenAICompatibleClient(baseURL: openRouterBaseURL, apiKey: apiKey, modelID: route.model.id,
                                      openRouterRoute: route)
    }

    /// OpenRouter's in-body error codes: a provider failure or timeout (502, 503, 408) reads as 503, the code the
    /// pipeline retries (`isRetryableError`); anything else (429, 402, 401…) is kept as sent.
    static func openRouterRetryCode(_ code: String?) -> String? {
        ["502", "503", "408"].contains(code ?? "") ? "503" : code
    }

    /// `openRouter(model:apiKey:)`, throwing for a model with no pinned route (a stale saved selection).
    static func pinnedOpenRouter(model: LLMModel, apiKey: String) throws -> OpenAICompatibleClient {
        guard let client = openRouter(model: model, apiKey: apiKey) else {
            throw OCRError.networkError("\(model.id) has no pinned OpenRouter provider. Choose one of the listed OpenRouter models.")
        }
        return client
    }

    /// The bench's request fields (`ocr_panel.py` `body`, `method_openrouter.py` `request_body`): the provider
    /// pinned with fallbacks off, its precision, a price ceiling at the pinned price (so a provider that raised its
    /// price fails the call instead of billing more than the estimate), temperature 0 and the reasoning setting.
    func applyOpenRouterRoute(_ body: inout [String: Any]) {
        guard let route = openRouterRoute else { return }
        body["provider"] = Self.openRouterProviderField(route)
        body["temperature"] = 0
        if let reasoning = route.reasoning.body { body["reasoning"] = reasoning }
        // Excluded reasoning still counts against max_tokens: give a reasoning model room above the answer's
        // budget, or a short call (classification asks for 64) can come back empty.
        if case .effort = route.reasoning, let limit = body["max_tokens"] as? Int {
            body["max_tokens"] = limit + Self.openRouterReasoningAllowance
        }
    }

    static func openRouterProviderField(_ route: OpenRouterRoute) -> [String: Any] {
        ["order": [route.providerTag],
         "allow_fallbacks": false,
         "quantizations": [route.precision],
         "max_price": ["prompt": route.model.inputCostPer1M, "completion": route.model.outputCostPer1M]]
    }
}
