import Foundation

/// Request body for Anthropic text completion, kept free of app types so the key-free
/// `scripts/test-thinking-budgets.sh` check compiles the exact production shape.
enum AnthropicTextRequest {
    /// `maxTokens` is the visible-answer allowance. With thinking enabled the total ceiling grows by
    /// the budget, since Anthropic rejects `budget_tokens >= max_tokens` (W12.dedup-fu1).
    static func body(prompt: String, modelID: String, thinkingLevel: ThinkingLevel?, maxTokens: Int) -> [String: Any] {
        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": thinkingLevel?.anthropicMaxTokens(baseOutputTokens: maxTokens, purpose: .textCompletion) ?? maxTokens,
            "messages": [["role": "user", "content": prompt]]
        ]
        if let thinking = thinkingLevel {
            body["thinking"] = ["type": "enabled", "budget_tokens": thinking.budgetTokens(for: .textCompletion)]
        }
        return body
    }
}
