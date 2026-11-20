import Foundation

/// How much of the Settings window a user sees (W47.settings-level-switch; `execution-plans/processing-review/settings-design/
/// levels.md` §3-4, approved by the owner 2026-11-19). A level only decides which rows are shown: it never changes a
/// value, a default or what the solver picks. Chosen in Settings › General and asked at the end of the setup questions;
/// a new user, and one who skips the questions, starts at Basic. It describes the person, not the material, so it is
/// kept for the whole app (`DefaultsKeys.settingsLevel`), never by a collection, and no run records it.
enum SettingsLevel: String, CaseIterable, Identifiable, Comparable, Sendable {
    case basic, standard, advanced

    var id: String { rawValue }

    static let defaultLevel = SettingsLevel.basic

    var title: String {
        switch self {
        case .basic: return "Basic"
        case .standard: return "Standard"
        case .advanced: return "Advanced"
        }
    }

    /// What the level shows, in the words of the design (§3).
    var detail: String {
        switch self {
        case .basic:
            return "The setup questions and the app's measured picks choose everything. You see each stage's pick with its figures, the limits, the keys and sign-ins, the output folder, tagging and capture."
        case .standard:
            return "Every choice the measurements support as well: choosing another route for a stage, the backend and model, switches with a measured cost or gain, image sizes, rotation and segmentation review."
        case .advanced:
            return "Everything else as well: routes that scored below what ships, switches with no measured gain, and the raw technical fields. Each such row says why it is here."
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: SettingsLevel, b: SettingsLevel) -> Bool { a.rank < b.rank }

    /// The level stored for this app; Basic when none is.
    static func current(_ defaults: UserDefaults = .standard) -> SettingsLevel {
        defaults.string(forKey: DefaultsKeys.settingsLevel).flatMap(SettingsLevel.init(rawValue:)) ?? defaultLevel
    }
}

/// Every row of the Settings window with its level (`levels.md` §4), the stored keys it sets, and for an Advanced row
/// the reason it sits there, in the words its route row uses. `SettingsLevelsTestDriver` holds every key a panel owns
/// (`SettingsPanelOwnership`) and every catalog key to exactly one row, and every route row of the measured table to a
/// level (`level(of:)`).
enum SettingsLevels {
    struct Row: Identifiable, Sendable {
        let id: String
        let level: SettingsLevel
        let keys: [String]
        /// Why an Advanced row is not Standard (§4's "why" column); nil below Advanced.
        let why: String?

        init(_ id: String, _ level: SettingsLevel, _ keys: [String], why: String? = nil) {
            self.id = id
            self.level = level
            self.keys = keys
            self.why = why
        }
    }

    static let rows: [Row] = [
        .appearance, .level, .setupQuestions, .collection, .keys, .skipProcessed, .straighten, .taggingMode, .capture,
        .overrides, .backend, .providerModel, .cascade, .pageKind, .handwritingOnTyped, .visionLanguages,
        .visionJudgement, .gatewayLocal, .cliAgent, .preOCRed, .batch, .outputSizes, .rotation, .vocabularyColours,
        .collectionID, .segmentationReview, .segmentationApproach, .dateImage, .placeHand, .searchable, .downloads,
        .driveRelay, .thinking, .cascadeDisagreement, .visionTuning, .gatewayFields, .cliFields, .customModels,
        .imageSize, .workers, .logFile, .previousImage, .customPrompt, .localSegmenter,
    ]

    /// The level of a stored key: the level of the one row that sets it.
    static func level(ofKey key: String) -> SettingsLevel? { rows.first { $0.keys.contains(key) }?.level }

    /// Whether a row is drawn: at its level or above, and at every level while its value differs from its default
    /// (a Basic user never runs a setting they cannot see).
    static func shows(_ row: Row, at current: SettingsLevel, changed: Bool) -> Bool {
        current >= row.level || changed
    }

    // MARK: Changed from its default

