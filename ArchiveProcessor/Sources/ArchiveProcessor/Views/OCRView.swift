import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

struct OCRView: View {
    // MARK: - State
    @StateObject private var processor = OCRProcessor()

    // Persisted via @AppStorage (UserDefaults)
    @AppStorage("selectedProvider") private var selectedProvider: LLMProvider = .gemini
    @AppStorage("selectedThinking") private var selectedThinking: ThinkingLevel = .low
    @AppStorage("batchMode") private var batchMode: Bool = false
    @AppStorage("preOCRedInput") private var preOCRedInput: Bool = false
    @AppStorage("enableCollectionSegmentation") private var enableCollectionSegmentation: Bool = false
    @AppStorage("confirmCollectionIDs") private var confirmCollectionIDs: Bool = false
    @AppStorage("enableTagging") private var enableTagging: Bool = true
    @AppStorage("passSourceTags") private var passSourceTags: Bool = false
    @AppStorage("reviewDocumentSegmentation") private var reviewDocumentSegmentation: Bool = false
    @AppStorage("enableSegmentJSON") private var enableSegmentJSON: Bool = true
    @AppStorage("sendPreviousImage") private var sendPreviousImage: Bool = false
    @AppStorage("contextCharCount") private var contextCharCount: Double = 200
    @AppStorage("customOCRPrompt") private var customOCRPrompt: String = ""
    @AppStorage("mergeDocuments") private var mergeDocuments: Bool = false
    @AppStorage("imageResolutionPercent") private var imageScale: Double = 100

    // Initialized from persisted state in init()
    @State private var selectedModel: LLMModel
    @State private var apiKey: String
    @State private var outputDirectory: URL?

    @AppStorage("keychainExplained") private var keychainExplained: Bool = false

    // Transient
    @State private var droppedFiles: [URL] = []
    @State private var isTargeted = false
    @State private var showKeychainSheet = false
    @State private var showResolutionTest = false
    @State private var showResolutionDropSheet = false
    @State private var resolutionTestResults: [(scale: Int, text: String?)] = []
    @State private var resolutionTestImage: URL?
    @State private var isRunningResolutionTest = false

    // Model comparison test state
    @State private var showModelSelectionSheet = false
    @State private var showModelTestDropSheet = false
    @State private var showModelTestResults = false
    @State private var modelTestSelections: [ModelTestEntry] = []
    @State private var modelTestResults: [ModelTestResult] = []
    @State private var modelTestImage: URL?
    @State private var isRunningModelTest = false

