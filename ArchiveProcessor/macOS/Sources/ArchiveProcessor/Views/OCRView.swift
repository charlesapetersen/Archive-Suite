import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO
import ArchiveCore

struct OCRView: View {
    // MARK: - State
    /// Shared processor (injected so the Live Capture tab can stage files into this view).
    @ObservedObject var processor: OCRProcessor
    @ObservedObject var capture: CaptureSession

    // Persisted via @AppStorage (UserDefaults)
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.selectedThinking) private var selectedThinking: ThinkingLevel = .low
    @AppStorage(DefaultsKeys.ocrPostCorrection) private var ocrPostCorrection = false
    @AppStorage(DefaultsKeys.batchMode) private var batchMode: Bool = false
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput: Bool = false
    @AppStorage(DefaultsKeys.skipAlreadyProcessed) private var skipAlreadyProcessed: Bool = false
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation: Bool = false
    @AppStorage(DefaultsKeys.confirmCollectionIDs) private var confirmCollectionIDs: Bool = false
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }
    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationApproachRaw: String =
        SegmentationApproach.defaultApproach.rawValue
    @AppStorage(DefaultsKeys.localSegmenterPartner) private var localSegmenterPartner = ""
    @AppStorage(DefaultsKeys.segmentationClaudeRoute) private var segmentationClaudeRoute: ClaudeRoute = .apiKey
    @AppStorage(DefaultsKeys.segmentationChatGPTRoute) private var segmentationChatGPTRoute: ChatGPTRoute = .apiKey
    /// Who segments with the current settings (W36.seg-opt-review).
    private var segmentationPlan: SegmentationPlan {
        SegmentationPlan.resolve(tagging: taggingMode,
                                 approach: visionLocalAutoDate ? .manual
                                     : SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach)
    }
    /// Which keys / `claude` the segmentation approaches can use; read on appear and on a key change, never
    /// while rendering.
    @State private var segmentationRoutes = SegmentationRoutes.none
    /// Re-renders the estimate once OpenRouter's prices and listing have been read (W41.app-openrouter-unmeasured).
    @State private var openRouterListingRead = 0
    @AppStorage(OpenRouterListing.defaultsKey) private var openRouterListingData: Data?
    /// W46.training-optout-run: what Start says before it runs a way the collection's "must not train" switch hides.
    @State private var trainingWarning: String?
    @State private var monthlyLimitWarning: String?
    @AppStorage(DefaultsKeys.rotationModeRaw) private var rotationModeRaw: String = RotationMode.standard.rawValue
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .standard }
    @AppStorage(DefaultsKeys.reviewRotation) private var reviewRotation: Bool = false
    @AppStorage(DefaultsKeys.ocrWorkerCount) private var ocrWorkerCount: Int = 4
    /// Derived for compatibility with existing pipeline flags.
    private var enableTagging: Bool { taggingMode.enablesTagging }
    private var passSourceTags: Bool { taggingMode == .copySource }
    private var classifyPreOCRedInput: Bool { (enableTagging && !passSourceTags) || enableCollectionSegmentation }
    private var hasCaptureGrouping: Bool { captureBoundaries.count == droppedFiles.count && !droppedFiles.isEmpty }

    private var windowSegmentationSpec: ApproachSpec? {
        guard !droppedFiles.isEmpty, !isPDFOnlyReOCR, preOCRedInput || !hasCaptureGrouping,
              case .windows(let approach) = segmentationPlan,
              let options = SegmentationOptionsStore.shared else { return nil }
        // Pre-OCRed inputs still go through the window stage. A pure PDF rebuild and staged photos
        // that already have their boundaries skip it.
        let partner = SegmentationApproach(rawValue: localSegmenterPartner).flatMap {
            approach == .local && SegmentationOptions.partnerApproaches.contains($0) ? $0 : nil
        }
        return try? options.spec(for: approach, partner: partner)
    }

    private var segmentationCredentialIssue: String? {
        guard let spec = windowSegmentationSpec else { return nil }
        var routes = segmentationRoutes
        routes.claudeRoute = segmentationClaudeRoute
        routes.chatGPTRoute = segmentationChatGPTRoute
        routes.hasClaudeCLI = claudeBinary != nil
        return WindowStageTransport.credentialIssue(spec, routes: routes)?.description
    }
    /// Only a PDF-only drop disables tagging. A mixed drop also runs the standard image path,
    /// so the picker remains active for images while rebuilt PDFs stay untagged.
    private var hasMixedReOCR: Bool {
        droppedHasMultiPagePDF && !preOCRedInput
            && droppedFiles.contains { !PDFToImageConverter.isMultiPagePDF($0) }
    }
    private var isPDFOnlyReOCR: Bool { droppedHasMultiPagePDF && !preOCRedInput && !hasMixedReOCR }
    @AppStorage(DefaultsKeys.reviewDocumentSegmentation) private var reviewDocumentSegmentation: Bool = true
    @AppStorage(DefaultsKeys.enableSegmentJSON) private var enableSegmentJSON: Bool = true
    @AppStorage(DefaultsKeys.sendPreviousImage) private var sendPreviousImage: Bool = false
    @AppStorage(DefaultsKeys.tagVocabulary) private var tagVocabulary: String = ""
    @AppStorage(DefaultsKeys.contextCharCount) private var contextCharCount: Double = 0   // context slider removed; kept 0 (parallel OCR)
    @AppStorage(DefaultsKeys.customOCRPrompt) private var customOCRPrompt: String = ""
    @AppStorage(DefaultsKeys.mergeDocuments) private var mergeDocuments: Bool = false
    @AppStorage(DefaultsKeys.imageResolutionPercent) private var imageScale: Double = 100
    @AppStorage(DefaultsKeys.outputImageFile) private var outputImageFile: Bool = true   // two files (PDF + image) vs one (PDF only)

    // Gateway mode (persisted)
    @AppStorage(DefaultsKeys.useGateway) private var useGateway: Bool = false
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel: Bool = false
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL: String = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID: String = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName: String = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayUpstreamProvider) private var gatewayUpstreamProvider: LLMProvider = .anthropic

    // Local Agent CLI backend (persisted; mutually exclusive with the gateway)
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent: Bool = false
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentTool: LocalAgentTool = .claude
    @AppStorage(DefaultsKeys.localAgentBinaryPath) private var localAgentBinaryPath = ""
    @ObservedObject private var claudeUsage = ClaudeCLIUsage.shared

    private var claudeBinary: String? {
        ClaudeCLIBilling.binaryPath(tool: localAgentTool, override: localAgentBinaryPath)
    }
    // Apple Vision is the no-key, on-device backend selected in Settings.
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision: Bool = false
    @AppStorage(DefaultsKeys.visionUseLLMJudgment) private var visionUseLLMJudgment: Bool = false
    @AppStorage(DefaultsKeys.ocrCascadeRoute) private var ocrCascadeRoute: String = ""
    @AppStorage(DefaultsKeys.ocrCascadeOnDisagreement) private var ocrCascadeOnDisagreement: Bool = false
    @AppStorage(DefaultsKeys.ocrPageKindRouting) private var ocrPageKindRouting: Bool = false
    @AppStorage(DefaultsKeys.ocrHandwritingOnTyped) private var ocrHandwritingOnTyped: Bool = true
    /// W41.app-page-kind — each dropped image's kind and the reader it chose.
    @StateObject private var pageKinds = PageKindStore()
    /// W41.app-institutional-compute — the institutional-computing bulk folder the next run takes text from; chosen per run.
    @State private var institutionalComputeImport: InstitutionalComputeImport?

    /// The model for the current provider, read live from the shared store so a change made in the
    /// Settings window updates this window's cost estimate — and the model a run launches with —
    /// immediately, exactly like the `@AppStorage` settings above. (Never re-introduce a `@State`
    /// mirror here: that is what left this window a model behind. See `ModelSelectionStore`.)
    ///
    /// Read-only by design: this window has no model picker, and a setter here would be keyed on the
    /// `@AppStorage` provider — so a future caller changing provider and model together could file the
    /// choice under the outgoing provider. Write via `ModelSelectionStore.saveModel(_:for:)` with an
    /// explicit provider instead.
    private var selectedModel: LLMModel { modelStore.model(for: selectedProvider) }

    // Initialized from persisted state in init()
    @State private var apiKey: String
    @State private var outputDirectory: URL?
    /// A newly chosen output folder with no settings of its own is a new collection: it is asked about its material
    /// (W46.settings-interviews).
    @State private var collectionInterview: CollectionInterviewView.Target?
    /// W44 Improve OCR: the files the dialog is open for.
    @State private var improveOCR: ImproveOCRSelection?
    @State private var improveOCRMessage: String?

    @AppStorage(DefaultsKeys.keychainExplained) private var keychainExplained: Bool = false

    // Transient
    @State private var droppedFiles: [URL] = []
    @State private var preservationSelectionSize: (bytes: Int64, known: Int)?
    /// W47.ct-processor-intake: for each file from a folder read as a tree, its folder below the output folder.
    @State private var droppedSubfolders: [URL: String] = [:]
    @State private var foldersBeyondDepth: [URL] = []
    @State private var flatDotFolders: [URL: String] = [:]
    @State private var showingPendingIntake = false
    /// The level map offered at Start for a tree, and why saving it was refused.
    @State private var containerLevels: ContainerLevelsDraft?
    @State private var containerLevelsError: String?
    /// A drop or Add Files whose folders hold folders: whether to read those too is asked first.
    @State private var treeQuestion: TreeQuestion?
    @State private var inputLocationCheck: Task<Void, Never>?
    private var checkingInputLocation: Bool { inputLocationCheck != nil }
    /// A tree being read in the background, and the file list's generation: Clear and Start bump it, so a walk that
    /// ends after either adds nothing.
    @State private var readingTree = false
    @State private var intakeGeneration = 0
    struct TreeQuestion: Identifiable {
        let id = UUID()
        let urls: [URL]
        let sortAll: Bool
        let names: [String]
    }
    /// Whether any dropped file is a multi-page PDF (recomputed on droppedFiles change, so PDFs aren't
    /// re-opened on every render). Combined with `!preOCRedInput` this is the auto re-OCR routing the
    /// pipeline applies — surfaced here only to grey out the (inapplicable) Tagging controls.
    @State private var droppedHasMultiPagePDF = false
    /// Multi-page PDFs among the dropped files and their total pages (recomputed with the flag above).
    /// Re-OCR calls the model once per page, so the cost pane prices those pages separately.
    @State private var droppedPDFFileCount = 0
    @State private var droppedPDFPageCount = 0
    @State private var stagedSelection: Set<URL> = []
    /// Pre-grouped segmentation from a Live Capture handoff (aligned to droppedFiles); empty otherwise.
    @State private var captureBoundaries: [Bool] = []
    @State private var captureTypes: [CaptureGroupType] = []
    /// Minimal on-phone tags from the same handoff (aligned to droppedFiles); empty otherwise.
    @State private var captureQualities: [String?] = []
    @State private var captureYears: [Int?] = []
    @State private var captureMonths: [Int?] = []
    @State private var captureSubjects: [[String]] = []
    @State private var isTargeted = false
    @State private var showKeychainSheet = false
    @Environment(\.scenePhase) private var scenePhase

    // Inline segmentation edit & review navigation
    @State private var editingFileIndex: Int? = nil
    @State private var reviewFocusedIndex: Int = 0

    // Per-item inline-disclosure (Files pane): which row is expanded + action sheet targets.
    @State private var expandedFileID: String?
    @State private var fileRotationRetryTarget: FileRotationRetryTarget?
    @State private var fileTextViewerTarget: FileTextViewerTarget?

    struct FileRotationRetryTarget: Identifiable {
        let jobIndex: Int
        var id: Int { jobIndex }
    }
    struct FileTextViewerTarget: Identifiable {
        let jobIndex: Int
        var id: Int { jobIndex }
    }

    /// Observed, not read directly: `selectedModel` resolves against `provider.models`, which includes
    /// this store's custom models — so adding or deleting one has to re-render this view too.
    @ObservedObject private var customModelStore = CustomModelStore.shared
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @ObservedObject private var settingsStore = SettingsLayerStore.shared

    init(processor: OCRProcessor, capture: CaptureSession) {
        _processor = ObservedObject(wrappedValue: processor)
        _capture = ObservedObject(wrappedValue: capture)
        _apiKey = State(initialValue: "")
#if DEBUG
        // The UI suite owns this temporary output directory. Never recover the operator's
        // last-selected folder, even though visual tests never start a paid run.
        _outputDirectory = State(initialValue: ProcessorUITestConfiguration.outputDirectory
                                 ?? ModelSelectionStore.savedOutputDirectory())
#else
        _outputDirectory = State(initialValue: ModelSelectionStore.savedOutputDirectory())
#endif
    }

    private var currentGatewayConfig: GatewayConfig? {
        useAppleVision ? nil : GatewayConfig.fromDefaults()
    }
    private var gatewaySetupIssue: String? {
        guard !useAppleVision, !useLocalAgent, useGateway, currentGatewayConfig == nil else { return nil }
        return "Set the gateway URL and model in Settings › Reading before starting."
    }
    private var currentLocalAgentConfig: LocalAgentConfig? {
        useAppleVision ? nil : LocalAgentConfig.fromDefaults()
    }
    private var effectiveProvider: LLMProvider { useAppleVision ? .appleVision : selectedProvider }
    private var effectiveModel: LLMModel {
        // The Mac's reader: Vision, or the on-device model when the reading card chose it (W47.wh-readers-lost-clients).
        useAppleVision ? modelStore.model(for: .appleVision) : (currentGatewayConfig?.asLLMModel() ?? selectedModel)
    }
    private var isDirectOCR: Bool {
        !useGateway && !useLocalAgent && !useAppleVision && !preOCRedInput
    }
    private var effectiveBatchMode: Bool {
        batchMode && effectiveProvider.supportsBatch && isDirectOCR
    }
    /// Both reader selection and institutional computing imports apply to direct, non-batch OCR.
    private var allowsPageReaders: Bool { isDirectOCR && !effectiveBatchMode }
    /// W41.app-page-kind applies to a direct API model reading pages one by one: not a paid batch (one model), the
    /// gateway or the Local Agent (the user's single route), Apple Vision (free; the guide never sends a page to it,
    /// and moving its pages to a paid model is not what choosing it asks for), or pre-OCRed input.
    private var pageKindsActive: Bool {
        ocrPageKindRouting && allowsPageReaders
    }
    private var pageKindRunDefault: PageKindRouting.Candidate {
        .init(provider: effectiveModel.provider, modelID: effectiveModel.id)
    }
    private var pageReaderPlan: PageReaderPlan {
        pageKindsActive ? pageKinds.plan(droppedFiles, guidance: .bundled, runDefault: pageKindRunDefault) : .empty
    }
    private var visionLocalAutoDate: Bool {
        useAppleVision && !visionUseLLMJudgment && !preOCRedInput && taggingMode == .autoDate
            && DateRoute.localImageEnabled(settingsStore.resolver(at: outputDirectory).resolve(.dateLocalImage).value)
    }

    private var visionWorkflowIsSupported: Bool {
        !useAppleVision || visionUseLLMJudgment || (!visionTaggingUnavailable && !enableCollectionSegmentation)
    }
    /// The Tagging mode is one transcription-only Apple Vision cannot run, so the Tagging box says so instead of
    /// describing what the mode would do (W40.fix-processor-settings-backend-mismatch).
    private var visionTaggingUnavailable: Bool {
        useAppleVision && !visionUseLLMJudgment && !visionLocalAutoDate
            && taggingMode != .none && taggingMode != .copySource
    }
    /// Whether this run needs the key `reloadAPIKey()` loads (W40.fix-processor-localagent-key). Apple Vision needs
    /// it only for its LLM judgement. The Local Agent needs none: its CLI signs in with the subscription, and no
    /// route of a Local Agent run reaches the direct provider — the OCR call, classification and tagging take the
    /// CLI first; rotation, the cascade, the refusal fallback, page readers and the institutional import are all
    /// skipped off the direct route; segmentation windows read their own keys.
    private var runNeedsAPIKey: Bool {
        useAppleVision ? visionUseLLMJudgment : !useLocalAgent
    }

    /// The provider whose key `reloadAPIKey()` put in the field, nil when it holds a gateway key or none.
    private var apiKeyFieldProvider: LLMProvider? {
        useAppleVision ? (visionUseLLMJudgment ? selectedProvider : nil) : (useGateway ? nil : selectedProvider)
    }
    private var pendingRunResumeBlockReason: String? {
        processor.pendingRunResumeBlockReason(fieldKey: apiKey, fieldProvider: apiKeyFieldProvider)
    }
    /// Worded by the interrupted run's own backend (W40.fix-processor-resume-run-key), not the one selected now.
    private var pendingRunResumeCaption: String {
        if let reason = pendingRunResumeBlockReason { return reason }
        switch processor.pendingRunBackend {
        case .localAgent: return "Click Resume to continue with the CLI configured for this run."
        case .gateway: return "Click Resume to continue through the gateway with its saved key."
        case .appleVision: return "Click Resume to continue with Apple Vision."
        case .direct, nil: return "Click Resume to continue processing remaining files."
        }
    }

    private func reloadAPIKey() {
#if DEBUG
        if MoneyJourneyFixture.isActive {
            apiKey = MoneyJourneyFixture.dummyKey
            return
        }
        if PaidBatchUITestFixture.isActive {
            apiKey = PaidBatchUITestFixture.dummyKey
            return
        }
#endif
        apiKey = useAppleVision
            ? (visionUseLLMJudgment ? (KeychainHelper.load(account: selectedProvider.rawValue) ?? "") : "")
            : (useGateway ? GatewayConfig.storedKey() : (KeychainHelper.load(account: selectedProvider.rawValue) ?? ""))
    }

    /// Dropped files that go down the image path; multi-page PDFs are re-OCR'd page by page instead.
    private var imageFileCount: Int {
        preOCRedInput ? droppedFiles.count : max(0, droppedFiles.count - droppedPDFFileCount)
    }

    /// The image subset's estimate (nil when every dropped file is a multi-page PDF).
    private var costEstimate: CostEstimate? {
        guard imageFileCount > 0 else { return nil }
        let model = useAppleVision && visionUseLLMJudgment ? selectedModel : effectiveModel
        let readersDelta = pageKindsActive
            ? pageReaderPlan.ocrCostDelta(runModel: effectiveModel, imageScale: imageScale / 100.0,
                                          sendPreviousImage: sendPreviousImage && segmentationPlan.usesPerPageClassifier,
                                          contextCharCount: Int(contextCharCount)) : 0
        let settings = settingsStore.resolver(at: outputDirectory)
        let namesCallShare = EntityRunPolicy.estimatedCallShare(
            taggingMode: taggingMode, gateway: currentGatewayConfig, usesLocalAgent: useLocalAgent,
            usesVision: useAppleVision, setting: { settings.resolve($0).value })
        return CostEstimator.estimate(
            fileCount: imageFileCount,
            model: model,
            enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput,
            sendPreviousImage: sendPreviousImage && segmentationPlan.usesPerPageClassifier,
            contextCharCount: Int(contextCharCount),
            imageScale: imageScale / 100.0,
            rotationMode: rotationMode,
            useGateway: useGateway || useAppleVision,
            imageTokenProvider: useGateway ? gatewayUpstreamProvider : nil,
            visionTextOnly: useAppleVision && visionUseLLMJudgment,
            classifyPreOCRedInput: classifyPreOCRedInput,
            gatewayRotation: gatewayRotation,
            measuredRoute: DateRoute.measuredRoute(gateway: useGateway ? currentGatewayConfig : nil,
                                                   usesLocalAgent: useLocalAgent),
            dateImageEveryDocument: DateRoute.imageEveryDocument(settings),
            sidecars: enableSegmentJSON || !preOCRedInput,
            namesCallShare: namesCallShare
        ).addingOCR(readersDelta)
    }

    /// The separate tagging-related calls shown in the Cost Estimate when they have a price.
    @ViewBuilder private func taggingCallRows(_ est: CostEstimate) -> some View {
        if est.datingCost > 0 {
            HStack {
                Text("Dating:").foregroundStyle(.primary)
                Spacer()
                Text(est.datingFormatted)
            }
        }
        if est.itemFieldCost > 0 {
            HStack {
                Text("Item fields:").foregroundStyle(.primary)
                Spacer()
                Text(est.itemFieldFormatted)
            }
        }
        if est.namesCost > 0 {
            HStack {
                Text("Names:").foregroundStyle(.primary)
                Spacer()
                Text(est.namesFormatted)
            }
        }
    }

    /// Direct per-page calls for the dropped multi-page PDFs, priced with the model that OCRs them.
    private var pdfPageEstimate: CostEstimate? {
        guard !preOCRedInput, droppedPDFPageCount > 0 else { return nil }
        return CostEstimator.estimateDirectPDFPages(
            pageCount: droppedPDFPageCount, model: effectiveModel, imageScale: imageScale / 100.0,
            rotationMode: rotationMode, useGateway: useGateway || useAppleVision,
            imageTokenProvider: useGateway ? gatewayUpstreamProvider : nil, gatewayRotation: gatewayRotation)
    }

    /// The pages the segmentation approach would segment: the image files. A multi-page PDF is rebuilt page by
    /// page with no tagging, so its pages are never segmented (Part 3 §3 wrote `droppedFiles.count +
    /// droppedPDFPageCount`, which also counts each such PDF once as a file and once per page).
    private var segmentationPageCount: Int { imageFileCount }

    /// The chosen approach's row for this run, or nil when there is nothing to segment.
    private var segmentationRow: SegmentationRow? {
        guard segmentationPageCount > 0, captureBoundaries.isEmpty,
              let options = SegmentationOptionsStore.shared else { return nil }
        let approach = SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach
        return SegmentationRow.make(approach, options: options, pageCount: segmentationPageCount,
                                    routes: segmentationRoutes.withClaudeBilling(claudeUsage.billing(for: claudeBinary)))
    }

    /// Processing-time estimate for the current batch (LLM/processing time only).
    private var timeEstimate: TimeEstimate? {
        guard !droppedFiles.isEmpty else { return nil }
        let model = effectiveModel
        return TimeEstimator.estimate(
            fileCount: droppedFiles.count, model: model, rotationMode: rotationMode,
            sequentialOCR: contextCharCount > 0, enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput, useGateway: useGateway || useAppleVision, ocrWorkers: ocrWorkerCount,
            localSecondsPerPage: currentGatewayConfig.flatMap {
                $0.isLocalModel ? LocalModelRoute.secondsPerPage(modelID: $0.modelID) : nil },
            gatewayRotation: gatewayRotation)
    }

    /// The run's rotation calls go to the remote gateway's model (W46.rotation-default), as `detectRotation` decides.
    private var gatewayRotation: Bool {
        !useAppleVision && LLMRotationDetector.callsGateway(mode: rotationMode, gateway: currentGatewayConfig,
                                                            usesLocalAgent: useLocalAgent)
    }

    private var gatewayHasCosts: Bool {
        gatewayInputCost >= 0 && gatewayOutputCost >= 0
    }

    private var unavailableOpenRouterSelection: String? {
        _ = openRouterListingData
        guard useAppleVision ? visionUseLLMJudgment : !useGateway && !useLocalAgent else { return nil }
        return modelStore.unavailableOpenRouterSelection(for: selectedProvider)
    }

    /// The OpenRouter model used for page reading has no usable estimate.
    private var openRouterUnpriced: Bool {
        openRouterListingRead >= 0 && !useGateway && !useLocalAgent && !useAppleVision
            && OpenRouterRoute.isUnpriced(selectedModel)
    }

    /// The estimate's "Segmentation" line: $0 for manual, the approach's dollars by API key, or "your plan" when
    /// only the user's own `claude` can run it. Its window calls are in addition to OCR.
    @ViewBuilder private var segmentationCostLine: some View {
        if let row = segmentationRow {
            HStack {
                Text("Segmentation (\(row.label)):").foregroundStyle(.primary)
                Spacer()
                Text(row.costSummary)
                    .accessibilityIdentifier("ap.ocr.segmentationCost")
            }
        }
    }

    // MARK: - Body
    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 300, maxWidth: 360)
                .padding()

            filePanel
                .padding()
        }
        .onAppear {
            reloadAPIKey()
            // Not before the Keychain explainer: each read can prompt, and the sheet says to click Always Allow.
            if keychainExplained { segmentationRoutes = SegmentationRoutes.currentPreselecting() }
            // W41.app-openrouter-unmeasured: with an OpenRouter key, read its prices and listing before an estimate
            // that picks an OpenRouter model shows ("Read with this", page-kind routing, Re-OCR's ranking), so the
            // estimate and the request's price ceiling are the listing's, not the guess before it.
            if keychainExplained, selectedProvider == .openrouter
                || !(KeychainHelper.load(account: LLMProvider.openrouter.rawValue) ?? "").isEmpty {
                Task {
                    await OpenRouterListing.refreshAllIfStale()
                    openRouterListingRead += 1
                }
            }
            processor.checkForPendingBatch()
            if !keychainExplained {
                showKeychainSheet = true
            }
            // Warm the system-tag suggestions if a manual tagging mode is already selected.
            if taggingMode.isManual { SystemTagsProvider.shared.warmUp() }
#if DEBUG
            // XCUITest cannot reliably hand a Finder file promise to the AppKit drop receiver in a
            // headless guest. Feed its scratch PDF through the exact same URL admission method instead.
            if droppedFiles.isEmpty, let testPDF = ProcessorUITestConfiguration.droppedPDF {
                handleDroppedURLs([testPDF])
            }
            if droppedFiles.isEmpty, let volume = ProcessorUITestConfiguration.droppedVolume {
                handleDroppedURLs(volume)
            }
            if droppedFiles.isEmpty, processor.statusMessage.isEmpty, let tree = MessageJourneyFixture.inputTree {
                handleDroppedURLs([tree])
            }
            if droppedFiles.isEmpty, let images = ProcessorUITestConfiguration.droppedImages {
                handleDroppedURLs(images)
            }
#endif
        }
        .onDisappear { inputLocationCheck?.cancel() }
        .onChange(of: taggingModeRaw) { _, _ in
            if taggingMode.isManual { SystemTagsProvider.shared.warmUp() }
        }
        .onChange(of: droppedFiles) { _, files in
            // Recompute the multi-page-PDF flag off the main render path (opens PDFs once per change,
            // not per render). Short-circuits at the first multi-page PDF; non-PDFs never open a file.
            let pageCounts = files.compactMap(PDFToImageConverter.multiPagePDFPageCount)
            droppedHasMultiPagePDF = !pageCounts.isEmpty
            droppedPDFFileCount = pageCounts.count
            droppedPDFPageCount = pageCounts.reduce(0, +)
            let sourceFiles = Set(files)
            let sizes = sourceFiles.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            preservationSelectionSize = (sizes.reduce(0) { $0 + Int64($1) }, sizes.count)
            if pageKindsActive { pageKinds.update(files) }
        }
        .onChange(of: pageKindsActive) { _, active in
            if active { pageKinds.update(droppedFiles) }
        }
        .onChange(of: ocrHandwritingOnTyped, initial: true) { _, on in pageKinds.handwritingOnTyped = on }
        .onChange(of: processor.stagedCaptureFiles) { _, staged in
            guard !staged.isEmpty else { return }
            // Live Capture handed off pre-grouped photos → load them as the input files.
            replaceFiles(with: staged)
            stagedSelection = Set(staged)
            captureBoundaries = processor.stagedCaptureBoundaries
            captureTypes = processor.stagedCaptureTypes
            captureQualities = processor.stagedCaptureQualities
            captureYears = processor.stagedCaptureYears
            captureMonths = processor.stagedCaptureMonths
            captureSubjects = processor.stagedCaptureSubjects
            processor.stagedCaptureFiles = []
        }
        .onAppear {
            // Live Capture stages files, THEN switches to this tab — so this view is created after
            // stagedCaptureFiles changed and .onChange won't fire for it. Pick up anything pending.
            let staged = processor.stagedCaptureFiles
            guard !staged.isEmpty else { return }
            replaceFiles(with: staged)
            stagedSelection = Set(staged)
            captureBoundaries = processor.stagedCaptureBoundaries
            captureTypes = processor.stagedCaptureTypes
            captureQualities = processor.stagedCaptureQualities
            captureYears = processor.stagedCaptureYears
            captureMonths = processor.stagedCaptureMonths
            captureSubjects = processor.stagedCaptureSubjects
            processor.stagedCaptureFiles = []
        }
        .onChange(of: keychainExplained) { _, explained in
            if explained { segmentationRoutes = SegmentationRoutes.currentPreselecting() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
            segmentationRoutes = SegmentationRoutes.currentPreselecting()
            reloadAPIKey()
        }
        .onChange(of: selectedProvider) { _, _ in syncForProviderChange() }
        .onChange(of: useAppleVision) { _, _ in syncForProviderChange() }
        .onChange(of: gatewayLocalModel) { _, _ in reloadAPIKey() }   // W41.app-local-models: the stand-in key
        .onChange(of: useGateway) { _, _ in reloadAPIKey() }
        .onChange(of: visionUseLLMJudgment) { _, _ in syncForProviderChange() }
        .onReceive(NotificationCenter.default.publisher(for: .startProcessingRequested)) { _ in
            // ⌘R: run the normal Start action, but only when it's actually allowed and no field is being
            // edited — the shortcut is guarded exactly like the Start button.
            guard !TextEditingGuard.isEditingText, canStartProcessing else { return }
            startProcessing()
        }
        // ⌘., ⌘O and ⇧⌘O (W40.fix-suite-shortcuts) do what the Cancel, Add Files… and Choose… buttons do,
        // and only when that button is on screen and enabled, with no sheet or alert over it (`SheetGuard`).
        // The two panels take no keystroke from a field, so only Stop stands down while one is edited (there
        // ⌘. ends the editing).
        .onReceive(NotificationCenter.default.publisher(for: .stopProcessingRequested)) { _ in
            guard !TextEditingGuard.isEditingText, !SheetGuard.sheetIsUp, processor.isProcessing || isInReviewMode
            else { return }
            processor.requestStop()   // W49.proc-stop-saves-inflight: waits for the pages being read, as the button does
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFilesRequested)) { _ in
            guard !SheetGuard.sheetIsUp, !isInReviewMode, !processor.isProcessing else { return }
            selectFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .chooseOutputFolderRequested)) { _ in
            guard !SheetGuard.sheetIsUp else { return }
            chooseOutputDirectory()
        }
        .modifier(ImproveOCRHooks(selection: $improveOCR, message: $improveOCRMessage, files: droppedFiles,
                                  canOpen: !isInReviewMode && !processor.isProcessing))
        .onChange(of: scenePhase) { _, phase in
            // Returning from the Settings window: pick up any changed key / output folder. (The model is
            // no longer re-synced here — it is read live from `ModelSelectionStore`, which also covers the
            // case this never did: Settings open *beside* this window, where a macOS `WindowGroup` sees no
            // scene-phase transition at all.)
            guard phase == .active else { return }
            reloadAPIKey()
            if keychainExplained { segmentationRoutes = SegmentationRoutes.currentPreselecting() }
            if let path = UserDefaults.standard.string(forKey: DefaultsKeys.outputDirectory), FileManager.default.fileExists(atPath: path) {
                outputDirectory = URL(fileURLWithPath: path)
            }
        }
        .sheet(item: $collectionInterview) { target in
            CollectionInterviewView(target: target, files: droppedFiles) { collectionInterview = nil }
        }
        .sheet(isPresented: $showKeychainSheet) {
            keychainExplanationSheet
        }
        .sheet(isPresented: $processor.awaitingCollectionConfirmation) {
            CollectionReviewSheet(processor: processor)
        }
        .sheet(isPresented: $processor.awaitingRetryDecision) {
            OCRRetrySheet(processor: processor)
        }
        // Per-item rotate-and-re-run uses the run's locked backend and changes only the forced rotation.
        .sheet(item: $fileRotationRetryTarget) { target in
            RotationRetrySheet(
                title: "Rotate & re-run",
                subtitle: processor.isProcessing
                    ? "Re-run OCR for this file before it is filed."
                    : "Re-run OCR and file a new PDF alongside the existing output.",
                backendDescription: processor.retryBackendDescription,
                initialRotation: processor.jobs.indices.contains(target.jobIndex)
                    ? (processor.jobs[target.jobIndex].result?.rotationDegrees ?? 0) : 0,
                onApply: { rotation in
                    Task {
                        guard let outDir = outputDirectory else { return }
                        await processor.retryOne(
                            index: target.jobIndex, outputDirectory: outDir,
                            rotation: rotation)
                    }
                    fileRotationRetryTarget = nil
                },
                onCancel: { fileRotationRetryTarget = nil })
        }
        // Per-item "view text" from the Files pane inline disclosure.
        .sheet(item: $fileTextViewerTarget) { target in
            let job = processor.jobs.indices.contains(target.jobIndex) ? processor.jobs[target.jobIndex] : nil
            FileTextViewerSheet(
                text: job?.result?.text,
                errorMessage: job?.result?.errorMessage,
                onDismiss: { fileTextViewerTarget = nil })
        }
        // Rotation/segmentation review + Segment & Tag open as real, movable, resizable windows filling
        // the screen (not sheets — sheets are anchored/centered and can't be moved).
        .reviewWindow(isPresented: $processor.awaitingDocumentReview) {
            DocumentSegmentReviewSheet(processor: processor)
        }
        .sheet(isPresented: $processor.awaitingBoxFolderConfirmation) {
            BoxFolderConfirmSheet(processor: processor)
        }
        .sheet(isPresented: $processor.awaitingManualTagging) {
            ManualTaggingSheet(processor: processor)
        }
        .reviewWindow(isPresented: $processor.awaitingManualSegTag) {
            ManualSegmentTagView(processor: processor)
        }
        .modifier(SegmentationStagePresentations(processor: processor))
        .modifier(TrainingWarningPresentation(warning: $trainingWarning) { beginProcessing() })
        .modifier(MonthlyLimitPresentation(warning: $monthlyLimitWarning) {
            runProcessing(confirmedMonthlyLimit: true)
        })
        .alert("Read the folders inside?", isPresented: Binding(get: { treeQuestion != nil },
                                                                 set: { if !$0 { treeQuestion = nil } }),
               presenting: treeQuestion) { question in
            Button("Read Folders Inside") { answer(question, readSubfolders: true) }
            Button("Only Its Own Files") { answer(question, readSubfolders: false) }
            Button("Cancel", role: .cancel) { treeQuestion = nil }
        } message: { question in
            Text("“\(question.names.joined(separator: "”, “"))” \(question.names.count == 1 ? "holds" : "hold") folders. "
                 + "Process Files can read the photos in them too and file each PDF in the same folders inside the "
                 + "output folder, so Archive Reader shows its collection, box and folder. Or it reads only the "
                 + "photos directly inside, as before.")
        }
        .sheet(item: $containerLevels) { draft in
            ContainerLevelsSheet(draft: draft, error: containerLevelsError, onSave: { edited in
                if let failure = ProcessFilesTree.saveLevels(edited) {
                    containerLevelsError = failure
                    return
                }
                containerLevels = nil
                runProcessing()
            }, onSkip: {
                containerLevels = nil
                runProcessing()
            }, onCancel: { containerLevels = nil })
        }
        .modifier(InstitutionalComputeResumePresentation(processor: processor) { mixedPDF in
            if mixedPDF { resumePendingMixedPDF(readWithoutClusterText: true) }
            else { resumePendingRun(readWithoutClusterText: true) }
        })
        // No `onChange(of: apiKey)` writes the Keychain here (W47.gateway-key-rewrites): nothing in this view edits
        // the key, only `reloadAPIKey()` fills it from the Keychain, so such a handler wrote each key back at launch
        // and at every route switch (resetting the item's partition list) and deleted it when a read came back empty.
        // Keys are edited in Settings and the key wizard.
        .onChange(of: outputDirectory) { _, newDir in
            ModelSelectionStore.saveOutputDirectory(newDir)
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Archive Processor")
                    .font(.title2)
                    .fontWeight(.semibold)

                // Pending batch resume
                if let info = processor.pendingBatchInfo {
                    GroupBox("Pending Batch") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(info)
                                .font(.caption)
                            Text("Enter your API key above, then click Resume.")
                                .font(.caption2)
                                .foregroundStyle(.primary)
                            HStack {
                                Button("Resume Batch") { resumePendingBatch() }
                                    .prominentButtonStyle()
                                    .disabled(apiKey.isEmpty || processor.isProcessing)
                                Button("Dismiss") { processor.dismissPendingBatch() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(4)
                    }
                }

                // Pending run resume
                if let info = processor.pendingRunInfo {
                    GroupBox("Interrupted Run") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(info)
                                .font(.caption)
                            Text(pendingRunResumeCaption)
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("ap.ocr.pendingRunCaption")
                            HStack {
                                Button("Resume Run") { resumePendingRun() }
                                    .prominentButtonStyle()
                                    .disabled(processor.isProcessing || pendingRunResumeBlockReason != nil)
                                    .accessibilityIdentifier("ap.ocr.resumeRun")
                                Button("Dismiss") { processor.dismissPendingRun() }
                                    .buttonStyle(.bordered)
                                    .disabled(processor.isProcessing)
                            }
                        }
                        .padding(4)
                    }
                }

                if let info = processor.pendingMixedPDFInfo {
                    GroupBox("Interrupted Mixed PDF Run") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(info).font(.caption)
                            Text("Enter the API key above to resume saved PDF pages. If a page may have been billed without a saved result, review it before dismissing this record.")
                                .font(.caption2).foregroundStyle(.primary)
                            HStack {
                                Button("Resume PDFs") { resumePendingMixedPDF() }
                                    .prominentButtonStyle()
                                    .disabled(processor.isProcessing || !processor.canResumePendingMixedPDF)
                                Button("Dismiss") { processor.dismissPendingMixedPDF() }
                                    .buttonStyle(.bordered)
                                    .disabled(processor.isProcessing || processor.mixedPDFCancellationUnwinding)
                            }
                        }.padding(4)
                    }
                }

                // Tagging mode stays in the main UI; other settings are in the Settings window (⌘,).
                GroupBox("Tagging") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(hasMixedReOCR ? "Tagging (images only)" : "Tagging", selection: $taggingModeRaw) {
                            ForEach(TaggingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                        .accessibilityIdentifier("ap.ocr.taggingPicker")
                        Text(hasMixedReOCR
                             ? "Applies to images only. Multi-page PDFs are rebuilt without tags."
                             : isPDFOnlyReOCR
                               ? "Not applied to a multi-page PDF — it is re-OCR'd into one alternating image/OCR-text PDF (a pure document rebuild, no tagging)."
                               : visionTaggingUnavailable
                                 ? "Apple Vision only transcribes, so this mode cannot run. Choose No tagging or Copy source file tags, or turn on LLM judgement in Settings (⌘,)."
                                 : visionLocalAutoDate
                                   ? "This Mac suggests dates. Confirm the document boundaries and enter subjects yourself."
                                   : taggingMode.detail)
                            .font(.caption2).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ap.ocr.reOCRExplanation")
                        if let home = SettingsPanelOwnership.shortcutNote(DefaultsKeys.taggingModeRaw) {
                            Text(home).font(.caption2).foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("ap.ocr.taggingHome")
                        }
                    }
                    .padding(4)
                    // Full width, so the card ends where the cards above and below it do (it stopped about
                    // 24 pt short when its text was narrower; W40.fix-processor-visual-polish).
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("ap.ocr.taggingPanel")
                .disabled(isPDFOnlyReOCR)

                // Who proposes the boundaries (W36.seg-opt-chooser). Not for Live Capture: the phone already
                // gave them. A shortcut to Settings › Documents, and says so.
                if captureBoundaries.isEmpty {
                    GroupBox("Segmentation") {
                        VStack(alignment: .leading, spacing: 4) {
                            SegmentationChooserView(
                                pageCount: segmentationPageCount > 0 ? segmentationPageCount : 100,
                                scaleCaption: segmentationPageCount > 0
                                    ? "for the \(segmentationPageCount) page\(segmentationPageCount == 1 ? "" : "s") dropped"
                                    : "per 100 pages",
                                routes: $segmentationRoutes,
                                shortcutNote: SettingsPanelOwnership.shortcutNote(DefaultsKeys.segmentationApproach))
                                .disabled(isPDFOnlyReOCR)
                            // A greyed chooser says why, as Tagging does (W40.fix-processor-start-why).
                            if isPDFOnlyReOCR {
                                Text("Not used for a multi-page PDF: it is rebuilt as one file, so there are no boundaries to propose.")
                                    .font(.caption2).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("ap.ocr.segmentationDisabledReason")
                            }
                        }
                        .padding(4)
                    }
                    .accessibilityIdentifier("ap.ocr.segmentationPanel")
                }


                if settingsStore.keepsPreservationCopies, !droppedFiles.isEmpty, let estimate = preservationSelectionSize {
                    let size = ByteCountFormatter.string(fromByteCount: estimate.bytes, countStyle: .file)
                    Text(estimate.known == 0 ? "Preservation copy size is unavailable for these originals."
                         : estimate.known == Set(droppedFiles).count
                           ? "Preservation copies add \(size) for the selected originals."
                           : "Preservation copies add \(size) for the originals with known sizes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("\(estimate.bytes.formatted()) bytes of original files with known sizes. A PDF-only share leaves these files behind.")
                }

                // Cost estimate
                if let warning = unavailableOpenRouterSelection, !droppedFiles.isEmpty {
                    GroupBox("Cost Estimate") {
                        Text(warning)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ap.ocr.openRouterEstimateUnavailable")
                    }
                } else if useAppleVision && !droppedFiles.isEmpty {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "cpu").foregroundStyle(.secondary)
                                Text("Free — runs on this Mac.")
                                    .accessibilityIdentifier("ap.ocr.appleVisionCost")
                                Spacer()
                            }
                            Text(visionWorkflowIsSupported
                                 ? (visionUseLLMJudgment
                                    ? "Vision transcribes locally. The selected LLM receives text only for judgement — never page images."
                                    : visionLocalAutoDate
                                      ? "Apple Vision and Auto Date run on this Mac without an API key."
                                      : "Apple Vision transcribes locally with no API key or network request. It uses the Mac's performance cores.")
                                 : "Apple Vision is transcription-only. Select No tagging or Copy source file tags, and turn off Collection ID, before starting.")
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .padding(.top, 2)
                            if visionUseLLMJudgment && OpenRouterRoute.isUnpriced(selectedModel) {
                                Text(OpenRouterRoute.unpricedEstimateMessage).font(.caption)
                            } else if visionUseLLMJudgment, let est = costEstimate {
                                HStack {
                                    Text("Text-only judgement:").foregroundStyle(.primary)
                                    Spacer()
                                    Text(est.classificationFormatted)
                                }
                                if taggingMode.llmTags {
                                    HStack {
                                        Text("Tags / dates:").foregroundStyle(.primary)
                                        Spacer()
                                        Text(est.taggingFormatted)
                                    }
                                }
                                taggingCallRows(est)
                                if enableCollectionSegmentation {
                                    HStack {
                                        Text("Collection ID:").foregroundStyle(.primary)
                                        Spacer()
                                        Text(est.collectionFormatted)
                                    }
                                }
                                Divider()
                                HStack {
                                    Text("Total (text-only):").fontWeight(.medium)
                                    Spacer()
                                    Text(CostEstimate.money(est.totalStandard + (segmentationRow?.apiDollars ?? 0)))
                                        .fontWeight(.medium)
                                }
                            }
                            segmentationCostLine
                        }
                        .padding(4)
                    }
                } else if useLocalAgent && !droppedFiles.isEmpty {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "terminal").foregroundStyle(.secondary)
                                Text(claudeUsage.costHeadline(binary: claudeBinary, tool: localAgentTool))
                                    .accessibilityIdentifier("ap.ocr.localAgentCost")
                                Spacer()
                            }
                            Text(claudeUsage.costDetail(binary: claudeBinary, tool: localAgentTool))
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .padding(.top, 2)
                                .accessibilityIdentifier("ap.ocr.localAgentPacing")
                            segmentationCostLine
                        }
                        .padding(4)
                    }
                } else if openRouterUnpriced && !droppedFiles.isEmpty {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(OpenRouterRoute.unpricedEstimateMessage)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("ap.ocr.openRouterUnpriced")
                            segmentationCostLine
                        }
                        .padding(4)
                    }
                } else if useGateway && !gatewayHasCosts && !droppedFiles.isEmpty {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enter model pricing in Gateway Configuration above to see cost estimates.")
                                .font(.caption)
                                .foregroundStyle(.primary)
                            segmentationCostLine
                        }
                        .padding(4)
                    }
                } else if costEstimate != nil || pdfPageEstimate != nil {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Files:").foregroundStyle(.primary)
                                Spacer()
                                Text("\(droppedFiles.count)")
                            }
                            if let pdf = pdfPageEstimate {
                                HStack {
                                    Text("PDF pages (\(droppedPDFPageCount) in \(droppedPDFFileCount) PDF\(droppedPDFFileCount == 1 ? "" : "s"), direct):")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text(pdf.totalStandardFormatted)
                                        .accessibilityIdentifier("ap.ocr.pdfPageCost")
                                }
                            }
                            if let est = costEstimate {
                                if pdfPageEstimate != nil {
                                    HStack {
                                        Text("Images:").foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(est.fileCount)")
                                    }
                                }
                                if !preOCRedInput {
                                    HStack {
                                        Text("OCR + classification:").foregroundStyle(.primary)
                                        Spacer()
                                        Text(est.ocrFormatted)
                                    }
                                }
                                if preOCRedInput && (enableTagging || enableCollectionSegmentation) {
                                    HStack {
                                        Text("Classification (text-only):").foregroundStyle(.primary)
                                        Spacer()
                                        Text(est.classificationFormatted)
                                    }
                                }
                                if taggingMode.llmTags {
                                    HStack {
                                        Text("Tagging (~\(max(1, est.fileCount / 3)) segments):").foregroundStyle(.primary)
                                        Spacer()
                                        Text(est.taggingFormatted)
                                    }
                                }
                                taggingCallRows(est)
                                if enableCollectionSegmentation {
                                    HStack {
                                        Text("Collection ID:").foregroundStyle(.primary)
                                        Spacer()
                                        Text(est.collectionFormatted)
                                    }
                                }
                                if est.rotationCost > 0 {
                                    HStack {
                                        Text("Rotation:").foregroundStyle(.primary)
                                        Spacer()
                                        Text(est.rotationFormatted)
                                    }
                                }
                            }
                            segmentationCostLine
                            Divider()
                            HStack {
                                Text(preOCRedInput ? "Total (standard):" : "Whole-page estimate (standard):").fontWeight(.medium)
                                Spacer()
                                Text(CostEstimate.money(CostEstimator.runTotal(
                                    images: costEstimate, directPDFPages: pdfPageEstimate, batch: false)
                                    + (segmentationRow?.apiDollars ?? 0)))
                                    .fontWeight(.medium)
                                    .accessibilityIdentifier("ap.ocr.standardTotal")
                            }
                            if effectiveBatchMode && costEstimate != nil {
                                HStack {
                                    Text(pdfPageEstimate == nil ? "Whole-page estimate (batch):" : "Whole-page estimate (batch images + direct PDF pages):")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    // Segmentation windows are never batched, so they add the same dollars.
                                    Text(CostEstimate.money(CostEstimator.runTotal(
                                        images: costEstimate, directPDFPages: pdfPageEstimate, batch: true)
                                        + (segmentationRow?.apiDollars ?? 0)))
                                        .accessibilityIdentifier("ap.ocr.batchTotal")
                                }
                            }
                            if !useGateway && !useLocalAgent && !useAppleVision && !preOCRedInput
                                && effectiveModel.measuredModel.provider == .gemini {
                                // W41.app-ocr-default-fu1 — a refused page is read again, outside the totals above.
                                let range = OCRRefusalFallback.pageCostRange(imageScale: imageScale / 100.0)
                                Text("Pages Gemini refuses are read by a second reader: \(CostEstimate.money(range.lowerBound))–\(CostEstimate.money(range.upperBound)) a page with a key, free with a Claude subscription. Not in the totals.")
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .accessibilityIdentifier("ap.ocr.secondReaderCost")
                            }
                            if let line = ContainerLabelCapture.estimateNote(gateway: useGateway ? currentGatewayConfig : nil,
                                                                             preOCRedInput: preOCRedInput) {
                                // W47.ct-label-cost — which photos are labels is known only once they are read.
                                Text(line)
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .accessibilityIdentifier("ap.ocr.labelReadCost")
                            }
                            if pageKindsActive && !droppedFiles.isEmpty {
                                PageKindBatchControl(store: pageKinds, plan: pageReaderPlan,
                                                     runDefault: pageKindRunDefault, runModel: effectiveModel)
                            }
                            if allowsPageReaders && !droppedFiles.isEmpty {
                                InstitutionalComputeImportControl(imported: $institutionalComputeImport)
                            }
                            let cascade = OCRCascade(routeID: ocrCascadeRoute, onDisagreement: ocrCascadeOnDisagreement)
                            if (!useGateway || currentGatewayConfig?.localEscalates == true) && !useLocalAgent && !preOCRedInput,
                               cascade.applies(to: effectiveModel.provider, model: effectiveModel),
                               let target = cascade.escalationModel,
                               let page = cascade.pageCost(imageScale: imageScale / 100.0) {
                                // W41.app-ocr-cascade — escalated pages are read again, outside the totals above.
                                Text("Pages \(effectiveModel.displayName) fails\(cascade.onDisagreement ? ", or whose word count disagrees with Apple Vision's," : "") are read again by \(target.provider.rawValue) · \(target.displayName): about \(CostEstimate.money(page)) a page. Not in the totals.")
                                    .font(.caption2)
                                    .foregroundStyle(.primary)
                                    .accessibilityIdentifier("ap.ocr.cascadeCost")
                            }
                            Text(useGateway ? "Estimates based on user-provided pricing. Actual gateway costs may differ." : "Estimates calibrated from actual API usage with high-resolution archival photos. Actual costs may vary with image resolution.")
                                .font(.caption2)
                                .foregroundStyle(.primary)
                                .padding(.top, 2)
                            if let t = timeEstimate {
                                Divider()
                                HStack {
                                    Text("Est. time:").fontWeight(.medium)
                                    Spacer()
                                    Text(t.totalFormatted).fontWeight(.medium)
                                }
                                Text("Processing time only (no user interaction). OCR \(t.ocrFormatted)\(t.rotationSeconds > 0 ? " · rotation \(t.rotationFormatted) (overlaps OCR)" : "")\(taggingMode.llmTags ? " · tagging \(t.taggingFormatted)" : "").")
                                    .font(.caption2).foregroundStyle(.primary)
                            }
                        }
                        .padding(4)
                    }
                }

                if unavailableOpenRouterSelection == nil {
                    newspaperLayoutAllowance
                    postCorrectionEstimate
                }

                // Output directory
                GroupBox("Output Folder") {
                    HStack {
                        Text(outputDirectory?.lastPathComponent ?? "Not set")
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseOutputDirectory() }
                    }
                    .padding(4)
                }

                // Start button
                Button(action: startProcessing) {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .prominentButtonStyle()
                .disabled(!canStartProcessing)
                .accessibilityIdentifier("ap.ocr.start")

                if let reason = startBlockedReason {
                    Label(reason, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.ocr.startBlockedReason")
                }

                if processor.isProcessing || isInReviewMode {
                    // W49.proc-stop-saves-inflight: in the OCR pass the first press waits for the pages being read.
                    Button(processor.drainingPages ? "Stop Now" : "Cancel") { processor.requestStop() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var postCorrectionEstimate: some View {
        if ocrPostCorrection, !droppedFiles.isEmpty {
            let notice: String = if let policy = OCRPostCorrection.policyReason(at: outputDirectory, store: settingsStore) {
                "Image correction is skipped. \(policy)"
            } else if visionLocalAutoDate {
                "This run stays on this Mac, so it skips OpenRouter image correction."
            } else if preOCRedInput || isPDFOnlyReOCR || useGateway || useLocalAgent
                        || effectiveBatchMode
                        || !customOCRPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                "This run skips image correction."
            } else if !segmentationRoutes.hasOpenRouterKey {
                "Image correction needs an OpenRouter key in Settings › Accounts."
            } else if let model = OCRPostCorrection.model {
                "Image correction via OpenRouter adds about \(CostEstimate.money(OCRPostCorrection.estimatedCost(model: model))) per eligible page, outside the reading estimate."
            } else {
                "The image correction route is unavailable."
            }
            Text(notice)
                .font(.caption2).foregroundStyle(.primary)
                .accessibilityIdentifier("ap.ocr.postCorrectionCost")
        }
    }

    /// The detector has not run at estimate time, so a numerical upper allowance assumes every input page
    /// is a newspaper and reserves all 130 requests per attempt. Multiplying the whole estimate (including
    /// tagging and rotation) is deliberately conservative; it is not a predicted bill or a spend cap.
    @ViewBuilder
    private var newspaperLayoutAllowance: some View {
        if !preOCRedInput && !droppedFiles.isEmpty {
            GroupBox("Newspaper layout allowance") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirmed newspaper pages use one reading request per region, with a possible fill and a whole-page fallback. Other kinds, handwriting, registers and uncertain pages keep whole-page reading.")
                    Text("Allow up to 130 requests per newspaper per attempt: 128 regions, one fill and one fallback. Retries and second readers can make additional attempts.")
                    if useLocalAgent {
                        Text("The CLI uses the billing method shown above. No per-request dollar estimate is available.")
                    } else if useAppleVision {
                        Text("Vision reads the regions locally, with no image-reading charge. Any optional text-only judgement is estimated separately above.")
                    } else if openRouterUnpriced {
                        Text("Price not estimated. The request allowance still applies.")
                    } else if useGateway && !gatewayHasCosts {
                        Text("Gateway pricing is unknown. Enter model pricing to see a dollar allowance; the request allowance still applies.")
                    } else {
                        let standard = CostEstimator.runTotal(images: costEstimate, directPDFPages: pdfPageEstimate, batch: false)
                            + (segmentationRow?.apiDollars ?? 0)
                        HStack {
                            Text("Conservative allowance (standard):")
                            Spacer()
                            Text(CostEstimate.money(standard * 130))
                                .accessibilityIdentifier("ap.ocr.newspaperStandardAllowance")
                        }
                        if effectiveBatchMode && costEstimate != nil {
                            let batch = CostEstimator.runTotal(images: costEstimate, directPDFPages: pdfPageEstimate, batch: true)
                                + (segmentationRow?.apiDollars ?? 0)
                            HStack {
                                Text("Conservative allowance (batch):")
                                Spacer()
                                Text(CostEstimate.money(batch * 130))
                                    .accessibilityIdentifier("ap.ocr.newspaperBatchAllowance")
                            }
                        }
                        Text("These allowances multiply the entire whole-page estimate by 130, as if every input page were a newspaper. They include non-reading costs repeatedly, so they are deliberately high. Actual costs depend on regions, fills, fallbacks and further attempts; this is not a spending limit.")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(4)
                .accessibilityIdentifier("ap.ocr.newspaperAllowance")
            }
        }
    }

    // MARK: - File Panel

    /// Whether the file pane is in an interactive review state
    private var isInReviewMode: Bool {
        processor.awaitingFinalReview
    }

    /// Both Start and ⌘R use the same checks and the same explanation.
    private var canStartProcessing: Bool {
        !processor.isProcessing && startBlockedReason == nil
    }

    /// The first unmet Start condition. While a run is going, the Cancel control takes its place.
    private var startBlockedReason: String? {
        guard !processor.isProcessing else { return nil }
        if isInReviewMode { return "Finish the review on the right before starting another run." }
        if processor.pendingBatchInfo != nil { return "Resume or dismiss the pending batch above first." }
        if processor.pendingRunInfo != nil { return "Resume or dismiss the interrupted run above first." }
        if processor.pendingMixedPDFInfo != nil { return "Resume or dismiss the interrupted PDF run above first." }
        if checkingInputLocation { return "Checking the selected files’ location…" }
        if droppedFiles.isEmpty { return "Add images or PDFs to process." }
        if !stagedSelection.isEmpty,
           capture.hasCompletedHandoff(in: droppedFiles.filter { stagedSelection.contains($0) }) {
            return "This selection includes photos already filed. To process another capture, start from Live Capture."
        }
        if readingTree { return "Reading the folders inside…" }   // W47.ct-processor-intake
        if !visionWorkflowIsSupported {
            if !visionTaggingUnavailable { return "Turn off Collection ID to process without LLM judgment." }
            return "Set Tagging to No tagging or Copy source file tags. For Auto Date with Apple Vision, "
                + "enable local image dating in Advanced Dates and names and process fresh images."
                + (enableCollectionSegmentation ? " Turn off Collection ID as well." : "")
        }
        if unavailableOpenRouterSelection != nil {
            return "Choose an available OpenRouter model in Settings › Reading before starting."
        }
        if let gatewaySetupIssue { return gatewaySetupIssue }
        if runNeedsAPIKey && apiKey.isEmpty {
            if useGateway && !useAppleVision { return "No gateway key is saved. Add it in Settings (⌘,)." }
            return "No \(selectedProvider.rawValue) API key is saved. Add one in Settings (⌘,)."
        }
        if let segmentationCredentialIssue {
            return "Segmentation: " + segmentationCredentialIssue + " Change the route or add a key in Settings."
        }
        if outputDirectory == nil { return "Choose an output folder." }
        return nil
    }

    /// Re-point the API-key field after `selectedProvider` changes from anywhere (the ⌘⌥P cycle
    /// shortcut or a return from Settings), so a run never uses the wrong Keychain
    /// account. The model needs no hook — `selectedModel` reads the store keyed by the *current*
    /// provider, so it re-points on the same render.
    private func syncForProviderChange() {
        reloadAPIKey()
    }

    private var canAddFiles: Bool {
        !processor.isProcessing && !isInReviewMode && !checkingInputLocation && treeQuestion == nil
    }

    private var filePanel: some View {
        // The header stays put above the list, so Add Files… and Clear are in reach at any scroll position
        // (it scrolled away with 60 files; W40.fix-processor-visual-polish).
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !isInReviewMode {
                    Button(action: selectFiles) {
                        Label("Add Files…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canAddFiles)
                    if !droppedFiles.isEmpty || !foldersBeyondDepth.isEmpty || !processor.treeIntakeWarnings.isEmpty {
                        Button("Clear") { replaceFiles(with: []); captureBoundaries = []; captureTypes = []; captureQualities = []; captureYears = []; captureMonths = []; captureSubjects = []; processor.jobs = []; processor.segments = []; processor.collectionSegments = []; processor.progress = 0; processor.statusMessage = ""; processor.failedFiles = [:] }
                            .buttonStyle(.bordered)
                            .disabled(processor.isProcessing)   // Clear mid-run would wipe processor.jobs out from under the running task (wasted paid calls, discarded output)
                    }
                }
            }
            if !droppedSubfolders.isEmpty && !preOCRedInput {
                // W47.ct-processor-intake
                Text("Folders kept: each PDF is filed in the same folders inside the output folder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("ap.files.treeNote")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if droppedFiles.isEmpty {
                        dropZone
                            .frame(minHeight: 300)
                    } else {
                        fileList
                    }

                    // Segment summary
                    if !processor.segments.isEmpty {
                        Divider()
                        segmentSummary
                    }

                    // Collection summary
                    if !processor.collectionSegments.isEmpty {
                        Divider()
                        collectionSummary
                    }

                    // Review action buttons
                    if processor.awaitingFinalReview {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Review tags and segmentation below. Arrow keys to navigate, 1-4 to classify, Enter to edit.")
                                .font(.caption)
                                .foregroundStyle(.primary)
                            HStack(spacing: 12) {
                                Button(action: { processor.redoTagging() }) {
                                    Label("Redo Segmentation & Tagging", systemImage: "arrow.counterclockwise")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                Button(action: { processor.confirmFinalReview() }) {
                                    Label("Complete", systemImage: "checkmark.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .prominentButtonStyle()
                            }
                        }
                    }

                    // Progress and intake warnings remain together when the run finishes.
                    runSummary
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingFileIndex != nil },
            set: { if !$0 { editingFileIndex = nil } }
        )) {
            if let index = editingFileIndex, index < processor.jobs.count {
                SegmentationEditSheet(processor: processor, fileIndex: index, fileName: processor.jobs[index].sourceURL.lastPathComponent) {
                    editingFileIndex = nil
                }
            }
        }
    }

    private var treeIntakeWarnings: [String] {
        var warnings = ProcessFilesTree.depthWarning(foldersBeyondDepth).map { [$0] } ?? []
        guard !preOCRedInput, !flatDotFolders.isEmpty else { return warnings }
        let flatFolders = Set(droppedFiles.compactMap { file in
            droppedSubfolders[file] == nil ? flatDotFolders[file] : nil
        }).sorted()
        warnings += flatFolders.map { name in
            "The name “\(name)” starts with a dot. Its folder structure is skipped when filing PDFs."
        }
        return warnings
    }

    private var runSummary: some View {
        let warnings = showingPendingIntake ? treeIntakeWarnings : processor.treeIntakeWarnings
        let showProgress = processor.isProcessing || (!processor.statusMessage.isEmpty && !isInReviewMode)
        return Group {
            if showProgress || !warnings.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if showProgress {
                        ProgressView(value: processor.progress)
                        Text(processor.statusMessage)
                        if processor.isProcessing { PlanPauseCaption() }
                    }
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning).textSelection(.enabled)
                    }
                }
                .font(.caption)
                .foregroundStyle(.primary)
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.3))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            VStack(spacing: 12) {
                Image(systemName: preOCRedInput ? "doc.text" : "photo.stack")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)   // decorative; the text below says what the zone is for
                Text(checkingInputLocation ? "Checking file location…" : (preOCRedInput ? "Drop PDFs here" : "Drop images or PDFs here"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("or use Add Files…")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            .allowsHitTesting(false)
            if canAddFiles {
                DropReceiver(isTargeted: $isTargeted) { urls in
                    handleDroppedURLs(urls)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("ap.ocr.dropZone")
    }

    /// Segmentation decided on the phone (Live Capture handoff), shown next to each file so the
    /// finished box/folder/start/continuation marks appear before processing and aren't redone.
    private func capturePreGroupedClassification(at index: Int) -> DocumentClassification? {
        guard captureBoundaries.count == droppedFiles.count,
              captureTypes.count == droppedFiles.count,
              index < droppedFiles.count else { return nil }
        switch captureTypes[index] {
        case .box: return .boxLabel
        case .folder: return .folderLabel
        case .document: return captureBoundaries[index] ? .documentStart : .documentContinuation
        }
    }

    /// Review shortcuts index the visible drop, while the running standard route holds only image jobs.
    private func reviewJobIndex(for rowIndex: Int) -> Int? {
        guard droppedFiles.indices.contains(rowIndex),
              !processor.reOCRSourceURLs.contains(droppedFiles[rowIndex]) else { return nil }
        return processor.jobs.firstIndex { $0.sourceURL == droppedFiles[rowIndex] }
    }

    /// W41.app-page-kind — the row's kind and reader, with its menu; nothing when kind routing is off.
    @ViewBuilder private func pageKindLine(_ url: URL) -> some View {
        if pageKindsActive {
            PageKindRowLine(store: pageKinds, url: url, guidance: .bundled, runDefault: pageKindRunDefault,
                            runModel: effectiveModel)
                .padding(.trailing, 8)
        }
    }

    private var fileList: some View {
        let jobsBySource = Dictionary(processor.jobs.map { ($0.sourceURL, $0) }, uniquingKeysWith: { _, last in last })
        return ZStack {
            ScrollViewReader { scrollProxy in
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(zip(droppedFiles.indices, droppedFiles)), id: \.0) { index, url in
                        let job = jobsBySource[url]
                        let itemID = job?.id.uuidString ?? url.path
                        FileRowView(
                            url: url,
                            job: job,
                            showTags: processor.awaitingFinalReview,
                            isFocused: isInReviewMode && index == reviewFocusedIndex,
                            isReOCRSource: processor.reOCRSourceURLs.contains(url),
                            actions: ItemActionHandler { action, id in performFileAction(action, on: id) },
                            isExpanded: expandedFileID == itemID,
                            presetClassification: capturePreGroupedClassification(at: index)
                        )
                        .overlay(alignment: .bottomTrailing) { pageKindLine(url) }
                        .contentShape(Rectangle())
                        .id(index)
                        .onTapGesture(count: 2) {
                            if isInReviewMode, let jobIndex = reviewJobIndex(for: index) {
                                editingFileIndex = jobIndex
                            }
                        }
                        .onTapGesture(count: 1) {
                            if isInReviewMode {
                                reviewFocusedIndex = index
                            } else {
                                expandedFileID = (expandedFileID == itemID) ? nil : itemID
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: reviewFocusedIndex) { _, newIndex in
                    withAnimation { scrollProxy.scrollTo(newIndex, anchor: .center) }
                }
                .onChange(of: processor.awaitingFinalReview) { _, entering in
                    // Reset review focus each time a review begins — otherwise a smaller second run leaves
                    // reviewFocusedIndex out of range, so no row shows the focus ring and the 1–4
                    // classification keys silently do nothing. Covers all entry paths (run/batch/resume).
                    if entering {
                        reviewFocusedIndex = droppedFiles.indices.first {
                            reviewJobIndex(for: $0) != nil
                        } ?? 0
                    }
                }
            }
            if canAddFiles {
                DropReceiver(isTargeted: .constant(false)) { urls in
                    handleDroppedURLs(urls)
                }
            }
        }
        .focusable(isInReviewMode)
        .onKeyPress(.upArrow) {
            guard isInReviewMode else { return .ignored }
            if reviewFocusedIndex > 0 { reviewFocusedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard isInReviewMode else { return .ignored }
            if reviewFocusedIndex < droppedFiles.count - 1 { reviewFocusedIndex += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            guard isInReviewMode, let jobIndex = reviewJobIndex(for: reviewFocusedIndex) else { return .ignored }
            editingFileIndex = jobIndex
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1")) { _ in
            guard isInReviewMode, let jobIndex = reviewJobIndex(for: reviewFocusedIndex) else { return .ignored }
            processor.updateClassification(at: jobIndex, to: .documentStart)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "2")) { _ in
            guard isInReviewMode, let jobIndex = reviewJobIndex(for: reviewFocusedIndex) else { return .ignored }
            processor.updateClassification(at: jobIndex, to: .documentContinuation)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "3")) { _ in
            guard isInReviewMode, let jobIndex = reviewJobIndex(for: reviewFocusedIndex) else { return .ignored }
            processor.updateClassification(at: jobIndex, to: .boxLabel)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "4")) { _ in
            guard isInReviewMode, let jobIndex = reviewJobIndex(for: reviewFocusedIndex) else { return .ignored }
            processor.updateClassification(at: jobIndex, to: .folderLabel)
            return .handled
        }
    }

    // MARK: - Per-item actions (Files pane inline disclosure)

    private func performFileAction(_ action: ItemAction, on itemID: String) {
        guard let jobIndex = processor.jobs.firstIndex(where: { $0.id.uuidString == itemID }) else { return }
        if processor.reOCRSourceURLs.contains(processor.jobs[jobIndex].sourceURL) {
            guard action == .viewText else { return }
        }
        switch action {
        case .retry:
            guard let outDir = outputDirectory else { return }
            // Prevent re-entrant retries while this job is already being OCR'd.
            guard processor.jobs[jobIndex].status != .processing else { return }
            Task {
                await processor.retryOne(
                    index: jobIndex, outputDirectory: outDir)
            }
        case .changeRotation:
            fileRotationRetryTarget = FileRotationRetryTarget(jobIndex: jobIndex)
        case .viewText:
            fileTextViewerTarget = FileTextViewerTarget(jobIndex: jobIndex)
        case .reclassify:
            editingFileIndex = jobIndex
        case .revealFiles, .fileAsImageOnly:
            break
        }
    }

    private var segmentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Document Segments (\(processor.segments.count))")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(processor.segments.enumerated()), id: \.offset) { index, seg in
                    HStack(spacing: 6) {
                        if seg.isBox {
                            Circle().fill(.red).frame(width: 8, height: 8)
                        } else if seg.isFolder {
                            Circle().fill(.purple).frame(width: 8, height: 8)
                        } else {
                            Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        }
                        Text("Segment \(index + 1): \(seg.pdfURLs.count) page\(seg.pdfURLs.count == 1 ? "" : "s")")
                            .font(.caption)
                        if seg.isBox { Text("(Box)").font(.caption).foregroundStyle(.red) }
                        if seg.isFolder { Text("(Folder)").font(.caption).foregroundStyle(.purple) }
                        Spacer()
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var collectionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Collections (\(processor.collectionSegments.count))")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(processor.collectionSegments.enumerated()), id: \.offset) { _, seg in
                    HStack(spacing: 6) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                        Text("\(seg.collectionName): \(seg.fileURLs.count) file\(seg.fileURLs.count == 1 ? "" : "s")")
                            .font(.caption)
                        Spacer()
                    }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Keychain Explanation Sheet

    private var keychainExplanationSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
                .padding(.top, 8)

            Text("Secure API Key Storage")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 14) {
                keychainInfoRow(
                    icon: "key.fill",
                    title: "Keychain Storage",
                    detail: "Your API keys are stored in the macOS Keychain, the same secure system used by Safari, Mail, and other Apple apps to store passwords."
                )
                keychainInfoRow(
                    icon: "lock.fill",
                    title: "Encrypted & Protected",
                    detail: "Keys are encrypted by macOS and protected by your login password. They are never stored in plain text or in app preferences."
                )
                keychainInfoRow(
                    icon: "app.badge.checkmark",
                    title: "App-Only Access",
                    detail: "Only Archive Processor can read the keys it stores. Other apps cannot access them without your explicit permission."
                )
                keychainInfoRow(
                    icon: "trash",
                    title: "Easy to Remove",
                    detail: "Clear the API key field at any time to delete it from the Keychain. You can also manage stored keys in Keychain Access."
                )
            }
            .padding(.horizontal, 8)

            Text("macOS may ask you to allow Keychain access for each provider item. Click \"Always Allow\" for every prompt; Settings may read several keys at once.")
                .font(.caption)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button("Got It") {
                keychainExplained = true
                showKeychainSheet = false
            }
            .prominentButtonStyle()
            .controlSize(.large)
            .padding(.bottom, 4)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func keychainInfoRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func handleDroppedURLs(_ urls: [URL]) {
        admit(urls, sortAll: true)
    }

    /// W47.ct-processor-intake: a folder holding folders is read as a tree only when the user says so; otherwise, and
    /// for every other drop, its own files as before (`ProcessFilesTree.collect`).
    private func admit(_ urls: [URL], sortAll: Bool) {
        guard canAddFiles, !urls.isEmpty else { return }
        let generation = intakeGeneration
        inputLocationCheck = Task {
            defer { inputLocationCheck = nil }
            guard await CloudDriveWarning.confirmUse(of: urls),
                  generation == intakeGeneration, !processor.isProcessing, !isInReviewMode else { return }
            admitCheckedURLs(urls, sortAll: sortAll)
        }
    }

    private func admitCheckedURLs(_ urls: [URL], sortAll: Bool) {
        let holding = urls.filter(ProcessFilesTree.hasSubfolders)
        guard holding.isEmpty else {
            treeQuestion = TreeQuestion(urls: urls, sortAll: sortAll, names: holding.map(\.lastPathComponent))
            return
        }
        add(ProcessFilesTree.collect(urls, accept: isImageFile, sortAll: sortAll, readSubfolders: false))
    }

    private func add(_ intake: ProcessFilesTree.Intake) {
        showingPendingIntake = true
        droppedFiles.append(contentsOf: intake.files)
        droppedSubfolders.merge(intake.subfolders) { $1 }
        flatDotFolders.merge(intake.flatDotFolders) { $1 }
        var seen = Set(foldersBeyondDepth)
        foldersBeyondDepth.append(contentsOf: intake.foldersBeyondDepth.filter { seen.insert($0).inserted })
    }

    private func replaceFiles(with files: [URL]) {
        droppedFiles = files
        stagedSelection = []
        droppedSubfolders = [:]
        flatDotFolders = [:]
        foldersBeyondDepth = []
        processor.treeIntakeWarnings = []
        showingPendingIntake = false
        intakeGeneration += 1
        readingTree = false
    }

    /// The answer to `treeQuestion`. Reading a whole tree is done off the main thread.
    private func answer(_ question: TreeQuestion, readSubfolders: Bool) {
        treeQuestion = nil
        guard readSubfolders else {
            add(ProcessFilesTree.collect(question.urls, accept: isImageFile, sortAll: question.sortAll, readSubfolders: false))
            return
        }
        let preOCRed = preOCRedInput, urls = question.urls, sortAll = question.sortAll
        let generation = intakeGeneration
        readingTree = true
        Task {
            let intake = await Task.detached(priority: .userInitiated) {
                ProcessFilesTree.collect(urls, accept: { ProcessFilesTree.isInput($0, preOCRed: preOCRed) }, sortAll: sortAll)
            }.value
            guard generation == intakeGeneration else { return }
            readingTree = false
            if !processor.isProcessing { add(intake) }
        }
    }

    private func selectFiles() {
        guard canAddFiles else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .tiff, .pdf]
        if panel.runModal() == .OK {
            admit(panel.urls, sortAll: false)   // W47.ct-processor-intake
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Output Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        if CollectionSettingsFile.read(in: url) == .missing { collectionInterview = .collection(url) }
    }

    private func isImageFile(_ url: URL) -> Bool {
        // Pre-OCRed input is the PDF-only tagging path. Otherwise accept images AND PDFs: images OCR
        // normally, a multi-page PDF auto-routes to the re-OCR transform, and a single-page PDF is
        // OCR'd like an image. A wrong-type file is still rejected at the door.
        ProcessFilesTree.isInput(url, preOCRed: preOCRedInput)
    }

    private func replaceFilesForResume(_ urls: [URL]) {
        replaceFiles(with: urls)
        if let captureHandoff = OCRProcessor.savedCatalogueRun()?.captureHandoffPhotos {
            stagedSelection = Set(captureHandoff.keys).intersection(urls)
            capture.registerHandoff(Array(stagedSelection))
        }
    }

    private func resumePendingBatch() {
        if let urls = processor.pendingBatchFileURLs {
            replaceFilesForResume(urls)
        }
        processor.passSourceTags = passSourceTags && enableTagging
        processor.taggingMode = taggingMode
        processor.rotationMode = rotationMode
        processor.reviewRotation = reviewRotation
        processor.exportOriginals = outputImageFile   // legacy fallback; a v2 runtime snapshot wins on resume
        processor.mergeDocuments = mergeDocuments
        processor.tagVocabulary = tagVocabulary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        processor.processingTask = Task {
            await processor.resumeBatch(apiKey: apiKey)
        }
    }

    private func resumePendingRun(readWithoutClusterText: Bool = false) {
        guard let key = processor.pendingRunResumeKey(fieldKey: apiKey) else { return }
        if let urls = processor.pendingRunFileURLs {
            replaceFilesForResume(urls)
        }
        processor.passSourceTags = passSourceTags && enableTagging
        processor.taggingMode = taggingMode
        processor.rotationMode = rotationMode
        processor.reviewRotation = reviewRotation
        processor.exportOriginals = outputImageFile   // legacy fallback; a v2 runtime snapshot wins on resume
        processor.mergeDocuments = mergeDocuments
        processor.tagVocabulary = tagVocabulary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        processor.processingTask = Task {
            await processor.resumeRun(apiKey: key, readWithoutClusterText: readWithoutClusterText)
        }
    }

    private func resumePendingMixedPDF(readWithoutClusterText: Bool = false) {
        if let urls = processor.pendingMixedPDFFileURLs { replaceFilesForResume(urls) }
        processor.processingTask = Task {
            await processor.resumeMixedPDF(apiKey: apiKey, keyProvider: effectiveProvider,
                                           readWithoutClusterText: readWithoutClusterText)
        }
    }

    /// Start, unless the output collection says its pages must not train and this run would send them where they
    /// may: then the warning asks first (W46.training-optout-run).
    private func startProcessing() {
        guard canStartProcessing else { return }
        if let warning = trainingRunWarning() {
            trainingWarning = warning
            return
        }
        beginProcessing()
    }

    /// The warning for this run, or nil: the output folder's collection, its project and the general layer, as the
    /// run freezes them, and the reader and the segmenter as the run would send their pages.
    private func trainingRunWarning() -> String? {
        guard let outDir = outputDirectory else { return nil }
        var doc: CollectionSettingsDocument?
        if case .document(let d) = CollectionSettingsFile.read(in: outDir) { doc = d }
        let resolver = SettingsLayerStore.shared.resolver(for: doc)
        guard resolver.resolve(.noTraining).value.bool == true else { return nil }
        var resources = SettingsResources(macMemoryGB: SettingsLayerStore.thisMacMemoryGB)
        resources.trainingOff = Set(resolver.resolve(.trainingOff).value.strings ?? [])
        let gatewayKnown = SettingsTraining.gatewayHasKnownTerms(currentGatewayConfig)
        var ways: [(SettingsTraining.RunWay, String)] = [
            (SettingsTraining.readingWay(provider: effectiveProvider, modelID: effectiveModel.id,
                                         gateway: currentGatewayConfig != nil, gatewayKnown: gatewayKnown,
                                         localAgent: currentLocalAgentConfig?.tool),
             "reading and tagging the pages"),
        ]
        // Apple Vision's judgement pass sends its text to the chosen provider on that provider's key.
        if useAppleVision && visionUseLLMJudgment {
            ways.append((SettingsTraining.readingWay(provider: selectedProvider, modelID: selectedModel.id, gateway: false,
                                                     localAgent: nil), "judging and tagging Vision's text"))
        }
        // The direct-provider path's other readers (`OCRProcessor`: the gateway and the Local Agent are the user's
        // single route): a kind's own reader, the cascade's escalation, and a refused page's second reader.
        let gateway = currentGatewayConfig
        let direct = currentLocalAgentConfig == nil && gateway == nil
        if direct {
            for choice in Set(pageReaderPlan.pages.values.map { "\($0.choice.provider.rawValue)|\($0.choice.modelID)" }).sorted() {
                let parts = choice.split(separator: "|", maxSplits: 1).map(String.init)
                guard let provider = LLMProvider(rawValue: parts[0]) else { continue }
                ways.append((SettingsTraining.readingWay(provider: provider, modelID: parts.count > 1 ? parts[1] : "",
                                                         gateway: false, localAgent: nil), "reading pages of one kind"))
            }
        }
        if direct || (gateway?.isLocalModel == true && gateway?.localEscalates == true),
           let escalation = OCRCascade.fromDefaults().escalationModel {
            ways.append((SettingsTraining.readingWay(provider: escalation.provider, modelID: escalation.id, gateway: false,
                                                     localAgent: nil), "reading the pages the first reader fails"))
        }
        if direct && !useAppleVision {
            ways += SettingsTraining.refusalFallbackWays(
                claudeByPlan: segmentationRoutes.claudeUsesCLI,
                openRouterKey: KeychainHelper.exists(account: LLMProvider.openrouter.rawValue),
                mistralKey: KeychainHelper.exists(account: LLMProvider.mistral.rawValue))
                .map { ($0, "reading a page the first reader refuses") }
        }
        ways += SettingsTraining.segmentationWays(segmentationPlan, routes: segmentationRoutes,
                                                  options: try? SegmentationOptions.loadBundled())
            .map { ($0, "finding where documents begin") }
        return SettingsTraining.runWarning(ways, resources: resources)
    }

    /// W47.ct-processor-intake: the tree's folders for the files listed now (a file removed from the list is not).
    private var plannedSubfolders: [URL: String] {
        guard !droppedSubfolders.isEmpty, !preOCRedInput else { return [:] }
        let listed = Set(droppedFiles)
        return droppedSubfolders.filter { listed.contains($0.key) }
    }

    /// Start, once a tree's level map has been offered for the output folder (W47.ct-processor-intake).
    private func beginProcessing() {
        guard let outDir = outputDirectory else { return }
        if let tree = ProcessFilesTree.treeHoldingOutput(subfolders: plannedSubfolders, outputDirectory: outDir) {
            processor.statusMessage = ProcessFilesTree.overlapMessage(tree)
            return
        }
        if let draft = ProcessFilesTree.levelsToOffer(files: droppedFiles, subfolders: plannedSubfolders,
                                                      outputDirectory: outDir) {
            containerLevelsError = nil
            containerLevels = draft
            return
        }
        runProcessing()
    }

    private func runProcessing(confirmedMonthlyLimit: Bool = false) {
        guard canStartProcessing, let outDir = outputDirectory else { return }
        // A confirmation sheet may have been open while a key or sign-in changed. Check again
        // before creating the processing task, including when Start is reached by shortcut.
        if let spec = windowSegmentationSpec {
            segmentationRoutes = SegmentationRoutes.currentPreselecting()
            if WindowStageTransport.credentialIssue(spec, routes: segmentationRoutes) != nil { return }
        }
        if let gatewaySetupIssue {
            processor.statusMessage = gatewaySetupIssue
            return
        }
        let provider = effectiveProvider
        let model = effectiveModel
        let useBatch = effectiveBatchMode
        if let warning = unavailableOpenRouterSelection {
            processor.statusMessage = warning
            return
        }
        // The listing can refresh off the main actor between resolution and the availability check.
        if provider == .openrouter, !useGateway, !useLocalAgent,
           let id = modelStore.selectedModelIDs[provider.rawValue], !id.isEmpty, id != model.id {
            processor.statusMessage = OpenRouterRoute.unavailableMessage(id)
            return
        }
        if !confirmedMonthlyLimit, let limit = settingsStore.resolver(at: outDir).monthlyLimitUSD {
            let pricedModel = useAppleVision && visionUseLLMJudgment && !isPDFOnlyReOCR ? selectedModel : model
            let usesReader = !preOCRedInput || classifyPreOCRedInput
            guard !usesReader || ProcessFilesMonthlySpend.hasPrice(model: pricedModel, gateway: currentGatewayConfig,
                                                     localAgent: currentLocalAgentConfig,
                                                     claudeBilling: claudeUsage.billing(for: claudeBinary)) else {
                processor.statusMessage = "This reader has no price estimate. Choose a priced or free reader to use the monthly spending limit."
                return
            }
            let spent = settingsStore.spentThisMonthUSD()
            let remaining = ProcessFilesMonthlySpend.remaining(limit: limit, spent: spent)
            let readingCost = useLocalAgent ? 0 : CostEstimator.runTotal(
                images: costEstimate, directPDFPages: pdfPageEstimate, batch: useBatch)
            let segmentationCost: Double
            if case .windows = segmentationPlan, segmentationPageCount > 1 {
                segmentationCost = segmentationRow?.apiDollars ?? 0
            } else {
                segmentationCost = 0
            }
            let estimate = readingCost + segmentationCost
            if !ProcessFilesMonthlySpend.fits(estimate, remaining: remaining) {
                let detail = useBatch
                    ? "The app submits the provider batch only if all its requests fit within the remaining budget."
                    : "The app stops before the next paid step that would exceed the limit and saves the results it can resume."
                monthlyLimitWarning = "This run is estimated at \(CostEstimate.money(estimate)). About "
                    + "\(CostEstimate.money(remaining)) remains of this month's \(CostEstimate.money(limit)) limit. \(detail)"
                return
            }
        }
        intakeGeneration += 1   // a tree still being read is not added to a started run
        readingTree = false
        let trimmedPrompt = customOCRPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = SegmentationContext(
            previousTextCharCount: Int(contextCharCount),
            sendPreviousImage: !useAppleVision && sendPreviousImage && segmentationPlan.usesPerPageClassifier,
            customPrompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
            imageScale: imageScale / 100.0
        )
        processor.passSourceTags = passSourceTags && enableTagging
        processor.taggingMode = taggingMode
        processor.rotationMode = rotationMode
        processor.reviewRotation = reviewRotation
        // Pre-grouped segmentation only applies when the loaded files match a Live Capture handoff.
        if hasCaptureGrouping {
            processor.preGroupedBoundaries = captureBoundaries
            processor.preGroupedTypes = captureTypes
            processor.preGroupedQualities = captureQualities.count == droppedFiles.count ? captureQualities : []
            processor.preGroupedYears = captureYears.count == droppedFiles.count ? captureYears : []
            processor.preGroupedMonths = captureMonths.count == droppedFiles.count ? captureMonths : []
            processor.preGroupedSubjects = captureSubjects.count == droppedFiles.count ? captureSubjects : []
            processor.exportOriginals = outputImageFile   // two-file output: also emit a sized image
        } else {
            processor.preGroupedBoundaries = []
            processor.preGroupedTypes = []
            processor.preGroupedQualities = []
            processor.preGroupedYears = []
            processor.preGroupedMonths = []
            processor.preGroupedSubjects = []
            processor.exportOriginals = outputImageFile
        }
        processor.mergeDocuments = mergeDocuments
        processor.pageReaders = pageReaderPlan   // W41.app-page-kind; the run ignores it where it does not apply
        processor.institutionalComputeImport = allowsPageReaders ? institutionalComputeImport : nil   // W41.app-institutional-compute
        processor.plannedOutputSubfolders = plannedSubfolders   // W47.ct-processor-intake
        processor.treeIntakeWarnings = treeIntakeWarnings
        showingPendingIntake = false
        processor.tagVocabulary = tagVocabulary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let gateway = currentGatewayConfig

        processor.processingTask = Task {
            await processor.startProcessing(
                files: droppedFiles,
                provider: provider,
                model: model,
                thinkingLevel: !useAppleVision && !useGateway && model.supportsThinking ? selectedThinking : nil,
                apiKey: useAppleVision ? "" : apiKey,
                outputDirectory: outDir,
                batchMode: useBatch,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: useAppleVision && !visionUseLLMJudgment ? false : enableCollectionSegmentation,
                confirmCollectionIDs: (!useAppleVision || visionUseLLMJudgment) && confirmCollectionIDs && enableCollectionSegmentation,
                reviewDocumentSegmentation: (!useAppleVision || visionUseLLMJudgment) && reviewDocumentSegmentation && enableCollectionSegmentation,
                reviewFreshDocumentSegmentation: reviewDocumentSegmentation,
                preOCRedInput: preOCRedInput,
                skipAlreadyProcessed: skipAlreadyProcessed,
                segmentationContext: context,
                gatewayConfig: gateway,
                localAgent: currentLocalAgentConfig,
                postCorrectionRequested: ocrPostCorrection && !useGateway && !useLocalAgent
            )
        }
    }
}

private struct MonthlyLimitPresentation: ViewModifier {
    @Binding var warning: String?
    let start: () -> Void

    func body(content: Content) -> some View {
        content.alert("This run may reach the monthly spending limit",
                      isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
            Button("Start Within Limit") {
                warning = nil
                start()
            }
            Button("Cancel", role: .cancel) { warning = nil }
        } message: {
            Text(warning ?? "")
        }
    }
}

/// W46.training-optout-run: Start's question when the run would send a collection's pages where they may train a
/// provider's models. Kept out of `OCRView.body` for the type-check reason below.
private struct TrainingWarningPresentation: ViewModifier {
    @Binding var warning: String?
    let runAnyway: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("These pages may train a provider's models",
                   isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
                Button("Run anyway") {
                    warning = nil
                    runAnyway()
                }
                Button("Cancel", role: .cancel) { warning = nil }
            } message: {
                Text(warning ?? "")
            }
    }
}

/// W40.fix-processor-instcompute-resume-silent: a resume whose cluster folder is gone asks before its pages are
/// bought from the run's model. Kept out of `OCRView.body` for the same type-check reason as the stage's below.
private struct InstitutionalComputeResumePresentation: ViewModifier {
    @ObservedObject var processor: OCRProcessor
    /// Resume again, reading without the cluster's text; true for the interrupted mixed PDF run.
    let readWithModel: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .alert(processor.institutionalComputeResumePrompt?.title ?? "",
                   isPresented: Binding(get: { processor.institutionalComputeResumePrompt != nil }, set: { _ in })) {
                Button("Read with the run's model") {
                    let mixedPDF = processor.institutionalComputeResumePrompt?.mixedPDF ?? false
                    processor.institutionalComputeResumePrompt = nil
                    readWithModel(mixedPDF)
                }
                Button("Stop", role: .cancel) { processor.declineInstitutionalComputeResume() }
            } message: {
                Text(processor.institutionalComputeResumePrompt?.message ?? "")
            }
    }
}

