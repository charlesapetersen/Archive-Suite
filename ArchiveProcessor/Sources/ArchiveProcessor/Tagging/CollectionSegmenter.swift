import Foundation

// MARK: - Collection Segment

struct CollectionSegment {
    let collectionName: String
    /// Source image URLs belonging to this collection, in order
    var fileURLs: [URL]
}

// MARK: - Collection Segmenter

@MainActor
class CollectionSegmenter {

    /// Segment files into collections based on box labels.
    ///
    /// 1. Identify box_label images and extract collection names via LLM.
    /// 2. Group consecutive images under the current collection.
    /// 3. Merge segments that share the same collection name (even if non-contiguous).
    func segment(
        files: [URL],
        classifications: [DocumentClassification?],
        texts: [String],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        onStatus: @escaping (String) -> Void
    ) async -> [CollectionSegment] {
        guard !files.isEmpty else { return [] }

        // Step 1: Extract collection names for every box_label image
        var boxNames: [Int: String] = [:]  // index -> raw extracted name
        var boxIndices: [Int] = []

        for i in 0..<files.count {
            let cls = i < classifications.count ? classifications[i] : nil
            if cls == .boxLabel {
                boxIndices.append(i)
            }
        }

        if boxIndices.isEmpty {
            // No boxes found — put everything in a single unnamed collection
            return [CollectionSegment(collectionName: "Uncategorized", fileURLs: files)]
        }

        onStatus("Extracting collection names from \(boxIndices.count) box images…")

        for (attempt, idx) in boxIndices.enumerated() {
            let text = idx < texts.count ? texts[idx] : ""
            let name = await extractCollectionName(
                from: text, provider: provider, model: model,
                thinkingLevel: thinkingLevel, apiKey: apiKey
            )
            boxNames[idx] = name
            onStatus("Identified collection \(attempt + 1)/\(boxIndices.count): \(name)")
        }

        // Step 2: Normalize names — ask LLM to cluster if we have multiple unique names
        let uniqueRawNames = Array(Set(boxNames.values))
        let canonicalMap: [String: String]
        if uniqueRawNames.count > 1 {
            onStatus("Resolving \(uniqueRawNames.count) collection names…")
            canonicalMap = await clusterCollectionNames(
                uniqueRawNames, provider: provider, model: model,
                thinkingLevel: thinkingLevel, apiKey: apiKey
            )
        } else {
            let single = uniqueRawNames.first ?? "Unknown"
            canonicalMap = [single: single]
        }

        // Map each box index to its canonical collection name
        for (idx, rawName) in boxNames {
            boxNames[idx] = canonicalMap[rawName] ?? rawName
        }

        // Step 3: Assign each file to a collection based on preceding box
        // Files before the first box go into the first box's collection
        var assignments: [(url: URL, collection: String)] = []
        var currentCollection = boxNames[boxIndices[0]] ?? "Unknown"

        for i in 0..<files.count {
            if let name = boxNames[i] {
                currentCollection = name
            }
            assignments.append((url: files[i], collection: currentCollection))
        }

        // Step 4: Merge into CollectionSegments, preserving file order within each collection
        var collectionOrder: [String] = []
        var collectionFiles: [String: [URL]] = [:]

        for assignment in assignments {
            if collectionFiles[assignment.collection] == nil {
                collectionOrder.append(assignment.collection)
                collectionFiles[assignment.collection] = []
            }
            collectionFiles[assignment.collection]!.append(assignment.url)
        }

        return collectionOrder.map { name in
            CollectionSegment(collectionName: name, fileURLs: collectionFiles[name] ?? [])
        }
    }

