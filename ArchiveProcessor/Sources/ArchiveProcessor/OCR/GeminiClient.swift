import Foundation
import AppKit

struct GeminiClient {
    let apiKey: String
    let model: LLMModel
    let thinkingLevel: ThinkingLevel?

    func ocr(imageURL: URL) async throws -> OCRResult {
        guard let imageData = try? Data(contentsOf: imageURL),
              let nsImage = NSImage(data: imageData),
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()

        var parts: [[String: Any]] = [
            ["inlineData": ["mimeType": "image/jpeg", "data": base64]],
            ["text": "Please transcribe all text visible in this document image exactly as it appears. Preserve the original formatting, line breaks, paragraph structure, and layout as closely as possible. Output only the transcribed text with no commentary."]
        ]

        var generationConfig: [String: Any] = [:]
        if let thinking = thinkingLevel {
            let budget = thinking == .low ? 1024 : 8000
            generationConfig["thinkingConfig"] = ["thinkingBudget": budget]
        }

        var requestBody: [String: Any] = [
            "contents": [["parts": parts]]
        ]
        if !generationConfig.isEmpty {
            requestBody["generationConfig"] = generationConfig
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model.id):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw OCRError.networkError("Bad URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            // Check for recitation error
            if errorBody.lowercased().contains("recitation") {
                return OCRResult(text: nil, errorMessage: "No text returned by model. Gemini refused to OCR this content (Recitation — likely copyrighted material).", errorCode: "Recitation")
            }
            return OCRResult(text: nil, errorMessage: errorBody, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OCRResult(text: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        // Check for prompt feedback / block reason
        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String {
            return OCRResult(text: nil, errorMessage: "Content blocked by Gemini: \(blockReason)", errorCode: blockReason)
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            return OCRResult(text: nil, errorMessage: "No candidates in response", errorCode: nil)
        }

        // Check finish reason
        if let finishReason = first["finishReason"] as? String, finishReason == "RECITATION" {
            return OCRResult(text: nil, errorMessage: "No text returned by model. Gemini refused to OCR this content (Recitation — likely copyrighted material).", errorCode: "Recitation")
        }

        guard let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return OCRResult(text: nil, errorMessage: "No content parts in response", errorCode: nil)
        }

        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return OCRResult(text: text.isEmpty ? nil : text, errorMessage: nil, errorCode: nil)
    }
}
