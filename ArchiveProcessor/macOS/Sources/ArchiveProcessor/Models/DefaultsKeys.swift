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
    static let gatewayLocalModel = "gatewayLocalModel"   // W41.app-local-models: the gateway is a model on this Mac
    static let gatewayLocalEscalates = "gatewayLocalEscalates"   // …and its failed pages may go to the escalation model

    // Local Agent CLI backend (a locally installed, subscription-authenticated CLI — no API key).
    // Additive + opt-in; mutually exclusive with useGateway (the XOR is enforced in SettingsView).
    static let useLocalAgent = "useLocalAgent"
    static let localAgentTool = "localAgentTool"           // LocalAgentTool rawValue (claude/gemini/codex)
    static let localAgentBinaryPath = "localAgentBinaryPath" // optional absolute path override (blank ⇒ auto-detect)
    static let localAgentModel = "localAgentModel"         // optional model override (blank ⇒ CLI default)

    // Apple Vision OCR backend (on-device, no API key). Mutually exclusive with gateway / Local Agent.
    static let useAppleVision = "useAppleVision"
    /// When Apple Vision is the OCR backend, opt in to a separate direct LLM for text-only
    /// classification, segmentation, dates, and generated tags. Disabled keeps the fully-offline
    /// transcription-only workflow.
    static let visionUseLLMJudgment = "visionUseLLMJudgment"
    static let visionLanguages = "visionLanguages"                 // comma-separated BCP-47 tags
    static let visionFastRecognition = "visionFastRecognition"
    static let visionMinimumConfidence = "visionMinimumConfidence" // 0...1
    static let visionCustomVocabulary = "visionCustomVocabulary"   // comma/newline-separated words
    // W41.app-ocr-cascade (`OCRCascade`)
    static let ocrCascadeRoute = "ocrCascadeRoute"                 // "<provider>|<model id>"; empty = off
    static let ocrCascadeOnDisagreement = "ocrCascadeOnDisagreement"
    // W41.app-page-kind (`PageKindRouting`): tell each page's kind and preselect its reader; off by default
    static let ocrPageKindRouting = "ocrPageKindRouting"

    // Input & processing
    static let batchMode = "batchMode"
    static let preOCRedInput = "preOCRedInput"
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
    /// `SegmentationApproach` rawValue: who proposes the run's boundaries (W36.seg-opt-engine). Absent ⇒ manual.
    static let segmentationApproach = "segmentationApproach"
    /// `ClaudeRoute` rawValue: Claude's windows by API key or by the user's own `claude` plan, asked only when both
    /// exist (W36.seg-opt-subscription). Absent ⇒ API key.
    static let segmentationClaudeRoute = "segmentationClaudeRoute"
    /// `ChatGPTRoute` rawValue: ChatGPT's windows by API key or by the user's ChatGPT plan (Sign in with ChatGPT),
    /// asked only when both exist (W36.seg-opt-siwc). Absent ⇒ API key.
    static let segmentationChatGPTRoute = "segmentationChatGPTRoute"
    /// Sign in with ChatGPT's `ext_agent_host_id` for this installation: made once, reused on every sign-in. Not a
    /// secret; the tokens are in the Keychain (`KeychainChatGPTCredentialStore`).
    static let chatGPTHostID = "chatGPTHostID"
    /// OpenAI's "You're using your ChatGPT plan" welcome has been shown (it is shown on the first sign-in only).
    static let chatGPTPlanWelcomeShown = "chatGPTPlanWelcomeShown"
    /// `PlanCalibrationStore` JSON: the plan meter's points per notional dollar, measured on this account.
    static let segmentationPlanCalibration = "segmentationPlanCalibration"
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
