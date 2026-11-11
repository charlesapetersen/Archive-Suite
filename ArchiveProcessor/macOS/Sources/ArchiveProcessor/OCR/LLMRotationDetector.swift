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
    /// Cheap OpenAI model used for rotation regardless of the OCR model. GPT-5.4 mini supports reasoning,
    /// but defaults to `none`; this path pins that effort and bounds total completion tokens. Verified
    /// against OpenAI's live model docs 2026-09-26: https://developers.openai.com/api/docs/models/gpt-5.4-mini
    static let cheapOpenAIModel = "gpt-5.4-mini"
    /// The model a remote gateway is asked for rotation, whatever its OCR model: the one W46.rotation-routes
    /// measured (Gemini 3.7 Flash through the Stanford gateway, temperature 0, minimal reasoning), so a gateway
    /// run's rotation is the measured route (W46.rotation-default, P9-3). A gateway without it answers an error,
    /// and the page falls back as on any failed call.
    static let gatewayModel = "gemini-3.7-flash"
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

    /// Whether an LLM rotation mode has a comparative call on this backend. A remote gateway asks `gatewayModel`
    /// (W46.rotation-default); a model on this Mac behind the gateway field, the Local Agent CLI, Apple Vision,
    /// Mistral and OpenRouter have no comparative call here, so their LLM modes fall back
    /// (`OCRProcessor.detectRotation`); Settings says so (W40.fix-processor-rotation-deadlock).
    static func hasRoute(provider: LLMProvider, usesGateway: Bool, usesLocalAgent: Bool,
                         gatewayIsLocal: Bool = false) -> Bool {
        if usesLocalAgent { return false }
        if usesGateway { return !gatewayIsLocal }
        return provider == .gemini || provider == .anthropic || provider == .openai
    }

    /// Whether this backend's comparative call is a MEASURED route (`gatewayModel` on a remote gateway). The direct
    /// keys ask models no bench measured on the rotation turns, so the agreement rule does not escalate to them
    /// (W46.rotation-default, P9-3: a direct-key model is measured on the same turns first).
    static func hasMeasuredRoute(usesGateway: Bool, usesLocalAgent: Bool, gatewayIsLocal: Bool) -> Bool {
        usesGateway && !usesLocalAgent && !gatewayIsLocal
    }

    static func detectCorrection(
        imageURL: URL,
        provider: LLMProvider,
        apiKey: String,
        orderings: Int,
        gatewayConfig: GatewayConfig?
    ) async -> Int? {
        guard hasRoute(provider: provider, usesGateway: gatewayConfig != nil, usesLocalAgent: false,
                       gatewayIsLocal: gatewayConfig?.isLocalModel == true) else { return nil }

        guard let candidates = renderCandidates(imageURL: imageURL) else { return nil }

        let orderList = Array(allOrderings.prefix(max(1, orderings)))
        var votes: [Int] = []
        for order in orderList {
            if let correction = await ask(order: order, candidates: candidates, provider: provider, apiKey: apiKey,
                                          gateway: gatewayConfig) {
                votes.append(correction)
            }
        }
        return majority(of: votes)
    }

    /// The most-voted correction; a tie goes to the earliest vote (the first ordering that answered), so the
    /// pick never follows the Dictionary's per-launch hash seed (W46.rotation-majority-fix). `nil` for no votes.
    static func majority(of votes: [Int]) -> Int? {
        var best: (value: Int, count: Int)?
        for value in votes {
            let count = votes.lazy.filter { $0 == value }.count
            if best == nil || count > best!.count { best = (value, count) }
        }
        return best?.value
    }

    // MARK: - One comparative call

    private static func ask(order: [Int], candidates: [Int: String], provider: LLMProvider, apiKey: String,
                            gateway: GatewayConfig?) async -> Int? {
        let labels = ["A", "B", "C", "D"]
        let images: [(label: String, base64: String)] = order.enumerated().compactMap { (i, corr) in
            guard let b64 = candidates[corr] else { return nil }
            return (labels[i], b64)
        }
        guard images.count == 4 else { return nil }

        let letter: String?
        if let gateway {
            letter = await askGateway(images: images, gateway: gateway)
        } else {
        switch provider {
        case .gemini: letter = await askGemini(images: images, apiKey: apiKey)
        case .anthropic: letter = await askAnthropic(images: images, apiKey: apiKey)
        case .mistral: letter = nil
        case .openai: letter = await askOpenAI(images: images, apiKey: apiKey)
        case .appleVision, .openrouter: letter = nil   // OpenRouter: no rotation route measured
        }
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
        guard let (respData, _) = try? await NetworkSession.data(
            for: request, policy: .nonIdempotent, maxRetries: 1),
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
        guard let (respData, _) = try? await NetworkSession.data(
            for: request, policy: .nonIdempotent, maxRetries: 1),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let contentArr = json["content"] as? [[String: Any]] else { return nil }
        return contentArr.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `gatewayModel` through the gateway's chat completions, the request W46.rotation-routes measured: temperature
    /// 0, minimal reasoning, 2,048 tokens (the model may think before its letter).
    private static func askGateway(images: [(label: String, base64: String)], gateway: GatewayConfig) async -> String? {
        let body: [String: Any] = [
            "model": gatewayModel,
            "temperature": 0,
            "reasoning_effort": "minimal",
            "max_tokens": 2048,
            "messages": [["role": "user", "content": chatContent(images)]]
        ]
        guard let url = URL(string: "\(GatewayConfig.normalizedBaseURL(gateway.baseURL))/chat/completions") else { return nil }
        return await chatLetter(url: url, body: body, apiKey: gateway.apiKey)
    }

    /// The prompt and four labelled candidates as OpenAI-style content parts.
    private static func chatContent(_ images: [(label: String, base64: String)]) -> [[String: Any]] {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for img in images {
            content.append(["type": "text", "text": "\nImage \(img.label):"])
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img.base64)"]])
        }
        return content
    }

    /// POST a chat-completions body and return the first choice's text; nil on any failure or a non-200.
    private static func chatLetter(url: URL, body: [String: Any], apiKey: String) async -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        guard let (respData, response) = try? await NetworkSession.data(
            for: request, policy: .nonIdempotent, maxRetries: 1),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func askOpenAI(images: [(label: String, base64: String)], apiKey: String) async -> String? {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for img in images {
            content.append(["type": "text", "text": "\nImage \(img.label):"])
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img.base64)"]])
        }
        // Keep rotation cheap and deterministic: effort `none`, an eight-token total completion ceiling,
        // and temperature zero. OpenAI's current API accepts temperature at effort `none`.
        let body: [String: Any] = [
            "model": cheapOpenAIModel,
            "max_completion_tokens": 8,
            "reasoning_effort": "none",
            "temperature": 0,
            "messages": [["role": "user", "content": content]]
        ]
        guard let url = URL(string: "\(OpenAICompatibleClient.openAIBaseURL)/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        guard let (respData, _) = try? await NetworkSession.data(
            for: request, policy: .nonIdempotent, maxRetries: 1),
              let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            guard let rotated = ImageEncoding.rotate(base, byDegreesClockwise: degrees),
                  let jpeg = jpegBase64(rotated) else { return nil }
            out[degrees] = jpeg
        }
        return out
    }

    private static func jpegBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
