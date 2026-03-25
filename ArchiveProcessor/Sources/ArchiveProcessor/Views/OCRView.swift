import SwiftUI
import UniformTypeIdentifiers

struct OCRView: View {
    // MARK: - State
    @StateObject private var processor = OCRProcessor()

    @State private var selectedProvider: LLMProvider = .gemini
    @State private var selectedModel: LLMModel = LLMModel.geminiModels[3] // gemini-2.5-flash
    @State private var selectedThinking: ThinkingLevel = .low
    @State private var apiKey: String = ""
    @State private var batchMode: Bool = false
    @State private var droppedFiles: [URL] = []
    @State private var outputDirectory: URL? = nil
    @State private var isTargeted = false

    private var currentModels: [LLMModel] { selectedProvider.models }

    private var costEstimate: CostEstimate? {
        guard !droppedFiles.isEmpty else { return nil }
        return CostEstimator.estimate(fileCount: droppedFiles.count, model: selectedModel)
    }

    // MARK: - Body
    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 280, maxWidth: 340)
                .padding()

            filePanel
                .padding()
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("OCR Settings")
                    .font(.title2)
                    .fontWeight(.semibold)

                GroupBox("Provider") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $selectedProvider) {
                            ForEach(LLMProvider.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: selectedProvider) { _, newProvider in
                            selectedModel = newProvider.models[0]
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

                GroupBox("API Key") {
                    VStack(alignment: .leading, spacing: 6) {
                        SecureField("Enter \(selectedProvider.rawValue) API key…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Text("Key is not stored to disk.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

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

                if let est = costEstimate {
                    GroupBox("Cost Estimate") {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Files:").foregroundStyle(.secondary)
                                Spacer()
                                Text("\(est.fileCount)")
                            }
                            HStack {
                                Text("Standard:").foregroundStyle(.secondary)
                                Spacer()
                                Text(est.standardFormatted)
                            }
                            HStack {
                                Text("Batch (50% off):").foregroundStyle(.secondary)
                                Spacer()
                                Text(est.batchFormatted)
                            }
                            .foregroundStyle(batchMode ? .primary : .secondary)
                            Text("Estimates based on ~1,800 tokens/image. Actual costs may vary.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                        .padding(4)
                    }
                }

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

                Button(action: startOCR) {
                    Label("Start OCR", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(droppedFiles.isEmpty || apiKey.isEmpty || outputDirectory == nil || processor.isProcessing)

                if processor.isProcessing {
                    Button("Cancel") { /* TODO: cancellation token */ }
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
                    Button("Clear") { droppedFiles = []; processor.jobs = [] }
                        .buttonStyle(.bordered)
                }
            }

            if droppedFiles.isEmpty {
                dropZone
            } else {
                fileList
            }

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

    private func startOCR() {
        guard let outDir = outputDirectory else { return }
        Task {
            await processor.startProcessing(
                files: droppedFiles,
                provider: selectedProvider,
                model: selectedModel,
                thinkingLevel: selectedModel.supportsThinking ? selectedThinking : nil,
                apiKey: apiKey,
                outputDirectory: outDir,
                batchMode: batchMode
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
            if let job = job, job.status == .failed, let msg = job.result?.errorMessage {
                Text(msg.prefix(40) + (msg.count > 40 ? "…" : ""))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.clear)
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
