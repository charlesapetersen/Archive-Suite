import Foundation

struct GeneratedTags {
    var year: String?             // e.g. "1987"
    var month: String?            // e.g. "03 March"
    var day: String?              // e.g. "Day 15"
    var dateUncertain: Bool = false
    var ocrFailed: Bool = false
    var subjectTags: [String] = []
    var colorTag: String?         // "Red" or "Purple"

    // Extended metadata for JSON export
    var format: String?           // e.g. "letter", "memo", "newspaper article"
    var authorName: String?
    var recipientName: String?
    var authorLocation: String?
    var recipientLocation: String?
    var publicationName: String?

    var allTags: [String] {
        var tags: [String] = []
        if ocrFailed {
            tags.append("OCR Failed")
            if let c = colorTag { tags.append(c) }
            return tags
        }
        if let y = year { tags.append(y) }
        if let m = month { tags.append(m.capitalized) }
        if let d = day { tags.append(d) }
        tags.append(contentsOf: subjectTags.map { $0.capitalized })
        if dateUncertain { tags.append("Date Uncertain") }
        if let c = colorTag { tags.append(c) }
        return tags
    }

    /// Machine-readable date string (ISO 8601 partial), e.g. "1987-03-15", "1987-03", "1987"
    var machineDate: String? {
        guard let y = year else { return nil }
        var date = y
        if let m = month, let monthNum = Int(m.prefix(2)) {
            date += String(format: "-%02d", monthNum)
            if let d = day, let dayNum = Int(d.replacingOccurrences(of: "Day ", with: "")) {
                date += String(format: "-%02d", dayNum)
            }
        }
        return date
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
        if segment.isBox { return GeneratedTags(subjectTags: ["Box"], colorTag: "Red") }
        if segment.isFolder { return GeneratedTags(subjectTags: ["Folder"], colorTag: "Purple") }

        let text = segment.combinedText
        guard !text.isEmpty else { return GeneratedTags(ocrFailed: true) }

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
          "day": "Day 15",
          "date_uncertain": false,
          "subject_tags": ["Democratic Party", "elections", "legislation"],
          "format": "letter",
          "author_name": "John Smith",
          "recipient_name": "Jane Doe",
          "author_location": "Washington, D.C.",
          "recipient_location": "New York, NY",
          "publication_name": null
        }

        Rules:
        - "year": 4-digit year string if determinable, or null if not
        - "month": format "MM MonthName" (e.g. "03 March"), or null if not determinable
        - "day": format "Day D" (e.g. "Day 15", "Day 3"), or null if not determinable
        - "date_uncertain": true if year cannot be determined from the document itself (even if estimated from context)
        - "subject_tags": 2–6 general-but-specific subject tags (e.g. "Democratic Party", "taxes", "education", "transportation", "business", "literature", "economics", "foreign policy", "civil rights", "military", "journalism", "science", "health care", "labor unions"). Do NOT use overly broad terms like "politics" or "history".
        - "format": document type, e.g. "letter", "memo", "newspaper article", "magazine article", "report", "draft", "speech", "press release", "telegram", "photograph", or null if unclear
        - "author_name": author, sender, or writer name if identifiable, or null
        - "recipient_name": recipient or addressee name if identifiable, or null
        - "author_location": author's or sender's location if identifiable, or null
        - "recipient_location": recipient's location if identifiable, or null
        - "publication_name": newspaper, magazine, or publication name if applicable, or null
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
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
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
        var request = URLRequest(url: url, timeoutInterval: 120)
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
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
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
        tags.day = json["day"] as? String
        tags.dateUncertain = json["date_uncertain"] as? Bool ?? false
        tags.subjectTags = json["subject_tags"] as? [String] ?? []
        tags.format = json["format"] as? String
        tags.authorName = json["author_name"] as? String
        tags.recipientName = json["recipient_name"] as? String
        tags.authorLocation = json["author_location"] as? String
        tags.recipientLocation = json["recipient_location"] as? String
        tags.publicationName = json["publication_name"] as? String
        return tags
    }
}
