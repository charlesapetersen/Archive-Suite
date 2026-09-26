import Foundation

/// Thinking budgets differ by request purpose. Keep OCR, text completion and tiny classification
/// separate so a shared helper cannot silently widen a paid request or exceed a provider ceiling.
enum ThinkingBudgetPurpose {
    case documentOCR
    case textCompletion
    case classification
}

extension ThinkingLevel {
    func budgetTokens(for purpose: ThinkingBudgetPurpose) -> Int {
        switch (purpose, self) {
        case (.documentOCR, .low): return 1024
        case (.documentOCR, .high): return 8000
        case (.textCompletion, .low): return 1024
        case (.textCompletion, .high): return 4000
        case (.classification, .low): return 512
        case (.classification, .high): return 2000
        }
    }

    /// Anthropic counts its thinking tokens inside max_tokens. Preserve the OCR output allowance.
    func anthropicOCRMaxTokens(baseOutputTokens: Int) -> Int {
        baseOutputTokens + budgetTokens(for: .documentOCR)
    }
}
