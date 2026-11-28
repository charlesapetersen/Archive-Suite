import Foundation

/// W49.proc-settings-config-unify (`execution-plans/processor-settings-redesign.md` §3): the one value a run reads
/// for every processing setting, resolved once at Start (Process Files) or session start (Live Capture) and then held
/// unchanged. Codable so a pending run can carry it whole; never a credential, which is `RunCredentials` and is not
/// Codable, so no key can reach `pending_run.json`, `pending_batch.json` or the collection's run records.
///
/// What a run is given beside it, rather than resolved from Settings, stays on `SessionProcessingConfig`: the page
/// readers its file list chose, and the institutional-computing text it imports.
struct ResolvedRunConfig: Codable, Equatable, Sendable {
    // MARK: Reading
    var provider: LLMProvider
    var model: LLMModel
    var thinkingLevel: ThinkingLevel
    var gateway: GatewayConfig?
    /// Cost-history attribution for a gateway run; nil off the gateway.
    var gatewayUpstreamProvider: LLMProvider? = nil
    var localAgent: LocalAgentConfig? = nil
    var visionSettings: VisionOCRSettings = .default
    /// The text-only model of an Apple Vision run that also classifies and tags. Its key is in `RunCredentials`.
    var visionText: VisionTextRoute? = nil
    var cascade: OCRCascade = .off
    var customOCRPrompt: String
    var postCorrection = false
    var imageScale: Double            // 0…1 (fraction of full resolution)
    var standardImageMB: Double = 3.0 // size target used to translate imageScale into dimensions
    var ocrWorkerCount: Int = 4       // parallel Process Files workers (1…12)

    // MARK: Documents and dates
    var taggingMode: TaggingMode
    var segmentationApproach: SegmentationApproach = .manual
    var mergeDocuments: Bool
    var tagVocabulary: [String]
    var reviewRotation = false
    /// Process Files only. Frozen for the manual date cards and interrupted runs.
    var dateLocalImage = false
    var macItemFields = true

    // MARK: Output
    var outputDirectory: URL
    var rotationMode: RotationMode
    var enableSegmentJSON: Bool
    var outputImageFile: Bool         // two files (PDF + separate image) vs one file (PDF only)
    // 0 still means "full resolution" to the writers (`PDFGenerator`, `ImageEncoding`), but no defaults read can
    // produce it: a read of 0 (or of anything out of range) resolves to the 1.5 MB / 3 MB fallback. Only a direct
    // construction can pass the 0 sentinel through.
    var pdfImageMB: Double            // target MB for the image embedded in the PDF (0 = full resolution)
    var exportedImageMB: Double       // target MB for the separately-exported image (0 = full resolution)
    var textColumns: Int              // number of text columns on the OCR text page (1 = single-column)
    /// The general layer's `keepPreservationCopies`, read with the rest so a run keeps the answer it started with.
    var keepPreservationCopies = true
    /// The direct model an Apple Vision run hands its text to, without the key.
    struct VisionTextRoute: Codable, Equatable, Sendable {
        var provider: LLMProvider
        var model: LLMModel
        var thinkingLevel: ThinkingLevel?
    }

    /// The five sizing values, for comparing an injected snapshot against a defaults read.
    var runSizing: SessionProcessingConfig.RunSizing {
        .init(standardImageMB: standardImageMB, ocrWorkerCount: ocrWorkerCount,
              pdfImageMB: pdfImageMB, textColumns: textColumns, exportedImageMB: exportedImageMB)
    }

    /// The value a run record keeps beside the output, in a folder the user may share: a gateway address cut to scheme,
    /// host, port and path (`ProcessingSettingsCapture.withoutCredentials`), so nothing typed into the address leaves
    /// this Mac's store; the output folder as `/<its name>` and no Local Agent program path, so no path of this Mac's
    /// (a user name) goes with it. The same value again when applied twice.
    var forRecord: ResolvedRunConfig {
        var copy = self
        if var gateway = copy.gateway {
            gateway.baseURL = ProcessingSettingsCapture.withoutCredentials(gateway.baseURL)
            copy.gateway = gateway
        }
        copy.localAgent?.binaryPath = ""
        copy.outputDirectory = URL(fileURLWithPath: "/").appendingPathComponent(outputDirectory.lastPathComponent)
        return copy
    }

    /// A resumed run's config: this frozen one, with the backend, destination and prompt of `identity`, which the
    /// resume took from the pending record it checks the key against. A local date pass reads without a text model.
    func resumed(identity: ResolvedRunConfig) -> ResolvedRunConfig {
        var c = self
        c.provider = identity.provider
        c.model = identity.model
        c.thinkingLevel = identity.thinkingLevel
        c.gateway = identity.gateway
        c.localAgent = identity.localAgent
        c.outputDirectory = identity.outputDirectory
        c.customOCRPrompt = identity.customOCRPrompt
        c.enableSegmentJSON = identity.enableSegmentJSON
        if c.dateLocalImage { c.visionText = nil }
        return c
    }

