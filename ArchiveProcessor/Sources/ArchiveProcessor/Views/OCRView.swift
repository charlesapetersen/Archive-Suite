import SwiftUI
import UniformTypeIdentifiers

struct OCRView: View {
    // MARK: - State
    @StateObject private var processor = OCRProcessor()

    // Persisted via @AppStorage (UserDefaults)
    @AppStorage("selectedProvider") private var selectedProvider: LLMProvider = .gemini
    @AppStorage("selectedThinking") private var selectedThinking: ThinkingLevel = .low
    @AppStorage("batchMode") private var batchMode: Bool = false
    @AppStorage("enableTagging") private var enableTagging: Bool = true
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

                // Tagging & Segmentation
                GroupBox("Tagging & Segmentation") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable tagging", isOn: $enableTagging)

                        if enableTagging {
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
                            HStack {
                                Text("OCR + classification:").foregroundStyle(.secondary)
                                Spacer()
                                Text(est.ocrFormatted)
                            }
                            if enableTagging {
                                HStack {
                                    Text("Tagging (~\(max(1, est.fileCount / 3)) segments):").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.taggingFormatted)
                                }
                            }
                            Divider()
                            HStack {
                                Text("Total (standard):").fontWeight(.medium)
                                Spacer()
                                Text(est.totalStandardFormatted).fontWeight(.medium)
                            }
                            if batchMode {
                                HStack {
                                    Text("Total (batch):").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(est.totalBatchFormatted)
                                }
                            }
                            Text("Estimates based on ~800 image tokens + ~850 output tokens/file. Actual costs may vary.")
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
                    Label(enableTagging ? "Start OCR + Tagging" : "Start OCR", systemImage: "play.fill")
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
                    Button("Clear") { droppedFiles = []; processor.jobs = []; processor.segments = [] }
                        .buttonStyle(.bordered)
                }
            }

            if droppedFiles.isEmpty {
                dropZone
            } else {
                fileList
                    .frame(maxHeight: .infinity)
            }

            // Segment summary
            if !processor.segments.isEmpty {
                Divider()
                segmentSummary
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

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor).opacity(0.3))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Drop images here")
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(zip(droppedFiles.indices, droppedFiles)), id: \.0) { index, url in
                        FileRowView(url: url, job: processor.jobs.first { $0.sourceURL == url })
                    }
                }
            }
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
            ScrollView {
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
            .frame(maxHeight: 150)
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
        panel.allowedContentTypes = [.image, .jpeg, .png, .tiff]
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
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp", "gif"]
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
