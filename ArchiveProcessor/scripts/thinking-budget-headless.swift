// Minimal type stub lets this $0 check compile the production ThinkingBudget.swift and
// AnthropicTextRequest.swift without the app.
enum ThinkingLevel { case low, high }

@main struct ThinkingBudgetCheck {
    static func main() {
        let cases: [(ThinkingBudgetPurpose, Int, Int)] = [
            (.documentOCR, 1024, 8000),
            (.textCompletion, 1024, 4000),
            (.classification, 512, 2000),
        ]
        for (purpose, low, high) in cases {
            precondition(ThinkingLevel.low.budgetTokens(for: purpose) == low)
            precondition(ThinkingLevel.high.budgetTokens(for: purpose) == high)
        }
        precondition(ThinkingLevel.low.anthropicOCRMaxTokens(baseOutputTokens: 8192) == 9216)
        precondition(ThinkingLevel.high.anthropicOCRMaxTokens(baseOutputTokens: 8192) == 16192)
        // W12.dedup-fu1: collection names (256) and tags (512) must keep budget_tokens < max_tokens
        // while preserving the visible-answer allowance; without thinking the body is unchanged.
        var shapes = 0
        for allowance in [256, 512] {
            let plain = AnthropicTextRequest.body(prompt: "p", modelID: "m", thinkingLevel: nil, maxTokens: allowance)
            precondition(plain["max_tokens"] as? Int == allowance)
            precondition(plain["thinking"] == nil)
            precondition(Set(plain.keys) == ["model", "max_tokens", "messages"])
            shapes += 1
            for level in [ThinkingLevel.low, .high] {
                let body = AnthropicTextRequest.body(prompt: "p", modelID: "m", thinkingLevel: level, maxTokens: allowance)
                let thinking = body["thinking"] as! [String: Any]
                let budget = thinking["budget_tokens"] as! Int
                let ceiling = body["max_tokens"] as! Int
                precondition(thinking["type"] as? String == "enabled")
                precondition(budget == level.budgetTokens(for: .textCompletion))
                precondition(budget < ceiling && ceiling - budget == allowance)
                shapes += 1
            }
        }
        precondition(shapes == 6)
        // W41.app-openrouter-claude: Claude 4.7 and later reject budget_tokens; they think adaptively at the level's
        // effort, with the same max_tokens room. Older ids keep the budget.
        for (id, adaptive) in [("claude-sonnet-5-5", true), ("claude-opus-4-7", true), ("claude-sonnet-5", true),
                               ("claude-sonnet-4-6", false), ("claude-opus-4-6", false), ("claude-haiku-4-5-20251001", false),
                               ("claude-3-5-sonnet-20241022", false), ("claude-3-7-sonnet-20250219", false), ("m", false)] {
            precondition(ThinkingLevel.anthropicThinksAdaptively(id) == adaptive, id)
        }
        for (level, effort) in [(ThinkingLevel.low, "low"), (.high, "high")] {
            let body = AnthropicTextRequest.body(prompt: "p", modelID: "claude-sonnet-5-5", thinkingLevel: level, maxTokens: 256)
            precondition((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
            precondition((body["thinking"] as? [String: Any])?["budget_tokens"] == nil)
            precondition((body["output_config"] as? [String: Any])?["effort"] as? String == effort)
            precondition(body["max_tokens"] as? Int == 256 + level.budgetTokens(for: .textCompletion))
        }
        print("THINKING BUDGET PASS: 6 purpose/level values, 2 Anthropic OCR ceilings, 6 Anthropic text request shapes, "
              + "9 adaptive-model ids, 2 adaptive request shapes")
    }
}
