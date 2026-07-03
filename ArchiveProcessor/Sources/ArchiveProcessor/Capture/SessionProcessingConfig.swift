import Foundation

/// A snapshot of every processing setting for a live-capture session. Built from the app's shared
/// settings stores when the operator confirms at session start, then **locked** once the first
/// segment is processed so every segment in the session is handled identically.
///
/// It reads the same UserDefaults / `@AppStorage` keys the Files tab uses (plus the API key from the
/// Keychain), so Live Capture and the Files tab share one source of truth.
struct SessionProcessingConfig {
    var provider: LLMProvider
    var model: LLMModel
    var thinkingLevel: ThinkingLevel
    var apiKey: String
    var taggingMode: TaggingMode
    var rotationMode: RotationMode
    var mergeDocuments: Bool
    var outputDirectory: URL
    var contextCharCount: Int
    var sendPreviousImage: Bool
    var customOCRPrompt: String
    var imageScale: Double            // 0…1 (fraction of full resolution)
    var enableSegmentJSON: Bool
    var tagVocabulary: [String]
    var gateway: GatewayConfig?

    /// Read the app's shared settings into a config snapshot.
    static func fromDefaults() -> SessionProcessingConfig {
        let d = UserDefaults.standard
        let provider = LLMProvider(rawValue: d.string(forKey: "selectedProvider") ?? "") ?? .gemini
        let modelId = d.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        let builtIns = provider.models
        let custom = CustomModelStore.shared.allCustomModels.filter { $0.provider == provider }
        let model = (builtIns + custom).first { $0.id == modelId } ?? builtIns.first ?? provider.models[0]

        let useGateway = d.bool(forKey: "useGateway")
        let gatewayBaseURL = d.string(forKey: "gatewayBaseURL") ?? ""
        let gatewayModelID = d.string(forKey: "gatewayModelID") ?? ""
        var gateway: GatewayConfig? = nil
        if useGateway, !gatewayBaseURL.isEmpty, !gatewayModelID.isEmpty {
            let inCost = d.object(forKey: "gatewayInputCost") as? Double ?? -1
            let outCost = d.object(forKey: "gatewayOutputCost") as? Double ?? -1
            let name = d.string(forKey: "gatewayDisplayName") ?? ""
            gateway = GatewayConfig(baseURL: gatewayBaseURL, modelID: gatewayModelID,
                                    displayName: name.isEmpty ? "API Gateway" : name,
                                    inputCostPer1M: inCost >= 0 ? inCost : nil,
                                    outputCostPer1M: outCost >= 0 ? outCost : nil)
        }

        let outURL: URL = {
            if let path = d.string(forKey: "outputDirectory"), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }()

        let apiKey = KeychainHelper.load(account: useGateway ? "Gateway" : provider.rawValue) ?? ""

        return SessionProcessingConfig(
            provider: provider,
            model: model,
            thinkingLevel: ThinkingLevel(rawValue: d.string(forKey: "selectedThinking") ?? "") ?? .low,
            apiKey: apiKey,
            taggingMode: TaggingMode(rawValue: d.string(forKey: "taggingModeRaw") ?? "") ?? .automatic,
            rotationMode: RotationMode(rawValue: d.string(forKey: "rotationModeRaw") ?? "") ?? .llmSingle,
            mergeDocuments: d.bool(forKey: "mergeDocuments"),
            outputDirectory: outURL,
            contextCharCount: Int(d.object(forKey: "contextCharCount") as? Double ?? 200),
            sendPreviousImage: d.bool(forKey: "sendPreviousImage"),
            customOCRPrompt: d.string(forKey: "customOCRPrompt") ?? "",
            imageScale: (d.object(forKey: "imageResolutionPercent") as? Double ?? 100) / 100.0,
            enableSegmentJSON: d.object(forKey: "enableSegmentJSON") as? Bool ?? true,
            tagVocabulary: (d.string(forKey: "tagVocabulary") ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            gateway: gateway
        )
    }

    /// The effective model for OCR calls (gateway model when a gateway is configured).
    var effectiveModel: LLMModel { gateway?.asLLMModel() ?? model }

    /// A short one-line summary for the control panel.
    var summary: String {
        "\(provider.rawValue) · \(gateway?.displayName ?? model.displayName) · \(taggingMode.displayName)"
    }
}
