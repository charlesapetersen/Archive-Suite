import Foundation

/// A snapshot of every processing setting for a live-capture session. Built from the app's shared
/// settings stores when the operator confirms at session start, then **locked** once the first
/// segment is processed so every segment in the session is handled identically.
///
/// It reads the same UserDefaults / `@AppStorage` keys the Files tab uses (plus the API key from the
/// Keychain), so Live Capture and the Files tab share one source of truth.
struct SessionProcessingConfig: Sendable {
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
    var standardImageMB: Double = 3.0 // size target used to translate imageScale into dimensions
    var ocrWorkerCount: Int = 4        // parallel Process Files workers (1…12)
    var enableSegmentJSON: Bool
    var tagVocabulary: [String]
    var gateway: GatewayConfig?
    var outputImageFile: Bool         // two files (PDF + separate image) vs one file (PDF only)
    var pdfImageMB: Double            // target MB for the image embedded in the PDF (0 = full resolution)
    var exportedImageMB: Double       // target MB for the separately-exported image (0 = full resolution)
    var textColumns: Int              // number of text columns on the OCR text page (1 = single-column)
    /// The Local Agent (subscription-auth CLI) backend for this live session, or nil when using an
    /// API key / gateway. Threaded alongside `gateway` (Design decision 2 of the local-agent plan);
    /// populated from settings + preferred at the construction sites in a later checkpoint. Default
    /// nil keeps the existing `fromDefaults` memberwise-init call (which omits it) compiling unchanged.
    var localAgent: LocalAgentConfig? = nil

    /// Preserve the Process Files run-start normalization while the mutable statics are migrated to this
    /// config in W16.cfg2/3/5/6.
    static func normalizedImageMB(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? min(20, max(0.5, value)) : fallback
    }

    static func ocrWorkerCount(from defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: DefaultsKeys.ocrWorkerCount)
        return value > 0 ? min(12, max(1, value)) : 4
    }

    /// Read the app's shared settings into a config snapshot.
    static func fromDefaults(_ d: UserDefaults = .standard) -> SessionProcessingConfig {
        let provider = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        let modelId = d.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        let builtIns = provider.models
        let custom = CustomModelStore.shared.allCustomModels.filter { $0.provider == provider }
        let model = (builtIns + custom).first { $0.id == modelId } ?? builtIns.first ?? provider.models[0]

        let useGateway = d.bool(forKey: DefaultsKeys.useGateway)
        let gateway = GatewayConfig.fromDefaults(d)

        let outURL: URL = {
            if let path = d.string(forKey: DefaultsKeys.outputDirectory), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }()

        // API key: the Keychain in production. Headless test fallback (env-gated): a headless CI/E2E host
        // has no GUI Keychain, so when running under ARCHIVEPROC_HEADLESS and the Keychain has no key, fall
        // back to the LIVECAPTURE_OCRKEY env var — this lets the LIVE phone-driven pipeline OCR headlessly.
        // The key stays in the environment only (never written to disk or logged). PROD: env unset (or a
        // real Keychain key present) → the Keychain value, exactly as before.
        let keychainKey = KeychainHelper.load(account: useGateway ? "Gateway" : provider.rawValue) ?? ""
        let apiKey: String = {
            if !keychainKey.isEmpty { return keychainKey }
            let env = ProcessInfo.processInfo.environment
            if env["ARCHIVEPROC_HEADLESS"] != nil, let envKey = env["LIVECAPTURE_OCRKEY"], !envKey.isEmpty {
                return envKey
            }
            return keychainKey
        }()

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
            standardImageMB: normalizedImageMB(d.double(forKey: DefaultsKeys.standardImageSizeMB), fallback: 3.0),
            ocrWorkerCount: ocrWorkerCount(from: d),
            enableSegmentJSON: d.object(forKey: DefaultsKeys.enableSegmentJSON) as? Bool ?? true,
            tagVocabulary: (d.string(forKey: DefaultsKeys.tagVocabulary) ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            gateway: gateway,
            outputImageFile: (d.object(forKey: DefaultsKeys.outputImageFile) as? Bool) ?? true,
            pdfImageMB: { let p = d.double(forKey: DefaultsKeys.pdfImageSizeMB); return p > 0 ? p : 2.0 }(),
            exportedImageMB: { let e = d.double(forKey: DefaultsKeys.exportedImageSizeMB); return e > 0 ? e : 3.0 }(),
            textColumns: { let tc = d.integer(forKey: DefaultsKeys.textColumns); return tc > 1 ? min(4, tc) : 1 }(),
            localAgent: LocalAgentConfig.fromDefaults(d)
        )
    }

    /// Build the Process Files run snapshot with the exact normalization currently performed by
    /// `OCRProcessor.loadStandardImageMB()`. W16.cfg2 uses it for OCR scheduling and PDF generation;
    /// the remaining migration steps will move review/tagging and resume consumers onto the same snapshot.
    static func fromProcessFilesRunStart(_ d: UserDefaults = .standard) -> SessionProcessingConfig {
        var config = fromDefaults(d)
        config.standardImageMB = normalizedImageMB(
            d.double(forKey: DefaultsKeys.standardImageSizeMB), fallback: 3.0)
        config.ocrWorkerCount = ocrWorkerCount(from: d)
        config.pdfImageMB = normalizedImageMB(
            d.double(forKey: DefaultsKeys.pdfImageSizeMB), fallback: 2.0)
        config.exportedImageMB = normalizedImageMB(
            d.double(forKey: DefaultsKeys.exportedImageSizeMB), fallback: 3.0)
        let columns = d.integer(forKey: DefaultsKeys.textColumns)
        config.textColumns = min(4, max(1, columns))
        return config
    }

    /// The effective model for OCR calls (gateway model when a gateway is configured).
    var effectiveModel: LLMModel { gateway?.asLLMModel() ?? model }

    /// A short one-line summary for the control panel.
    var summary: String {
        "\(provider.rawValue) · \(gateway?.displayName ?? model.displayName) · \(taggingMode.displayName)"
    }
}
