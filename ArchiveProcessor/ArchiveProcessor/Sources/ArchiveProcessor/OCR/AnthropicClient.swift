import Foundation
import AppKit

struct AnthropicClient {
    let apiKey: String
    let model: LLMModel
    let thinkingLevel: ThinkingLevel?

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func ocr(imageURL: URL, previousText: String? = nil, previousImageURL: URL? = nil, customPrompt: String? = nil, imageScale: Double = 1.0) async throws -> OCRResult {
        guard let jpegData = ImageEncoding.loadImageAsJPEG(url: imageURL, scale: imageScale) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()
        let prompt = OCRPrompt.build(previousText: previousText, previousImageIncluded: previousImageURL != nil, customPrompt: customPrompt)

        var content: [[String: Any]] = []

        // If sending previous image, add it first
        if let prevURL = previousImageURL, let prevData = ImageEncoding.loadImageAsJPEG(url: prevURL, scale: imageScale) {
            content.append(["type": "image", "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": prevData.base64EncodedString()
            ]])
        }

        content.append(["type": "image", "source": [
            "type": "base64",
            "media_type": "image/jpeg",
            "data": base64
        ]])
        content.append(["type": "text", "text": prompt])

        let messages: [[String: Any]] = [["role": "user", "content": content]]

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 8192,
            "messages": messages
        ]

        if let thinking = thinkingLevel {
            let budget = thinking == .low ? 1024 : 8000
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            // Anthropic counts thinking tokens against max_tokens, so the ceiling must exceed
            // the budget or the visible transcription is silently truncated to the remainder.
            // Raise it by the budget to preserve the full output allowance.
            body["max_tokens"] = 8192 + budget
        }

        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if thinkingLevel != nil {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await NetworkSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let err = Self.parseErrorResponse(data: data, statusCode: http.statusCode)
            return OCRResult(text: nil, classification: nil, errorMessage: err.message, errorCode: err.code)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            return OCRResult(text: nil, classification: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        let rawText = contentArray
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(rawText)
        return OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil)
    }

    /// Returns a friendly message plus the provider's semantic error code (Anthropic `error.type`,
    /// e.g. `invalid_request_error`, `request_too_large`), falling back to the HTTP status. Status-code
    /// classification also runs when the body is empty/non-JSON (some gateway 5xx have no JSON body).
    private static func parseErrorResponse(data: Data, statusCode: Int) -> (message: String, code: String) {
        var apiType = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let errorType = error["type"] as? String ?? ""
            apiType = errorType
            let message = error["message"] as? String
            let code = errorType.isEmpty ? "\(statusCode)" : errorType
            if statusCode == 529 || errorType == "overloaded_error" {
                return ("Model in high use. Try again later.", code)
            }
            if statusCode == 429 || errorType == "rate_limit_error" {
                return ("Rate limit exceeded. Try again later.", code)
            }
            if let message = message {
                return (message, code)
            }
        }
        let fallbackCode = apiType.isEmpty ? "\(statusCode)" : apiType
        if statusCode == 529 || statusCode == 503 { return ("Model in high use. Try again later.", fallbackCode) }
        if statusCode == 429 { return ("Rate limit exceeded. Try again later.", fallbackCode) }
        return ("API error (\(statusCode))", "\(statusCode)")
    }
}

enum OCRError: Error, LocalizedError {
    case imageLoadFailed
    case networkError(String)
    case apiError(String, String?)

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed: return "Failed to load or convert image"
        case .networkError(let msg): return "Network error: \(msg)"
        case .apiError(let msg, let code): return "API error [\(code ?? "?")]: \(msg)"
        }
    }
}