    /// A stored key's built-in value, as the panel that owns it declares it; nil for a key whose every stored value
    /// counts as a change (a Keychain account, read only by its panel).
    static func defaultValue(_ key: String) -> AnyHashable? {
        if let p = LLMProvider.allCases.first(where: { ModelSelectionStore.modelKey(for: $0) == key }) {
            return p.models.first?.id ?? ""
        }
        switch key {
        case DefaultsKeys.selectedThinking: return ThinkingLevel.low.rawValue
        case DefaultsKeys.selectedProvider: return LLMProvider.gemini.rawValue
        case DefaultsKeys.gatewayUpstreamProvider: return LLMProvider.anthropic.rawValue
        case DefaultsKeys.localAgentTool: return LocalAgentTool.claude.rawValue
        case DefaultsKeys.rotationModeRaw: return RotationMode.standard.rawValue
        case DefaultsKeys.segmentationApproach: return SegmentationApproach.defaultApproach.rawValue
        case DefaultsKeys.segmentationClaudeRoute: return ClaudeRoute.apiKey.rawValue
        case DefaultsKeys.localSegmenterBaseURL: return LocalSegmenter.defaultBaseURL
        case DefaultsKeys.localSegmenterModelID: return LocalSegmenter.defaultModelID
        case DefaultsKeys.visionLanguages: return "en-US"
        case DefaultsKeys.gatewayBaseURL, DefaultsKeys.gatewayModelID, DefaultsKeys.gatewayDisplayName,
             DefaultsKeys.visionCustomVocabulary, DefaultsKeys.ocrCascadeRoute, DefaultsKeys.localAgentBinaryPath,
             DefaultsKeys.localAgentModel, DefaultsKeys.tagVocabulary, DefaultsKeys.customOCRPrompt,
             DefaultsKeys.localSegmenterPartner, DefaultsKeys.driveClientId:
            return ""
        case DefaultsKeys.useGateway, DefaultsKeys.useLocalAgent, DefaultsKeys.useAppleVision, DefaultsKeys.gatewayLocalModel,
             DefaultsKeys.gatewayLocalEscalates, DefaultsKeys.visionUseLLMJudgment, DefaultsKeys.visionFastRecognition,
             DefaultsKeys.ocrCascadeOnDisagreement, DefaultsKeys.ocrPageKindRouting, DefaultsKeys.ocrHandwritingOnTyped,
             DefaultsKeys.preOCRedInput, DefaultsKeys.batchMode, DefaultsKeys.reviewRotation,
             DefaultsKeys.enableCollectionSegmentation, DefaultsKeys.confirmCollectionIDs,
             DefaultsKeys.reviewDocumentSegmentation, DefaultsKeys.mergeDocuments, DefaultsKeys.sendPreviousImage,
             DefaultsKeys.writeLogFile:
            return false
        case DefaultsKeys.outputImageFile, DefaultsKeys.enableSegmentJSON: return true
        case DefaultsKeys.visionMinimumConfidence: return 0.0
        case DefaultsKeys.gatewayInputCost, DefaultsKeys.gatewayOutputCost: return -1.0
        case DefaultsKeys.imageResolutionPercent: return 100.0
        case DefaultsKeys.standardImageSizeMB, DefaultsKeys.exportedImageSizeMB: return 3.0
        case DefaultsKeys.pdfImageSizeMB: return 2.0
        case DefaultsKeys.ocrWorkerCount: return 4.0
        case DefaultsKeys.textColumns: return 1.0
        case DefaultsKeys.itemTypeColourBox, DefaultsKeys.itemTypeColourFolder: return 0.0
        default: return nil
        }
    }

    /// Whether a stored key holds something other than its built-in value. Numbers compare as numbers, so a Double
    /// stored for an Int setting (or `normalizeSizingDefaults` writing back the default) is no change.
    static func changed(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        if key.hasPrefix("keychain:") { return false }   // never read while drawing; the Accounts panel shows each
        guard let stored = defaults.object(forKey: key) else { return false }
        guard let builtIn = defaultValue(key) else { return true }
        switch (stored, builtIn) {
        case let (s as String, d as String): return s != d
        case let (s as NSNumber, d as Bool): return s.boolValue != d
        case let (s as NSNumber, d as Double): return abs(s.doubleValue - d) > 1e-9
        default: return true   // a value of another kind than the setting's own
        }
    }

