import Foundation
import AppKit
import ImageIO

struct GeminiClient {
    let apiKey: String
    let model: LLMModel
    let thinkingLevel: ThinkingLevel?

    func ocr(imageURL: URL, previousText: String? = nil, previousImageURL: URL? = nil, customPrompt: String? = nil, imageScale: Double = 1.0) async throws -> OCRResult {
        guard let jpegData = Self.loadImageAsJPEG(url: imageURL, scale: imageScale) else {
            throw OCRError.imageLoadFailed
        }
        let base64 = jpegData.base64EncodedString()
        let prompt = OCRPrompt.build(previousText: previousText, previousImageIncluded: previousImageURL != nil, customPrompt: customPrompt)

        var parts: [[String: Any]] = []

        // If sending previous image, add it first
        if let prevURL = previousImageURL, let prevData = Self.loadImageAsJPEG(url: prevURL, scale: imageScale) {
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": prevData.base64EncodedString()]])
        }

        parts.append(["inlineData": ["mimeType": "image/jpeg", "data": base64]])
        parts.append(["text": prompt])

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

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await NetworkSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OCRError.networkError("No HTTP response") }

        if http.statusCode != 200 {
            let errorMessage = Self.parseErrorResponse(data: data, statusCode: http.statusCode)
            return OCRResult(text: nil, classification: nil, errorMessage: errorMessage, errorCode: "\(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OCRResult(text: nil, classification: nil, errorMessage: "Malformed response", errorCode: nil)
        }

        if let promptFeedback = json["promptFeedback"] as? [String: Any],
           let blockReason = promptFeedback["blockReason"] as? String {
            return OCRResult(text: nil, classification: nil, errorMessage: "Content blocked by Gemini: \(blockReason)", errorCode: blockReason)
        }

        guard let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first else {
            return OCRResult(text: nil, classification: nil, errorMessage: "No candidates in response", errorCode: nil)
        }

        if let finishReason = first["finishReason"] as? String, finishReason == "RECITATION" {
            return OCRResult(text: nil, classification: nil, errorMessage: "Gemini refused to OCR this content (Recitation — likely copyrighted material).", errorCode: "Recitation")
        }

        guard let content = first["content"] as? [String: Any],
              let respParts = content["parts"] as? [[String: Any]] else {
            return OCRResult(text: nil, classification: nil, errorMessage: "No content parts in response", errorCode: nil)
        }

        let rawText = respParts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let (classification, rotationDegrees, ocrText) = OCRPrompt.parseResponse(rawText)
        return OCRResult(text: ocrText, classification: classification, rotationDegrees: rotationDegrees, errorMessage: nil, errorCode: nil)
    }

    static func parseErrorResponse(data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any] {
            let status = error["status"] as? String ?? ""
            let message = error["message"] as? String
            // Handle common error statuses with friendly messages
            if statusCode == 503 || status == "UNAVAILABLE" {
                return "Model in high use. Try again later."
            }
            if status == "RESOURCE_EXHAUSTED" || statusCode == 429 {
                return "Rate limit exceeded. Try again later."
            }
            if let message = message, message.lowercased().contains("recitation") {
                return "Gemini refused to OCR this content (Recitation — likely copyrighted material)."
            }
            if let message = message {
                return message
            }
        }
        return "API error (\(statusCode))"
    }

    /// Long-edge cap (px) for images sent to OCR APIs (~3 MP). Vision LLMs downsample internally,
    /// so larger just wastes memory/CPU/bandwidth — and full-resolution phone photos otherwise
    /// beachball the app while decoding. The PDF page-1 image and the archived original are produced
    /// separately (PDFGenerator / dual-output copy) and are unaffected. Tunable.
    static let maxOCRDimension = 2048

    /// Load an image as JPEG for upload — efficiently. Reads dimensions from the file header and
    /// decodes straight to the target long edge (honoring EXIF orientation) via a thumbnail request,
    /// so the full-resolution bitmap is never materialized. `scale` (0–1) applies the user's
    /// resolution setting; the result is then capped at `maxOCRDimension`. Never upscales.
    static func loadImageAsJPEG(url: URL, scale: Double = 1.0) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceType = CGImageSourceGetType(source) as? String
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        let pixelW = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelH = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxDim = max(pixelW, pixelH)

        // Apply the optional user scale, then cap for OCR. Never upscale.
        let scaledDim = (scale > 0 && scale < 1.0) ? Int(Double(maxDim) * scale) : maxDim
        let target = maxDim > 0 ? min(scaledDim, maxOCRDimension) : maxOCRDimension

        // Fast path: an already-small JPEG with normal orientation → send raw bytes, no decode.
        if sourceType == "public.jpeg" && orientation == 1 && maxDim > 0 && target >= maxDim {
            return try? Data(contentsOf: url)
        }

        // Decode directly to the target long edge — the thumbnail path avoids the full-res buffer
        // and bakes in orientation via kCGImageSourceCreateThumbnailWithTransform.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return try? Data(contentsOf: url)   // fallback: raw bytes
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
