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
    @AppStorage("enableSegmentJSON") private var enableSegmentJSON: Bool = true
    @AppStorage("sendPreviousImage") private var sendPreviousImage: Bool = false
    @AppStorage("contextCharCount") private var contextCharCount: Double = 200

    // Initialized from persisted state in init()
    @State private var selectedModel: LLMModel
    @State private var apiKey: String
    @State private var outputDirectory: URL?

    @AppStorage("keychainExplained") private var keychainExplained: Bool = false

    // Transient
    @State private var droppedFiles: [URL] = []
    @State private var isTargeted = false
    @State private var showKeychainSheet = false

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
            contextCharCount: Int(contextCharCount)
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
                        }

                        Divider()

                        Toggle("Enable tagging", isOn: $enableTagging)

                        if enableTagging {
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
                        }
                    }
                    .padding(4)
                }

                // Batch
                GroupBox("Processing Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Batch Mode (slower, ~50% cheaper)", isOn: $batchMode)
                        if batchMode {
                            Text("Batch jobs are queued and returned asynchronously. Results may take minutes to hours.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                            if enableTagging {
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
                            if batchMode && !preOCRedInput {
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

    private func startProcessing() {
        guard let outDir = outputDirectory else { return }
        let context = SegmentationContext(
            previousTextCharCount: Int(contextCharCount),
            sendPreviousImage: sendPreviousImage
        )
        processor.processingTask = Task {
            await processor.startProcessing(
                files: droppedFiles,
                provider: selectedProvider,
                model: selectedModel,
                thinkingLevel: selectedModel.supportsThinking ? selectedThinking : nil,
                apiKey: apiKey,
                outputDirectory: outDir,
                batchMode: batchMode,
                enableTagging: enableTagging,
                enableSegmentJSON: enableSegmentJSON,
                enableCollectionSegmentation: enableCollectionSegmentation,
                confirmCollectionIDs: confirmCollectionIDs && enableCollectionSegmentation,
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
            if let job = job, job.status == .failed, let msg = job.result?.errorMessage {
                Text(String(msg.prefix(30)) + (msg.count > 30 ? "…" : ""))
                    .font(.caption2)
                    .foregroundStyle(.red)
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Box and Folder Identifications")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Toggle between Box and Folder classifications. Edit collection names for boxes. Files between boxes are automatically assigned to the preceding box's collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Box and folder list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(processor.collectionReviewItems.indices, id: \.self) { idx in
                        CollectionReviewRow(item: $processor.collectionReviewItems[idx])
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Text("\(boxCount) box\(boxCount == 1 ? "" : "es"), \(folderCount) folder\(folderCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Confirm and Organize") {
                    processor.confirmCollectionReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .frame(minWidth: 700, idealWidth: 1000, maxWidth: .infinity, minHeight: 500, idealHeight: 700, maxHeight: .infinity)
        .onAppear {
            // Allow the sheet's hosting window to be resizable
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

            // Box/Folder radio buttons
            HStack(spacing: 12) {
                radioButton(label: "Box", selected: item.classification == .boxLabel, color: .red) {
                    item.classification = .boxLabel
                    item.isBoxLabel = true
                }
                radioButton(label: "Folder", selected: item.classification == .folderLabel, color: .purple) {
                    item.classification = .folderLabel
                    item.isBoxLabel = false
                }
            }
            .frame(width: 130)

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
            Color.purple.opacity(0.05)
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
