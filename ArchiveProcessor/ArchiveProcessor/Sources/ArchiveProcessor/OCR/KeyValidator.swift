import Foundation

/// Validates a pasted API key against its provider with one cheap live call, and maps every outcome
/// to a plain-English status the onboarding wizard can show. Never surfaces raw JSON/HTTP to the user.
enum KeyValidator {

    /// The outcome of validating a key, mapped to user-facing guidance.
    enum KeyStatus: Equatable {
        case works              // ✓ authenticated (and OCR-capable where probed)
        case invalidKey         // wrong / mistyped / expired / not permitted
        case needsBilling       // free tier unavailable in region / billing required (Gemini)
        case ocrNotEnabled      // key valid but OCR needs a paid plan (Mistral)
        case rateLimited        // 429 — fine during onboarding; the app paces requests
        case offline            // request never reached the provider (not the key's fault)
        case providerBusy       // provider 5xx
        case unknown(String)    // unexpected; detail is logged, not blamed on the user

        /// Good enough to let the user proceed (key authenticates; a 429 is transient).
        var isUsable: Bool { self == .works || self == .rateLimited }

        /// One plain-English sentence for the user.
        func message(provider: String) -> String {
            switch self {
            case .works:
                return "✓ Your \(provider) key works."
            case .rateLimited:
                return "✓ Your \(provider) key works. You're at the free-tier rate limit right now — that's fine; the app paces requests automatically."
            case .invalidKey:
                return "That key isn't valid. Re-copy it from \(provider) and paste it again."
            case .needsBilling:
                return "\(provider)'s free tier isn't available in your region. Enable billing in Google AI Studio, or use Mistral instead."
            case .ocrNotEnabled:
                return "Your \(provider) key works, but OCR needs a paid plan. Add your own card in \(provider) — charges go to \(provider), not to this app."
            case .offline:
                return "Couldn't reach \(provider). Check your internet connection and try again — this isn't a problem with your key."
            case .providerBusy:
                return "\(provider) is busy right now. Wait a moment and tap Retry."
            case .unknown(let detail):
                return "Couldn't verify the key (\(detail)). Tap Retry."
            }
        }
    }

    private static let timeout: TimeInterval = 15

    // MARK: - Gemini (Google AI Studio)

    /// Cheap, near-free auth check: GET /v1beta/models?key=… (no image, no generation cost).
    static func validateGemini(key: String) async -> KeyStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }
        guard var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
            return .unknown("bad-url")
        }
        comps.queryItems = [URLQueryItem(name: "key", value: trimmed)]
        guard let url = comps.url else { return .unknown("bad-url") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .providerBusy }
            if http.statusCode == 200 { return .works }
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let status = (error?["status"] as? String) ?? ""
            let message = ((error?["message"] as? String) ?? "").lowercased()
            switch http.statusCode {
            case 400:
                if status == "FAILED_PRECONDITION" || message.contains("billing") || message.contains("free tier is not available") {
                    return .needsBilling
                }
                return .invalidKey   // API_KEY_INVALID / malformed
            case 401, 403: return .invalidKey
            case 429: return .rateLimited
            case 500...599: return .providerBusy
            default: return .unknown("HTTP \(http.statusCode)")
            }
        } catch {
            return .offline
        }
    }

    // MARK: - Mistral

    /// Cheap auth check: GET /v1/models with a Bearer token. OCR-plan capability is confirmed later by
    /// the end-to-end sample-OCR test (which can surface `ocrNotEnabled`).
    static func validateMistral(key: String) async -> KeyStatus {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidKey }
        guard let url = URL(string: "https://api.mistral.ai/v1/models") else { return .unknown("bad-url") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .providerBusy }
            switch http.statusCode {
            case 200: return .works
            case 401, 403: return .invalidKey
            case 402: return .ocrNotEnabled   // payment required
            case 429: return .rateLimited
            case 500...599: return .providerBusy
            default: return .unknown("HTTP \(http.statusCode)")
            }
        } catch {
            return .offline
        }
    }

    /// Map an OCR-pipeline error (from the end-to-end sample test) to a status. `errorCode` is the
    /// provider HTTP status string the OCR clients already surface; used to catch plan/billing on Mistral.
    static func classifySampleOCR(errorCode: String?, errorMessage: String?) -> KeyStatus {
        let msg = (errorMessage ?? "").lowercased()
        switch errorCode {
        case "401", "403": return .invalidKey
        case "402": return .ocrNotEnabled
        case "429": return .rateLimited
        case let c? where (Int(c) ?? 0) >= 500: return .providerBusy
        default:
            if msg.contains("billing") || msg.contains("free tier is not available") { return .needsBilling }
            if msg.contains("plan") || msg.contains("payment") || msg.contains("subscription") { return .ocrNotEnabled }
            return .unknown(errorCode ?? "ocr")
        }
    }
}