    init() {
        let provider = LLMProvider(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .gemini
        let modelId = UserDefaults.standard.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        _selectedModel = State(initialValue: provider.models.first { $0.id == modelId } ?? provider.models[0])
        _apiKey = State(initialValue: KeychainHelper.load(account: provider.rawValue) ?? "")

        if let path = UserDefaults.standard.string(forKey: "outputDirectory"),
           FileManager.default.fileExists(atPath: path) {
            _outputDirectory = State(initialValue: URL(fileURLWithPath: path))
        } else {
            _outputDirectory = State(initialValue: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        }
    }

    private var currentModels: [LLMModel] { selectedProvider.models }

    private var costEstimate: CostEstimate? {
        guard !droppedFiles.isEmpty else { return nil }
        return CostEstimator.estimate(
            fileCount: droppedFiles.count,
            model: selectedModel,
            enableTagging: enableTagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput,
            sendPreviousImage: sendPreviousImage,
            contextCharCount: Int(contextCharCount),
            imageScale: imageScale / 100.0
        )
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
            processor.checkForPendingBatch()
            if !keychainExplained {
                showKeychainSheet = true
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
        .sheet(isPresented: $processor.awaitingDocumentReview) {
            DocumentSegmentReviewSheet(processor: processor)
        }
        .sheet(isPresented: $showResolutionDropSheet) {
            ResolutionDropSheet { url in
                showResolutionDropSheet = false
                resolutionTestImage = url
                runResolutionTest(imageURL: url)
            } onDismiss: {
                showResolutionDropSheet = false
            }
        }
        .sheet(isPresented: $showResolutionTest) {
            ResolutionTestSheet(
                imageURL: resolutionTestImage,
                results: resolutionTestResults,
                isRunning: isRunningResolutionTest,
                onSelect: { scale in
                    imageScale = Double(scale)
                    showResolutionTest = false
                },
                onDismiss: { showResolutionTest = false }
            )
        }
        .sheet(isPresented: $showModelSelectionSheet) {
            ModelSelectionSheet(
                currentProvider: selectedProvider,
                onStart: { entries in
                    modelTestSelections = entries
                    showModelSelectionSheet = false
                    showModelTestDropSheet = true
                },
                onDismiss: { showModelSelectionSheet = false }
            )
        }
        .sheet(isPresented: $showModelTestDropSheet) {
            ResolutionDropSheet { url in
                showModelTestDropSheet = false
                modelTestImage = url
                runModelTest(imageURL: url)
            } onDismiss: {
                showModelTestDropSheet = false
            }
        }
        .sheet(isPresented: $showModelTestResults) {
            ModelTestResultsSheet(
                imageURL: modelTestImage,
                results: modelTestResults,
                isRunning: isRunningModelTest,
                totalCount: modelTestSelections.count,
                onSelect: { provider, model in
                    selectedProvider = provider
                    selectedModel = model
                    apiKey = KeychainHelper.load(account: provider.rawValue) ?? ""
                    showModelTestResults = false
                },
                onDismiss: { showModelTestResults = false }
            )
        }
        .onChange(of: selectedModel) { _, newModel in
            UserDefaults.standard.set(newModel.id, forKey: "selectedModelId_\(selectedProvider.rawValue)")
        }
        .onChange(of: apiKey) { _, newKey in
            if newKey.isEmpty {
                KeychainHelper.delete(account: selectedProvider.rawValue)
            } else {
                KeychainHelper.save(account: selectedProvider.rawValue, password: newKey)
            }
        }
        .onChange(of: outputDirectory) { _, newDir in
            UserDefaults.standard.set(newDir?.path, forKey: "outputDirectory")
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

                // Provider & Model
                GroupBox("Provider & Model") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $selectedProvider) {
                            ForEach(LLMProvider.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedProvider) { _, newProvider in
                            let savedId = UserDefaults.standard.string(forKey: "selectedModelId_\(newProvider.rawValue)") ?? ""
                            selectedModel = newProvider.models.first { $0.id == savedId } ?? newProvider.models[0]
                            apiKey = KeychainHelper.load(account: newProvider.rawValue) ?? ""
                        }

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

                        Button("Compare Models…") {
                            showModelSelectionSheet = true
                        }
                        .font(.caption)
                        .disabled(isRunningModelTest)
                    }
                    .padding(4)
                }

                // API Key
                GroupBox("API Key") {
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField("Enter \(selectedProvider.rawValue) API key…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 4) {
                            Image(systemName: "lock.shield")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Stored securely in macOS Keychain.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Learn more") { showKeychainSheet = true }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(4)
                }

                // Input Mode
                GroupBox("Input Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Pre-OCRed PDF input", isOn: $preOCRedInput)
                        if preOCRedInput {
                            Text("Accept PDFs that already contain OCR text. Skips OCR API calls and uses the existing text for tagging and collection segmentation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }

                // Tagging & Segmentation
                GroupBox("Tagging & Segmentation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable collection ID and file renaming", isOn: $enableCollectionSegmentation)
                            .font(.caption)
                        if enableCollectionSegmentation {
                            Text("Identifies collections from box labels and organizes output PDFs into collection folders with sequential naming.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            Toggle("Confirm identifications before organizing", isOn: $confirmCollectionIDs)
                                .font(.caption)
                                .padding(.leading, 16)

                            Toggle("Review document segmentation", isOn: $reviewDocumentSegmentation)
                                .font(.caption)
                                .padding(.leading, 16)
                            if reviewDocumentSegmentation {
                                Text("Review and correct document start/continuation classifications for each collection before tagging.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 32)
                            }
                        }

                        Divider()

                        Toggle("Enable tagging", isOn: $enableTagging)

                        if enableTagging {
                            Toggle("Copy source file tags to output PDFs", isOn: $passSourceTags)
                                .font(.caption)
                                .padding(.leading, 16)
                            if passSourceTags {
                                Text("Reads macOS Finder tags from each source image and applies them to the output PDF. Skips LLM-based tagging.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 32)
                            }

                            if !passSourceTags {
                            Toggle("Export segment JSON metadata", isOn: $enableSegmentJSON)
                                .font(.caption)
                                .padding(.leading, 16)

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Context from previous page:")
                                        .font(.caption)
                                    Spacer()
                                    Text("\(Int(contextCharCount)) chars")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $contextCharCount, in: 0...1000, step: 50)
                                Text("Characters of the previous page's OCR text sent as context for segmentation.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Divider()

                            Toggle("Send previous page image (higher accuracy, higher cost)", isOn: $sendPreviousImage)
                                .font(.caption)
                            if sendPreviousImage {
                                Text("Sends the full previous page image alongside the current image. ~2× image token cost but significantly better segmentation accuracy.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            } // end if !passSourceTags
                        }

                        Divider()

                        Toggle("Merge multi-page documents", isOn: $mergeDocuments)
                        if mergeDocuments {
                            Text("Combines continuation pages into single multi-page PDFs. Each page's image is followed by its OCR text.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 16)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom prompt (optional):")
                                .font(.caption)
                            TextEditor(text: $customOCRPrompt)
                                .font(.caption)
                                .frame(minHeight: 40, maxHeight: 80)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            Text("Additional context appended to the OCR prompt, e.g. \"This collection contains legal documents from the 1950s\"")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(4)
                }

                // Batch & Resolution
                GroupBox("Processing Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Batch Mode (slower, ~50% cheaper)", isOn: $batchMode)
                            .disabled(selectedProvider == .gemini)
                        if selectedProvider == .gemini {
                            Text("Gemini batch processing is temporarily unavailable due to a Google API infrastructure issue. Individual requests still work normally.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if batchMode {
                            Text("Batch jobs are queued and returned asynchronously. Results may take minutes to hours.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Image resolution:")
                                    .font(.caption)
                                Spacer()
                                Text("\(Int(imageScale))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $imageScale, in: 5...100, step: 5)
                            if imageScale < 100 {
                                Text("Images downscaled to \(Int(imageScale))% of original dimensions (\(Int(imageScale * imageScale / 100))% pixel count). Lower resolution reduces cost but may reduce OCR accuracy.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Button("Test Resolution…") {
                                showResolutionDropSheet = true
                            }
                            .font(.caption)
                            .disabled(apiKey.isEmpty || isRunningResolutionTest)
                        }
                    }
                    .padding(4)
                }

                // Cost estimate
                if let est = costEstimate {
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
                            if enableTagging && !passSourceTags {
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
                            Divider()
                            HStack {
                                Text("Total (standard):").fontWeight(.medium)
                                Spacer()
                                Text(est.totalStandardFormatted).fontWeight(.medium)
                            }
                            if batchMode && !preOCRedInput && selectedProvider != .gemini {
                                HStack {
                                    Text("Total (batch):").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.totalBatchFormatted)
                                }
                            }
                            Text("Estimates calibrated from actual API usage with high-resolution archival photos. Actual costs may vary with image resolution.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
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
                    Label(preOCRedInput ? "Start Processing" : (enableTagging || enableCollectionSegmentation ? "Start OCR + Tagging" : "Start OCR"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(droppedFiles.isEmpty || apiKey.isEmpty || outputDirectory == nil || processor.isProcessing)

                if processor.isProcessing {
                    Button("Cancel") { processor.cancel() }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - File Panel

    private var filePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Files")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button(action: selectFiles) {
                        Label("Add Files…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    if !droppedFiles.isEmpty {
                        Button("Clear") { droppedFiles = []; processor.jobs = []; processor.segments = []; processor.collectionSegments = [] }
                            .buttonStyle(.bordered)
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

                // Progress
                if processor.isProcessing || !processor.statusMessage.isEmpty {
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

    private var fileList: some View {
        ZStack {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(zip(droppedFiles.indices, droppedFiles)), id: \.0) { index, url in
                    FileRowView(url: url, job: processor.jobs.first { $0.sourceURL == url })
                }
            }
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            DropReceiver(isTargeted: .constant(false)) { urls in
                handleDroppedURLs(urls)
            }
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

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select Output Folder"
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    private func runResolutionTest(imageURL: URL) {
        isRunningResolutionTest = true
        resolutionTestResults = []
        showResolutionTest = true
        let scales = [10, 20, 40, 60, 80, 100]
        let provider = selectedProvider
        let model = selectedModel
        let thinking = selectedModel.supportsThinking ? selectedThinking : nil
        let key = apiKey

        Task {
            for scale in scales {
                let result = await OCRProcessor.performResolutionTestCall(
                    imageURL: imageURL, provider: provider, model: model,
                    thinkingLevel: thinking, apiKey: key,
                    imageScale: Double(scale) / 100.0
                )
                resolutionTestResults.append((scale: scale, text: result.text))
            }
            isRunningResolutionTest = false
        }
    }

    private func runModelTest(imageURL: URL) {
        isRunningModelTest = true
        modelTestResults = []
        showModelTestResults = true
        let entries = modelTestSelections
        let scale = imageScale / 100.0

        Task {
            for entry in entries {
                let result = await OCRProcessor.performResolutionTestCall(
                    imageURL: imageURL, provider: entry.provider, model: entry.model,
                    thinkingLevel: entry.model.supportsThinking ? .low : nil,
                    apiKey: entry.apiKey,
                    imageScale: scale
                )
                modelTestResults.append(ModelTestResult(
                    provider: entry.provider,
                    model: entry.model,
                    text: result.text,
                    errorMessage: result.errorMessage
                ))
            }
            isRunningModelTest = false
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp", "gif", "pdf"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func resumePendingBatch() {
        if let urls = processor.pendingBatchFileURLs {
            droppedFiles = urls
        }
        processor.processingTask = Task {
            await processor.resumeBatch(apiKey: apiKey)
        }
    }

    private func resumePendingRun() {
        if let urls = processor.pendingRunFileURLs {
            droppedFiles = urls
        }
        processor.processingTask = Task {
            await processor.resumeRun(apiKey: apiKey)
        }
    }

    private func startProcessing() {
        guard let outDir = outputDirectory else { return }
        let trimmedPrompt = customOCRPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = SegmentationContext(
            previousTextCharCount: Int(contextCharCount),
            sendPreviousImage: sendPreviousImage,
            customPrompt: trimmedPrompt.isEmpty ? nil : trimmedPrompt,
            imageScale: imageScale / 100.0
        )
        processor.passSourceTags = passSourceTags && enableTagging
        processor.mergeDocuments = mergeDocuments
        processor.processingTask = Task {
            await processor.startProcessing(
                files: droppedFiles,
                provider: selectedProvider,
                model: selectedModel,
                thinkingLevel: selectedModel.supportsThinking ? selectedThinking : nil,
                apiKey: apiKey,
                outputDirectory: outDir,
                batchMode: selectedProvider == .gemini ? false : batchMode,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: enableCollectionSegmentation,
                confirmCollectionIDs: confirmCollectionIDs && enableCollectionSegmentation,
                reviewDocumentSegmentation: reviewDocumentSegmentation && enableCollectionSegmentation,
                preOCRedInput: preOCRedInput,
                segmentationContext: context
            )
        }
    }
}

// MARK: - File Row

struct FileRowView: View {
    let url: URL
    let job: OCRJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                statusIcon
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let classification = job?.classification {
                    Text(classification.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(classificationColor(classification).opacity(0.15))
                        .foregroundStyle(classificationColor(classification))
                        .clipShape(Capsule())
                }
                if let tags = job?.appliedTags, !tags.isEmpty {
                    Text(tags.prefix(2).joined(separator: " \u{00B7} "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        .background(Color.clear)
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

                Picker("Provider", selection: $selectedProvider) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProvider) { _, newProvider in
                    selectedModel = newProvider.models[0]
                    apiKey = KeychainHelper.load(account: newProvider.rawValue) ?? ""
                }

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

    private var boxCount: Int {
        processor.collectionReviewItems.filter { $0.classification == .boxLabel }.count
    }

    private var folderCount: Int {
        processor.collectionReviewItems.filter { $0.classification == .folderLabel }.count
    }

    private var documentCount: Int {
        processor.collectionReviewItems.filter { $0.classification == .documentStart }.count
    }

    private var hasBoxes: Bool {
        boxCount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Box and Folder Identifications")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if hasBoxes {
                        Text("Toggle between Box and Folder classifications. Edit collection names for boxes. Files between boxes are automatically assigned to the preceding box's collection.")
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
                // Box and folder list
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
                    Text("\(boxCount) box\(boxCount == 1 ? "" : "es"), \(folderCount) folder\(folderCount == 1 ? "" : "s")\(documentCount > 0 ? ", \(documentCount) reclassified as document" : "")")
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

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            thumbnail
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Box/Folder/Document radio buttons
            VStack(alignment: .leading, spacing: 6) {
                radioButton(label: "Box", selected: item.classification == .boxLabel, color: .red) {
                    item.classification = .boxLabel
                    item.isBoxLabel = true
                }
                radioButton(label: "Folder", selected: item.classification == .folderLabel, color: .purple) {
                    item.classification = .folderLabel
                    item.isBoxLabel = false
                }
                radioButton(label: "Document", selected: item.classification == .documentStart, color: .blue) {
                    item.classification = .documentStart
                    item.isBoxLabel = false
                }
            }
            .frame(width: 100)

            // Filename
            Text(item.fileName)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 180, alignment: .leading)

            Spacer()

            // Collection name (editable for boxes, hidden for folders)
            if item.classification == .boxLabel {
                TextField("Collection name", text: $item.collectionName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit {
                        item.collectionName = CollectionSegmenter.normalizeCollectionName(item.collectionName)
                    }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            item.classification == .boxLabel ? Color.red.opacity(0.05) :
            item.classification == .folderLabel ? Color.purple.opacity(0.05) :
            Color.blue.opacity(0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let nsImage = loadThumbnail(url: item.fileURL, maxSize: 360) {
            Image(nsImage: nsImage)
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

    private func loadThumbnail(url: URL, maxSize: Int) -> NSImage? {
        // For PDFs, render first page
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFKit.PDFDocument(url: url),
                  let page = doc.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = CGFloat(maxSize) / max(bounds.width, bounds.height)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = NSImage(size: size)
            image.lockFocus()
            if let context = NSGraphicsContext.current?.cgContext {
                context.setFillColor(CGColor.white)
                context.fill(CGRect(origin: .zero, size: size))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
            }
            image.unlockFocus()
            return image
        }
        // For images, use ImageIO thumbnail generation
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Document Segmentation: \(processor.currentReviewCollectionName)")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Review document start and continuation classifications. Change classifications to adjust how documents are grouped.")
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(processor.documentReviewItems.indices, id: \.self) { idx in
                        DocumentReviewRow(
                            item: $processor.documentReviewItems[idx],
                            thumbnailSize: thumbnailSize
                        )
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Text("\(newDocCount) new document\(newDocCount == 1 ? "" : "s"), \(continuationCount) continuation\(continuationCount == 1 ? "" : "s")\(boxCount > 0 ? ", \(boxCount) box\(boxCount == 1 ? "" : "es")" : "")\(folderCount > 0 ? ", \(folderCount) folder\(folderCount == 1 ? "" : "s")" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Confirm") {
                    processor.confirmDocumentReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .frame(minWidth: 700, idealWidth: 1000, maxWidth: .infinity, minHeight: 500, idealHeight: 700, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    window.styleMask.insert(.resizable)
                }
            }
        }
    }
}

struct DocumentReviewRow: View {
    @Binding var item: DocumentReviewItem
    let thumbnailSize: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            thumbnail
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Classification radio buttons
            VStack(alignment: .leading, spacing: 6) {
                radioButton(label: "New Document", selected: item.classification == .documentStart, color: .blue) {
                    item.classification = .documentStart
                }
                radioButton(label: "Continuation", selected: item.classification == .documentContinuation, color: .gray) {
                    item.classification = .documentContinuation
                }
                radioButton(label: "Box", selected: item.classification == .boxLabel, color: .red) {
                    item.classification = .boxLabel
                }
                radioButton(label: "Folder", selected: item.classification == .folderLabel, color: .purple) {
                    item.classification = .folderLabel
                }
            }
            .frame(width: 120)

            // Filename
            Text(item.fileName)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 180, alignment: .leading)

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            item.classification == .boxLabel ? Color.red.opacity(0.05) :
            item.classification == .folderLabel ? Color.purple.opacity(0.05) :
            item.classification == .documentStart ? Color.blue.opacity(0.05) :
            Color.gray.opacity(0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let nsImage = loadThumbnail(url: item.fileURL, maxSize: Int(max(thumbnailSize * 2, 800))) {
            Image(nsImage: nsImage)
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

    private func loadThumbnail(url: URL, maxSize: Int) -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFKit.PDFDocument(url: url),
                  let page = doc.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = CGFloat(maxSize) / max(bounds.width, bounds.height)
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            let image = NSImage(size: size)
            image.lockFocus()
            if let context = NSGraphicsContext.current?.cgContext {
                context.setFillColor(CGColor.white)
                context.fill(CGRect(origin: .zero, size: size))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
            }
            image.unlockFocus()
            return image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
