import SwiftUI
import UniformTypeIdentifiers

struct TaggingView: View {
    @StateObject private var processor = TaggingProcessor()

    @State private var selectedProvider: LLMProvider = .gemini
    @State private var selectedModel: LLMModel = LLMModel.geminiModels[3] // gemini-2.5-flash
    @State private var selectedThinking: ThinkingLevel = .low
    @State private var apiKey: String = ""
    @State private var imageFiles: [URL] = []
    @State private var ocrTextFiles: [URL] = []
    @State private var isTargeted = false
    @State private var inputMode: InputMode = .images

    enum InputMode: String, CaseIterable {
        case images = "Images (will auto-load OCR PDFs)"
        case manual = "Images + OCR text files"
    }

    private var currentModels: [LLMModel] { selectedProvider.models }

    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 280, maxWidth: 340)
                .padding()

            rightPanel
                .padding()
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Tagging Settings")
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

                GroupBox("How It Works") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The tagging module:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        bulletText("Segments your images into documents using text heuristics")
                        bulletText("Asks the LLM for year, month, and subject tags")
                        bulletText("Applies tags to image files and associated PDFs in Finder")
                        bulletText("Boxes → Red tag, Folders → Purple tag")
                    }
                    .padding(4)
                }

                Button(action: startTagging) {
                    Label("Start Tagging", systemImage: "tag.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(imageFiles.isEmpty || apiKey.isEmpty || processor.isProcessing)
            }
        }
    }

    private func bulletText(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•").font(.caption).foregroundStyle(.secondary)
            Text(s).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Right Panel

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Images to Tag")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Add Images…") { selectImages() }
                    .buttonStyle(.bordered)
                if !imageFiles.isEmpty {
                    Button("Clear") { imageFiles = []; processor.jobs = [] }
                        .buttonStyle(.bordered)
                }
            }

            if imageFiles.isEmpty {
                dropZone
            } else {
                jobList
            }

            if !processor.segments.isEmpty {
                Divider()
                segmentSummary
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
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "tag.square")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Drop image files here")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Tags will be applied directly to these files in Finder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 220)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(imageFiles.enumerated()), id: \.offset) { _, url in
                    let job = processor.jobs.first { $0.sourceURL == url }
                    HStack(spacing: 8) {
                        jobStatusIcon(job)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if let tags = job?.appliedTags, !tags.isEmpty {
                            Text(tags.prefix(3).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [.image, .fileURL], isTargeted: $isTargeted, perform: handleDrop)
    }

    private var segmentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Document Segments (\(processor.segments.count))")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            ForEach(Array(processor.segments.enumerated()), id: \.offset) { index, seg in
                HStack(spacing: 6) {
                    if seg.isBox {
                        Circle().fill(.red).frame(width: 8, height: 8)
                    } else if seg.isFolder {
                        Circle().fill(.purple).frame(width: 8, height: 8)
                    } else {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                    }
                    Text("Segment \(index + 1): \(seg.imageURLs.count) page\(seg.imageURLs.count == 1 ? "" : "s")")
                        .font(.caption)
                    if seg.isBox { Text("(Box)").font(.caption).foregroundStyle(.red) }
                    if seg.isFolder { Text("(Folder)").font(.caption).foregroundStyle(.purple) }
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func jobStatusIcon(_ job: TaggingJob?) -> some View {
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

    // MARK: - Actions

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let data = item as? Data,
                          let path = String(data: data, encoding: .utf8),
                          let url = URL(string: path) ?? URL(fileURLWithPath: path) as URL? else { return }

                    var isDir: ObjCBool = false
                    var urls: [URL] = []
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                        urls = contents.filter { self.isImageFile($0) }
                    } else if self.isImageFile(url) {
                        urls = [url]
                    }

                    DispatchQueue.main.async {
                        self.imageFiles.append(contentsOf: urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
                    }
                }
            }
        }
        return true
    }

    private func selectImages() {
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
            imageFiles.append(contentsOf: urls)
        }
    }

    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "bmp", "gif"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func startTagging() {
        // Try to load OCR text from associated PDFs (not yet implemented — use empty strings for now)
        let texts = imageFiles.map { _ in "" }
        Task {
            await processor.startTagging(
                files: imageFiles,
                ocrTexts: texts,
                provider: selectedProvider,
                model: selectedModel,
                thinkingLevel: selectedModel.supportsThinking ? selectedThinking : nil,
                apiKey: apiKey
            )
        }
    }
}
