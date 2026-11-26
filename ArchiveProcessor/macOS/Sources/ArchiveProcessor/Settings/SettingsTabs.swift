import Foundation
import ArchiveCore

/// The Settings window's five tabs (W49.proc-settings-redesign-core; `execution-plans/processor-settings-redesign.md`
/// §5, Option B, approved by the owner 2026-11-25), in the toolbar's order. Every setting has one home tab
/// (`SettingsTabOwnership`); Process Files' Tagging picker and segmentation chooser write the same keys as shortcuts.
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case processing, output, capture, accounts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processing: return "Processing"
        case .output: return "Output"
        case .capture: return "Capture"
        case .accounts: return "Accounts"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .processing: return "text.viewfinder"
        case .output: return "doc.richtext"
        case .capture: return "camera"
        case .accounts: return "key"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// The words a shortcut uses to name the setting's home, e.g. "Settings › Processing".
    var home: String { "Settings › \(title)" }
}

/// Which tab sets each stored key: the one place it is set, so no key has two homes in the window.
/// `SettingsTabsTestDriver` checks the table, and `scripts/test-settings-tabs.sh` checks that each tab's file stores only
/// the keys this table gives it.
enum SettingsTabOwnership {
    /// `DefaultsKeys` names, layered `SettingsKey` raw values and Keychain accounts (`keychain:<account>`).
    static let owners: [(key: String, tab: SettingsTab)] = {
        var out: [(String, SettingsTab)] = []
        func add(_ tab: SettingsTab, _ keys: [String]) { out += keys.map { ($0, tab) } }

        add(.processing, [
            AppAppearance.defaultsKey, DefaultsKeys.outputDirectory,
            DefaultsKeys.selectedProvider, DefaultsKeys.useGateway, DefaultsKeys.useLocalAgent, DefaultsKeys.useAppleVision,
            DefaultsKeys.visionLanguages, DefaultsKeys.visionUseLLMJudgment, DefaultsKeys.ocrPageKindRouting,
            DefaultsKeys.taggingModeRaw, DefaultsKeys.segmentationApproach, DefaultsKeys.segmentationClaudeRoute,
            DefaultsKeys.localSegmenterPartner, DefaultsKeys.reviewDocumentSegmentation, DefaultsKeys.mergeDocuments,
            DefaultsKeys.enableCollectionSegmentation, DefaultsKeys.confirmCollectionIDs, DefaultsKeys.macItemFields,
            DefaultsKeys.batchMode,
            SettingsKey.numericDatesDayFirst.rawValue, SettingsKey.dateImageEveryDocument.rawValue,
            SettingsKey.staysOnMac.rawValue, SettingsKey.noTraining.rawValue, SettingsKey.moneyHabit.rawValue,
            SettingsKey.monthCeilingUSD.rawValue, SettingsKey.batchCeilingUSD.rawValue, SettingsKey.cluster.rawValue,
        ] + LLMProvider.allCases.map { ModelSelectionStore.modelKey(for: $0) })
        add(.output, [
            SettingsKey.keepPreservationCopies.rawValue, SettingsKey.straightenReadingCopy.rawValue,
            SettingsKey.searchableFor.rawValue,   // the PDF form; Advanced holds its per-format editor
            DefaultsKeys.pdfImageSizeMB, DefaultsKeys.textColumns, DefaultsKeys.outputImageFile,
            DefaultsKeys.exportedImageSizeMB, DefaultsKeys.rotationModeRaw, DefaultsKeys.reviewRotation,
            DefaultsKeys.skipAlreadyProcessed, DefaultsKeys.itemTypeColourBox, DefaultsKeys.itemTypeColourFolder,
            DefaultsKeys.tagVocabulary,
        ])
        add(.capture, [
            DefaultsKeys.liveProcessingMode, DefaultsKeys.readContainerLabels, DefaultsKeys.driveClientId,
            "keychain:DriveClientSecret",
        ])
        add(.accounts, [DefaultsKeys.localAgentTool, "keychain:Gateway"]
            + LLMProvider.allCases.filter { $0 != .appleVision }.map { "keychain:\($0.rawValue)" })
        add(.advanced, SettingsAdvanced.groups.flatMap { $0.keys + $0.layered.filter { $0 != .searchableFor }.map(\.rawValue) } + [
            DefaultsKeys.gatewayBaseURL, DefaultsKeys.gatewayModelID, DefaultsKeys.gatewayDisplayName,
            DefaultsKeys.gatewayInputCost, DefaultsKeys.gatewayOutputCost, DefaultsKeys.gatewayUpstreamProvider,
            DefaultsKeys.gatewayLocalModel, DefaultsKeys.gatewayLocalEscalates,
        ])
        return out
    }()