    /// Extract a collection/archive name from the OCR text of a box label image.
    private func extractCollectionName(
        from boxText: String,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async -> String {
        guard !boxText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Unknown"
        }

        let prompt = """
        You are analyzing the OCR text from a photograph of an archival storage box label.
        Extract ONLY the collection or archive name (the name of the person or organization whose papers are in this box).

        Do NOT include:
        - Library names (e.g. "Baker Library", "Hoover Institution")
        - Box numbers (e.g. "Box 104", "Box 5 of 12")
        - Accession numbers
        - Date ranges
        - Call numbers or MSS numbers
        - Words like "Special Collections" or "Archives"

        OCR text from box label:
        ---
        \(boxText.prefix(2000))
        ---

        FORMATTING RULES:
        - Use Title Case (capitalize each major word): "Joel Dean Papers" not "joel dean papers" or "JOEL DEAN PAPERS"
        - Replace ampersands with "and": "Deaver and Hannaford" not "Deaver & Hannaford"
        - Replace all special characters with words (e.g. "/" with "and", "#" with "Number")
        - Keep it clean and readable

        Respond with ONLY the collection name, nothing else. For example: "Joel Dean Papers" or "Deaver and Hannaford" or "Papers of Richard Herrnstein"
        """

        do {
            let response = try await callLLM(prompt: prompt, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
            let raw = response.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = Self.normalizeCollectionName(raw)
            return name.isEmpty ? "Unknown" : name
        } catch {
            return "Unknown"
        }
    }

    /// Given a list of raw extracted collection names, ask the LLM to cluster them
    /// into canonical names (handling variations like case, whitespace, abbreviations).
    private func clusterCollectionNames(
        _ names: [String],
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async -> [String: String] {
        let nameList = names.enumerated().map { "\($0.offset + 1). \"\($0.element)\"" }.joined(separator: "\n")

        let prompt = """
        You have the following collection names extracted from archival box labels. Some may refer to the same collection but with slight variations (different casing, extra whitespace, abbreviations, etc.).

        \(nameList)

        Group these into unique collections. For each group, pick the best canonical name.

        FORMATTING RULES for canonical names:
        - Use Title Case (capitalize each major word)
        - Replace ampersands with "and"
        - Replace all special characters with words
        - Keep names clean and readable

        Respond with ONLY a valid JSON object mapping each input name to its canonical name. Example:
        {
          "Joel Dean Papers": "Joel Dean Papers",
          "joel dean papers": "Joel Dean Papers",
          "DEAVER & HANNAFORD": "Deaver and Hannaford",
          "Deaver & Hannaford": "Deaver and Hannaford"
        }

        If all names are already unique and distinct collections, map each to itself (with corrected formatting).
        Respond with ONLY the JSON object.
        """

        do {
            let response = try await callLLM(prompt: prompt, provider: provider, model: model, thinkingLevel: thinkingLevel, apiKey: apiKey)
            return parseClusterResponse(response, names: names)
        } catch {
            // Fallback: use trimmed, normalized names
            return fallbackCluster(names)
        }
    }

    private func parseClusterResponse(_ raw: String, names: [String]) -> [String: String] {
        var jsonStr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonStr.hasPrefix("```") {
            let lines = jsonStr.components(separatedBy: .newlines)
            jsonStr = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        if let start = jsonStr.firstIndex(of: "{"), let end = jsonStr.lastIndex(of: "}") {
            jsonStr = String(jsonStr[start...end])
        }

        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return fallbackCluster(names)
        }

        // Ensure every input name has a mapping, and normalize all canonical values
        var result: [String: String] = [:]
        for (key, value) in dict {
            result[key] = Self.normalizeCollectionName(value)
        }
        for name in names where result[name] == nil {
            result[name] = Self.normalizeCollectionName(name)
        }
        return result
    }

    /// Simple fallback clustering: trim whitespace, case-insensitive grouping.
    private func fallbackCluster(_ names: [String]) -> [String: String] {
        var groups: [String: String] = [:]  // lowercased-trimmed -> first normalized occurrence
        var result: [String: String] = [:]

        for name in names {
            let key = Self.normalizeCollectionName(name).lowercased()
            if let canonical = groups[key] {
                result[name] = canonical
            } else {
                let normalized = Self.normalizeCollectionName(name)
                groups[key] = normalized
                result[name] = normalized
            }
        }
        return result
    }

    // MARK: - Name Normalization

    /// Normalize a collection name: title case, replace special characters with words.
    static func normalizeCollectionName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Replace special characters with words
        result = result.replacingOccurrences(of: "&", with: "and")
        result = result.replacingOccurrences(of: "/", with: "and")
        result = result.replacingOccurrences(of: "#", with: "Number ")
        result = result.replacingOccurrences(of: "@", with: "at")

        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Title Case: capitalize first letter of each word, lowercase the rest,
        // but keep short words like "of", "the", "and", "in" lowercase (unless first word)
        let lowercaseWords: Set<String> = ["of", "the", "and", "in", "for", "to", "a", "an", "on", "at", "by"]
        let words = result.components(separatedBy: " ")
        let titleCased = words.enumerated().map { (index, word) -> String in
            guard !word.isEmpty else { return word }
            let lower = word.lowercased()
            if index > 0 && lowercaseWords.contains(lower) {
                return lower
            }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        result = titleCased.joined(separator: " ")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Organize Output

    /// Create collection folders and move/rename output PDFs and JSONs into them.
    /// PDFs are renamed with sequential numbering: "00001 Collection Name.pdf"
    /// JSON files are similarly renamed: "00001 Collection Name.json"
    func organizeOutput(
        collections: [CollectionSegment],
        outputDirectory: URL,
        outputURLMap: [URL: URL]
    ) throws {
        let fm = FileManager.default

        for collection in collections {
            // Create collection folder
            let folderURL = outputDirectory.appendingPathComponent(collection.collectionName)
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

            // Move/rename PDFs and JSONs
            for (seqIndex, sourceURL) in collection.fileURLs.enumerated() {
                let seqNum = String(format: "%05d", seqIndex + 1)
                let newBaseName = "\(seqNum) \(collection.collectionName)"

                // Move output PDF
                if let pdfURL = outputURLMap[sourceURL], fm.fileExists(atPath: pdfURL.path) {
                    let destPDF = folderURL.appendingPathComponent(newBaseName + ".pdf")
                    if fm.fileExists(atPath: destPDF.path) {
                        try fm.removeItem(at: destPDF)
                    }
                    try fm.moveItem(at: pdfURL, to: destPDF)

                    // Also check for a matching JSON file (same base name as original PDF)
                    let jsonName = pdfURL.deletingPathExtension().lastPathComponent + ".json"
                    let jsonURL = outputDirectory.appendingPathComponent(jsonName)
                    if fm.fileExists(atPath: jsonURL.path) {
                        let jsonFolder = folderURL.appendingPathComponent("JSON Output")
                        try fm.createDirectory(at: jsonFolder, withIntermediateDirectories: true)
                        let destJSON = jsonFolder.appendingPathComponent(newBaseName + ".json")
                        if fm.fileExists(atPath: destJSON.path) {
                            try fm.removeItem(at: destJSON)
                        }
                        try fm.moveItem(at: jsonURL, to: destJSON)
                    }
                }
            }
        }
    }

    // MARK: - LLM Calls

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
            return try await callMistralChat(prompt: prompt, apiKey: apiKey)
        }
    }

    private func callAnthropic(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 256,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let thinking = thinkingLevel {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinking == .low ? 1024 : 4000]
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
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

    private func callGemini(prompt: String, model: LLMModel, thinkingLevel: ThinkingLevel?, apiKey: String) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.id):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw OCRError.networkError("Bad URL") }
        var body: [String: Any] = ["contents": [["parts": [["text": prompt]]]]]
        if let thinking = thinkingLevel {
            body["generationConfig"] = ["thinkingConfig": ["thinkingBudget": thinking == .low ? 1024 : 4000]]
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
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

    private func callMistralChat(prompt: String, apiKey: String) async throws -> String {
        let endpoint = URL(string: "https://api.mistral.ai/v1/chat/completions")!
        let body: [String: Any] = [
            "model": "mistral-small-latest",
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 256
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
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
