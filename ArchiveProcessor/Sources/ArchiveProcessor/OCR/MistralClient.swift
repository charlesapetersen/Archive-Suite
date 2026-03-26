import Foundation
import AppKit

struct MistralClient {
    let apiKey: String
    let model: LLMModel

    private let endpoint = URL(string: "https://api.mistral.ai/v1/ocr")!

    /// Mistral OCR uses a dedicated endpoint that only returns text.
    /// Classification is done via text heuristics since the OCR endpoint doesn't support custom prompts.
    func ocr(imageURL: URL, previousText: String? = nil) async throws -> OCRResult {
        guard let jpegData = GeminiClient.loadImageAsJPEG(url: imageURL) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()
        let dataURI = "data:image/jpeg;base64,\(base64)"

        let body: [String: Any] = [
            "model": model.id,
            "document": [
                "type": "image_url",
                "image_url": dataURI
            ]
        ]

        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorMessage = Self.parseErrorResponse(data: data, statusCode: http.statusCode)
            return OCRResult(text: nil, classification: nil, errorMessage: errorMessage, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OCRResult(text: nil, classification: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        var ocrText: String? = nil
        if let pages = json["pages"] as? [[String: Any]] {
            let text = pages.compactMap { $0["markdown"] as? String }.joined(separator: "\n\n")
            ocrText = text.isEmpty ? nil : text
        } else if let text = json["text"] as? String {
            ocrText = text.isEmpty ? nil : text
        }

        // Mistral doesn't support classification in its OCR endpoint,
        // so we use text heuristics as a fallback
        let classification = heuristicClassify(text: ocrText, previousText: previousText)
        return OCRResult(text: ocrText, classification: classification, errorMessage: nil, errorCode: nil)
    }

    /// Simple heuristic classification for Mistral (since we can't add it to the prompt)
    private func heuristicClassify(text: String?, previousText: String?) -> DocumentClassification {
        guard let text = text else { return .documentStart }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Box detection
        if trimmed.count < 300 {
            let boxKeywords = ["box no", "box \\d", "accession", "record group", "rg \\d", "archives"]
            if boxKeywords.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
                return .boxLabel
            }
        }

        // Folder detection
        if trimmed.count < 200 {
            if trimmed.range(of: "^\\d{1,4}[\\-–]\\d{1,4}", options: .regularExpression) != nil {
                return .folderLabel
            }
            let folderKeywords = ["folder \\d", "series \\d", "file \\d"]
            if folderKeywords.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
                return .folderLabel
            }
        }

        // Continuation detection
        let continuationPhrases = ["continued from", "from page", "cont'd", "(continued)"]
        if continuationPhrases.contains(where: { lower.contains($0) }) {
            return .documentContinuation
        }
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let firstLine = lines.first {
            let firstWord = firstLine.prefix(while: { $0.isLetter })
            if firstWord.count > 1 && firstWord.first?.isLowercase == true {
                return .documentContinuation
            }
        }
        if let prev = previousText?.trimmingCharacters(in: .whitespacesAndNewlines),
           prev.count > 50,
           let lastChar = prev.last,
           !".!?\"'\u{201D}\u{2019}".contains(lastChar) {
            return .documentContinuation
        }

        return .documentStart
    }

    private static func parseErrorResponse(data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Mistral errors can be {"message": "..."} or {"error": {"message": "..."}}
            let message = (json["message"] as? String)
                ?? (json["error"] as? [String: Any])?["message"] as? String
            if statusCode == 503 || statusCode == 529 {
                return "Model in high use. Try again later."
            }
            if statusCode == 429 {
                return "Rate limit exceeded. Try again later."
            }
            if let message = message {
                return message
            }
        }
        return "API error (\(statusCode))"
    }
}
