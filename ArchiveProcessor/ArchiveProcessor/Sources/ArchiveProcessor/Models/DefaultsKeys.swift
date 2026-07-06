import Foundation

/// Single source of truth for the app's `UserDefaults` / `@AppStorage` key strings.
///
/// The Process Files / Settings / Tools / Live Capture views (and the OCR/Capture services) share durable
/// state ONLY through exact key-string equality. Hand-typing the same key as a literal in several files means
/// one typo silently splits a setting — the writer stores under the wrong key and the reader sees the default,
/// with no compiler error. Referencing these constants makes every key compiler-checked and defined once.
///
/// INVARIANT: never change the string value of an existing constant — the value IS the persisted key, so
/// changing it orphans users' saved settings (same rule as the persisted enums in `ProviderModels`). The
/// constant name may be refactored freely; the string must not. Add new keys as needed.
///
/// Intentionally NOT here (dynamic / interpolated keys, handled elsewhere): the per-provider selected-model id
/// (`ModelSelectionStore.modelKey(for:)`, i.e. selectedModelId_<provider>) and the per-account key-wizard
/// prefixes (keyValidated_ / keyOCRTested_ / keySaveFailed_). Keychain account names are not UserDefaults keys.
enum DefaultsKeys {
    // Provider / model / thinking
    static let selectedProvider = "selectedProvider"
    static let selectedThinking = "selectedThinking"

    // OpenAI-compatible gateway
    static let useGateway = "useGateway"
    static let gatewayBaseURL = "gatewayBaseURL"
    static let gatewayModelID = "gatewayModelID"
    static let gatewayDisplayName = "gatewayDisplayName"
    static let gatewayInputCost = "gatewayInputCost"
    static let gatewayOutputCost = "gatewayOutputCost"
    static let gatewayUpstreamProvider = "gatewayUpstreamProvider"

    // Input & processing
    static let batchMode = "batchMode"
    static let preOCRedInput = "preOCRedInput"
    static let ocrWorkerCount = "ocrWorkerCount"
    static let imageResolutionPercent = "imageResolutionPercent"
    static let standardImageSizeMB = "standardImageSizeMB"
    static let pdfImageSizeMB = "pdfImageSizeMB"
    static let exportedImageSizeMB = "exportedImageSizeMB"
    static let outputImageFile = "outputImageFile"
    static let contextCharCount = "contextCharCount"
    static let sendPreviousImage = "sendPreviousImage"
    static let customOCRPrompt = "customOCRPrompt"
    static let mergeDocuments = "mergeDocuments"

    // Rotation
    static let rotationModeRaw = "rotationModeRaw"
    static let reviewRotation = "reviewRotation"

    // Tagging & segmentation
    static let taggingModeRaw = "taggingModeRaw"
    static let enableCollectionSegmentation = "enableCollectionSegmentation"
    static let confirmCollectionIDs = "confirmCollectionIDs"
    static let reviewDocumentSegmentation = "reviewDocumentSegmentation"
    static let enableSegmentJSON = "enableSegmentJSON"
    static let tagVocabulary = "tagVocabulary"

    // Output & logging
    static let outputDirectory = "outputDirectory"
    static let writeLogFile = "writeLogFile"

    // Live Capture
    static let liveProcessingMode = "liveProcessingMode"

    // Onboarding / key wizard
    static let hasSeenKeyOnboarding = "hasSeenKeyOnboarding"
    static let keychainExplained = "keychainExplained"

    // Tools
    static let modelTestSelections = "modelTestSelections"

    // One-time migration flags
    static let contextRemovedMigratedV1 = "contextRemovedMigratedV1"
    static let rotationDefaultMigratedV1 = "rotationDefaultMigratedV1"
}
