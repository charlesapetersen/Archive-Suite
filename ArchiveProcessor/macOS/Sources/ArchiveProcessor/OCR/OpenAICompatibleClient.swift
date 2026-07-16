import Foundation
import AppKit

struct OpenAICompatibleClient {
    let baseURL: String
    let apiKey: String
    let modelID: String

    /// Token-limit parameter name. OpenAI **reasoning** models (o-series / GPT-5 family) require
    /// `max_completion_tokens` and reject the legacy `max_tokens`; every other model — and every
    /// OpenAI-compatible gateway — still takes `max_tokens`. Defaults to `max_tokens`, so the existing
    /// gateway callers build a byte-identical request. // VERIFY families when finalizing the OpenAI list.
    var maxTokensParam: String = "max_tokens"
    /// Optional OpenAI `reasoning_effort` ("low"/"medium"/"high"), sent only when non-nil (reasoning
    /// models only). Set by the `openAI(model:apiKey:thinkingLevel:)` factory from the caller's
    /// `ThinkingLevel` (see `ThinkingLevel.openAIReasoningEffort`); left nil for gateway callers.
    var reasoningEffort: String? = nil

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
        body[maxTokensParam] = 8192
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }

        let (data, response) = try await sendRequest(body: body, timeoutInterval: 120)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorMessage = Self.parseErrorResponse(data: data, statusCode: http.statusCode)
            return OCRResult(text: nil, classification: nil, errorMessage: errorMessage, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return OCRResult(text: nil, classification: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(content)
        return OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil)
    }

    func textCompletion(prompt: String, maxTokens: Int = 512) async throws -> String {
        var body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]]
        ]
        body[maxTokensParam] = maxTokens
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }

        let (data, _) = try await sendRequest(body: body, timeoutInterval: 120)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OCRError.networkError("bad response")
        }

        return content
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
        return try await NetworkSession.data(for: request)
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
    /// (OpenAI plan, Design decision 3): OpenAI **reasoning** models (o-series / GPT-5 family) require
    /// `max_completion_tokens` instead of `max_tokens` (and reject `temperature`, which this client never
    /// sends). Keyed off `model.supportsThinking`, which the built-in `openaiModels` list sets `true`
    /// only for those reasoning families.
    ///
    /// `reasoning_effort` (W13.oai-2) is likewise gated on `supportsThinking`: it is sent ONLY for
    /// reasoning models — non-reasoning models (gpt-4o etc.) reject the parameter — and only when the
    /// caller passes a `thinkingLevel` (otherwise OpenAI's own "medium" default applies). The
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
