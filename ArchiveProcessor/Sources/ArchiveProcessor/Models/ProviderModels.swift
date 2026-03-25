import Foundation

// MARK: - Providers

enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic = "Anthropic"
    case gemini = "Gemini"
    case mistral = "Mistral"

    var id: String { rawValue }

    var models: [LLMModel] {
        switch self {
        case .anthropic: return LLMModel.anthropicModels
        case .gemini: return LLMModel.geminiModels
        case .mistral: return LLMModel.mistralModels
        }
    }
}

// MARK: - Thinking Level

enum ThinkingLevel: String, CaseIterable, Identifiable {
    case low = "Low"
    case high = "High"
    var id: String { rawValue }
}

// MARK: - Models

struct LLMModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let provider: LLMProvider
    let supportsThinking: Bool
    let returnsMd: Bool
    /// Cost per 1M input tokens (USD), standard pricing
    let inputCostPer1M: Double
    /// Cost per 1M output tokens (USD), standard pricing
    let outputCostPer1M: Double
    /// Batch discount multiplier (e.g. 0.5 = 50% off)
    let batchDiscount: Double

    static let anthropicModels: [LLMModel] = [
        LLMModel(
            id: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            provider: .anthropic,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 3.0,
            outputCostPer1M: 15.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "claude-opus-4-6",
            displayName: "Claude Opus 4.6",
            provider: .anthropic,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 15.0,
            outputCostPer1M: 75.0,
            batchDiscount: 0.5
        ),
    ]

    static let geminiModels: [LLMModel] = [
        LLMModel(
            id: "gemini-3-flash-preview",
            displayName: "Gemini 3 Flash Preview",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.075,
            outputCostPer1M: 0.30,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro Preview",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 1.25,
            outputCostPer1M: 5.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.1-flash-lite-preview",
            displayName: "Gemini 3.1 Flash Lite Preview",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.0375,
            outputCostPer1M: 0.15,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-2.5-flash",
            displayName: "Gemini 2.5 Flash",
            provider: .gemini,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 0.075,
            outputCostPer1M: 0.30,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-2.5-flash-lite",
            displayName: "Gemini 2.5 Flash Lite",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.0375,
            outputCostPer1M: 0.15,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-2.5-pro",
            displayName: "Gemini 2.5 Pro",
            provider: .gemini,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 1.25,
            outputCostPer1M: 10.0,
            batchDiscount: 0.5
        ),
    ]

    static let mistralModels: [LLMModel] = [
        LLMModel(
            id: "mistral-ocr-latest",
            displayName: "Mistral OCR 3",
            provider: .mistral,
            supportsThinking: false,
            returnsMd: true,
            inputCostPer1M: 1.0,
            outputCostPer1M: 1.0,
            batchDiscount: 0.5
        ),
    ]
}

// MARK: - OCR Job

struct OCRJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var status: JobStatus = .pending
    var result: OCRResult?

    enum JobStatus {
        case pending, processing, succeeded, failed
    }
}

struct OCRResult {
    let text: String?
    let errorMessage: String?
    let errorCode: String?
}

// MARK: - Tagging Job

struct TaggingJob: Identifiable {
    let id = UUID()
    let sourceURL: URL
    var status: JobStatus = .pending
    var appliedTags: [String] = []

    enum JobStatus {
        case pending, processing, succeeded, failed
    }
}
