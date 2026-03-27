import Foundation

struct CostEstimate {
    let ocrCost: Double
    let taggingCost: Double
    let batchOcrCost: Double
    let fileCount: Int
    let model: LLMModel

    var totalStandard: Double { ocrCost + taggingCost }
    var totalBatch: Double { batchOcrCost + taggingCost }

    var ocrFormatted: String { "$\(String(format: "%.4f", ocrCost))" }
    var taggingFormatted: String { "$\(String(format: "%.4f", taggingCost))" }
    var totalStandardFormatted: String { "$\(String(format: "%.4f", totalStandard))" }
    var totalBatchFormatted: String { "$\(String(format: "%.4f", totalBatch))" }
}

struct CostEstimator {
    // OCR: image tokens + prompt (including classification instruction + context) + output (OCR text + classification tag)
    static let estimatedPromptTokens: Double = 400       // classification prompt + context text
    static let estimatedOutputTokens: Double = 850       // OCR text + classification tag

    // Image token estimates per provider (calibrated from actual API costs).
    // Gemini tiles high-res images extensively (~40k tokens per archival photo).
    // Anthropic uses a more compact image encoding (~6k tokens per photo).
    // Mistral OCR endpoint has flat per-page pricing reflected as ~1k equivalent tokens.
    static func estimatedImageTokens(for provider: LLMProvider) -> Double {
        switch provider {
        case .gemini: return 40_000
        case .anthropic: return 6_000
        case .mistral: return 1_000
        }
    }

    // Tagging: text-only, ~1 call per segment (~3 files/segment average)
    static let estimatedTaggingInputTokens: Double = 1500
    static let estimatedTaggingOutputTokens: Double = 200

    static func estimate(
        fileCount: Int,
        model: LLMModel,
        enableTagging: Bool,
        sendPreviousImage: Bool,
        contextCharCount: Int
    ) -> CostEstimate {
        // OCR cost
        let imgTokens = estimatedImageTokens(for: model.provider)
        let contextTokens = Double(contextCharCount) / 4.0 // ~4 chars per token
        let inputPerFile = estimatedPromptTokens + imgTokens + contextTokens
            + (sendPreviousImage ? imgTokens : 0)
        let totalOcrInput = Double(fileCount) * inputPerFile
        let totalOcrOutput = Double(fileCount) * estimatedOutputTokens
        let ocrCost = (totalOcrInput / 1_000_000) * model.inputCostPer1M
                    + (totalOcrOutput / 1_000_000) * model.outputCostPer1M
        let batchOcrCost = ocrCost * model.batchDiscount

        // Tagging cost
        var taggingCost: Double = 0
        if enableTagging {
            let estimatedSegments = max(1.0, Double(fileCount) / 3.0)
            let tagInput = estimatedSegments * estimatedTaggingInputTokens
            let tagOutput = estimatedSegments * estimatedTaggingOutputTokens
            taggingCost = (tagInput / 1_000_000) * model.inputCostPer1M
                        + (tagOutput / 1_000_000) * model.outputCostPer1M
        }

        return CostEstimate(
            ocrCost: ocrCost,
            taggingCost: taggingCost,
            batchOcrCost: batchOcrCost,
            fileCount: fileCount,
            model: model
        )
    }
}
