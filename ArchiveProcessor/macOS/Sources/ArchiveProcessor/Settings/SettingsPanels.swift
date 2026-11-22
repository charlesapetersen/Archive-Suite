import Foundation
import ArchiveCore

/// The Settings window's eight panels (W47.settings-panels; `execution-plans/processing-review/settings-design/levels.md`
/// §2, approved by the owner 2026-11-19), in the design's order. Each is one form in the standard macOS settings toolbar.
enum SettingsPanel: String, CaseIterable, Identifiable, Sendable {
    case general, collection, reading, documents, datesAndNames, pagesAndOutput, capture, accounts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .collection: return "Collection"
        case .reading: return "Reading"
        case .documents: return "Documents"
        case .datesAndNames: return "Dates and names"
        case .pagesAndOutput: return "Pages and output"
        case .capture: return "Capture"
        case .accounts: return "Accounts"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .collection: return "folder"
        case .reading: return "text.viewfinder"
        case .documents: return "doc.on.doc"
        case .datesAndNames: return "calendar"
        case .pagesAndOutput: return "doc.richtext"
        case .capture: return "camera"
        case .accounts: return "key"
        }
    }

    /// The words a shortcut uses to name the setting's home, e.g. "Settings › Documents".
    var home: String { "Settings › \(title)" }
}

/// Which panel owns each setting: the one place the setting is set (W47.settings-panels: no key has two owners).
/// Process Files' Tagging picker and segmentation chooser, and the settings sheet's cards and rule switches, write the
/// same keys as shortcuts and name the owning panel (`shortcuts`). `SettingsPanelsTestDriver` checks the table, and
/// `scripts/test-settings-panels.sh` checks that each panel's file stores only the keys this table gives it.
enum SettingsPanelOwnership {
    /// The owner of every stored key the Settings window sets: `DefaultsKeys` names, the layered `SettingsKey` raw
    /// values (the interviews' answers and the sheet's switches) and the stage cards' override keys, and the Keychain
    /// accounts (`keychain:<account>`).
    static let owners: [(key: String, panel: SettingsPanel)] = {
        var out: [(String, SettingsPanel)] = []
        func add(_ panel: SettingsPanel, _ keys: [String]) { out += keys.map { ($0, panel) } }

        add(.general, [AppAppearance.defaultsKey, DefaultsKeys.settingsLevel] + SettingsKey.generalOnly.map(\.rawValue))
        // The collection interview's answers; the setup interview's answers to the same questions are the general
        // layer under them, shown in the Collection panel with their source.
        add(.collection, [DefaultsKeys.outputDirectory] + SettingsKey.anyLayer.filter { !sheetSwitches.contains($0) }.map(\.rawValue))
        add(.reading, [
            DefaultsKeys.selectedProvider, DefaultsKeys.selectedThinking,
            DefaultsKeys.useGateway, DefaultsKeys.useLocalAgent, DefaultsKeys.useAppleVision,
            DefaultsKeys.gatewayBaseURL, DefaultsKeys.gatewayModelID, DefaultsKeys.gatewayDisplayName,
            DefaultsKeys.gatewayInputCost, DefaultsKeys.gatewayOutputCost, DefaultsKeys.gatewayUpstreamProvider,
            DefaultsKeys.gatewayLocalModel, DefaultsKeys.gatewayLocalEscalates,
            DefaultsKeys.visionUseLLMJudgment, DefaultsKeys.visionLanguages, DefaultsKeys.visionFastRecognition,
            DefaultsKeys.visionMinimumConfidence, DefaultsKeys.visionCustomVocabulary,
            DefaultsKeys.ocrCascadeRoute, DefaultsKeys.ocrCascadeOnDisagreement, DefaultsKeys.ocrPostCorrection,
            DefaultsKeys.ocrPageKindRouting, DefaultsKeys.ocrHandwritingOnTyped,
            SettingsSheetModel.overrideKey("reading").rawValue, SettingsKey.scanNewspapersDocLayoutYOLO.rawValue,
        ] + LLMProvider.allCases.map { ModelSelectionStore.modelKey(for: $0) })
        add(.documents, [
            DefaultsKeys.taggingModeRaw, DefaultsKeys.itemTypeColourBox, DefaultsKeys.itemTypeColourFolder,
            DefaultsKeys.tagVocabulary, DefaultsKeys.enableCollectionSegmentation, DefaultsKeys.confirmCollectionIDs,
            DefaultsKeys.reviewDocumentSegmentation, DefaultsKeys.enableSegmentJSON, DefaultsKeys.sendPreviousImage,
            DefaultsKeys.macItemFields,
            DefaultsKeys.mergeDocuments, DefaultsKeys.customOCRPrompt,
            DefaultsKeys.segmentationApproach, DefaultsKeys.segmentationClaudeRoute,
            DefaultsKeys.localSegmenterPartner, DefaultsKeys.localSegmenterBaseURL, DefaultsKeys.localSegmenterModelID,
            SettingsSheetModel.overrideKey("segmentation").rawValue,
        ])
        add(.datesAndNames, [
            SettingsKey.dateImageEveryDocument.rawValue, SettingsKey.dateLocalImage.rawValue, SettingsKey.lowConfidenceNames.rawValue,
            SettingsSheetModel.overrideKey("dating").rawValue, SettingsSheetModel.overrideKey("entities").rawValue,
        ])
        add(.pagesAndOutput, [
            SettingsKey.straightenReadingCopy.rawValue, SettingsKey.placeHandOnImage.rawValue,
            SettingsKey.searchableFor.rawValue,
            DefaultsKeys.rotationModeRaw, DefaultsKeys.reviewRotation,
            DefaultsKeys.imageResolutionPercent, DefaultsKeys.standardImageSizeMB, DefaultsKeys.pdfImageSizeMB,
            DefaultsKeys.exportedImageSizeMB, DefaultsKeys.outputImageFile, DefaultsKeys.textColumns,
            DefaultsKeys.skipAlreadyProcessed, DefaultsKeys.preOCRedInput, DefaultsKeys.batchMode,
            DefaultsKeys.ocrWorkerCount, DefaultsKeys.writeLogFile,
        ])
        add(.capture, [
            DefaultsKeys.liveProcessingMode, DefaultsKeys.readContainerLabels, DefaultsKeys.driveClientId,
            "keychain:DriveClientSecret",
        ])
        add(.accounts, [
            DefaultsKeys.localAgentTool, DefaultsKeys.localAgentBinaryPath, DefaultsKeys.localAgentModel,
            "keychain:Gateway",
        ] + LLMProvider.allCases.filter { $0 != .appleVision }.map { "keychain:\($0.rawValue)" })
        return out
    }()

