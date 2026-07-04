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
    var outputImageFile: Bool         // two files (PDF + separate image) vs one file (PDF only)
    var pdfImageMB: Double            // target MB for the image embedded in the PDF (0 = full resolution)
    var exportedImageMB: Double       // target MB for the separately-exported image (0 = full resolution)

    /// Read the app's shared settings into a config snapshot.
    static func fromDefaults() -> SessionProcessingConfig {
        let d = UserDefaults.standard
        let provider = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        let modelId = d.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        let builtIns = provider.models
        let custom = CustomModelStore.shared.allCustomModels.filter { $0.provider == provider }
        let model = (builtIns + custom).first { $0.id == modelId } ?? builtIns.first ?? provider.models[0]

        let useGateway = d.bool(forKey: DefaultsKeys.useGateway)
        let gatewayBaseURL = d.string(forKey: DefaultsKeys.gatewayBaseURL) ?? ""
        let gatewayModelID = d.string(forKey: DefaultsKeys.gatewayModelID) ?? ""
        var gateway: GatewayConfig? = nil
        if useGateway, !gatewayBaseURL.isEmpty, !gatewayModelID.isEmpty {
            let inCost = d.object(forKey: DefaultsKeys.gatewayInputCost) as? Double ?? -1
            let outCost = d.object(forKey: DefaultsKeys.gatewayOutputCost) as? Double ?? -1
            let name = d.string(forKey: DefaultsKeys.gatewayDisplayName) ?? ""
            gateway = GatewayConfig(baseURL: gatewayBaseURL, modelID: gatewayModelID,
                                    displayName: name.isEmpty ? "API Gateway" : name,
                                    inputCostPer1M: inCost >= 0 ? inCost : nil,
                                    outputCostPer1M: outCost >= 0 ? outCost : nil)
        }

        let outURL: URL = {
            if let path = d.string(forKey: DefaultsKeys.outputDirectory), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }()

        let apiKey = KeychainHelper.load(account: useGateway ? "Gateway" : provider.rawValue) ?? ""

        return SessionProcessingConfig(
            provider: provider,
            model: model,
            thinkingLevel: ThinkingLevel(rawValue: d.string(forKey: DefaultsKeys.selectedThinking) ?? "") ?? .low,
            apiKey: apiKey,
            taggingMode: TaggingMode(rawValue: d.string(forKey: DefaultsKeys.taggingModeRaw) ?? "") ?? .automatic,
            rotationMode: RotationMode(rawValue: d.string(forKey: DefaultsKeys.rotationModeRaw) ?? "") ?? .llmSingle,
            mergeDocuments: d.bool(forKey: DefaultsKeys.mergeDocuments),
            outputDirectory: outURL,
            contextCharCount: Int(d.object(forKey: DefaultsKeys.contextCharCount) as? Double ?? 200),
            sendPreviousImage: d.bool(forKey: DefaultsKeys.sendPreviousImage),
            customOCRPrompt: d.string(forKey: DefaultsKeys.customOCRPrompt) ?? "",
            imageScale: (d.object(forKey: DefaultsKeys.imageResolutionPercent) as? Double ?? 100) / 100.0,
            enableSegmentJSON: d.object(forKey: DefaultsKeys.enableSegmentJSON) as? Bool ?? true,
            tagVocabulary: (d.string(forKey: DefaultsKeys.tagVocabulary) ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            gateway: gateway,
            outputImageFile: (d.object(forKey: DefaultsKeys.outputImageFile) as? Bool) ?? true,
            pdfImageMB: { let p = d.double(forKey: DefaultsKeys.pdfImageSizeMB); return p > 0 ? p : 2.0 }(),
            exportedImageMB: { let e = d.double(forKey: DefaultsKeys.exportedImageSizeMB); return e > 0 ? e : 3.0 }()
        )
    }

    /// The effective model for OCR calls (gateway model when a gateway is configured).
    var effectiveModel: LLMModel { gateway?.asLLMModel() ?? model }

    /// A short one-line summary for the control panel.
    var summary: String {
        "\(provider.rawValue) · \(gateway?.displayName ?? model.displayName) · \(taggingMode.displayName)"
    }
}
