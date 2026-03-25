import Foundation

struct CostEstimate {
    let standardCost: Double
    let batchCost: Double
    let fileCount: Int
    let model: LLMModel

    var standardFormatted: String { "$\(String(format: "%.4f", standardCost))" }
    var batchFormatted: String { "$\(String(format: "%.4f", batchCost))" }
    var savingsFormatted: String {
        let savings = standardCost - batchCost
        return "$\(String(format: "%.4f", savings))"
    }
}

struct CostEstimator {
    /// Approximate tokens per image (image + prompt + output).
    /// Images are encoded as base64 and priced as image tokens.
    /// We estimate ~1000 input tokens per image (prompt) + image tokens,
    /// and ~800 output tokens for the OCR text.
    static let estimatedInputTokensPerImage: Double = 1000
    static let estimatedOutputTokensPerImage: Double = 800
    // Gemini/Anthropic charge image tokens separately; approximate ~800 tokens per standard image
    static let estimatedImageTokensPerImage: Double = 800

    static func estimate(fileCount: Int, model: LLMModel) -> CostEstimate {
        let totalInput = Double(fileCount) * (estimatedInputTokensPerImage + estimatedImageTokensPerImage)
        let totalOutput = Double(fileCount) * estimatedOutputTokensPerImage
        let standardCost = (totalInput / 1_000_000) * model.inputCostPer1M
                         + (totalOutput / 1_000_000) * model.outputCostPer1M
        let batchCost = standardCost * model.batchDiscount
        return CostEstimate(standardCost: standardCost, batchCost: batchCost, fileCount: fileCount, model: model)
    }
}
