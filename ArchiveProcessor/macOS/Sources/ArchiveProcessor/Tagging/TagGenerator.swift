import Foundation
import ArchiveCore

@MainActor
class TagGenerator: ObservableObject {

    func generateTags(
        for segment: DocumentSegment,
        nearbySegments: [DocumentSegment],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        vocabulary: [String] = [],
        gatewayConfig: GatewayConfig? = nil,
        localAgent: LocalAgentConfig? = nil
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
        - "year": 4-digit year string. ALWAYS provide a year — if not stated in the document, estimate from nearby documents or contextual clues. Never return null for year.
        - "month": format "MM MonthName" (e.g. "03 March"). Provide ONLY if the month is explicitly stated in THIS document. NEVER infer or estimate the month from context or nearby documents. Return null otherwise.
        - "day": format "Day D" (e.g. "Day 15", "Day 3"), or null if not determinable
        - "date_uncertain": true if year cannot be determined from the document itself (even if estimated from context)
        - "subject_tags": \(vocabulary.isEmpty ? "2–6 general-but-specific subject tags (e.g. \"Democratic Party\", \"taxes\", \"education\", \"transportation\", \"business\", \"literature\", \"economics\", \"foreign policy\", \"civil rights\", \"military\", \"journalism\", \"science\", \"health care\", \"labor unions\"). Do NOT use overly broad terms like \"politics\" or \"history\"." : "2–6 tags chosen ONLY from this controlled vocabulary: [\(vocabulary.map { "\"\($0)\"" }.joined(separator: ", "))]. Use only tags from this list that are relevant to the document. Do not invent new tags.")
        - Never emit "OCR Poor": it is a person's assessment, not a subject inferred by the model.
        - "format": document type, e.g. "letter", "memo", "newspaper article", "magazine article", "report", "draft", "speech", "press release", "telegram", "photograph", or null if unclear
        - "author_name": the person who wrote, signed or sent the document (a signature, a typed name under the closing, a "From:" line, a byline), or null. Always a person: if no person is named as its writer, null, never the organisation on the letterhead
        - "recipient_name": everyone it is addressed to, a person or a body such as a committee or "All Employees" (the inside address, a "To:" line, the salutation), names separated by "; " (e.g. "Jane Doe; John Smith"), or null. Copies ("cc") are not recipients
        - "author_location": where it was written or sent from (the letterhead's or the dateline's city), as "City, State" with the state written out (e.g. "Chicago, Illinois") or "City, Country", or null. Only a place the document writes (a dateline, a letterhead or an address): null when it writes none, never a place inferred from an institution's name, the collection or the nearby documents
        - "recipient_location": recipient's location if identifiable, or null
        - "publication_name": newspaper, magazine, or publication name if applicable, or null
        - Respond with ONLY the JSON object. No commentary.
        """

        do {
            let rawResponse = try await callLLM(prompt: prompt, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey, gatewayConfig: gatewayConfig, localAgent: localAgent)
            return parseTagResponse(rawResponse, vocabulary: vocabulary)
        } catch {
            return GeneratedTags(dateUncertain: true)
        }
    }

    /// Extract ONLY the date for a segment (used by the auto-date manual tagging mode).
    /// Cheaper than `generateTags` — no subject/format/party fields.
    func generateDateOnly(
        for segment: DocumentSegment,
        nearbySegments: [DocumentSegment],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        gatewayConfig: GatewayConfig? = nil,
        localAgent: LocalAgentConfig? = nil
    ) async -> GeneratedTags {
        if segment.isBox || segment.isFolder { return GeneratedTags() }
        let text = segment.combinedText
        guard !text.isEmpty else { return GeneratedTags(dateUncertain: true) }

        let contextText = nearbySegments
            .prefix(3)
            .map { $0.combinedText.prefix(300) }
            .joined(separator: "\n---\n")

        let prompt = """
        You are a date-extraction assistant for a historical archive.

        OCR text of a document:
        ---
        \(text.prefix(3000))
        ---

        Nearby documents for date-estimation context (use only if this document's date is unclear):
        ---
        \(contextText.isEmpty ? "(none)" : contextText)
        ---

        Respond with ONLY a valid JSON object in this exact format:
        { "year": "1987", "month": "03 March", "day": "Day 15", "date_uncertain": false }

        Rules:
        - "year": 4-digit year string. ALWAYS provide a year — if not stated, estimate from nearby documents or contextual clues. Never null.
        - "month": format "MM MonthName" (e.g. "03 March"). Provide ONLY if the month is explicitly stated in THIS document. NEVER infer or estimate the month from context or nearby documents. Return null otherwise.
        - "day": format "Day D" (e.g. "Day 15"), or null if not determinable
        - "date_uncertain": true if the year cannot be determined from the document itself (even if estimated from context)
        - Respond with ONLY the JSON object. No commentary.
        """

        do {
            let raw = try await callLLM(prompt: prompt, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey, gatewayConfig: gatewayConfig, localAgent: localAgent)
            return parseTagResponse(raw)
        } catch {
            return GeneratedTags(dateUncertain: true)
        }
    }

    // Tagging uses maxTokens 512 / timeout 120 s (see LLMTextClient — the shared request path).
    private func callLLM(
        prompt: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        gatewayConfig: GatewayConfig? = nil,
        localAgent: LocalAgentConfig? = nil
    ) async throws -> String {
        try await LLMTextClient.complete(prompt: prompt, provider: provider, model: model,
                                         thinkingLevel: thinkingLevel, apiKey: apiKey,
                                         gatewayConfig: gatewayConfig, localAgent: localAgent, maxTokens: 512, timeout: 120)
    }

    private func parseTagResponse(_ raw: String, vocabulary: [String] = []) -> GeneratedTags {
        // Extract JSON from the response (model may wrap in markdown code fences)
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonStr.hasPrefix("```") {
            let lines = jsonStr.components(separatedBy: .newlines)
            jsonStr = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        // Find JSON object
        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}"), start <= end {
            jsonStr = String(jsonStr[start...end])
        }

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return GeneratedTags(dateUncertain: true)
        }

        var tags = GeneratedTags()
        // Coerce year/month/day: models frequently return these as JSON numbers, not strings.
        // Normalize bare-number months/days to SPEC format ("MM Month" / "Day N").
        tags.year = GeneratedTags.stringField(json["year"])
        if let rawMonth = GeneratedTags.stringField(json["month"]) {
            if let n = GeneratedTags.monthNumber(from: rawMonth), GeneratedTags.monthTag(n) != nil {
                // Already SPEC-conforming ("03 March") or a bare number/name → normalize
                tags.month = GeneratedTags.monthTag(n)
            } else {
                tags.month = rawMonth
            }
        }
        if let rawDay = GeneratedTags.stringField(json["day"]) {
            if let n = GeneratedTags.dayNumber(from: rawDay) {
                tags.day = "Day \(n)"
            } else {
                tags.day = rawDay
            }
        }
        tags.dateUncertain = json["date_uncertain"] as? Bool ?? false
        // Enforce both the upper bound and, when configured, the controlled vocabulary. The prompt is
        // advisory; models can still invent values or alter case/spacing, so canonicalize at this boundary.
        // W44.reocr-spec: Poor OCR is a person's flag, even if a configured vocabulary includes it.
        // Filter before the cap so it cannot displace a legitimate subject, and again after canonicalization.
        func isPoorFlag(_ value: String) -> Bool {
            isSameTag(value.trimmingCharacters(in: .whitespacesAndNewlines), DocumentTags.poorOCRTag)
        }
        tags.subjectTags = ControlledVocabulary.enforce(
            (json["subject_tags"] as? [String] ?? []).filter { !isPoorFlag($0) }, vocabulary: vocabulary)
            .filter { !isPoorFlag($0) }
        // Malformed date strings are also model-controlled tag positions; none can smuggle in the flag.
        if let year = tags.year, isPoorFlag(year) { tags.year = nil }
        if let month = tags.month, isPoorFlag(month) { tags.month = nil }
        if let day = tags.day, isPoorFlag(day) { tags.day = nil }
        tags.format = json["format"] as? String
        tags.authorName = Self.names(json["author_name"])
        tags.recipientName = Self.names(json["recipient_name"])
        tags.authorLocation = json["author_location"] as? String
        tags.recipientLocation = json["recipient_location"] as? String
        tags.publicationName = json["publication_name"] as? String
        return tags
    }

    /// A name field as the one string the sidecar keeps. The prompt asks for several addressees joined by "; ",
    /// but a model may answer with a JSON array instead; join that the same way rather than drop it.
    private static func names(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        guard let list = value as? [Any] else { return nil }
        let parts = list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