    /// Read every processing setting from `UserDefaults` and the general settings layer, without the Keychain. The
    /// sizing values go through `SessionProcessingConfig.runSizing(_:)`, the one normalization every path uses.
    static func fromDefaults(_ d: UserDefaults = .standard,
                             keepPreservationCopies: Bool = true) -> ResolvedRunConfig {
        let sizing = SessionProcessingConfig.runSizing(d)
        let useAppleVision = d.bool(forKey: DefaultsKeys.useAppleVision)
        let useVisionLLMJudgment = useAppleVision && d.bool(forKey: DefaultsKeys.visionUseLLMJudgment)
        let selectedProvider = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        let provider: LLMProvider = useAppleVision ? .appleVision : selectedProvider
        // Ask `ModelSelectionStore` for the key rather than re-spelling `selectedModelId_<provider>` here: one drifted
        // string would silently snapshot the wrong model for a whole run. `provider.models` is already the built-ins
        // plus that provider's custom models.
        let modelId = d.string(forKey: ModelSelectionStore.modelKey(for: provider)) ?? ""
        let candidates = provider.models
        let model = candidates.first { $0.id == modelId } ?? candidates[0]
        let textModelId = d.string(forKey: ModelSelectionStore.modelKey(for: selectedProvider)) ?? ""
        let textCandidates = selectedProvider.models
        let visionTextModel = textCandidates.first { $0.id == textModelId } ?? textCandidates[0]
        let thinking = ThinkingLevel(rawValue: d.string(forKey: DefaultsKeys.selectedThinking) ?? "") ?? .low

        let gateway = useAppleVision ? nil : GatewayConfig.fromDefaults(d)
        let localAgent = useAppleVision ? nil : LocalAgentConfig.fromDefaults(d)

        let outURL: URL = {
            if let path = d.string(forKey: DefaultsKeys.outputDirectory), FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
        }()

        let savedTaggingMode = TaggingMode(rawValue: d.string(forKey: DefaultsKeys.taggingModeRaw) ?? "") ?? .automatic
        // Vision deliberately owns transcription only. Copying existing source tags remains local metadata work, but
        // every mode that asks the selected backend to classify, date, segment, or generate tags must be turned off
        // even when stale defaults bypass the Settings picker.
        let taggingMode: TaggingMode = useAppleVision && !useVisionLLMJudgment && savedTaggingMode != .copySource
            ? .none : savedTaggingMode

        return ResolvedRunConfig(
            provider: provider,
            model: model,
            thinkingLevel: thinking,
            gateway: gateway,
            gatewayUpstreamProvider: gateway == nil ? nil : OCRProcessor.gatewayUpstreamProviderFromDefaults(d),
            localAgent: localAgent,
            visionSettings: VisionOCRSettings.fromDefaults(d),
            visionText: useVisionLLMJudgment
                ? VisionTextRoute(provider: selectedProvider, model: visionTextModel,
                                  thinkingLevel: visionTextModel.supportsThinking ? thinking : nil)
                : nil,
            cascade: OCRCascade.fromDefaults(d),
            customOCRPrompt: d.string(forKey: DefaultsKeys.customOCRPrompt) ?? "",
            imageScale: (d.object(forKey: DefaultsKeys.imageResolutionPercent) as? Double ?? 100) / 100.0,
            standardImageMB: sizing.standardImageMB,
            ocrWorkerCount: sizing.ocrWorkerCount,
            taggingMode: taggingMode,
            segmentationApproach: SegmentationApproach.stored(d),
            mergeDocuments: d.bool(forKey: DefaultsKeys.mergeDocuments),
            tagVocabulary: (d.string(forKey: DefaultsKeys.tagVocabulary) ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            reviewRotation: d.bool(forKey: DefaultsKeys.reviewRotation),
            macItemFields: d.object(forKey: DefaultsKeys.macItemFields) == nil
                || d.bool(forKey: DefaultsKeys.macItemFields),
            outputDirectory: outURL,
            rotationMode: SessionProcessingConfig.defaultRotationMode(d),
            enableSegmentJSON: d.bool(forKey: DefaultsKeys.enableSegmentJSON),
            outputImageFile: (d.object(forKey: DefaultsKeys.outputImageFile) as? Bool) ?? true,
            pdfImageMB: sizing.pdfImageMB,
            exportedImageMB: sizing.exportedImageMB,
            textColumns: sizing.textColumns,
            keepPreservationCopies: keepPreservationCopies
        )
    }
}

/// The keys a run needs, loaded at its start and never written anywhere (`ResolvedRunConfig` holds everything else).
struct RunCredentials: Sendable {
    /// The OCR backend's key: the provider's, the gateway's, or empty for Apple Vision and a Local Agent.
    var apiKey: String
    /// The key of `ResolvedRunConfig.visionText`'s provider; empty when there is none.
    var visionTextAPIKey: String = ""
}