    /// The sheet's switches (its rules tab and the dating card), each owned by the panel that holds its stage.
    static let sheetSwitches: [SettingsKey] = [.straightenReadingCopy, .placeHandOnImage, .dateImageEveryDocument, .dateLocalImage, .lowConfidenceNames,
                                               .scanNewspapersDocLayoutYOLO, .searchableFor]

    /// Which panel holds each settings-sheet stage: the four cards and the rule stages (`SettingsSheetModel`).
    static let stagePanels: [String: SettingsPanel] = [
        "reading": .reading, "segmentation": .documents, "dating": .datesAndNames, "entities": .datesAndNames,
        "reading-copy": .pagesAndOutput, "ocr-input": .reading, "layout": .reading, "placement": .pagesAndOutput,
        "marks": .pagesAndOutput, "capture": .capture,
    ]

    /// The controls outside the Settings window that write a key a panel owns, and the key each writes.
    static let shortcuts: [(control: String, key: String)] = [
        ("Process Files › Tagging", DefaultsKeys.taggingModeRaw),
        ("Process Files › Segmentation", DefaultsKeys.segmentationApproach),
        ("Settings sheet › each card's Use instead…", SettingsSheetModel.overrideKey("reading").rawValue),
        ("Settings sheet › each card's Use instead…", SettingsSheetModel.overrideKey("segmentation").rawValue),
        ("Settings sheet › each card's Use instead…", SettingsSheetModel.overrideKey("dating").rawValue),
        ("Settings sheet › each card's Use instead…", SettingsSheetModel.overrideKey("entities").rawValue),
        ("Settings sheet › the Dates card", SettingsKey.dateImageEveryDocument.rawValue),
        ("Settings sheet › the Dates card", SettingsKey.dateLocalImage.rawValue),
        ("Settings sheet › the Names card", SettingsKey.lowConfidenceNames.rawValue),
        ("Settings sheet › Rules", SettingsKey.straightenReadingCopy.rawValue),
        ("Settings sheet › Rules", SettingsKey.placeHandOnImage.rawValue),
        ("Settings sheet › Rules", SettingsKey.scanNewspapersDocLayoutYOLO.rawValue),
        ("Settings sheet › Rules", SettingsKey.searchableFor.rawValue),
    ]

    /// The panel that owns `key`, or nil when no panel sets it.
    static func owner(of key: String) -> SettingsPanel? { owners.first { $0.key == key }?.panel }

    /// The line a shortcut shows under its control.
    static func shortcutNote(_ key: String) -> String? {
        owner(of: key).map { "Also set in \($0.home); a change here changes it there." }
    }

    /// The line a sheet card or rule box shows: where its stage is set.
    static func stageNote(_ stage: String) -> String? {
        stagePanels[stage].map { "Set in \($0.home) too; a change in either place is the same setting." }
    }
}
