import Foundation

struct GeneratedTags {
    var year: String?             // e.g. "1987"
    var month: String?            // e.g. "03 March"
    var dateUncertain: Bool = false
    var subjectTags: [String] = []
    var colorTag: String?         // "Red" or "Purple"

    var allTags: [String] {
        var tags: [String] = []
        if let y = year { tags.append(y) }
        if let m = month { tags.append(m) }
        tags.append(contentsOf: subjectTags)
        if dateUncertain { tags.append("Date Uncertain") }
        if let c = colorTag { tags.append(c) }
        return tags
    }
}

@MainActor
class TagGenerator: ObservableObject {

    func generateTags(
        for segment: DocumentSegment,
        nearbySegments: [DocumentSegment],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async -> GeneratedTags {
        // Box/folder: just a color tag
        if segment.isBox { return GeneratedTags(colorTag: "Red") }
        if segment.isFolder { return GeneratedTags(colorTag: "Purple") }

        let text = segment.combinedText
        guard !text.isEmpty else { return GeneratedTags(dateUncertain: true) }

        // Build prompt
        let contextText = nearbySegments
            .prefix(3)
            .map { $0.combinedText.prefix(300) }
            .joined(separator: "\n---\n")

        let prompt = """
        You are a metadata tagging assistant for a historical archive.

        Here is the OCR text of a document:
        ---
        \(text.prefix(3000))
        ---

        Nearby documents for date estimation context (use only if this document's date is unclear):
        ---
        \(contextText.isEmpty ? "(none)" : contextText)
        ---

        Please respond with ONLY a valid JSON object in this exact format:
        {
          "year": "1987",
          "month": "03 March",
          "date_uncertain": false,
          "subject_tags": ["Democratic Party", "elections", "legislation"]
        }

        Rules:
        - "year": 4-digit year string if determinable, or null if not
        - "month": format "MM MonthName" (e.g. "03 March"), or null if not determinable
        - "date_uncertain": true if year cannot be determined from the document itself (even if estimated from context)
        - "subject_tags": 2–6 general-but-specific subject tags (e.g. "Democratic Party", "taxes", "education", "transportation", "business", "literature", "economics", "foreign policy", "civil rights", "military", "journalism", "science", "health care", "labor unions"). Do NOT use overly broad terms like "politics" or "history".
        - If date_uncertain is true, still attempt to estimate year from nearby documents.
        - Respond with ONLY the JSON object. No commentary.
        """

        do {
            let rawResponse = try await callLLM(prompt: prompt, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
            return parseTagResponse(rawResponse)
        } catch {
            return GeneratedTags(dateUncertain: true)
        }
    }

    private func callLLM(
        prompt: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async throws -> String {
        switch provider {
        case .anthropic:
            return try await callAnthropic(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
        case .gemini:
            return try await callGemini(prompt: prompt, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
        case .mistral:
            return try await callMistralChat(prompt: prompt, model: model, apiKey: apiKey)
        }
    }

    private func callAnthropic(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 512,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let thinking = thinkingLevel {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinking == .low ? 1024 : 4000]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { throw OCRError.networkError("bad response") }
        return content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    private func callGemini(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.id):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw OCRError.networkError("Bad URL") }
        var body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        if let thinking = thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingBudget": thinking == .low ? 1024 : 4000]]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { throw OCRError.networkError("bad response") }
        return parts.compactMap { $0["text"] as? String }.joined()
    }

    private func callMistralChat(prompt: String, model: LLMModel, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "mistral-small-latest",  // Use cheaper model for tagging
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 512
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw OCRError.networkError("bad response") }
        return content
    }

    private func parseTagResponse(_ raw: String) -> GeneratedTags {
        // Extract JSON from the response (model may wrap in markdown code fences)
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonStr.hasPrefix("```") {
            let lines = jsonStr.components(separatedBy: .newlines)
            jsonStr = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        // Find JSON object
        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GeneratedTags(dateUncertain: true)
        }

        var tags = GeneratedTags()
        tags.year = json["year"] as? String
        tags.month = json["month"] as? String
        tags.dateUncertain = json["date_uncertain"] as? Bool ?? false
        tags.subjectTags = json["subject_tags"] as? [String] ?? []
        return tags
    }
}
