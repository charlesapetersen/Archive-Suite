import Foundation
import AppKit

struct OpenAICompatibleClient {
    let baseURL: String
    let apiKey: String
    let modelID: String

    private var chatEndpoint: URL {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: "\(base)/chat/completions")!
    }

    func ocr(imageURL: URL, previousText: String? = nil, previousImageURL: URL? = nil, customPrompt: String? = nil, imageScale: Double = 1.0) async throws -> OCRResult {
        guard let jpegData = ImageEncoding.loadImageAsJPEG(url: imageURL, scale: imageScale) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()
        let prompt = OCRPrompt.build(previousText: previousText, previousImageIncluded: previousImageURL != nil, customPrompt: customPrompt)

        var contentParts: [[String: Any]] = []

        if let prevURL = previousImageURL, let prevData = ImageEncoding.loadImageAsJPEG(url: prevURL, scale: imageScale) {
            contentParts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(prevData.base64EncodedString())"]
            ])
        }

        contentParts.append([
            "type": "image_url",
            "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
        ])
        contentParts.append(["type": "text", "text": prompt])

        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": contentParts]],
            "max_tokens": 8192
        ]

        let (data, response) = try await sendRequest(body: body, timeoutInterval: 120)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorMessage = Self.parseErrorResponse(data: data, statusCode: http.statusCode)
            return OCRResult(text: nil, classification: nil, errorMessage: errorMessage, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return OCRResult(text: nil, classification: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(content)
        return OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil)
    }

    func textCompletion(prompt: String, maxTokens: Int = 512) async throws -> String {
        let body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": maxTokens
        ]

        let (data, _) = try await sendRequest(body: body, timeoutInterval: 120)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OCRError.networkError("bad response")
        }

        return content
    }

    private func sendRequest(body: [String: Any], timeoutInterval: TimeInterval) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: chatEndpoint, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await NetworkSession.data(for: request)
    }

    static func parseErrorResponse(data: Data, statusCode: Int) -> String {
        // Status-based classification first, independent of body shape — gateways (vLLM/LiteLLM/Ollama
        // shims, CDNs) often return an empty or non-JSON 5xx/429 body.
        if statusCode == 503 || statusCode == 529 { return "Model in high use. Try again later." }
        if statusCode == 429 { return "Rate limit exceeded. Try again later." }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Handle the several error shapes arbitrary OpenAI-compatible gateways use.
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let error = json["error"] as? String { return error }
            if let detail = json["detail"] as? String { return detail }
            if let message = json["message"] as? String { return message }
        }
        return "API error (\(statusCode))"
    }
}
