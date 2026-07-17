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

    // Local Agent CLI backend (a locally installed, subscription-authenticated CLI — no API key).
    // Additive + opt-in; mutually exclusive with useGateway (the XOR is enforced in SettingsView).
    static let useLocalAgent = "useLocalAgent"
    static let localAgentTool = "localAgentTool"           // LocalAgentTool rawValue (claude/gemini/codex)
    static let localAgentBinaryPath = "localAgentBinaryPath" // optional absolute path override (blank ⇒ auto-detect)
    static let localAgentModel = "localAgentModel"         // optional model override (blank ⇒ CLI default)

    // Input & processing
    static let batchMode = "batchMode"
    static let preOCRedInput = "preOCRedInput"
    static let reOCRMultiPagePDF = "reOCRMultiPagePDF"
    static let skipAlreadyProcessed = "skipAlreadyProcessed"   // incremental processing: skip inputs whose output PDF already exists + is newer
    static let ocrWorkerCount = "ocrWorkerCount"
    static let imageResolutionPercent = "imageResolutionPercent"
    static let standardImageSizeMB = "standardImageSizeMB"
    static let pdfImageSizeMB = "pdfImageSizeMB"
    static let textColumns = "textColumns"
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
    static let liveTransport = "liveTransport"       // DEPRECATED (A5 removed the picker); no longer read — LAN+Drive run together. CI uses env LIVECAPTURE_TRANSPORT.
    static let liveRelayDir = "liveRelayDir"         // shared directory root for the file-relay transport
    static let driveClientId = "driveClientId"       // Google OAuth Desktop client id for the cloud relay (secret in Keychain acct "DriveClientSecret")

    // Onboarding / key wizard
    static let hasSeenKeyOnboarding = "hasSeenKeyOnboarding"
    static let keychainExplained = "keychainExplained"

    // Tools
    static let modelTestSelections = "modelTestSelections"

    // Processing profiles (named snapshots of the durable processing settings; JSON-encoded [ProcessingProfile])
    static let processingProfiles = "processingProfiles"

    // Processing history (bounded log of completed Process-Files runs; JSON-encoded [ProcessingRun])
    static let processingHistory = "processingHistory"

    // One-time migration flags
    static let contextRemovedMigratedV1 = "contextRemovedMigratedV1"
    static let rotationDefaultMigratedV1 = "rotationDefaultMigratedV1"
}
