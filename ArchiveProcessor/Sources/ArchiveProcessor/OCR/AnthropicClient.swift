import Foundation
import AppKit

struct AnthropicClient {
    let apiKey: String
    let model: LLMModel
    let thinkingLevel: ThinkingLevel?

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func ocr(imageURL: URL) async throws -> OCRResult {
        guard let imageData = try? Data(contentsOf: imageURL),
              let nsImage = NSImage(data: imageData),
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()

        var messages: [[String: Any]] = []
        var content: [[String: Any]] = [
            ["type": "image", "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": base64
            ]],
            ["type": "text", "text": "Please transcribe all text visible in this document image exactly as it appears. Preserve the original formatting, line breaks, paragraph structure, and layout as closely as possible. Output only the transcribed text with no commentary."]
        ]
        messages.append(["role": "user", "content": content])

        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": 8192,
            "messages": messages
        ]

        if let thinking = thinkingLevel {
            let budget = thinking == .low ? 1024 : 8000
            body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if thinkingLevel != nil {
            request.setValue("interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            return OCRResult(text: nil, errorMessage: errorBody, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]] else {
            return OCRResult(text: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        // Extract text blocks (skip thinking blocks)
        let text = contentArray
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")

        return OCRResult(text: text.isEmpty ? nil : text, errorMessage: nil, errorCode: nil)
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
