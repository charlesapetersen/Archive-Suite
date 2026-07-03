import Foundation

// MARK: - Providers

enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic = "Anthropic"
    case gemini = "Gemini"
    case mistral = "Mistral"

    var id: String { rawValue }

    var models: [LLMModel] {
        let builtIn: [LLMModel]
        switch self {
        case .anthropic: builtIn = LLMModel.anthropicModels
        case .gemini: builtIn = LLMModel.geminiModels
        case .mistral: builtIn = LLMModel.mistralModels
        }
        let custom = CustomModelStore.shared.models(for: self)
        return builtIn + custom
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

// MARK: - Tagging Mode

/// How tags are assigned to document segments.
enum TaggingMode: String, CaseIterable, Identifiable, Codable {
    case none              // No tagging
    case copySource        // Copy macOS Finder tags from source images to output PDFs
    case automatic         // LLM generates all tags (date + subjects) — the original behavior
    case autoDate          // LLM segments + dates; the user enters subject tags
    case autoDateManualSeg // The user segments + enters subjects; the LLM fills each date
    case human             // The user segments and enters date + subject tags entirely

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "No tagging"
        case .copySource: return "Copy source file tags"
        case .automatic: return "Automatic (LLM)"
        case .autoDate: return "Auto date and segmentation, manual subjects"
        case .autoDateManualSeg: return "Auto date, manual segmentation & subjects"
        case .human: return "Manual (human)"
        }
    }

    var detail: String {
        switch self {
        case .none: return "Skip tagging entirely."
        case .copySource: return "Read macOS Finder tags from each source image and apply them to the output PDF. No LLM tagging."
        case .automatic: return "The model generates date and subject tags for every document segment."
        case .autoDate: return "The model determines the segmentation and date; you enter subject tags for each document segment."
        case .autoDateManualSeg: return "You group the images into segments and enter subject tags; the model fills in each document's date."
        case .human: return "You group the images into segments and enter the date and subject tags."
        }
    }

    /// Whether this mode performs LLM/segment-based tagging (drives segmentation review, box/folder confirm, and Phase 2).
    var enablesTagging: Bool { self != .none }

    /// Whether outputs from this mode get a trailing "Unread" tag. Applies to modes that generate
    /// real tags (date/subject/priority); excludes "No tagging" and "Copy source tags".
    var stampsUnread: Bool { self != .none && self != .copySource }

    /// Whether the user manually tags each segment (any mode with a manual tagging UI).
    var isManual: Bool { self == .autoDate || self == .autoDateManualSeg || self == .human }

    /// Whether the user defines segments themselves in the full-window manual UI.
    var usesManualSegmentationUI: Bool { self == .autoDateManualSeg || self == .human }

    /// Whether the LLM performs document segmentation in this mode. Only then do segmentation-context
    /// options (send previous page image, review segmentation) matter — otherwise the user segments
    /// (or there's no segmentation), so those settings are irrelevant.
    var llmSegments: Bool { self == .automatic || self == .autoDate }

    /// Whether the LLM makes per-segment tagging/date calls (drives the tagging cost/time estimate).
    /// Excludes `.human` (user enters everything), `.copySource`, and `.none` (no LLM tagging calls).
    var llmTags: Bool { self == .automatic || self == .autoDate || self == .autoDateManualSeg }

    /// Whether the LLM fills in the date automatically.
    var autoFillsDate: Bool { self == .autoDateManualSeg }

    /// Whether document start/continuation segmentation is meaningful in the rotation review
    /// (only the LLM-segmented modes; manual-segmentation modes own grouping in their own UI).
    var showsDocumentClassesInReview: Bool {
        self == .automatic || self == .autoDate
    }
}

// MARK: - Rotation Mode

/// How the app detects the rotation needed to make each scanned image upright.
enum RotationMode: String, CaseIterable, Identifiable, Codable {
    case off               // No rotation correction
    case localVision       // Free, local macOS Vision (fast, ~60% accurate on documents)
    case llmSingle         // One LLM "which-of-4-is-upright" comparative call
    case llmMajority       // Three comparative calls, majority vote (most accurate)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .localVision: return "Local (fast, free)"
        case .llmSingle: return "LLM comparative"
        case .llmMajority: return "LLM comparative ×3 (most accurate)"
        }
    }

    var detail: String {
        switch self {
        case .off: return "Do not correct rotation."
        case .localVision: return "On-device macOS Vision. Free and fast, but only ~60% accurate on rotated documents."
        case .llmSingle: return "Shows the model all four rotations and asks which is upright — one extra cheap API call per image."
        case .llmMajority: return "Repeats the comparison three times and takes the majority vote. Most accurate; three extra cheap API calls per image."
        }
    }

    /// Number of shuffled orderings to vote over (LLM modes only).
    var orderings: Int {
        switch self {
        case .llmMajority: return 3
        case .llmSingle: return 1
        default: return 0
        }
    }

    var usesLLM: Bool { self == .llmSingle || self == .llmMajority }
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
            id: "gemini-3.1-flash-lite",
            displayName: "Gemini 3.1 Flash Lite",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.25,
            outputCostPer1M: 1.50,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.5-flash",
            displayName: "Gemini 3.5 Flash",
            provider: .gemini,
            supportsThinking: true,
            returnsMd: false,
            inputCostPer1M: 1.50,
            outputCostPer1M: 9.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3.1-pro",
            displayName: "Gemini 3.1 Pro",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 2.0,
            outputCostPer1M: 12.0,
            batchDiscount: 0.5
        ),
        LLMModel(
            id: "gemini-3-flash-preview",
            displayName: "Gemini 3 Flash Preview",
            provider: .gemini,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: 0.50,
            outputCostPer1M: 3.0,
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
        case pending, processing, succeeded, failed, removed
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

// MARK: - Gateway Config

struct GatewayConfig: Codable, Equatable {
    var baseURL: String
    var modelID: String
    var displayName: String
    var inputCostPer1M: Double?
    var outputCostPer1M: Double?

    var apiKey: String {
        KeychainHelper.load(account: "Gateway") ?? ""
    }

    func asLLMModel() -> LLMModel {
        LLMModel(
            id: modelID,
            displayName: modelID,
            provider: .anthropic,
            supportsThinking: false,
            returnsMd: false,
            inputCostPer1M: inputCostPer1M ?? 0,
            outputCostPer1M: outputCostPer1M ?? 0,
            batchDiscount: 0
        )
    }
}

// MARK: - Custom Model Store

final class CustomModelStore: ObservableObject, @unchecked Sendable {
    static let shared = CustomModelStore()

    private static let storageKey = "customModels"

    @Published private(set) var allCustomModels: [LLMModel] = []

    private init() {
        allCustomModels = Self.load()
    }

    func models(for provider: LLMProvider) -> [LLMModel] {
        allCustomModels.filter { $0.provider == provider }
    }

    func add(_ model: LLMModel) {
        allCustomModels.append(model)
        save()
    }

    func remove(at offsets: IndexSet, provider: LLMProvider) {
        let providerModels = models(for: provider)
        let idsToRemove = offsets.map { providerModels[$0].id }
        allCustomModels.removeAll { idsToRemove.contains($0.id) }
        save()
    }

    func removeById(_ id: String) {
        allCustomModels.removeAll { $0.id == id }
        save()
    }

    func isCustom(_ model: LLMModel) -> Bool {
        allCustomModels.contains { $0.id == model.id && $0.provider == model.provider }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(allCustomModels) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private static func load() -> [LLMModel] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let models = try? JSONDecoder().decode([LLMModel].self, from: data) else { return [] }
        return models
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
