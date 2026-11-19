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

    /// Anthropic counts its thinking tokens inside max_tokens and requires the budget to be smaller.
    /// Adding the budget preserves the caller's visible-answer allowance.
    func anthropicMaxTokens(baseOutputTokens: Int, purpose: ThinkingBudgetPurpose) -> Int {
        baseOutputTokens + budgetTokens(for: purpose)
    }

    func anthropicOCRMaxTokens(baseOutputTokens: Int) -> Int {
        anthropicMaxTokens(baseOutputTokens: baseOutputTokens, purpose: .documentOCR)
    }

    /// W41.app-openrouter-claude — the request's thinking fields for an Anthropic model. Claude 4.7 and later reject a
    /// fixed `budget_tokens` with a 400 (platform.claude.com, "Extended thinking", checked 2026-11-18): they think
    /// adaptively, at the level's effort; older models keep the budget. `max_tokens` keeps the budget's room either way.
    func anthropicThinkingFields(modelID: String, purpose: ThinkingBudgetPurpose) -> [String: Any] {
        guard Self.anthropicThinksAdaptively(modelID) else {
            return ["thinking": ["type": "enabled", "budget_tokens": budgetTokens(for: purpose)]]
        }
        let effort: String
        switch self {
        case .low: effort = "low"
        case .high: effort = "high"
        }
        return ["thinking": ["type": "adaptive"], "output_config": ["effort": effort]]
    }

    /// Whether an Anthropic model id names Claude 4.7 or later (`claude-sonnet-5-5`, `claude-opus-4-7`, `claude-sonnet-5`),
    /// whose thinking is adaptive only; a dated id (`claude-haiku-4-5-20251001`) reads by its version, not its date.
    static func anthropicThinksAdaptively(_ modelID: String) -> Bool {
        let parts = modelID.split(separator: "-").map(String.init)
        // The 3.x layout puts the version first (`claude-3-5-sonnet-20241022`): those predate adaptive thinking.
        guard parts.count >= 3, parts[0] == "claude", Int(parts[1]) == nil, let major = Int(parts[2]) else { return false }
        let minor = parts.count > 3 && parts[3].count <= 2 ? Int(parts[3]) ?? 0 : 0
        return major > 4 || (major == 4 && minor >= 7)
    }
}
