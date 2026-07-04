import Foundation

struct CostEstimate {
    let ocrCost: Double
    let classificationCost: Double
    let taggingCost: Double
    let collectionCost: Double
    let rotationCost: Double
    let batchOcrCost: Double
    let fileCount: Int
    let model: LLMModel

    var totalStandard: Double { ocrCost + classificationCost + taggingCost + collectionCost + rotationCost }
    var totalBatch: Double { batchOcrCost + classificationCost + taggingCost + collectionCost + rotationCost }

    var ocrFormatted: String { "$\(String(format: "%.4f", ocrCost))" }
    var classificationFormatted: String { "$\(String(format: "%.4f", classificationCost))" }
    var taggingFormatted: String { "$\(String(format: "%.4f", taggingCost))" }
    var collectionFormatted: String { "$\(String(format: "%.4f", collectionCost))" }
    var rotationFormatted: String { "$\(String(format: "%.4f", rotationCost))" }
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

    // Collection segmentation: text-only calls (~500 input + 50 output per box, plus one clustering call)
    static let estimatedCollectionInputTokens: Double = 500
    static let estimatedCollectionOutputTokens: Double = 50
    static let estimatedClusteringInputTokens: Double = 800
    static let estimatedClusteringOutputTokens: Double = 200

    // Text-only classification: prompt (~600 tokens) + short output (~10 tokens)
    static let estimatedClassificationInputTokens: Double = 600
    static let estimatedClassificationOutputTokens: Double = 10

    // Rotation (LLM comparative call): 4 downscaled (~800px) candidate images + a short prompt,
    // one letter of output. `.llmSingle` = 1 call/file, `.llmMajority` = 3 calls/file. Always runs
    // on a fixed cheap model (gemini-2.5-flash-lite for Gemini, claude-sonnet-4-6 for Anthropic);
    // Gateway/Mistral fall back to free local Vision.
    static let estimatedRotationPromptTokens: Double = 90
    static let estimatedRotationOutputTokens: Double = 5
    static func estimatedRotationCandidateTokens(for provider: LLMProvider) -> Double {
        provider == .anthropic ? 650 : 600     // per 800px candidate image
    }
    /// (inputCostPer1M, outputCostPer1M) of the fixed model used for rotation, or nil if rotation
    /// is free/unavailable for this provider.
    static func rotationModelCost(for provider: LLMProvider) -> (Double, Double)? {
        switch provider {
        case .gemini: return (0.0375, 0.15)     // gemini-2.5-flash-lite
        case .anthropic: return (3.0, 15.0)     // claude-sonnet-4-6
        case .mistral: return nil               // no LLM rotation path → local Vision (free)
        }
    }

    static func estimate(
        fileCount: Int,
        model: LLMModel,
        enableTagging: Bool,
        enableCollectionSegmentation: Bool = false,
        preOCRedInput: Bool = false,
        sendPreviousImage: Bool,
        contextCharCount: Int,
        imageScale: Double = 1.0,
        rotationMode: RotationMode = .off,
        useGateway: Bool = false,
        imageTokenProvider: LLMProvider? = nil
    ) -> CostEstimate {
        // OCR cost (zero when using pre-OCRed PDFs).
        // `imageScale` is the size-target slider fraction; for a standard-size file it equals the
        // image *area* fraction (target size ∝ area), so image tokens scale linearly with it.
        var ocrCost: Double = 0
        var batchOcrCost: Double = 0
        if !preOCRedInput {
            let scaleArea = max(0.01, min(1.0, imageScale))   // defensive clamp against stale/out-of-range values
            // For a gateway, model.provider is a stand-in (.anthropic); use the caller-supplied upstream
            // family so a Gemini-behind-gateway isn't under-estimated ~6.7×.
            let imgTokens = estimatedImageTokens(for: imageTokenProvider ?? model.provider) * scaleArea
            let contextTokens = Double(contextCharCount) / 4.0 // ~4 chars per token
            let inputPerFile = estimatedPromptTokens + imgTokens + contextTokens
                + (sendPreviousImage ? imgTokens : 0)
            let totalOcrInput = Double(fileCount) * inputPerFile
            let totalOcrOutput = Double(fileCount) * estimatedOutputTokens
            ocrCost = (totalOcrInput / 1_000_000) * model.inputCostPer1M
                    + (totalOcrOutput / 1_000_000) * model.outputCostPer1M
            batchOcrCost = ocrCost * model.batchDiscount
        }

        // Text-only classification cost (only for pre-OCRed input when tagging or collection is enabled)
        var classificationCost: Double = 0
        if preOCRedInput && (enableTagging || enableCollectionSegmentation) {
            let classInput = Double(fileCount) * estimatedClassificationInputTokens
            let classOutput = Double(fileCount) * estimatedClassificationOutputTokens
            classificationCost = (classInput / 1_000_000) * model.inputCostPer1M
                               + (classOutput / 1_000_000) * model.outputCostPer1M
        }

        // Tagging cost
        var taggingCost: Double = 0
        if enableTagging {
            let estimatedSegments = max(1.0, Double(fileCount) / 3.0)
            let tagInput = estimatedSegments * estimatedTaggingInputTokens
            let tagOutput = estimatedSegments * estimatedTaggingOutputTokens
            taggingCost = (tagInput / 1_000_000) * model.inputCostPer1M
                        + (tagOutput / 1_000_000) * model.outputCostPer1M
        }

        // Collection segmentation cost
        var collectionCost: Double = 0
        if enableCollectionSegmentation {
            let estimatedBoxes = max(1.0, Double(fileCount) / 7.0)
            let boxInput = estimatedBoxes * estimatedCollectionInputTokens
            let boxOutput = estimatedBoxes * estimatedCollectionOutputTokens
            let clusterInput = estimatedClusteringInputTokens
            let clusterOutput = estimatedClusteringOutputTokens
            collectionCost = ((boxInput + clusterInput) / 1_000_000) * model.inputCostPer1M
                           + ((boxOutput + clusterOutput) / 1_000_000) * model.outputCostPer1M
        }

        // Rotation cost (LLM modes only; free for Gateway/Mistral/local Vision/off; none for pre-OCRed).
        var rotationCost: Double = 0
        let rotCalls = rotationMode.orderings
        if rotCalls > 0, !preOCRedInput, !useGateway,
           let (rIn, rOut) = rotationModelCost(for: model.provider) {
            let inputPerCall = 4 * estimatedRotationCandidateTokens(for: model.provider) + estimatedRotationPromptTokens
            let calls = Double(fileCount) * Double(rotCalls)
            rotationCost = (calls * inputPerCall / 1_000_000) * rIn
                         + (calls * estimatedRotationOutputTokens / 1_000_000) * rOut
        }

        return CostEstimate(
            ocrCost: ocrCost,
            classificationCost: classificationCost,
            taggingCost: taggingCost,
            collectionCost: collectionCost,
            rotationCost: rotationCost,
            batchOcrCost: batchOcrCost,
            fileCount: fileCount,
            model: model
        )
    }
}