/// The window stage's presentations, kept out of `OCRView.body`: with them inline its modifier chain grew past what
/// the Tart VM's compiler would type-check ("unable to type-check this expression in reasonable time").
private struct SegmentationStagePresentations: ViewModifier {
    @ObservedObject var processor: OCRProcessor

    func body(content: Content) -> some View {
        content
            // W36.seg-opt-review: the flagged pass, and the choice when a window run cannot finish.
            .reviewWindow(isPresented: $processor.awaitingFlaggedReview) {
                FlaggedBoundaryReviewSheet(processor: processor)
            }
            // W36.seg-opt-subscription: the Claude plan's first measurement on this account.
            .alert("Your Claude plan, measured",
                   isPresented: Binding(get: { processor.planCheckPrompt != nil }, set: { _ in })) {
                Button("Go on") { processor.answerPlanCheck(goOn: true) }
                Button("Stop here", role: .cancel) { processor.answerPlanCheck(goOn: false) }
            } message: {
                Text((processor.planCheckPrompt?.message ?? "")
                     + "\n\nLater folders show this figure before they start. Go on with this folder?")
            }
            .alert(processor.windowStopPrompt?.title ?? WindowStopPrompt.defaultTitle,
                   isPresented: Binding(get: { processor.windowStopPrompt != nil }, set: { _ in })) {
                Button("Check the rest myself") { processor.answerWindowStop(.checkMyself) }
                // Stop is offered only when the run can be resumed: a paid batch's journal is already retired
                // here, so stopping would leave its finished OCR untagged with nothing to resume from.
                if processor.windowStopPrompt?.canResumeLater == true {
                    Button("Stop and resume later", role: .cancel) { processor.answerWindowStop(.stop) }
                }
            } message: {
                Text((processor.windowStopPrompt?.message ?? "")
                     + (processor.windowStopPrompt?.canResumeLater == true
                        ? "\n\nYou can check every boundary the model did not answer yourself, or stop and resume later."
                        : "\n\nYou can check every boundary the model did not answer yourself."))
            }
    }
}
