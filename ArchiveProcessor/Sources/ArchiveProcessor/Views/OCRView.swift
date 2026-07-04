import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

struct OCRView: View {
    // MARK: - State
    /// Shared processor (injected so the Live Capture tab can stage files into this view).
    @ObservedObject var processor: OCRProcessor

    // Persisted via @AppStorage (UserDefaults)
    @AppStorage("selectedProvider") private var selectedProvider: LLMProvider = .gemini
    @AppStorage("selectedThinking") private var selectedThinking: ThinkingLevel = .low
    @AppStorage("batchMode") private var batchMode: Bool = false
    @AppStorage("preOCRedInput") private var preOCRedInput: Bool = false
    @AppStorage("enableCollectionSegmentation") private var enableCollectionSegmentation: Bool = false
    @AppStorage("confirmCollectionIDs") private var confirmCollectionIDs: Bool = false
    @AppStorage("taggingModeRaw") private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }
    @AppStorage("rotationModeRaw") private var rotationModeRaw: String = RotationMode.llmSingle.rawValue
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .llmSingle }
    @AppStorage("reviewRotation") private var reviewRotation: Bool = false
    @AppStorage("ocrWorkerCount") private var ocrWorkerCount: Int = 4
    /// Derived for compatibility with existing pipeline flags.
    private var enableTagging: Bool { taggingMode.enablesTagging }
    private var passSourceTags: Bool { taggingMode == .copySource }
    @AppStorage("reviewDocumentSegmentation") private var reviewDocumentSegmentation: Bool = false
    @AppStorage("enableSegmentJSON") private var enableSegmentJSON: Bool = true
    @AppStorage("sendPreviousImage") private var sendPreviousImage: Bool = false
    @AppStorage("tagVocabulary") private var tagVocabulary: String = ""
    @AppStorage("contextCharCount") private var contextCharCount: Double = 0   // context slider removed; kept 0 (parallel OCR)
    @AppStorage("customOCRPrompt") private var customOCRPrompt: String = ""
    @AppStorage("mergeDocuments") private var mergeDocuments: Bool = false
    @AppStorage("imageResolutionPercent") private var imageScale: Double = 100
    @AppStorage("outputImageFile") private var outputImageFile: Bool = true   // two files (PDF + image) vs one (PDF only)

    // Gateway mode (persisted)
    @AppStorage("useGateway") private var useGateway: Bool = false
    @AppStorage("gatewayBaseURL") private var gatewayBaseURL: String = ""
    @AppStorage("gatewayModelID") private var gatewayModelID: String = ""
    @AppStorage("gatewayDisplayName") private var gatewayDisplayName: String = ""
    @AppStorage("gatewayInputCost") private var gatewayInputCost: Double = -1
    @AppStorage("gatewayOutputCost") private var gatewayOutputCost: Double = -1
    @AppStorage("gatewayUpstreamProvider") private var gatewayUpstreamProvider: LLMProvider = .anthropic

    // Initialized from persisted state in init()
    @State private var selectedModel: LLMModel
    @State private var apiKey: String
    @State private var outputDirectory: URL?

    @AppStorage("keychainExplained") private var keychainExplained: Bool = false

    // Transient
    @State private var droppedFiles: [URL] = []
    /// Pre-grouped segmentation from a Live Capture handoff (aligned to droppedFiles); empty otherwise.
    @State private var captureBoundaries: [Bool] = []
    @State private var captureTypes: [CaptureGroupType] = []
    /// Minimal on-phone tags from the same handoff (aligned to droppedFiles); empty otherwise.
    @State private var capturePriorities: [String?] = []
    @State private var captureYears: [Int?] = []
    @State private var captureMonths: [Int?] = []
    @State private var captureSubjects: [[String]] = []
    @State private var isTargeted = false
    @State private var showKeychainSheet = false
    @Environment(\.scenePhase) private var scenePhase

    // Inline segmentation edit & review navigation
    @State private var editingFileIndex: Int? = nil
    @State private var csvDropTargeted = false
    @State private var reviewFocusedIndex: Int = 0

    @ObservedObject private var customModelStore = CustomModelStore.shared

    init(processor: OCRProcessor) {
        _processor = ObservedObject(wrappedValue: processor)
        let provider = LLMProvider(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .gemini
        _selectedModel = State(initialValue: ModelSelectionStore.savedModel(for: provider))
        _apiKey = State(initialValue: "")
        _outputDirectory = State(initialValue: ModelSelectionStore.savedOutputDirectory())
    }

    private var currentGatewayConfig: GatewayConfig? {
        guard useGateway, !gatewayBaseURL.isEmpty, !gatewayModelID.isEmpty else { return nil }
        return GatewayConfig(
            baseURL: gatewayBaseURL,
            modelID: gatewayModelID,
            displayName: gatewayDisplayName.isEmpty ? "API Gateway" : gatewayDisplayName,
            inputCostPer1M: gatewayInputCost >= 0 ? gatewayInputCost : nil,
            outputCostPer1M: gatewayOutputCost >= 0 ? gatewayOutputCost : nil
        )
    }

    private var currentModels: [LLMModel] {
        let builtIn: [LLMModel]
        switch selectedProvider {
        case .anthropic: builtIn = LLMModel.anthropicModels
        case .gemini: builtIn = LLMModel.geminiModels
        case .mistral: builtIn = LLMModel.mistralModels
        }
        return builtIn + customModelStore.allCustomModels.filter { $0.provider == selectedProvider }
    }

    private var costEstimate: CostEstimate? {
        guard !droppedFiles.isEmpty else { return nil }
        let model = useGateway ? currentGatewayConfig?.asLLMModel() ?? selectedModel : selectedModel
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
            useGateway: useGateway,
            imageTokenProvider: useGateway ? gatewayUpstreamProvider : nil
        )
    }

    /// Processing-time estimate for the current batch (LLM/processing time only).
    private var timeEstimate: TimeEstimate? {
        guard !droppedFiles.isEmpty else { return nil }
        let model = useGateway ? currentGatewayConfig?.asLLMModel() ?? selectedModel : selectedModel
        return TimeEstimator.estimate(
            fileCount: droppedFiles.count, model: model, rotationMode: rotationMode,
            sequentialOCR: contextCharCount > 0, enableTagging: taggingMode.llmTags,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput, useGateway: useGateway, ocrWorkers: ocrWorkerCount)
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
            let isGateway = UserDefaults.standard.bool(forKey: "useGateway")
            apiKey = KeychainHelper.load(account: isGateway ? "Gateway" : selectedProvider.rawValue) ?? ""
            processor.checkForPendingBatch()
            if !keychainExplained {
                showKeychainSheet = true
            }
            // Warm the system-tag suggestions if a manual tagging mode is already selected.
            if taggingMode.isManual { SystemTagsProvider.shared.warmUp() }
        }
        .onChange(of: taggingModeRaw) { _, _ in
            if taggingMode.isManual { SystemTagsProvider.shared.warmUp() }
        }
        .onChange(of: processor.stagedCaptureFiles) { _, staged in
            guard !staged.isEmpty else { return }
            // Live Capture handed off pre-grouped photos → load them as the input files.
            droppedFiles = staged
            captureBoundaries = processor.stagedCaptureBoundaries
            captureTypes = processor.stagedCaptureTypes
            capturePriorities = processor.stagedCapturePriorities
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
            capturePriorities = processor.stagedCapturePriorities
            captureYears = processor.stagedCaptureYears
            captureMonths = processor.stagedCaptureMonths
            captureSubjects = processor.stagedCaptureSubjects
            processor.stagedCaptureFiles = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
            apiKey = KeychainHelper.load(account: useGateway ? "Gateway" : selectedProvider.rawValue) ?? ""
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from the Settings window: pick up any changed key / model / output folder.
            guard phase == .active else { return }
            apiKey = KeychainHelper.load(account: useGateway ? "Gateway" : selectedProvider.rawValue) ?? ""
            if let path = UserDefaults.standard.string(forKey: "outputDirectory"), FileManager.default.fileExists(atPath: path) {
                outputDirectory = URL(fileURLWithPath: path)
            }
            let modelId = UserDefaults.standard.string(forKey: ModelSelectionStore.modelKey(for: selectedProvider)) ?? ""
            if let m = currentModels.first(where: { $0.id == modelId }) {
                selectedModel = m
            } else if !currentModels.contains(where: { $0.id == selectedModel.id }) {
                // Saved model gone (e.g. a deleted custom model) and the current selection is no longer
                // valid → fall back to a valid model so a run can't use a ghost model id.
                selectedModel = ModelSelectionStore.savedModel(for: selectedProvider)
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
        .onChange(of: selectedModel) { _, newModel in
            ModelSelectionStore.saveModel(newModel, for: selectedProvider)
        }
        .onChange(of: apiKey) { _, newKey in
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
                        Text(taggingMode.detail).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(4)
                }


                // Cost estimate
                if useGateway && !gatewayHasCosts && !droppedFiles.isEmpty {
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
                .disabled(droppedFiles.isEmpty || apiKey.isEmpty || outputDirectory == nil || processor.isProcessing || isInReviewMode)

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
                            Button("Clear") { droppedFiles = []; captureBoundaries = []; captureTypes = []; capturePriorities = []; captureYears = []; captureMonths = []; captureSubjects = []; processor.jobs = []; processor.segments = []; processor.collectionSegments = []; processor.progress = 0; processor.statusMessage = ""; processor.failedFiles = [] }
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
                Text(preOCRedInput ? "Drop PDFs here" : "Drop images here")
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
        ZStack {
            ScrollViewReader { scrollProxy in
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(zip(droppedFiles.indices, droppedFiles)), id: \.0) { index, url in
                        FileRowView(
                            url: url,
                            job: processor.jobs.first { $0.sourceURL == url },
                            showTags: processor.awaitingFinalReview,
                            isFocused: isInReviewMode && index == reviewFocusedIndex,
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
                            if isInReviewMode { reviewFocusedIndex = index }
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

            Text("macOS may ask you to allow Keychain access the first time you save or retrieve a key. Click \"Always Allow\" to avoid repeated prompts.")
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

    private func loadTagVocabularyCSV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Select a CSV or text file containing tag vocabulary"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadTagVocabularyFromURL(url)
    }

    private func loadTagVocabularyFromURL(_ url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        var tags: [String] = []
        for line in content.components(separatedBy: .newlines) {
            for field in line.components(separatedBy: ",") {
                let tag = field.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    .trimmingCharacters(in: .whitespaces)
                if !tag.isEmpty { tags.append(tag) }
            }
        }
        var seen = Set<String>()
        tags = tags.filter { seen.insert($0.lowercased()).inserted }
        tagVocabulary = tags.joined(separator: "\n")
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
        // Mode-aware: pre-OCRed input ingests PDFs; image mode accepts only the documented image
        // formats (JPEG/PNG/TIFF/HEIC) — so a wrong-type file is rejected at the door instead of
        // entering the pipeline and failing later.
        return preOCRedInput ? (ext == "pdf") : ["jpg", "jpeg", "png", "tiff", "tif", "heic"].contains(ext)
    }

    private func resumePendingBatch() {
        if let urls = processor.pendingBatchFileURLs {
            droppedFiles = urls
        }
        processor.passSourceTags = passSourceTags && enableTagging
        processor.taggingMode = taggingMode
        processor.rotationMode = rotationMode
        processor.reviewRotation = reviewRotation
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
            sendPreviousImage: sendPreviousImage && taggingMode.llmSegments,
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
            processor.preGroupedPriorities = capturePriorities.count == droppedFiles.count ? capturePriorities : []
            processor.preGroupedYears = captureYears.count == droppedFiles.count ? captureYears : []
            processor.preGroupedMonths = captureMonths.count == droppedFiles.count ? captureMonths : []
            processor.preGroupedSubjects = captureSubjects.count == droppedFiles.count ? captureSubjects : []
            processor.exportOriginals = outputImageFile   // two-file output: also emit a sized image
        } else {
            processor.preGroupedBoundaries = []
            processor.preGroupedTypes = []
            processor.preGroupedPriorities = []
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
        let effectiveModel = gateway?.asLLMModel() ?? selectedModel

        processor.processingTask = Task {
            await processor.startProcessing(
                files: droppedFiles,
                provider: selectedProvider,
                model: effectiveModel,
                thinkingLevel: !useGateway && selectedModel.supportsThinking ? selectedThinking : nil,
                apiKey: apiKey,
                outputDirectory: outDir,
                batchMode: useGateway ? false : batchMode,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: enableCollectionSegmentation,
                confirmCollectionIDs: confirmCollectionIDs && enableCollectionSegmentation,
                reviewDocumentSegmentation: reviewDocumentSegmentation && enableCollectionSegmentation,
                preOCRedInput: preOCRedInput,
                segmentationContext: context,
                gatewayConfig: gateway
            )
        }
    }
}