    /// The controls outside the Settings window that write a key a tab owns, and the key each writes.
    static let shortcuts: [(control: String, key: String)] = [
        ("Process Files › Tagging", DefaultsKeys.taggingModeRaw),
        ("Process Files › Segmentation", DefaultsKeys.segmentationApproach),
    ]

    /// The tab that owns `key`, or nil when no tab sets it.
    static func owner(of key: String) -> SettingsTab? { owners.first { $0.key == key }?.tab }

    /// The line a shortcut shows under its control.
    static func shortcutNote(_ key: String) -> String? {
        owner(of: key).map { "Also set in \($0.home); a change here changes it there." }
    }
}

/// A measured route's tier: Standard routes are offered in every picker; Advanced ones (losses, floors, trained models
/// under the kit gate's minimums and the lower-scoring readers of owner call 15) only while Settings › Advanced ›
/// "Offer lower-scoring and experimental choices" is on, or while one is the current choice.
enum RouteTier: String, Comparable, Sendable {
    case standard, advanced

    private var rank: Int { self == .standard ? 0 : 1 }
    static func < (a: RouteTier, b: RouteTier) -> Bool { a.rank < b.rank }

    /// The highest tier the user is offered now.
    static func current(_ defaults: UserDefaults = .standard) -> RouteTier {
        defaults.bool(forKey: DefaultsKeys.offerExperimentalRoutes) ? .advanced : .standard
    }
}

/// The Advanced tab's settings (`processor-settings-redesign.md` §5.5): each group with the keys it sets, the reason
/// it sits in Advanced, and what "changed from its default" means, so the Processing tab can say how many are in use
/// and put them back (`activeGroups`, `reset`).
enum SettingsAdvanced {
    struct Group: Identifiable, Sendable {
        let id: String
        let title: String
        /// Plain `UserDefaults` keys.
        let keys: [String]
        /// Layered keys (`SettingsKey`), judged on the value the layers resolve.
        let layered: [SettingsKey]
        /// Why it is in Advanced, in the measured words.
        let why: String

        init(_ id: String, _ title: String, keys: [String] = [], layered: [SettingsKey] = [], why: String) {
            self.id = id
            self.title = title
            self.keys = keys
            self.layered = layered
            self.why = why
        }
    }

