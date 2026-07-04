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
            useGateway: useGateway
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
            if let m = currentModels.first(where: { $0.id == modelId }) { selectedModel = m }
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
        .sheet(isPresented: $processor.awaitingDocumentReview) {
            DocumentSegmentReviewSheet(processor: processor)
        }
        .sheet(isPresented: $processor.awaitingBoxFolderConfirmation) {
            BoxFolderConfirmSheet(processor: processor)
        }
        .sheet(isPresented: $processor.awaitingManualTagging) {
            ManualTaggingSheet(processor: processor)
        }
        .sheet(isPresented: $processor.awaitingManualSegTag) {
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
                        if !droppedFiles.isEmpty {
                            Button("Clear") { droppedFiles = []; captureBoundaries = []; captureTypes = []; capturePriorities = []; captureYears = []; captureMonths = []; captureSubjects = []; processor.jobs = []; processor.segments = []; processor.collectionSegments = [] }
                                .buttonStyle(.bordered)
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
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp", "gif", "pdf"]
        return imageExtensions.contains(url.pathExtension.lowercased())
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

// MARK: - File Row

struct FileRowView: View {
    let url: URL
    let job: OCRJob?
    var showTags: Bool = false
    var isFocused: Bool = false
    /// Live Capture segmentation to show before a job exists (falls back to `job.classification`).
    var presetClassification: DocumentClassification? = nil
    @AppStorage("taggingModeRaw") private var taggingModeRaw: String = TaggingMode.automatic.rawValue

    /// Document start/continuation only mean something when the LLM segments (Automatic / Auto-date).
    /// In manual-segmentation, Human, No-tagging, and Copy-source modes those are user-defined or
    /// unused, so they shouldn't clutter the file pane. Box/folder markers always show.
    private func shows(_ c: DocumentClassification) -> Bool {
        if c == .documentStart || c == .documentContinuation {
            return (TaggingMode(rawValue: taggingModeRaw) ?? .automatic).llmSegments
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                statusIcon
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let rotation = job?.result?.rotationDegrees, rotation != 0 {
                    Text("\(rotation)°")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if let classification = job?.classification ?? presetClassification, shows(classification) {
                    Text(classification.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(classificationColor(classification).opacity(0.15))
                        .foregroundStyle(classificationColor(classification))
                        .clipShape(Capsule())
                }
                if !showTags, let tags = job?.appliedTags, !tags.isEmpty {
                    Text(tags.prefix(2).joined(separator: " \u{00B7} "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if showTags, let tags = job?.appliedTags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.filter { $0 != "Red" && $0 != "Purple" }, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .padding(.leading, 24)
            }
            if let job = job, job.status == .failed, let msg = job.result?.errorMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(classificationBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        )
    }

    private var classificationBackground: Color {
        guard let classification = job?.classification ?? presetClassification, shows(classification) else { return .clear }
        switch classification {
        case .documentStart: return .blue.opacity(0.06)
        case .documentContinuation: return .green.opacity(0.06)
        case .boxLabel: return .red.opacity(0.06)
        case .folderLabel: return .purple.opacity(0.06)
        }
    }

    private func classificationColor(_ c: DocumentClassification) -> Color {
        switch c {
        case .boxLabel: return .red
        case .folderLabel: return .purple
        case .documentStart: return .blue
        case .documentContinuation: return .gray
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job?.status {
        case .processing:
            ProgressView().scaleEffect(0.6)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .removed:
            Image(systemName: "trash.circle.fill").foregroundStyle(.secondary).font(.caption)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
        }
    }
}

// MARK: - OCR Retry Sheet

struct OCRRetrySheet: View {
    @ObservedObject var processor: OCRProcessor

    @State private var selectedProvider: LLMProvider = .gemini
    @State private var selectedModel: LLMModel = LLMModel.geminiModels[0]
    @State private var selectedThinking: ThinkingLevel = .low
    @State private var apiKey: String = ""

    private var currentModels: [LLMModel] { selectedProvider.models }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OCR Failures")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(processor.failedFileIndices.count) file(s) failed to produce OCR text. You can retry with a different provider or model, or continue without them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Failed files list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(processor.failedFileIndices, id: \.self) { index in
                        let job = processor.jobs[index]
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text(job.sourceURL.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let msg = job.result?.errorMessage {
                                Text(String(msg.prefix(50)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 200)

            Divider()

            // Provider/Model selection for retry
            VStack(alignment: .leading, spacing: 12) {
                Text("Retry with")
                    .font(.headline)

                Picker("Provider", selection: Binding(
                    get: { selectedProvider },
                    set: { newProvider in
                        selectedModel = newProvider.models[0]
                        apiKey = KeychainHelper.load(account: newProvider.rawValue) ?? ""
                        selectedProvider = newProvider
                    }
                )) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Model", selection: $selectedModel) {
                    ForEach(currentModels) { m in
                        Text(m.displayName).tag(m)
                    }
                }

                if selectedModel.supportsThinking {
                    Picker("Thinking", selection: $selectedThinking) {
                        ForEach(ThinkingLevel.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                // Cost estimate
                let retryEstimate = CostEstimator.estimate(
                    fileCount: processor.failedFileIndices.count,
                    model: selectedModel,
                    enableTagging: false,
                    sendPreviousImage: false,
                    contextCharCount: 0
                )
                Text("Estimated cost: \(retryEstimate.ocrFormatted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Actions
            HStack {
                Button("Continue Without Retrying") {
                    processor.continueWithoutRetry()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Retry \(processor.failedFileIndices.count) File(s)") {
                    processor.retryFailedFiles(
                        provider: selectedProvider,
                        model: selectedModel,
                        thinkingLevel: selectedModel.supportsThinking ? selectedThinking : nil,
                        apiKey: apiKey
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 550, idealWidth: 650, minHeight: 450, idealHeight: 550)
        .onAppear {
            apiKey = KeychainHelper.load(account: selectedProvider.rawValue) ?? ""
        }
    }
}

// MARK: - Collection Review Sheet

struct CollectionReviewSheet: View {
    @ObservedObject var processor: OCRProcessor

    private var hasBoxes: Bool {
        !processor.collectionReviewItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Collection Names")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if hasBoxes {
                        Text("Verify and correct collection names for each box. Files between boxes are automatically assigned to the preceding box's collection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No box labels were identified. Enter a name for this collection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding()

            Divider()

            if hasBoxes {
                // Box list with editable collection names
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(processor.collectionReviewItems.indices, id: \.self) { idx in
                            CollectionReviewRow(item: $processor.collectionReviewItems[idx])
                        }
                    }
                    .padding()
                }
            } else {
                // No boxes — show collection name text field
                VStack(spacing: 12) {
                    Spacer()
                    Text("Collection Name")
                        .font(.headline)
                    TextField("Enter collection name", text: $processor.noBoxCollectionName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    Text("All \(processor.jobs.count) files will be organized into this collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Footer
            HStack {
                if hasBoxes {
                    Text("\(processor.collectionReviewItems.count) box\(processor.collectionReviewItems.count == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Confirm and Organize") {
                    processor.confirmCollectionReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .frame(minWidth: 700, idealWidth: 1000, maxWidth: .infinity, minHeight: hasBoxes ? 500 : 250, idealHeight: hasBoxes ? 700 : 300, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    window.styleMask.insert(.resizable)
                }
            }
        }
    }
}

struct CollectionReviewRow: View {
    @Binding var item: CollectionReviewItem
    @State private var loadedImage: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            thumbnail
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Filename
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Box")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer()

            // Collection name (editable)
            TextField("Collection name", text: $item.collectionName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    item.collectionName = CollectionSegmenter.normalizeCollectionName(item.collectionName)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.red.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
            }
        }
        // Decode off the main thread so the collection-review pane fills without stalling.
        .task(id: item.fileURL) {
            loadedImage = await Self.loadThumbnailAsync(url: item.fileURL, maxSize: 500)
        }
    }

    private static func loadThumbnailAsync(url: URL, maxSize: Int) async -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFKit.PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return page.thumbnail(of: NSSize(width: maxSize, height: maxSize), for: .mediaBox)
        }
        return await ArchiveThumbnail.loadImageThumbnail(url: url, maxSize: maxSize)
    }

    private func radioButton(label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? color : .secondary)
                    .font(.system(size: 12))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(selected ? color : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Document Segmentation Review Sheet

struct DocumentSegmentReviewSheet: View {
    @ObservedObject var processor: OCRProcessor
    @State private var thumbnailSize: CGFloat = 400
    @State private var focusedIndex: Int = 0

    /// Whether New-Document / Continuation options are offered (only when merging or tagging by segment).
    private var showDocClasses: Bool { processor.reviewShowsDocumentClasses }
    /// When true this is the dedicated rotation-review pass — show only the rotation control.
    private var rotationOnly: Bool { processor.reviewRotationOnly }

    private var newDocCount: Int {
        processor.documentReviewItems.filter { $0.classification == .documentStart }.count
    }

    private var continuationCount: Int {
        processor.documentReviewItems.filter { $0.classification == .documentContinuation }.count
    }

    private var boxCount: Int {
        processor.documentReviewItems.filter { $0.classification == .boxLabel }.count
    }

    private var folderCount: Int {
        processor.documentReviewItems.filter { $0.classification == .folderLabel }.count
    }

    private var removedCount: Int {
        processor.documentReviewItems.filter { $0.markedForRemoval }.count
    }

    private var footerSummary: String {
        let active = processor.documentReviewItems.filter { !$0.markedForRemoval }
        if rotationOnly {
            let rotated = active.filter { $0.rotationDegrees % 360 != 0 }.count
            let n = active.count
            return "\(n) page\(n == 1 ? "" : "s")" + (rotated > 0 ? ", \(rotated) rotated" : "")
        }
        var parts: [String] = []
        if showDocClasses {
            let n = active.filter { $0.classification == .documentStart }.count
            let c = active.filter { $0.classification == .documentContinuation }.count
            parts.append("\(n) new document\(n == 1 ? "" : "s")")
            parts.append("\(c) continuation\(c == 1 ? "" : "s")")
        } else {
            let docs = active.filter { $0.classification != .boxLabel && $0.classification != .folderLabel }.count
            parts.append("\(docs) document\(docs == 1 ? "" : "s")")
        }
        let boxes = active.filter { $0.classification == .boxLabel }.count
        let folders = active.filter { $0.classification == .folderLabel }.count
        if boxes > 0 { parts.append("\(boxes) box\(boxes == 1 ? "" : "es")") }
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if removedCount > 0 { parts.append("\(removedCount) removed") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rotationOnly ? "Review Rotation" : "Document Segmentation Review")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(rotationOnly
                         ? "Keys: \u{2190}\u{2192} or [ ]=Rotate  \u{2191}\u{2193}=Navigate  Return=Confirm"
                         : (showDocClasses
                            ? "Keys: 1=New Doc  2=Continuation  3=Box  4=Folder  X=Remove  \u{2191}\u{2193}=Navigate  Return=Confirm"
                            : "Keys: 3=Box  4=Folder  X=Remove  \u{2191}\u{2193}=Navigate  Return=Confirm"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Thumbnail size slider
            HStack(spacing: 8) {
                Image(systemName: "photo.artframe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $thumbnailSize, in: 60...800, step: 10)
                Image(systemName: "photo.artframe")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("\(Int(thumbnailSize))px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Document list
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(processor.documentReviewItems.indices, id: \.self) { idx in
                            DocumentReviewRow(
                                item: $processor.documentReviewItems[idx],
                                thumbnailSize: thumbnailSize,
                                isFocused: idx == focusedIndex,
                                showDocumentClasses: showDocClasses,
                                rotationOnly: rotationOnly
                            )
                            .id(idx)
                            .onTapGesture { focusedIndex = idx }
                        }
                    }
                    .padding()
                }
                .onChange(of: focusedIndex) { _, newIndex in
                    withAnimation {
                        scrollProxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text(footerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Confirm") {
                    processor.confirmDocumentReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
        .frame(minWidth: 1000, idealWidth: 1900, maxWidth: .infinity, minHeight: 800, idealHeight: 1300, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    window.styleMask.insert(.resizable)
                }
            }
        }
        .onKeyPress(.upArrow) {
            if focusedIndex > 0 { focusedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if focusedIndex < processor.documentReviewItems.count - 1 { focusedIndex += 1 }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                let current = processor.documentReviewItems[focusedIndex].rotationDegrees
                processor.documentReviewItems[focusedIndex].rotationDegrees = (current - 90 + 360) % 360
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].rotationDegrees = (processor.documentReviewItems[focusedIndex].rotationDegrees + 90) % 360
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1")) { _ in
            if !rotationOnly, showDocClasses, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .documentStart
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "2")) { _ in
            if !rotationOnly, showDocClasses, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .documentContinuation
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "xX")) { _ in
            if !rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].markedForRemoval.toggle()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "3")) { _ in
            if !rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .boxLabel
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "4")) { _ in
            if !rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .folderLabel
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[")) { _ in
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                let current = processor.documentReviewItems[focusedIndex].rotationDegrees
                processor.documentReviewItems[focusedIndex].rotationDegrees = (current - 90 + 360) % 360
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "]")) { _ in
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].rotationDegrees = (processor.documentReviewItems[focusedIndex].rotationDegrees + 90) % 360
            }
            return .handled
        }
    }
}

struct DocumentReviewRow: View {
    @Binding var item: DocumentReviewItem
    let thumbnailSize: CGFloat
    var isFocused: Bool = false
    var showDocumentClasses: Bool = true
    /// Dedicated rotation-review pass: show only the rotation control, no classification/remove.
    var rotationOnly: Bool = false
    @State private var loadedImage: NSImage?

    private var rowBackground: Color {
        // Rotation-only review: we're checking orientation, not classification — keep every row
        // neutral so box/folder color themes don't distract.
        if rotationOnly { return Color.gray.opacity(0.10) }
        if item.markedForRemoval { return Color.secondary.opacity(0.10) }
        switch item.classification {
        case .boxLabel: return Color.red.opacity(0.12)
        case .folderLabel: return Color.purple.opacity(0.12)
        case .documentStart: return showDocumentClasses ? Color.blue.opacity(0.12) : Color.gray.opacity(0.10)
        case .documentContinuation: return showDocumentClasses ? Color.green.opacity(0.12) : Color.gray.opacity(0.10)
        case .none: return Color.gray.opacity(0.10)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail (rotated to match current rotation setting)
            thumbnail
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(item.markedForRemoval ? 0.4 : 1)

            // Classification radio buttons (hidden in the dedicated rotation-review pass).
            if !rotationOnly {
                VStack(alignment: .leading, spacing: 6) {
                    if showDocumentClasses {
                        radioButton(label: "1 New Document", selected: item.classification == .documentStart, color: .blue) {
                            item.classification = .documentStart
                        }
                        radioButton(label: "2 Continuation", selected: item.classification == .documentContinuation, color: .green) {
                            item.classification = .documentContinuation
                        }
                    } else {
                        // Segmentation is irrelevant here — a page is either a plain document or a box/folder label.
                        radioButton(label: "Document", selected: item.classification == .documentStart || item.classification == .documentContinuation || item.classification == nil, color: .gray) {
                            item.classification = .documentStart
                        }
                    }
                    radioButton(label: "3 Box", selected: item.classification == .boxLabel, color: .red) {
                        item.classification = .boxLabel
                    }
                    radioButton(label: "4 Folder", selected: item.classification == .folderLabel, color: .purple) {
                        item.classification = .folderLabel
                    }
                }
                .frame(width: 130)
                .disabled(item.markedForRemoval)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Filename
                Text(item.fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(item.markedForRemoval)
                    .frame(minWidth: 180, alignment: .leading)

                // Rotation radio buttons — only in the dedicated rotation-review pass.
                if rotationOnly {
                    HStack(spacing: 8) {
                        Text("Rotate:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        rotationRadio(label: "0°", degrees: 0)
                        rotationRadio(label: "90°", degrees: 90)
                        rotationRadio(label: "180°", degrees: 180)
                        rotationRadio(label: "270°", degrees: 270)
                    }
                }
            }

            Spacer()

            // Remove / restore button (segmentation review only).
            if !rotationOnly {
                Button {
                    item.markedForRemoval.toggle()
                } label: {
                    Image(systemName: item.markedForRemoval ? "arrow.uturn.backward.circle" : "trash")
                        .foregroundStyle(item.markedForRemoval ? Color.accentColor : .red)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help(item.markedForRemoval ? "Restore this photo" : "Remove this photo from output")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func rotationRadio(label: String, degrees: Int) -> some View {
        Button {
            item.rotationDegrees = degrees
        } label: {
            HStack(spacing: 3) {
                Image(systemName: item.rotationDegrees == degrees ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(item.rotationDegrees == degrees ? .orange : .secondary)
                    .font(.system(size: 10))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(item.rotationDegrees == degrees ? .orange : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let loadedImage {
                // Show the entire image (fit, not fill/crop) so nothing is cut off during review.
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(Double(item.rotationDegrees)))
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
            }
        }
        // Decode off the main thread so filling the review pane never blocks the UI.
        .task(id: item.fileURL) {
            loadedImage = await Self.loadThumbnailAsync(url: item.fileURL, maxSize: 1000)
        }
    }

    /// Decode a thumbnail off the main actor (image case) and return an NSImage on the caller's
    /// actor — prevents a burst of synchronous decodes from beachballing the review pane.
    private static func loadThumbnailAsync(url: URL, maxSize: Int) async -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFKit.PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return page.thumbnail(of: NSSize(width: maxSize, height: maxSize), for: .mediaBox)
        }
        return await ArchiveThumbnail.loadImageThumbnail(url: url, maxSize: maxSize)
    }

    private func radioButton(label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? color : .secondary)
                    .font(.system(size: 12))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(selected ? color : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Resolution Test Sheet

struct ResolutionTestSheet: View {
    let imageURL: URL?
    let results: [(scale: Int, text: String?)]
    let isRunning: Bool
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void

    @State private var showDiff = true

    /// The 100% result text, used as diff baseline
    private var baselineText: String? {
        results.first(where: { $0.scale == 100 })?.text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Resolution Test")
                    .font(.headline)
                Spacer()
                if baselineText != nil {
                    Toggle("Highlight differences", isOn: $showDiff)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            if isRunning && results.isEmpty {
                Spacer()
                ProgressView("Running OCR at 6 resolution levels…")
                Spacer()
            } else {
                HSplitView {
                    // Left: original image
                    VStack {
                        Text("Original Image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = imageURL, let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 250)
                    .padding(8)

                    // Right: results columns
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.offset) { idx, entry in
                                resolutionColumn(scale: entry.scale, text: entry.text, index: idx)
                            }
                            if isRunning {
                                let scales = [10, 20, 40, 60, 80, 100]
                                ForEach(results.count..<6, id: \.self) { idx in
                                    VStack {
                                        Text("\(scales[idx])%")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        ProgressView()
                                        Spacer()
                                    }
                                    .frame(minWidth: 180)
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.05))
                                }
                            }
                        }
                    }
                    .frame(minWidth: 400)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .frame(idealWidth: 1200, idealHeight: 700)
    }

    private func resolutionColumn(scale: Int, text: String?, index: Int) -> some View {
        let diffResult: WordDiff.DiffResult? = {
            guard showDiff, scale != 100, let baseline = baselineText, let text = text else { return nil }
            return WordDiff.diff(baseline: baseline, candidate: text)
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(scale)%")
                    .font(.caption)
                    .fontWeight(.semibold)
                if let diff = diffResult {
                    similarityBadge(diff.similarity)
                }
                Spacer()
                Button("Use") { onSelect(scale) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if let diff = diffResult {
                HStack(spacing: 8) {
                    if diff.missing > 0 {
                        Label("\(diff.missing) missing", systemImage: "minus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    if diff.added > 0 {
                        Label("\(diff.added) added", systemImage: "plus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    if diff.changed > 0 {
                        Label("\(diff.changed) changed", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
            }
            if scale == 100 && showDiff {
                Text("Baseline")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .italic()
            }
            Divider()
            ScrollView {
                if let text = text {
                    if let diff = diffResult {
                        diffHighlightedText(diff)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No text returned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
        .frame(width: 220)
        .padding(8)
        .background(index % 2 == 0 ? Color.secondary.opacity(0.05) : Color.clear)
    }

    private func similarityBadge(_ similarity: Double) -> some View {
        let pct = Int(round(similarity * 100))
        let color: Color = similarity >= 0.95 ? .green
            : similarity >= 0.85 ? .yellow
            : similarity >= 0.70 ? .orange
            : .red
        return Text("\(pct)%")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func diffHighlightedText(_ diff: WordDiff.DiffResult) -> some View {
        Text(WordDiff.buildAttributedString(from: diff.elements))
            .textSelection(.enabled)
    }
}

// MARK: - Word-level Diff Engine

enum WordDiff {
    enum Element {
        case equal(String)
        case inserted(String)
        case deleted(String)
        case changed(String, String) // (baseline, candidate)
        case whitespace(String)
    }

    struct DiffResult {
        let elements: [Element]
        let similarity: Double
        let missing: Int  // words in baseline but not candidate
        let added: Int    // words in candidate but not baseline
        let changed: Int  // words that differ between baseline and candidate
    }

    /// Tokenize text preserving whitespace as separate tokens
    private static func tokenize(_ text: String) -> [(word: String, isWhitespace: Bool)] {
        var tokens: [(String, Bool)] = []
        var current = ""
        var inWhitespace = false

        for ch in text {
            let charIsWS = ch.isWhitespace || ch.isNewline
            if charIsWS != inWhitespace && !current.isEmpty {
                tokens.append((current, inWhitespace))
                current = ""
            }
            inWhitespace = charIsWS
            current.append(ch)
        }
        if !current.isEmpty {
            tokens.append((current, inWhitespace))
        }
        return tokens
    }

    /// Extract just the words (non-whitespace tokens) for LCS comparison
    private static func words(from tokens: [(word: String, isWhitespace: Bool)]) -> [String] {
        tokens.filter { !$0.isWhitespace }.map { $0.word }
    }

    /// Longest Common Subsequence returning aligned pairs: (baselineIndex?, candidateIndex?)
    private static func lcs(_ a: [String], _ b: [String]) -> [(Int?, Int?)] {
        let m = a.count, n = b.count
        // Build LCS table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(m, 1) {
            guard i <= m else { break }
            for j in 1...max(n, 1) {
                guard j <= n else { break }
                if a[i-1].lowercased() == b[j-1].lowercased() {
                    dp[i][j] = dp[i-1][j-1] + 1
                } else {
                    dp[i][j] = max(dp[i-1][j], dp[i][j-1])
                }
            }
        }

        // Backtrack to get alignment
        var result: [(Int?, Int?)] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i-1].lowercased() == b[j-1].lowercased() {
                result.append((i-1, j-1))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                result.append((nil, j-1))
                j -= 1
            } else {
                result.append((i-1, nil))
                i -= 1
            }
        }
        return result.reversed()
    }

    static func diff(baseline: String, candidate: String) -> DiffResult {
        let baseTokens = tokenize(baseline)
        let candTokens = tokenize(candidate)
        let baseWords = words(from: baseTokens)
        let candWords = words(from: candTokens)

        let aligned = lcs(baseWords, candWords)

        // Build a set of which candidate word indices are "equal" vs "inserted"
        // and reconstruct the display from the candidate's token stream
        var candWordStatus: [Int: (matched: Bool, baseIdx: Int?)] = [:]
        var missingCount = 0
        var addedCount = 0
        var changedCount = 0

        for (baseIdx, candIdx) in aligned {
            if let bi = baseIdx, let ci = candIdx {
                // Check if exact match or just case-insensitive match
                if baseWords[bi] == candWords[ci] {
                    candWordStatus[ci] = (matched: true, baseIdx: bi)
                } else {
                    candWordStatus[ci] = (matched: false, baseIdx: bi)
                    changedCount += 1
                }
            } else if baseIdx != nil {
                missingCount += 1
            } else if let ci = candIdx {
                candWordStatus[ci] = (matched: false, baseIdx: nil)
                addedCount += 1
            }
        }

        // Build display elements from candidate token stream, interleaving deleted words
        var elements: [Element] = []
        var candWordIdx = 0

        // Rebuild from candidate tokens, inserting deleted markers
        // First, build a map of "before candidate word index X, insert these deleted baseline words"
        var deletionsBeforeCandWord: [Int: [Int]] = [:]
        var pendingDeletions: [Int] = []
        for (bi, ci) in aligned {
            if let bi = bi, ci == nil {
                pendingDeletions.append(bi)
            } else if let ci = ci {
                if !pendingDeletions.isEmpty {
                    deletionsBeforeCandWord[ci] = pendingDeletions
                    pendingDeletions = []
                }
            }
        }
        // Any remaining deletions go at the end
        let trailingDeletions = pendingDeletions

        candWordIdx = 0
        for token in candTokens {
            if token.isWhitespace {
                elements.append(.whitespace(token.word))
            } else {
                // Insert any deletions that should appear before this candidate word
                if let dels = deletionsBeforeCandWord[candWordIdx] {
                    for di in dels {
                        elements.append(.deleted(baseWords[di]))
                        elements.append(.whitespace(" "))
                    }
                }

                if let status = candWordStatus[candWordIdx] {
                    if status.matched {
                        elements.append(.equal(token.word))
                    } else if let bi = status.baseIdx {
                        elements.append(.changed(baseWords[bi], token.word))
                    } else {
                        elements.append(.inserted(token.word))
                    }
                } else {
                    elements.append(.inserted(token.word))
                }
                candWordIdx += 1
            }
        }

        // Append trailing deletions
        for di in trailingDeletions {
            elements.append(.whitespace(" "))
            elements.append(.deleted(baseWords[di]))
        }

        let totalBaseWords = baseWords.count
        let matchedWords = totalBaseWords - missingCount - changedCount
        let similarity = totalBaseWords > 0 ? Double(max(0, matchedWords)) / Double(totalBaseWords) : 1.0

        return DiffResult(
            elements: elements,
            similarity: similarity,
            missing: missingCount,
            added: addedCount,
            changed: changedCount
        )
    }

    static func buildAttributedString(from elements: [Element]) -> AttributedString {
        var attributed = AttributedString()
        for element in elements {
            var part: AttributedString
            switch element {
            case .equal(let word):
                part = AttributedString(word)
                part.font = .system(size: 10, design: .monospaced)
            case .inserted(let word):
                part = AttributedString(word)
                part.font = .system(size: 10, design: .monospaced).bold()
                part.foregroundColor = .blue
                part.backgroundColor = Color.blue.opacity(0.12)
            case .deleted(let word):
                part = AttributedString(word)
                part.font = .system(size: 10, design: .monospaced).bold()
                part.foregroundColor = .red
                part.strikethroughStyle = .single
                part.backgroundColor = Color.red.opacity(0.12)
            case .changed(let from, let to):
                var fromPart = AttributedString(from)
                fromPart.font = .system(size: 10, design: .monospaced).bold()
                fromPart.foregroundColor = .red
                fromPart.strikethroughStyle = .single
                fromPart.backgroundColor = Color.red.opacity(0.12)
                var toPart = AttributedString(to)
                toPart.font = .system(size: 10, design: .monospaced).bold()
                toPart.foregroundColor = .orange
                toPart.backgroundColor = Color.orange.opacity(0.12)
                attributed.append(fromPart)
                part = toPart
            case .whitespace(let ws):
                part = AttributedString(ws)
                part.font = .system(size: 10, design: .monospaced)
            }
            attributed.append(part)
        }
        return attributed
    }
}

// MARK: - Model Test Data Types

struct ModelTestEntry: Identifiable {
    let id = UUID()
    let provider: LLMProvider
    let model: LLMModel
    let apiKey: String
}

struct ModelTestResult: Identifiable {
    let id = UUID()
    let provider: LLMProvider
    let model: LLMModel
    let text: String?
    let errorMessage: String?
}

// MARK: - Model Selection Sheet

struct ModelSelectionSheet: View {
    let currentProvider: LLMProvider
    let onStart: ([ModelTestEntry]) -> Void
    let onDismiss: () -> Void

    @State private var selections: [String: Bool] = [:]  // model.id -> selected
    @State private var apiKeys: [String: String] = [:]    // provider.rawValue -> key

    private var allModels: [(provider: LLMProvider, model: LLMModel)] {
        LLMProvider.allCases.flatMap { provider in
            provider.models.map { (provider: provider, model: $0) }
        }
    }

    /// Models sorted by cost descending (most expensive first)
    private var sortedModels: [(provider: LLMProvider, model: LLMModel)] {
        allModels.sorted { $0.model.inputCostPer1M + $0.model.outputCostPer1M > $1.model.inputCostPer1M + $1.model.outputCostPer1M }
    }

    private var selectedEntries: [ModelTestEntry] {
        // Return selected models sorted by cost descending (most expensive = baseline first)
        sortedModels
            .filter { selections[$0.model.id] == true }
            .compactMap { pair in
                guard let key = apiKeys[pair.provider.rawValue], !key.isEmpty else { return nil }
                return ModelTestEntry(provider: pair.provider, model: pair.model, apiKey: key)
            }
    }

    private var missingKeys: Set<String> {
        var providers = Set<String>()
        for pair in allModels where selections[pair.model.id] == true {
            let key = apiKeys[pair.provider.rawValue] ?? ""
            if key.isEmpty { providers.insert(pair.provider.rawValue) }
        }
        return providers
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Models to Compare")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(LLMProvider.allCases) { provider in
                        providerSection(provider)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                let count = selectedEntries.count
                Text("\(count) model\(count == 1 ? "" : "s") selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !missingKeys.isEmpty {
                    Text("— missing API key for: \(missingKeys.sorted().joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Select Image…") {
                    UserDefaults.standard.set(selections, forKey: "modelTestSelections")
                    onStart(selectedEntries)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntries.count < 2)
            }
            .padding()
        }
        .frame(width: 500, height: 520)
        .onAppear {
            // Load saved API keys for all providers
            for provider in LLMProvider.allCases {
                apiKeys[provider.rawValue] = KeychainHelper.load(account: provider.rawValue) ?? ""
            }
            // Restore previously saved model selections, or default to current provider's first model
            if let saved = UserDefaults.standard.dictionary(forKey: "modelTestSelections") as? [String: Bool], !saved.isEmpty {
                selections = saved
            } else if let firstModel = currentProvider.models.first {
                selections[firstModel.id] = true
            }
        }
    }

    private func providerSection(_ provider: LLMProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.rawValue)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                let key = Binding(
                    get: { apiKeys[provider.rawValue] ?? "" },
                    set: { apiKeys[provider.rawValue] = $0 }
                )
                SecureField("API Key", text: key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .font(.caption)
            }

            ForEach(provider.models) { model in
                let isOn = Binding(
                    get: { selections[model.id] ?? false },
                    set: { selections[model.id] = $0 }
                )
                HStack {
                    Toggle(model.displayName, isOn: isOn)
                        .font(.caption)
                    Spacer()
                    Text(formatCost(model))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
            }
        }
    }

    private func formatCost(_ model: LLMModel) -> String {
        let total = model.inputCostPer1M + model.outputCostPer1M
        if total < 1.0 {
            return String(format: "$%.3f/M", total)
        } else {
            return String(format: "$%.2f/M", total)
        }
    }
}

// MARK: - Model Test Results Sheet

struct ModelTestResultsSheet: View {
    let imageURL: URL?
    let results: [ModelTestResult]
    let isRunning: Bool
    let totalCount: Int
    let onSelect: (LLMProvider, LLMModel) -> Void
    let onDismiss: () -> Void

    @State private var showDiff = true

    /// The baseline is the most expensive model that returned text
    private var baselineResult: ModelTestResult? {
        results
            .filter { $0.text != nil }
            .max(by: { ($0.model.inputCostPer1M + $0.model.outputCostPer1M) < ($1.model.inputCostPer1M + $1.model.outputCostPer1M) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Model Comparison")
                    .font(.headline)
                Spacer()
                if baselineResult != nil {
                    Toggle("Highlight differences", isOn: $showDiff)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Button("Done") { onDismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            if isRunning && results.isEmpty {
                Spacer()
                ProgressView("Running OCR on \(totalCount) models…")
                Spacer()
            } else {
                HSplitView {
                    // Left: original image
                    VStack {
                        Text("Original Image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = imageURL, let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 250)
                    .padding(8)

                    // Right: results columns
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.offset) { idx, entry in
                                modelResultColumn(entry: entry, index: idx)
                            }
                            if isRunning {
                                ForEach(results.count..<totalCount, id: \.self) { _ in
                                    VStack {
                                        Text("…")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        ProgressView()
                                        Spacer()
                                    }
                                    .frame(minWidth: 200)
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.05))
                                }
                            }
                        }
                    }
                    .frame(minWidth: 400)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .frame(idealWidth: 1300, idealHeight: 700)
    }

    private func modelResultColumn(entry: ModelTestResult, index: Int) -> some View {
        let isBaseline = baselineResult?.model.id == entry.model.id
        let diffResult: WordDiff.DiffResult? = {
            guard showDiff, !isBaseline, let baseline = baselineResult?.text, let text = entry.text else { return nil }
            return WordDiff.diff(baseline: baseline, candidate: text)
        }()

        return VStack(alignment: .leading, spacing: 4) {
            // Header: provider + model name
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.provider.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(entry.model.displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let diff = diffResult {
                        similarityBadge(diff.similarity)
                    }
                }
            }

            HStack {
                // Cost indicator
                Text(formatCost(entry.model))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Use") { onSelect(entry.provider, entry.model) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if isBaseline && showDiff {
                Text("Baseline (most expensive)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .italic()
            }

            // Diff stats
            if let diff = diffResult {
                HStack(spacing: 6) {
                    if diff.missing > 0 {
                        Label("\(diff.missing)", systemImage: "minus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    if diff.added > 0 {
                        Label("\(diff.added)", systemImage: "plus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    if diff.changed > 0 {
                        Label("\(diff.changed)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Divider()

            // Text content
            ScrollView {
                if let text = entry.text {
                    if let diff = diffResult {
                        Text(WordDiff.buildAttributedString(from: diff.elements))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let err = entry.errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No text returned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
        .frame(width: 240)
        .padding(8)
        .background(index % 2 == 0 ? Color.secondary.opacity(0.05) : Color.clear)
    }

    private func similarityBadge(_ similarity: Double) -> some View {
        let pct = Int(round(similarity * 100))
        let color: Color = similarity >= 0.95 ? .green
            : similarity >= 0.85 ? .yellow
            : similarity >= 0.70 ? .orange
            : .red
        return Text("\(pct)%")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func formatCost(_ model: LLMModel) -> String {
        let total = model.inputCostPer1M + model.outputCostPer1M
        if total < 1.0 {
            return String(format: "$%.3f/M tokens", total)
        } else {
            return String(format: "$%.2f/M tokens", total)
        }
    }
}

// MARK: - Resolution Drop Sheet

struct ResolutionDropSheet: View {
    let onSelect: (URL) -> Void
    let onDismiss: () -> Void
    @State private var isTargeted = false

    private let dropTypes: [UTType] = [.fileURL]
    private let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic"]

    var body: some View {
        VStack(spacing: 16) {
            Text("Select Image for Resolution Test")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(isTargeted ? .blue : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isTargeted ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.05))
                    )

                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Drop an image here")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text("JPEG, PNG, TIFF, or HEIC")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 160)
            .onDrop(of: dropTypes, isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true),
                          imageExtensions.contains(url.pathExtension.lowercased()) else { return }
                    DispatchQueue.main.async { onSelect(url) }
                }
                return true
            }

            HStack {
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic]
                    panel.allowsMultipleSelection = false
                    panel.message = "Select an image to test OCR at different resolutions"
                    if panel.runModal() == .OK, let url = panel.url {
                        onSelect(url)
                    }
                }
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - Segmentation Edit Sheet (double-click from file pane)

struct SegmentationEditSheet: View {
    @ObservedObject var processor: OCRProcessor
    let fileIndex: Int
    let fileName: String
    let onDismiss: () -> Void

    @State private var selectedClassification: DocumentClassification = .documentStart

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Classification")
                .font(.title3)
                .fontWeight(.semibold)

            Text(fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("Classification", selection: $selectedClassification) {
                Text("1  Document Start").tag(DocumentClassification.documentStart)
                Text("2  Continuation").tag(DocumentClassification.documentContinuation)
                Text("3  Box Label").tag(DocumentClassification.boxLabel)
                Text("4  Folder Label").tag(DocumentClassification.folderLabel)
            }
            .pickerStyle(.radioGroup)
            .padding(.vertical, 4)

            // Show OCR text preview
            if let text = processor.jobs[fileIndex].result?.text, !text.isEmpty {
                GroupBox("OCR Text Preview") {
                    ScrollView {
                        Text(String(text.prefix(500)))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            }

            HStack {
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    processor.updateClassification(at: fileIndex, to: selectedClassification)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            if let cls = processor.jobs[fileIndex].result?.classification ?? processor.jobs[fileIndex].classification {
                selectedClassification = cls
            }
        }
    }
}
