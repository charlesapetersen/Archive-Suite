import Foundation
import ImageIO
import CoreGraphics

/// Detects the clockwise rotation needed to make a scanned image upright by asking a vision
/// LLM to *compare* the four candidate rotations and pick the upright one. Empirically far
/// more accurate than local Vision on documents (comparison plays to the model's strengths;
/// absolute-orientation judgment does not). Optionally votes across several label orderings.
///
/// Returns a correction in {0, 90, 180, 270}, or `nil` if the call fails / provider is
/// unsupported (the caller then falls back to local Vision).
enum LLMRotationDetector {

    /// Cheap, fast Gemini model used for rotation regardless of the OCR model.
    static let cheapGeminiModel = "gemini-2.5-flash-lite"
    /// Long edge of the downscaled candidate images (orientation is obvious at low res).
    private static let candidatePixels = 800

    private static let prompt = """
    You are shown the SAME scanned document in four different rotations, labeled A, B, C, D. \
    Exactly one of them is correctly upright: text horizontal, reading left-to-right, not upside \
    down or sideways. Reply with EXACTLY one letter — A, B, C, or D — for the upright one. Nothing else.
    """

    /// Fixed orderings mapping label positions [A,B,C,D] → candidate correction values.
    private static let allOrderings: [[Int]] = [
        [0, 90, 180, 270],
        [90, 270, 0, 180],
        [180, 0, 270, 90]
    ]

    static func detectCorrection(
        imageURL: URL,
        provider: LLMProvider,
        apiKey: String,
        orderings: Int,
        gatewayConfig: GatewayConfig?
    ) async -> Int? {
        // Gateway / Mistral don't have a supported multi-image vision chat path here.
        if gatewayConfig != nil { return nil }
        guard provider == .gemini || provider == .anthropic else { return nil }

        guard let candidates = renderCandidates(imageURL: imageURL) else { return nil }

        let orderList = Array(allOrderings.prefix(max(1, orderings)))
        var votes: [Int] = []
        for order in orderList {
            if let correction = await ask(order: order, candidates: candidates, provider: provider, apiKey: apiKey) {
                votes.append(correction)
            }
        }
        guard !votes.isEmpty else { return nil }
        let counts = Dictionary(grouping: votes, by: { $0 }).mapValues { $0.count }
        return counts.max { $0.value < $1.value }!.key
    }

    // MARK: - One comparative call

    private static func ask(order: [Int], candidates: [Int: String], provider: LLMProvider, apiKey: String) async -> Int? {
        let labels = ["A", "B", "C", "D"]
        let images: [(label: String, base64: String)] = order.enumerated().compactMap { (i, corr) in
            guard let b64 = candidates[corr] else { return nil }
            return (labels[i], b64)
        }
        guard images.count == 4 else { return nil }

        let letter: String?
        switch provider {
        case .gemini: letter = await askGemini(images: images, apiKey: apiKey)
        case .anthropic: letter = await askAnthropic(images: images, apiKey: apiKey)
        case .mistral: letter = nil
        }
        guard let ch = letter?.uppercased().first, let idx = labels.firstIndex(of: String(ch)) else { return nil }
        return order[idx]
    }

    private static func askGemini(images: [(label: String, base64: String)], apiKey: String) async -> String? {
        var parts: [[String: Any]] = [["text": prompt]]
        for img in images {
            parts.append(["text": "\nImage \(img.label):"])
            parts.append(["inlineData": ["mimeType": "image/jpeg", "data": img.base64]])
        }
        let body: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": ["temperature": 0]
        ]
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(cheapGeminiModel):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        guard let (respData, _) = try? await NetworkSession.data(for: request, maxRetries: 1),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func askAnthropic(images: [(label: String, base64: String)], apiKey: String) async -> String? {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for img in images {
            content.append(["type": "text", "text": "\nImage \(img.label):"])
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": img.base64]])
        }
        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 8,
            "messages": [["role": "user", "content": content]]
        ]
        guard let url = URL(string: "https://api.anthropic.com/v1/messages"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = data
        guard let (respData, _) = try? await NetworkSession.data(for: request, maxRetries: 1),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let contentArr = json["content"] as? [[String: Any]] else { return nil }
        return contentArr.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Candidate rendering

    /// Render the four rotations (0/90/180/270 clockwise) of the downscaled image as JPEG base64,
    /// keyed by their correction value. Rotation matches PDFGenerator's clockwise convention.
    private static func renderCandidates(imageURL: URL) -> [Int: String]? {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: candidatePixels,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let base = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        var out: [Int: String] = [:]
        for degrees in [0, 90, 180, 270] {
            guard let rotated = rotate(base, byDegreesClockwise: degrees),
                  let jpeg = jpegBase64(rotated) else { return nil }
            out[degrees] = jpeg
        }
        return out
    }

    /// Rotate a CGImage clockwise by 0/90/180/270 (matches PDFGenerator.rotateImage).
    private static func rotate(_ image: CGImage, byDegreesClockwise degrees: Int) -> CGImage? {
        if degrees % 360 == 0 { return image }
        let w = image.width, h = image.height
        let radians = -Double(degrees) * .pi / 180.0
        let swap = degrees == 90 || degrees == 270
        let newW = swap ? h : w
        let newH = swap ? w : h
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = space.numberOfComponents == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil, width: newW, height: newH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else { return nil }
        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        ctx.rotate(by: radians)
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func jpegBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