    static let groups: [Group] = [
        Group("experimental", "Lower-scoring and experimental choices", keys: [DefaultsKeys.offerExperimentalRoutes],
              why: "each scored below what ships on the bench, or has no measured gain"),
        Group("post-correction", "OCR post-correction", keys: [DefaultsKeys.ocrPostCorrection],
              why: "an extra paid reading with mixed results"),
        Group("date-local-image", "Search page images for dates on this Mac", layered: [.dateLocalImage],
              why: "the extra pass took about 12 seconds per document on the test Mac, with no measured gain"),
        Group("low-confidence-names", "Find names on this Mac (low confidence)", layered: [.lowConfidenceNames],
              why: "the finder can miss names or assign them to the wrong role"),
        Group("scan-newspapers", "Scanned-newspaper detector", layered: [.scanNewspapersDocLayoutYOLO],
              why: "an optional download, measured on 15 scanned newspapers only"),
        Group("place-hand", "Place handwritten text on the page image", layered: [.placeHandOnImage],
              why: "about 7.5 seconds a handwritten page and up to 8.5 GB of memory, for a layer kept on 9 of 20 test pages"),
        Group("thinking", "Thinking level", keys: [DefaultsKeys.selectedThinking],
              why: "no measured figure compares Low thinking with High"),
        Group("cascade", "Escalate failed pages", keys: [DefaultsKeys.ocrCascadeRoute, DefaultsKeys.ocrCascadeOnDisagreement],
              why: "a second paid model for the pages the first one fails"),
        Group("vision-tuning", "Apple Vision tuning",
              keys: [DefaultsKeys.visionFastRecognition, DefaultsKeys.visionMinimumConfidence, DefaultsKeys.visionCustomVocabulary],
              why: "none of these is measured on the bench"),
        Group("cli-fields", "Command-line agent path and model",
              keys: [DefaultsKeys.localAgentBinaryPath, DefaultsKeys.localAgentModel],
              why: "raw fields; left blank, the CLI is found and uses its own model"),
        Group("local-segmenter", "Local segmenter server",
              keys: [DefaultsKeys.localSegmenterBaseURL, DefaultsKeys.localSegmenterModelID],
              why: "raw fields; the app's server and model are the ones measured"),
        Group("custom-prompt", "Custom OCR prompt", keys: [DefaultsKeys.customOCRPrompt], why: "a raw field"),
        Group("pre-ocred", "Pre-OCRed PDF input", keys: [DefaultsKeys.preOCRedInput],
              why: "for PDFs that already carry text; it skips reading"),
        Group("searchable", "Per-format searchable pages", layered: [.searchableFor],
              why: "a finer choice than the Output tab's PDF format"),
        Group("previous-image", "Send previous page image", keys: [DefaultsKeys.sendPreviousImage],
              why: "no measured figure for the switch itself"),
        Group("image-size", "Image send size", keys: [DefaultsKeys.imageResolutionPercent, DefaultsKeys.standardImageSizeMB],
              why: "the bench sends 2,048 px at 0.85; no figure is measured for other sizes"),
        Group("workers", "Parallel OCR workers", keys: [DefaultsKeys.ocrWorkerCount], why: "throughput only"),
        Group("segment-json", "Export segment JSON", keys: [DefaultsKeys.enableSegmentJSON],
              why: "the catalogue record already keeps what it holds"),
        Group("log-file", "Processing log file", keys: [DefaultsKeys.writeLogFile], why: "a diagnostic"),
    ]

    static func group(_ id: String) -> Group? { groups.first { $0.id == id } }

    // MARK: Changed from its default

    /// A stored key's built-in value, as the control that sets it declares it; nil for a key whose every stored value
    /// counts as a change.
    static func defaultValue(_ key: String) -> AnyHashable? {
        switch key {
        case DefaultsKeys.selectedThinking: return ThinkingLevel.low.rawValue
        case DefaultsKeys.localSegmenterBaseURL: return LocalSegmenter.defaultBaseURL
        case DefaultsKeys.localSegmenterModelID: return LocalSegmenter.defaultModelID
        case DefaultsKeys.visionCustomVocabulary, DefaultsKeys.ocrCascadeRoute, DefaultsKeys.localAgentBinaryPath,
             DefaultsKeys.localAgentModel, DefaultsKeys.customOCRPrompt:
            return ""
        case DefaultsKeys.offerExperimentalRoutes, DefaultsKeys.ocrPostCorrection, DefaultsKeys.visionFastRecognition,
             DefaultsKeys.ocrCascadeOnDisagreement, DefaultsKeys.preOCRedInput, DefaultsKeys.sendPreviousImage,
             DefaultsKeys.writeLogFile, DefaultsKeys.enableSegmentJSON:
            return false
        case DefaultsKeys.visionMinimumConfidence: return 0.0
        case DefaultsKeys.imageResolutionPercent: return 100.0
        case DefaultsKeys.standardImageSizeMB: return 3.0
        case DefaultsKeys.ocrWorkerCount: return 4.0
        default: return nil
        }
    }

