// Minimal type stub lets this $0 check compile the production ThinkingBudget.swift without the app.
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
        print("THINKING BUDGET PASS: 6 purpose/level values and 2 Anthropic OCR ceilings")
    }
}