    /// Whether any of a row's stored keys differs from its default. Layered keys (the sheet's switches, the
    /// interviews) are judged by the views that resolve them, and the card overrides by their card.
    static func changed(_ row: Row, in defaults: UserDefaults = .standard) -> Bool {
        row.keys.contains { changed($0, in: defaults) }
    }

    /// Puts a row back to its built-in values: its stored keys are removed, so each reads its default again.
    static func reset(_ row: Row, in defaults: UserDefaults = .standard) {
        for key in row.keys where !key.hasPrefix("keychain:") && SettingsKey(rawValue: key).isKnown == false {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Route rows

    /// The level of a measured route row (§3-4): a row the notes keep as a loss or a floor (`offered == false`,
    /// rule (a)) and a trained model admitted under the kit gate's minimums (`afterTraining`, rule (c), owner's call)
    /// are Advanced; every other row is a choice the bench supports, Standard. The card's own pick is shown at every
    /// level, and the solver never picks an Advanced row.
    static func level(of route: SettingsRouteTable.Route) -> SettingsLevel {
        (!route.offered || route.afterTraining) ? .advanced : .standard
    }

    /// Why an Advanced route row sits there, in its route row's own words.
    static func why(_ route: SettingsRouteTable.Route) -> String? {
        if route.afterTraining { return "a trained model checked on a small held-out set" }
        if !route.offered {
            return route.conditions.first { $0.hasPrefix("not offered") || $0.hasPrefix("never offered") }
        }
        return nil
    }
}

/// Every row of §4, by name (`SettingsLevels.rows` lists them all).
extension SettingsLevels.Row {
    // MARK: Basic

    static let appearance = Self("appearance", .basic, ["archiveAppearance"])   // AppAppearance.defaultsKey
    static let level = Self("level", .basic, [DefaultsKeys.settingsLevel])
    static let setupQuestions = Self("setup-questions", .basic, SettingsKey.generalOnly.map(\.rawValue))
    static let collection = Self("collection", .basic, [DefaultsKeys.outputDirectory]
         + SettingsKey.anyLayer.filter { !SettingsPanelOwnership.sheetSwitches.contains($0) }.map(\.rawValue))
    static let keys = Self("keys", .basic, ["keychain:Gateway"]
         + LLMProvider.allCases.filter { $0 != .appleVision }.map { "keychain:\($0.rawValue)" })
    static let skipProcessed = Self("skip-processed", .basic, [DefaultsKeys.skipAlreadyProcessed])
    static let straighten = Self("straighten", .basic, [SettingsKey.straightenReadingCopy.rawValue])
    static let taggingMode = Self("tagging-mode", .basic, [DefaultsKeys.taggingModeRaw])
    static let capture = Self("capture", .basic, [DefaultsKeys.liveProcessingMode, DefaultsKeys.readContainerLabels])

    // MARK: Standard

    static let overrides = Self("overrides", .standard,
                                SettingsSheetModel.cardStages.map { SettingsSheetModel.overrideKey($0).rawValue })
    static let backend = Self("backend", .standard, [DefaultsKeys.useGateway, DefaultsKeys.useLocalAgent, DefaultsKeys.useAppleVision])
    static let providerModel = Self("provider-model", .standard, [DefaultsKeys.selectedProvider]
         + LLMProvider.allCases.map { ModelSelectionStore.modelKey(for: $0) })
    static let cascade = Self("cascade", .standard, [DefaultsKeys.ocrCascadeRoute])
    static let pageKind = Self("page-kind", .standard, [DefaultsKeys.ocrPageKindRouting])
    static let handwritingOnTyped = Self("handwriting-on-typed", .standard, [DefaultsKeys.ocrHandwritingOnTyped])
    static let visionLanguages = Self("vision-languages", .standard, [DefaultsKeys.visionLanguages])
    static let visionJudgement = Self("vision-judgement", .standard, [DefaultsKeys.visionUseLLMJudgment])
    static let gatewayLocal = Self("gateway-local", .standard, [DefaultsKeys.gatewayLocalModel, DefaultsKeys.gatewayLocalEscalates])
    static let cliAgent = Self("cli-agent", .standard, [DefaultsKeys.localAgentTool])
    static let preOCRed = Self("pre-ocred", .standard, [DefaultsKeys.preOCRedInput])
    static let batch = Self("batch", .standard, [DefaultsKeys.batchMode])
    static let outputSizes = Self("output-sizes", .standard, [DefaultsKeys.pdfImageSizeMB, DefaultsKeys.outputImageFile,
                                                              DefaultsKeys.exportedImageSizeMB, DefaultsKeys.textColumns])
    static let rotation = Self("rotation", .standard, [DefaultsKeys.rotationModeRaw, DefaultsKeys.reviewRotation])
    static let vocabularyColours = Self("vocabulary-colours", .standard,
                                        [DefaultsKeys.tagVocabulary, DefaultsKeys.itemTypeColourBox, DefaultsKeys.itemTypeColourFolder])
    static let collectionID = Self("collection-id", .standard,
                                   [DefaultsKeys.enableCollectionSegmentation, DefaultsKeys.confirmCollectionIDs])
    static let segmentationReview = Self("segmentation-review", .standard,
                                         [DefaultsKeys.reviewDocumentSegmentation, DefaultsKeys.mergeDocuments, DefaultsKeys.enableSegmentJSON])
    static let segmentationApproach = Self("segmentation-approach", .standard,
                                           [DefaultsKeys.segmentationApproach, DefaultsKeys.segmentationClaudeRoute])
    static let dateImage = Self("date-image", .standard, [SettingsKey.dateImageEveryDocument.rawValue])
    static let placeHand = Self("place-hand", .standard, [SettingsKey.placeHandOnImage.rawValue])
    static let searchable = Self("searchable", .standard, [SettingsKey.searchableFor.rawValue])
    static let downloads = Self("downloads", .standard, [])
    static let driveRelay = Self("drive-relay", .standard, [DefaultsKeys.driveClientId, "keychain:DriveClientSecret"])

    // MARK: Advanced: the twelve groups the owner moved (2026-11-19, levels.md §4)

    static let thinking = Self("thinking", .advanced, [DefaultsKeys.selectedThinking],
                               why: "no measured figure compares Low thinking with High")
    static let cascadeDisagreement = Self("cascade-disagreement", .advanced, [DefaultsKeys.ocrCascadeOnDisagreement],
                                          why: "opt-in, with no measured gain over escalating failed pages alone")
    static let visionTuning = Self("vision-tuning", .advanced,
                                   [DefaultsKeys.visionFastRecognition, DefaultsKeys.visionMinimumConfidence, DefaultsKeys.visionCustomVocabulary],
                                   why: "none of these is measured on the bench")
    static let gatewayFields = Self("gateway-fields", .advanced,
                                    [DefaultsKeys.gatewayBaseURL, DefaultsKeys.gatewayModelID, DefaultsKeys.gatewayDisplayName,
                                     DefaultsKeys.gatewayInputCost, DefaultsKeys.gatewayOutputCost, DefaultsKeys.gatewayUpstreamProvider],
                                    why: "raw fields; the presets fill them")
    static let cliFields = Self("cli-fields", .advanced, [DefaultsKeys.localAgentBinaryPath, DefaultsKeys.localAgentModel],
                                why: "raw fields; left blank, the CLI is found and uses its own model")
    static let customModels = Self("custom-models", .advanced, [], why: "raw fields")
    static let imageSize = Self("image-size", .advanced, [DefaultsKeys.imageResolutionPercent, DefaultsKeys.standardImageSizeMB],
                                why: "the bench sends 2,048 px at 0.85; no figure is measured for other sizes")
    static let workers = Self("workers", .advanced, [DefaultsKeys.ocrWorkerCount], why: "throughput only")
    static let logFile = Self("log-file", .advanced, [DefaultsKeys.writeLogFile], why: "a diagnostic")
    static let previousImage = Self("previous-image", .advanced, [DefaultsKeys.sendPreviousImage],
                                    why: "no measured figure for the switch itself")
    static let customPrompt = Self("custom-prompt", .advanced, [DefaultsKeys.customOCRPrompt], why: "a raw field")
    static let localSegmenter = Self("local-segmenter", .advanced,
                                     [DefaultsKeys.localSegmenterBaseURL, DefaultsKeys.localSegmenterModelID, DefaultsKeys.localSegmenterPartner],
                                     why: "raw fields; the app's server and model are the ones measured")
}
