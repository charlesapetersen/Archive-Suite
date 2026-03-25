import Foundation
import AppKit

struct MistralClient {
    let apiKey: String
    let model: LLMModel

    private let endpoint = URL(string: "https://api.mistral.ai/v1/ocr")!

    func ocr(imageURL: URL) async throws -> OCRResult {
        guard let imageData = try? Data(contentsOf: imageURL),
              let nsImage = NSImage(data: imageData),
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
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

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            return OCRResult(text: nil, errorMessage: errorBody, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OCRResult(text: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        // Mistral OCR returns pages array with markdown content
        if let pages = json["pages"] as? [[String: Any]] {
            let text = pages.compactMap { $0["markdown"] as? String }.joined(separator: "\n\n")
            return OCRResult(text: text.isEmpty ? nil : text, errorMessage: nil, errorCode: nil)
        }

        // Fallback: check for text field
        if let text = json["text"] as? String {
            return OCRResult(text: text.isEmpty ? nil : text, errorMessage: nil, errorCode: nil)
        }

        return OCRResult(text: nil, errorMessage: "Unexpected response format", errorCode: nil)
    }
}
