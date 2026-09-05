import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

struct OCRView: View {
    // MARK: - State
    /// Shared processor (injected so the Live Capture tab can stage files into this view).
    @ObservedObject var processor: OCRProcessor

    // Persisted via @AppStorage (UserDefaults)
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.selectedThinking) private var selectedThinking: ThinkingLevel = .low
    @AppStorage(DefaultsKeys.batchMode) private var batchMode: Bool = false
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput: Bool = false
    @AppStorage(DefaultsKeys.skipAlreadyProcessed) private var skipAlreadyProcessed: Bool = false
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation: Bool = false
    @AppStorage(DefaultsKeys.confirmCollectionIDs) private var confirmCollectionIDs: Bool = false
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }
    @AppStorage(DefaultsKeys.rotationModeRaw) private var rotationModeRaw: String = RotationMode.llmSingle.rawValue
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .llmSingle }
    @AppStorage(DefaultsKeys.reviewRotation) private var reviewRotation: Bool = false
    @AppStorage(DefaultsKeys.ocrWorkerCount) private var ocrWorkerCount: Int = 4
    /// Derived for compatibility with existing pipeline flags.
    private var enableTagging: Bool { taggingMode.enablesTagging }
    private var passSourceTags: Bool { taggingMode == .copySource }
    /// The dropped input will auto-route to the multi-page-PDF re-OCR transform (a pure document
    /// rebuild), so tagging/segmentation don't apply. Mirrors the pipeline's `autoReOCR` decision.
    private var isMultiPagePDFReOCR: Bool { droppedHasMultiPagePDF && !preOCRedInput }
    @AppStorage(DefaultsKeys.reviewDocumentSegmentation) private var reviewDocumentSegmentation: Bool = false
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
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL: String = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID: String = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName: String = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayUpstreamProvider) private var gatewayUpstreamProvider: LLMProvider = .anthropic

    // Local Agent CLI backend (persisted; mutually exclusive with the gateway)
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent: Bool = false
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentTool: LocalAgentTool = .claude
    // Apple Vision is the no-key, on-device backend selected in Settings.
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision: Bool = false
    @AppStorage(DefaultsKeys.visionUseLLMJudgment) private var visionUseLLMJudgment: Bool = false

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

    @AppStorage(DefaultsKeys.keychainExplained) private var keychainExplained: Bool = false

    // Transient
    @State private var droppedFiles: [URL] = []
    /// Whether any dropped file is a multi-page PDF (recomputed on droppedFiles change, so PDFs aren't
    /// re-opened on every render). Combined with `!preOCRedInput` this is the auto re-OCR routing the
    /// pipeline applies — surfaced here only to grey out the (inapplicable) Tagging controls.
    @State private var droppedHasMultiPagePDF = false
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

    init(processor: OCRProcessor) {
        _processor = ObservedObject(wrappedValue: processor)
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
    private var currentLocalAgentConfig: LocalAgentConfig? {
        useAppleVision ? nil : LocalAgentConfig.fromDefaults()
    }
    private var effectiveProvider: LLMProvider { useAppleVision ? .appleVision : selectedProvider }
    private var effectiveModel: LLMModel {
        useAppleVision ? LLMModel.appleVisionModels[0] : (currentGatewayConfig?.asLLMModel() ?? selectedModel)
    }
    private var visionWorkflowIsSupported: Bool {
        !useAppleVision || visionUseLLMJudgment || ((taggingMode == .none || taggingMode == .copySource)
            && !enableCollectionSegmentation)
    }
    private var visionJudgementKeyIsPresent: Bool { !apiKey.isEmpty }

    private func reloadAPIKey() {
        apiKey = useAppleVision
            ? (visionUseLLMJudgment ? (KeychainHelper.load(account: selectedProvider.rawValue) ?? "") : "")
            : (KeychainHelper.load(account: useGateway ? "Gateway" : selectedProvider.rawValue) ?? "")
    }

    private var costEstimate: CostEstimate? {
        guard !droppedFiles.isEmpty else { return nil }
        let model = useAppleVision && visionUseLLMJudgment ? selectedModel : effectiveModel
        return CostEstimator.estimate(
            fileCount: droppedFiles.count,
            model: model,
            enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput,
            sendPreviousImage: sendPreviousImage && taggingMode.llmSegments,
            contextCharCount: Int(contextCharCount),
            imageScale: imageScale / 100.0,
            rotationMode: rotationMode,
            useGateway: useGateway || useAppleVision,
            imageTokenProvider: useGateway ? gatewayUpstreamProvider : nil,
            visionTextOnly: useAppleVision && visionUseLLMJudgment
        )
    }

    /// Processing-time estimate for the current batch (LLM/processing time only).
    private var timeEstimate: TimeEstimate? {
        guard !droppedFiles.isEmpty else { return nil }
        let model = effectiveModel
        return TimeEstimator.estimate(
            fileCount: droppedFiles.count, model: model, rotationMode: rotationMode,
            sequentialOCR: contextCharCount > 0, enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput, useGateway: useGateway || useAppleVision, ocrWorkers: ocrWorkerCount)
    }

    private var gatewayHasCosts: Bool {
        gatewayInputCost >= 0 && gatewayOutputCost >= 0
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
#endif
        }
        .onChange(of: taggingModeRaw) { _, _ in
            if taggingMode.isManual { SystemTagsProvider.shared.warmUp() }
        }
        .onChange(of: droppedFiles) { _, files in
            // Recompute the multi-page-PDF flag off the main render path (opens PDFs once per change,
            // not per render). Short-circuits at the first multi-page PDF; non-PDFs never open a file.
            droppedHasMultiPagePDF = files.contains(where: PDFToImageConverter.isMultiPagePDF)
        }
        .onChange(of: processor.stagedCaptureFiles) { _, staged in
            guard !staged.isEmpty else { return }
            // Live Capture handed off pre-grouped photos → load them as the input files.
            droppedFiles = staged
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
            droppedFiles = staged
            captureBoundaries = processor.stagedCaptureBoundaries
            captureTypes = processor.stagedCaptureTypes
            captureQualities = processor.stagedCaptureQualities
            captureYears = processor.stagedCaptureYears
            captureMonths = processor.stagedCaptureMonths
            captureSubjects = processor.stagedCaptureSubjects
            processor.stagedCaptureFiles = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
            reloadAPIKey()
        }
        .onChange(of: selectedProvider) { _, _ in syncForProviderChange() }
        .onChange(of: useAppleVision) { _, _ in syncForProviderChange() }
        .onChange(of: visionUseLLMJudgment) { _, _ in syncForProviderChange() }
        .onReceive(NotificationCenter.default.publisher(for: .processingProfileApplied)) { _ in
            // An applied profile may change the model for the *current* provider (no provider change), so
            // re-sync the derived model/key state explicitly (the provider onChange above covers the rest).
            syncForProviderChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startProcessingRequested)) { _ in
            // ⌘R: run the normal Start action, but only when it's actually allowed and no field is being
            // edited — the shortcut is guarded exactly like the Start button.
            guard !TextEditingGuard.isEditingText, canStartProcessing else { return }
            startProcessing()
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from the Settings window: pick up any changed key / output folder. (The model is
            // no longer re-synced here — it is read live from `ModelSelectionStore`, which also covers the
            // case this never did: Settings open *beside* this window, where a macOS `WindowGroup` sees no
            // scene-phase transition at all.)
            guard phase == .active else { return }
            reloadAPIKey()
            if let path = UserDefaults.standard.string(forKey: DefaultsKeys.outputDirectory), FileManager.default.fileExists(atPath: path) {
                outputDirectory = URL(fileURLWithPath: path)
            }
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
                subtitle: "Re-run OCR for this file; the old output is replaced.",
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
        .onChange(of: apiKey) { _, newKey in
            guard !useAppleVision else { return }
            let account = useGateway ? "Gateway" : selectedProvider.rawValue
            if newKey.isEmpty {
                KeychainHelper.delete(account: account)
            } else {
                KeychainHelper.save(account: account, password: newKey)
            }
        }
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
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Resume Batch") { resumePendingBatch() }
                                    .buttonStyle(.borderedProminent)
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
                            Text("Enter your API key above, then click Resume to continue processing remaining files.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Resume Run") { resumePendingRun() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(apiKey.isEmpty || processor.isProcessing)
                                Button("Dismiss") { processor.dismissPendingRun() }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(4)
                    }
                }

                // Tagging mode stays in the main UI; other settings are in the Settings window (⌘,).
                GroupBox("Tagging") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Tagging", selection: $taggingModeRaw) {
                            ForEach(TaggingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                        .accessibilityIdentifier("ap.ocr.taggingPicker")
                        Text(isMultiPagePDFReOCR
                             ? "Not applied to a multi-page PDF — it is re-OCR'd into one alternating image/OCR-text PDF (a pure document rebuild, no tagging)."
                             : taggingMode.detail)
                            .font(.caption2).foregroundStyle(.tertiary)
                            .accessibilityIdentifier("ap.ocr.reOCRExplanation")
                    }
                    .padding(4)
                }
                .accessibilityIdentifier("ap.ocr.taggingPanel")
                .disabled(isMultiPagePDFReOCR)


                // Cost estimate
                if useAppleVision && !droppedFiles.isEmpty {
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
                                    : "Apple Vision transcribes locally with no API key or network request. It uses the Mac's performance cores.")
                                 : "Apple Vision is transcription-only. Select No tagging or Copy source file tags, and turn off Collection ID, before starting.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                            if visionUseLLMJudgment, let est = costEstimate {
                                HStack {
                                    Text("Text-only judgement:").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.classificationFormatted)
                                }
                                if taggingMode.llmTags {
                                    HStack {
                                        Text("Tags / dates:").foregroundStyle(.secondary)
                                        Spacer()
                                        Text(est.taggingFormatted)
                                    }
                                }
                                if enableCollectionSegmentation {
                                    HStack {
                                        Text("Collection ID:").foregroundStyle(.secondary)
                                        Spacer()
                                        Text(est.collectionFormatted)
                                    }
                                }
                                Divider()
                                HStack {
                                    Text("Total (text-only):").fontWeight(.medium)
                                    Spacer()
                                    Text(est.totalStandardFormatted).fontWeight(.medium)
                                }
                            }
                        }
                        .padding(4)
                    }
                } else if useLocalAgent && !droppedFiles.isEmpty {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "infinity.circle").foregroundStyle(.secondary)
                                Text("Included in your subscription — usage limits apply.")
                                    .accessibilityIdentifier("ap.ocr.localAgentCost")
                                Spacer()
                            }
                            Text("The \(localAgentTool.displayName) CLI uses your subscription login — no per-page charge. If you hit your plan's usage window, the app paces and resumes when it resets. It runs at a low concurrency (1–2), so expect it to be slower than a metered API.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                                .accessibilityIdentifier("ap.ocr.localAgentPacing")
                        }
                        .padding(4)
                    }
                } else if useGateway && !gatewayHasCosts && !droppedFiles.isEmpty {
                    GroupBox("Cost Estimate") {
                        Text("Enter model pricing in Gateway Configuration above to see cost estimates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(4)
                    }
                } else if let est = costEstimate {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Files:").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(est.fileCount)")
                            }
                            if !preOCRedInput {
                                HStack {
                                    Text("OCR + classification:").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.ocrFormatted)
                                }
                            }
                            if preOCRedInput && (enableTagging || enableCollectionSegmentation) {
                                HStack {
                                    Text("Classification (text-only):").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.classificationFormatted)
                                }
                            }
                            if taggingMode.llmTags {
                                HStack {
                                    Text("Tagging (~\(max(1, est.fileCount / 3)) segments):").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.taggingFormatted)
                                }
                            }
                            if enableCollectionSegmentation {
                                HStack {
                                    Text("Collection ID:").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.collectionFormatted)
                                }
                            }
                            if est.rotationCost > 0 {
                                HStack {
                                    Text("Rotation:").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.rotationFormatted)
                                }
                            }
                            Divider()
                            HStack {
                                Text("Total (standard):").fontWeight(.medium)
                                Spacer()
                                Text(est.totalStandardFormatted).fontWeight(.medium)
                            }
                            if !useGateway && batchMode && !preOCRedInput {
                                HStack {
                                    Text("Total (batch):").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.totalBatchFormatted)
                                }
                            }
                            Text(useGateway ? "Estimates based on user-provided pricing. Actual gateway costs may differ." : "Estimates calibrated from actual API usage with high-resolution archival photos. Actual costs may vary with image resolution.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                            if let t = timeEstimate {
                                Divider()
                                HStack {
                                    Text("Est. time:").fontWeight(.medium)
                                    Spacer()
                                    Text(t.totalFormatted).fontWeight(.medium)
                                }
                                Text("Processing time only (no user interaction). OCR \(t.ocrFormatted)\(t.rotationSeconds > 0 ? " · rotation \(t.rotationFormatted) (overlaps OCR)" : "")\(taggingMode.llmTags ? " · tagging \(t.taggingFormatted)" : "").")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(4)
                    }
                }

                // Output directory
                GroupBox("Output Folder") {
                    HStack {
                        Text(outputDirectory?.lastPathComponent ?? "Not set")
                            .foregroundStyle(outputDirectory == nil ? .secondary : .primary)
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
                .buttonStyle(.borderedProminent)
                .disabled(!canStartProcessing)

                if processor.isProcessing || isInReviewMode {
                    Button("Cancel") { processor.cancel() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - File Panel

    /// Whether the file pane is in an interactive review state
    private var isInReviewMode: Bool {
        processor.awaitingFinalReview
    }

    /// Whether a run can be started now — the single source of truth for both the Start button's enabled
    /// state and the ⌘R "Start Processing" shortcut (so the shortcut can never start a run the button
    /// wouldn't allow: no files, no key, no output folder, already busy, or mid-review).
    private var canStartProcessing: Bool {
        !droppedFiles.isEmpty && (useAppleVision ? (!visionUseLLMJudgment || visionJudgementKeyIsPresent) : !apiKey.isEmpty) && visionWorkflowIsSupported && outputDirectory != nil
            && !processor.isProcessing && !isInReviewMode
            && processor.pendingBatchInfo == nil && processor.pendingRunInfo == nil
    }

    /// Re-point the API-key field after `selectedProvider` changes from anywhere (the ⌘⌥P cycle
    /// shortcut, an applied profile, or a return from Settings), so a run never uses the wrong Keychain
    /// account. The model needs no hook — `selectedModel` reads the store keyed by the *current*
    /// provider, so it re-points on the same render.
    private func syncForProviderChange() {
        reloadAPIKey()
    }

    private var filePanel: some View {
        ScrollView {
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
                        .disabled(processor.isProcessing)   // don't mutate the input set mid-run
                        if !droppedFiles.isEmpty {
                            Button("Clear") { droppedFiles = []; captureBoundaries = []; captureTypes = []; captureQualities = []; captureYears = []; captureMonths = []; captureSubjects = []; processor.jobs = []; processor.segments = []; processor.collectionSegments = []; processor.progress = 0; processor.statusMessage = ""; processor.failedFiles = [] }
                                .buttonStyle(.bordered)
                                .disabled(processor.isProcessing)   // Clear mid-run would wipe processor.jobs out from under the running task (wasted paid calls, discarded output)
                        }
                    }
                }

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
                            .foregroundStyle(.secondary)
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
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // Progress
                if processor.isProcessing || (!processor.statusMessage.isEmpty && !isInReviewMode) {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: processor.progress)
                        Text(processor.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                Text(preOCRedInput ? "Drop PDFs here" : "Drop images or PDFs here")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("or use Add Files…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .allowsHitTesting(false)
            DropReceiver(isTargeted: $isTargeted) { urls in
                handleDroppedURLs(urls)
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
                            actions: ItemActionHandler { action, id in performFileAction(action, on: id) },
                            isExpanded: expandedFileID == itemID,
                            presetClassification: capturePreGroupedClassification(at: index)
                        )
                        .contentShape(Rectangle())
                        .id(index)
                        .onTapGesture(count: 2) {
                            if isInReviewMode, index < processor.jobs.count {
                                editingFileIndex = index
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
                    if entering { reviewFocusedIndex = 0 }
                }
            }
            if !isInReviewMode {
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
            guard isInReviewMode, reviewFocusedIndex < processor.jobs.count else { return .ignored }
            editingFileIndex = reviewFocusedIndex
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1")) { _ in
            guard isInReviewMode, reviewFocusedIndex < processor.jobs.count else { return .ignored }
            processor.updateClassification(at: reviewFocusedIndex, to: .documentStart)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "2")) { _ in
            guard isInReviewMode, reviewFocusedIndex < processor.jobs.count else { return .ignored }
            processor.updateClassification(at: reviewFocusedIndex, to: .documentContinuation)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "3")) { _ in
            guard isInReviewMode, reviewFocusedIndex < processor.jobs.count else { return .ignored }
            processor.updateClassification(at: reviewFocusedIndex, to: .boxLabel)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "4")) { _ in
            guard isInReviewMode, reviewFocusedIndex < processor.jobs.count else { return .ignored }
            processor.updateClassification(at: reviewFocusedIndex, to: .folderLabel)
            return .handled
        }
    }

    // MARK: - Per-item actions (Files pane inline disclosure)

    private func performFileAction(_ action: ItemAction, on itemID: String) {
        guard let jobIndex = processor.jobs.firstIndex(where: { $0.id.uuidString == itemID }) else { return }
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
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button("Got It") {
                keychainExplained = true
                showKeychainSheet = false
            }
            .buttonStyle(.borderedProminent)
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
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func handleDroppedURLs(_ urls: [URL]) {
        var imageURLs: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                imageURLs.append(contentsOf: contents.filter { isImageFile($0) })
            } else if isImageFile(url) {
                imageURLs.append(url)
            }
        }
        droppedFiles.append(contentsOf: imageURLs.sorted { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .tiff, .pdf]
        if panel.runModal() == .OK {
            var urls: [URL] = []
            for url in panel.urls {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    urls.append(contentsOf: contents.filter { isImageFile($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent })
                } else if isImageFile(url) {
                    urls.append(url)
                }
            }
            droppedFiles.append(contentsOf: urls)
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Output Folder"
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        // Pre-OCRed input is the PDF-only tagging path. Otherwise accept images AND PDFs: images OCR
        // normally, a multi-page PDF auto-routes to the re-OCR transform, and a single-page PDF is
        // OCR'd like an image. A wrong-type file is still rejected at the door.
        if preOCRedInput { return ext == "pdf" }
        return ext == "pdf" || ImageEncoding.acceptedImageExtensions.contains(ext)
    }

    private func resumePendingBatch() {
        if let urls = processor.pendingBatchFileURLs {
            droppedFiles = urls
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

    private func resumePendingRun() {
        if let urls = processor.pendingRunFileURLs {
            droppedFiles = urls
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
            await processor.resumeRun(apiKey: apiKey)
        }
    }

    private func startProcessing() {
        guard let outDir = outputDirectory else { return }
        let trimmedPrompt = customOCRPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = SegmentationContext(
            previousTextCharCount: Int(contextCharCount),
            sendPreviousImage: !useAppleVision && sendPreviousImage && taggingMode.llmSegments,
            customPrompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
            imageScale: imageScale / 100.0
        )
        processor.passSourceTags = passSourceTags && enableTagging
        processor.taggingMode = taggingMode
        processor.rotationMode = rotationMode
        processor.reviewRotation = reviewRotation
        // Pre-grouped segmentation only applies when the loaded files match a Live Capture handoff.
        if captureBoundaries.count == droppedFiles.count && !droppedFiles.isEmpty {
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
        processor.tagVocabulary = tagVocabulary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let gateway = currentGatewayConfig

        processor.processingTask = Task {
            await processor.startProcessing(
                files: droppedFiles,
                provider: effectiveProvider,
                model: effectiveModel,
                thinkingLevel: !useAppleVision && !useGateway && selectedModel.supportsThinking ? selectedThinking : nil,
                apiKey: useAppleVision ? "" : apiKey,
                outputDirectory: outDir,
                batchMode: (useGateway || useLocalAgent || useAppleVision) ? false : batchMode,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: useAppleVision && !visionUseLLMJudgment ? false : enableCollectionSegmentation,
                confirmCollectionIDs: (!useAppleVision || visionUseLLMJudgment) && confirmCollectionIDs && enableCollectionSegmentation,
                reviewDocumentSegmentation: (!useAppleVision || visionUseLLMJudgment) && reviewDocumentSegmentation && enableCollectionSegmentation,
                preOCRedInput: preOCRedInput,
                skipAlreadyProcessed: skipAlreadyProcessed,
                segmentationContext: context,
                gatewayConfig: gateway,
                localAgent: currentLocalAgentConfig
            )
        }
    }
}
