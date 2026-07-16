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