    /// Whether a stored key holds something other than its built-in value. Numbers compare as numbers, so a Double
    /// stored for an Int setting (or `normalizeSizingDefaults` writing back the default) is no change.
    static func changed(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: key) != nil else { return false }
        // Read as the setting's own kind, as `@AppStorage` reads it: a value given as a launch argument arrives as text
        // ("NO", "4"), and the defaults' typed getters convert it.
        switch defaultValue(key) {
        case let d as Bool: return defaults.bool(forKey: key) != d
        case let d as Double: return abs(defaults.double(forKey: key) - d) > 1e-9
        case let d as String:
            return (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != d
        default: return true
        }
    }

    /// Whether a group differs from its defaults: its stored keys, and its layered keys as `resolver` resolves them.
    static func changed(_ group: Group, in defaults: UserDefaults = .standard, resolver: SettingsResolver?) -> Bool {
        if group.keys.contains(where: { changed($0, in: defaults) }) { return true }
        guard let resolver else { return false }
        return group.layered.contains { key in
            let value = resolver.resolve(key).value
            // The Output tab's "One searchable page where possible" is a Standard choice; only a per-format list is
            // the Advanced editor's.
            if key == .searchableFor, value == .strings(SettingsAdvanced.searchableEverywhere) { return false }
            return value != key.defaultValue
        }
    }

    /// The Output tab's "One searchable page where possible": every format, every kind.
    static let searchableEverywhere = ["*/*"]

    /// The groups in use, for the Processing tab's "N Advanced settings in use" line.
    static func activeGroups(in defaults: UserDefaults = .standard, resolver: SettingsResolver?) -> [Group] {
        groups.filter { changed($0, in: defaults, resolver: resolver) }
    }

    /// Puts a group's stored keys back to their built-in values (the layered keys are cleared by the caller, which
    /// knows the collection).
    static func reset(_ group: Group, in defaults: UserDefaults = .standard) {
        for key in group.keys { defaults.removeObject(forKey: key) }
    }

    // MARK: Route rows

    /// The tier of a measured route row: a row the notes keep as a loss or a floor (`offered == false`), a trained model
    /// admitted under the kit gate's minimums (`afterTraining`) and the previously withheld readers (`lowerScoring`,
    /// owner call 15, W47.wh-readers-lost) are Advanced; every other row is a choice the bench supports. The solver
    /// never picks an Advanced row.
    static func tier(of route: SettingsRouteTable.Route) -> RouteTier {
        (!route.offered || route.afterTraining || route.lowerScoring) ? .advanced : .standard
    }

    /// Why an Advanced route row sits there, in its route row's own words. A trained model's reason says what its gate
    /// measured (W47.settings-trained-label): `trained` is the manifest of the model the app would load
    /// (`LocalSegmenter.loadedManifest`); without one, no held-out figure is claimed.
    static func why(_ route: SettingsRouteTable.Route, trained: LocalSegmenter.Manifest? = nil) -> String? {
        if route.afterTraining {
            return "a trained model " + (trained.map(LocalSegmenter.gateClause)
                ?? "that the training kit's gate must check on held-out material of your own before the app runs it")
        }
        if let c = route.conditions.first(where: { $0.hasPrefix("lower-scoring: ") }) {
            // "lower-scoring: <why>; offered at the Advanced level only, …": the measured reason alone.
            let why = c.dropFirst("lower-scoring: ".count)
            return (why.components(separatedBy: "; offered").first ?? String(why)) + "."
        }
        if !route.offered {
            return route.conditions.first { $0.hasPrefix("not offered") || $0.hasPrefix("never offered") }
        }
        return nil
    }
}
