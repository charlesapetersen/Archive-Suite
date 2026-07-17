import Foundation

/// Shared single-shot text-completion client for the tagging + collection-segmentation LLM calls.
///
/// Extracted verbatim from the (byte-for-byte) duplicated `callLLM`/`callGateway`/`callAnthropic`/
/// `callGemini`/`callMistralChat` paths in `TagGenerator` and `CollectionSegmenter`, which differed
/// only by the request `maxTokens` (512 vs 256) and `timeout` (120 s vs 60 s). Each caller passes its
/// own original values, so the requests this issues are identical to the pre-refactor ones.
enum LLMTextClient {
    static func complete(
        prompt: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        gatewayConfig: GatewayConfig?,
        localAgent: LocalAgentConfig? = nil,
        maxTokens: Int,
        timeout: TimeInterval
    ) async throws -> String {
        // Backend precedence (mirrors the OCR seam + classifyViaLLM): the Local Agent CLI wins, then the
        // gateway, then the direct provider path. Settings makes useLocalAgent/useGateway mutually
        // exclusive, so at most one is non-nil; the explicit order is defensive.
        if let localAgent {
            return try await LocalAgentClient(config: localAgent).textCompletion(prompt: prompt, maxTokens: maxTokens)
        }
        if let gateway = gatewayConfig {
            let client = OpenAICompatibleClient(baseURL: gateway.baseURL, apiKey: gateway.apiKey, modelID: gateway.modelID)
            return try await client.textCompletion(prompt: prompt, maxTokens: maxTokens)
        }
        switch provider {
        case .anthropic:
            return try await callAnthropic(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey, maxTokens: maxTokens, timeout: timeout)
        case .gemini:
            return try await callGemini(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey, timeout: timeout)
        case .mistral:
            return try await callMistralChat(prompt: prompt, apiKey: apiKey, maxTokens: maxTokens, timeout: timeout)
        case .openai:
            let client = OpenAICompatibleClient.openAI(model: model, apiKey: apiKey, thinkingLevel: thinkingLevel)
            return try await client.textCompletion(prompt: prompt, maxTokens: maxTokens)
        }
    }

    private static func callAnthropic(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let thinking = thinkingLevel {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinking == .low ? 1024 : 4000]
        }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { throw OCRError.networkError("bad response") }
        return content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    private static func callGemini(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String, timeout: TimeInterval) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.id):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw OCRError.networkError("Bad URL") }
        var body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        if let thinking = thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingBudget": thinking == .low ? 1024 : 4000]]
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw OCRError.networkError("bad response") }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    // The tagging/segmentation model is intentionally fixed to mistral-small-latest (cheaper), so no model param.
    private static func callMistralChat(prompt: String, apiKey: String, maxTokens: Int, timeout: TimeInterval) async throws -> String {
        let endpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "mistral-small-latest",  // Use cheaper model for tagging
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await NetworkSession.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw OCRError.networkError("bad response") }
        return content
    }
}
