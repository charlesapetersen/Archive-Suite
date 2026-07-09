import Foundation

struct GeneratedTags: Codable {
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

    /// Capitalize only the first letter of each word, preserving the rest (unlike .capitalized which lowercases non-initial letters).
    static func capitalizeFirstLetters(_ string: String) -> String {
        string.split(separator: " ", omittingEmptySubsequences: false).map { word in
            guard let first = word.first else { return String(word) }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    var allTags: [String] {
        var tags: [String] = []
        if ocrFailed {
            tags.append("OCR Failed")
            if let c = colorTag { tags.append(c) }
            return tags
        }
        if let y = year { tags.append(y) }
        if let m = month { tags.append(Self.capitalizeFirstLetters(m)) }
        if let d = day { tags.append(d) }
        if dateUncertain { tags.append("Date Uncertain") }
        tags.append(contentsOf: subjectTags.map { Self.capitalizeFirstLetters($0) })
        if let c = colorTag { tags.append(c) }
        return tags
    }

    /// Machine-readable date string (ISO 8601 partial), e.g. "1987-03-15", "1987-03", "1987"
    var machineDate: String? {
        guard let y = year else { return nil }
        var date = y
        if let m = month, let monthNum = Self.monthNumber(from: m) {
            date += String(format: "-%02d", monthNum)
            if let d = day, let dayNum = Self.dayNumber(from: d) {
                date += String(format: "-%02d", dayNum)
            }
        }
        return date
    }

    /// Parse a month from the "MM Month" tag form ("03 March"), a bare number, or a bare name — so
    /// the JSON `date` doesn't silently drop a month the user typed as "March" instead of "03 March".
    static func monthNumber(from s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(trimmed.prefix(2)), (1...12).contains(n) { return n }
        if let n = Int(trimmed), (1...12).contains(n) { return n }
        let lower = trimmed.lowercased()
        let names = ["january", "february", "march", "april", "may", "june",
                     "july", "august", "september", "october", "november", "december"]
        if let idx = names.firstIndex(where: { lower.contains($0) }) { return idx + 1 }
        return nil
    }

    /// Canonical English month names — the single source for building "MM MonthName" date tags.
    static let englishMonthNames = ["January", "February", "March", "April", "May", "June",
                                    "July", "August", "September", "October", "November", "December"]

    /// Build a "MM MonthName" month tag (e.g. "03 March") for a 1...12 month; nil for an out-of-range month.
    static func monthTag(_ month: Int) -> String? {
        guard (1...12).contains(month) else { return nil }
        return String(format: "%02d %@", month, englishMonthNames[month - 1])
    }

    /// Parse a day-of-month from "Day 15", "day 15", or "15".
    static func dayNumber(from s: String) -> Int? {
        let digits = s.filter { $0.isNumber }
        guard let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }

    /// Coerce a JSON value to a trimmed non-empty String — LLMs often return year/month/day as a
    /// JSON *number* (`"year": 1987`), which `as? String` would drop, spuriously forcing a no-date.
    static func stringField(_ value: Any?) -> String? {
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        if let i = value as? Int { return String(i) }
        if let d = value as? Double { return String(Int(d)) }
        return nil
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
        apiKey: String,
        vocabulary: [String] = [],
        gatewayConfig: GatewayConfig? = nil
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
        - "format": document type, e.g. "letter", "memo", "newspaper article", "magazine article", "report", "draft", "speech", "press release", "telegram", "photograph", or null if unclear
        - "author_name": author, sender, or writer name if identifiable, or null
        - "recipient_name": recipient or addressee name if identifiable, or null
        - "author_location": author's or sender's location if identifiable, or null
        - "recipient_location": recipient's location if identifiable, or null
        - "publication_name": newspaper, magazine, or publication name if applicable, or null
        - Respond with ONLY the JSON object. No commentary.
        """

        do {
            let rawResponse = try await callLLM(prompt: prompt, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey, gatewayConfig: gatewayConfig)
            return parseTagResponse(rawResponse)
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
        gatewayConfig: GatewayConfig? = nil
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
            let raw = try await callLLM(prompt: prompt, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey, gatewayConfig: gatewayConfig)
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
        gatewayConfig: GatewayConfig? = nil
    ) async throws -> String {
        try await LLMTextClient.complete(prompt: prompt, provider: provider, model: model,
                                         thinkingLevel: thinkingLevel, apiKey: apiKey,
                                         gatewayConfig: gatewayConfig, maxTokens: 512, timeout: 120)
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
        // Enforce the 2–6 subject-tag contract's upper bound (models sometimes return many more).
        tags.subjectTags = Array((json["subject_tags"] as? [String] ?? []).prefix(6))
        tags.format = json["format"] as? String
        tags.authorName = json["author_name"] as? String
        tags.recipientName = json["recipient_name"] as? String
        tags.authorLocation = json["author_location"] as? String
        tags.recipientLocation = json["recipient_location"] as? String
        tags.publicationName = json["publication_name"] as? String
        return tags
    }
}
