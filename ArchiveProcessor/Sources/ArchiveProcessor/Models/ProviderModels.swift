import Foundation

// MARK: - Providers

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
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

    var supportsBatch: Bool {
        switch self {
        case .anthropic, .gemini, .mistral: return true
        }
    }
}

// MARK: - Thinking Level

enum ThinkingLevel: String, CaseIterable, Identifiable, Codable {
    case low = "Low"
    case high = "High"
    var id: String { rawValue }
}

// MARK: - Document Classification

enum DocumentClassification: String, Codable {
    case boxLabel = "box_label"
    case folderLabel = "folder_label"
    case documentStart = "document_start"
    case documentContinuation = "document_continuation"

    var displayName: String {
        switch self {
        case .boxLabel: return "Box"
        case .folderLabel: return "Folder"
        case .documentStart: return "Document Start"
        case .documentContinuation: return "Continuation"
        }
    }
}

// MARK: - Models

struct LLMModel: Identifiable, Hashable, Codable {
    let id: String
    let displayName: String
    let provider: LLMProvider
    let supportsThinking: Bool
    let returnsMd: Bool
    let inputCostPer1M: Double
    let outputCostPer1M: Double
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
    var classification: DocumentClassification?
    var appliedTags: [String] = []

    enum JobStatus {
        case pending, processing, succeeded, failed
    }
}

struct OCRResult: Codable {
    let text: String?
    let classification: DocumentClassification?
    /// Clockwise rotation in degrees needed to correct image orientation (0, 90, 180, 270).
    let rotationDegrees: Int
    let errorMessage: String?
    let errorCode: String?

    init(text: String?, classification: DocumentClassification?, rotationDegrees: Int = 0, errorMessage: String?, errorCode: String?) {
        self.text = text
        self.classification = classification
        self.rotationDegrees = rotationDegrees
        self.errorMessage = errorMessage
        self.errorCode = errorCode
    }
}

// MARK: - Segmentation Context

struct SegmentationContext {
    /// Characters of previous page's OCR text to include as context
    var previousTextCharCount: Int = 200
    /// Whether to send the full previous page image for higher accuracy
    var sendPreviousImage: Bool = false
    /// Optional custom prompt appended to OCR instructions
    var customPrompt: String? = nil
    /// Image resolution scale factor (0.2–1.0). 1.0 = full resolution.
    var imageScale: Double = 1.0
}
