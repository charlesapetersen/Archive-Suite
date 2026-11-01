import Foundation

/// Friendly, user-facing message for a transient overload / rate-limit HTTP status — or `nil` when the
/// status isn't one of these. Shared by the OCR clients (Anthropic / Gemini / Mistral /
/// OpenAI-compatible) so 503/529 ("Model in high use") and 429 ("Rate limit exceeded") read identically
/// across providers instead of being re-typed in each `parseErrorResponse`.
func transientStatusMessage(_ statusCode: Int) -> String? {
    if statusCode == 503 || statusCode == 529 { return "Model in high use. Try again later." }
    if statusCode == 429 { return "Rate limit exceeded. Try again later." }
    return nil
}

/// The message for an HTTP 402, or `nil` for any other status (W40.fix-processor-gemini-402-message). A 402 is the
/// provider refusing for want of credit or billing (Gemini's "prepayment credits are depleted", sent with status
/// RESOURCE_EXHAUSTED; OpenRouter's "Insufficient credits"), so it says so, names the provider and where to add
/// credit, and keeps the provider's own words. It is not a wait-and-retry: the page's code stays "402", which
/// `isRetryableError` never retries, and the text avoids every word that function reads as transient.
func billingStatusMessage(_ statusCode: Int, provider: LLMProvider?, detail: String?) -> String? {
    guard statusCode == 402 else { return nil }
    var message: String
    if let provider {
        message = "Your \(provider.rawValue) account is out of credit or needs billing set up."
        if let url = billingPage(provider) {
            message += " Add credit or billing at \(url.absoluteString), then run these pages again."
        }
    } else {
        message = "The provider's account is out of credit or needs billing set up. Add credit or billing there, then run these pages again."
    }
    if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
        message += " (\(provider?.rawValue ?? "The provider") said: \(detail.prefix(300)))"
    }
    return message
}

/// The provider's billing page, from its key-onboarding spec (one copy of each URL).
private func billingPage(_ provider: LLMProvider) -> URL? {
    [ProviderKeySpec.anthropic, .gemini, .mistral, .openai, .openrouter]
        .first { $0.provider == provider }?.billingURL
}
