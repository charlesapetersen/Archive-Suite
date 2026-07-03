import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted when the API key changes in Settings, so the main window reloads it from the Keychain.
    static let apiKeyChanged = Notification.Name("APIKeyChanged")
}

/// The app's durable settings, shown in a native Settings window (⌘,). Settings are shared with the
/// Process Files view via the same `@AppStorage`/UserDefaults keys (auto-synced) plus the Keychain
/// for the API key. The tagging-mode dropdown and the output folder stay in the main UI; the
/// model-comparison/resolution tools live in the Tools tab.
///
/// Layout: a scrolling settings form on the left, with a **fixed cost-estimate pane on the right**
/// that stays visible so cost effects of each change are immediately apparent.
struct SettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider: LLMProvider = .gemini
    @AppStorage("selectedThinking") private var selectedThinking: ThinkingLevel = .low
    @AppStorage("useGateway") private var useGateway: Bool = false
    @AppStorage("gatewayBaseURL") private var gatewayBaseURL: String = ""
    @AppStorage("gatewayModelID") private var gatewayModelID: String = ""
    @AppStorage("gatewayDisplayName") private var gatewayDisplayName: String = ""
    @AppStorage("gatewayInputCost") private var gatewayInputCost: Double = -1
    @AppStorage("gatewayOutputCost") private var gatewayOutputCost: Double = -1

    @AppStorage("preOCRedInput") private var preOCRedInput: Bool = false
    @AppStorage("batchMode") private var batchMode: Bool = false
    @AppStorage("imageResolutionPercent") private var imageScale: Double = 100
    @AppStorage("standardImageSizeMB") private var standardImageSizeMB: Double = 3.0
    @AppStorage("ocrWorkerCount") private var ocrWorkerCount: Int = 4
    @AppStorage("rotationModeRaw") private var rotationModeRaw: String = RotationMode.llmSingle.rawValue

    @AppStorage("taggingModeRaw") private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage("enableCollectionSegmentation") private var enableCollectionSegmentation: Bool = false
    @AppStorage("confirmCollectionIDs") private var confirmCollectionIDs: Bool = false
    @AppStorage("reviewDocumentSegmentation") private var reviewDocumentSegmentation: Bool = false
    @AppStorage("enableSegmentJSON") private var enableSegmentJSON: Bool = true
    @AppStorage("sendPreviousImage") private var sendPreviousImage: Bool = false
    @AppStorage("contextCharCount") private var contextCharCount: Double = 0   // context slider removed; kept 0 (parallel OCR)
    @AppStorage("tagVocabulary") private var tagVocabulary: String = ""
    @AppStorage("mergeDocuments") private var mergeDocuments: Bool = false
    @AppStorage("customOCRPrompt") private var customOCRPrompt: String = ""
    @AppStorage("liveProcessingMode") private var liveProcessingMode: String = "stage"

    @ObservedObject private var customModelStore = CustomModelStore.shared
    @State private var selectedModel: LLMModel
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var mistralKey = ""
    @State private var gatewayKey = ""
    @State private var showManageModels = false

    init() {
        let provider = LLMProvider(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .gemini
        let modelId = UserDefaults.standard.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        _selectedModel = State(initialValue: provider.models.first { $0.id == modelId } ?? provider.models[0])
    }

    private var models: [LLMModel] {
        selectedProvider.models + customModelStore.allCustomModels.filter { $0.provider == selectedProvider }
    }
    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .llmSingle }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                liveCaptureSection
                providerSection
                apiKeySection
                inputSection
                rotationSection
                taggingSection
            }
            .formStyle(.grouped)
            .frame(minWidth: 400)

            Divider()
            costPane
                .frame(width: 210)
        }
        .frame(width: 680, height: 660)
        .onAppear {
            anthropicKey = KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? ""
            geminiKey = KeychainHelper.load(account: LLMProvider.gemini.rawValue) ?? ""
            mistralKey = KeychainHelper.load(account: LLMProvider.mistral.rawValue) ?? ""
            gatewayKey = KeychainHelper.load(account: "Gateway") ?? ""
        }
        .sheet(isPresented: $showManageModels) { ManageModelsView() }
    }

    // MARK: Fixed cost pane (stays put while the form scrolls)

    @ViewBuilder private var costPane: some View {
        let tagging = taggingMode.enablesTagging && taggingMode != .copySource
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimate — 1,000 files").font(.headline)
            Text("~\(String(format: "%.2g", standardImageSizeMB)) MB each")
                .font(.caption2).foregroundStyle(.secondary)

            let model = useGateway ? gatewayModel : selectedModel
            if let model {
                let est = CostEstimator.estimate(
                    fileCount: 1000, model: model, enableTagging: tagging,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    preOCRedInput: preOCRedInput, sendPreviousImage: sendPreviousImage,
                    contextCharCount: Int(contextCharCount), imageScale: imageScale / 100.0,
                    rotationMode: rotationMode, useGateway: useGateway)
                let time = TimeEstimator.estimate(
                    fileCount: 1000, model: model, rotationMode: rotationMode,
                    sequentialOCR: contextCharCount > 0, enableTagging: tagging,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    preOCRedInput: preOCRedInput, useGateway: useGateway, ocrWorkers: ocrWorkerCount)

                Divider().padding(.vertical, 2)
                Text("COST").font(.caption2).fontWeight(.bold).foregroundStyle(.secondary)
                costRow("Total", est.totalStandardFormatted, bold: true)
                if batchMode && !useGateway && !preOCRedInput { costRow("Batch", est.totalBatchFormatted) }
                if !preOCRedInput { costRow("· OCR", est.ocrFormatted) }
                if est.rotationCost > 0 { costRow("· Rotation", est.rotationFormatted) }
                if tagging { costRow("· Tagging", est.taggingFormatted) }
                if enableCollectionSegmentation { costRow("· Collection", est.collectionFormatted) }

                Divider().padding(.vertical, 2)
                Text("TIME (processing only)").font(.caption2).fontWeight(.bold).foregroundStyle(.secondary)
                costRow("Total", time.totalFormatted, bold: true)
                if time.ocrSeconds > 0 { costRow("· OCR", time.ocrFormatted) }
                if time.rotationSeconds > 0 { costRow("· Rotation*", time.rotationFormatted) }
                if tagging { costRow("· Tagging", time.taggingFormatted) }
                if enableCollectionSegmentation { costRow("· Collection", time.collectionFormatted) }
                if time.rotationSeconds > 0 {
                    Text("*runs during OCR").font(.caption2).foregroundStyle(.tertiary)
                }

                Spacer()
                Text("Approximate; varies with model, content & network.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("Enter gateway model pricing to estimate cost.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func costRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(bold ? .primary : .secondary)
            Spacer()
            Text(value).font(.caption).fontWeight(bold ? .semibold : .regular)
        }
    }

    // MARK: Sections

    @ViewBuilder private var providerSection: some View {
        Section("Provider & Model") {
            Picker("API mode", selection: $useGateway) {
                Text("Direct API").tag(false)
                Text("API Gateway").tag(true)
            }

            if useGateway {
                TextField("Gateway URL", text: $gatewayBaseURL)
                TextField("Model ID", text: $gatewayModelID)
                TextField("Display name (for PDF headers)", text: $gatewayDisplayName)
                TextField("Input $/1M tokens", value: Binding(get: { gatewayInputCost >= 0 ? gatewayInputCost : nil }, set: { gatewayInputCost = $0 ?? -1 }), format: .number)
                TextField("Output $/1M tokens", value: Binding(get: { gatewayOutputCost >= 0 ? gatewayOutputCost : nil }, set: { gatewayOutputCost = $0 ?? -1 }), format: .number)
            } else {
                Picker("Provider", selection: Binding(
                    get: { selectedProvider },
                    set: { p in
                        let saved = UserDefaults.standard.string(forKey: "selectedModelId_\(p.rawValue)") ?? ""
                        selectedModel = p.models.first { $0.id == saved } ?? p.models[0]
                        selectedProvider = p
                    })) {
                    ForEach(LLMProvider.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Model", selection: $selectedModel) {
                    ForEach(models) { m in
                        Text(customModelStore.isCustom(m) ? "\(m.displayName) (custom)" : m.displayName).tag(m)
                    }
                }
                .onChange(of: selectedModel) { _, m in
                    UserDefaults.standard.set(m.id, forKey: "selectedModelId_\(selectedProvider.rawValue)")
                }
                if selectedModel.supportsThinking {
                    Picker("Thinking", selection: $selectedThinking) {
                        ForEach(ThinkingLevel.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Button("Manage custom models…") { showManageModels = true }
            }
        }
    }

    @ViewBuilder private var apiKeySection: some View {
        Section {
            keyField("Anthropic", account: LLMProvider.anthropic.rawValue, text: $anthropicKey)
            keyField("Gemini", account: LLMProvider.gemini.rawValue, text: $geminiKey)
            keyField("Mistral", account: LLMProvider.mistral.rawValue, text: $mistralKey)
            if useGateway { keyField("Gateway", account: "Gateway", text: $gatewayKey) }
        } header: {
            Text("API Keys")
        } footer: {
            Label("Each provider's key is stored separately in the macOS Keychain.", systemImage: "lock.shield").font(.caption)
        }
    }

    @ViewBuilder private func keyField(_ label: String, account: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            SecureField("\(label) API key", text: text)
                .onChange(of: text.wrappedValue) { _, k in
                    let t = k.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { KeychainHelper.delete(account: account) } else { KeychainHelper.save(account: account, password: t) }
                    NotificationCenter.default.post(name: .apiKeyChanged, object: nil)
                }
        }
    }

    @ViewBuilder private var inputSection: some View {
        Section("Input & Processing") {
            Toggle("Pre-OCRed PDF input", isOn: $preOCRedInput)
            Toggle("Batch mode (slower, ~50% cheaper)", isOn: $batchMode).disabled(useGateway)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text("Image resolution"); Spacer(); Text("\(Int(imageScale))% of standard").foregroundStyle(.secondary) }
                Slider(value: $imageScale, in: 5...100, step: 5)
                Text("Targets \(String(format: "%.2g", imageScale / 100 * standardImageSizeMB)) MB per image. Larger files are downscaled more; smaller files are left as-is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Standard image size")
                Spacer()
                TextField("MB", value: $standardImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 52).multilineTextAlignment(.trailing)
                Stepper("MB", value: $standardImageSizeMB, in: 0.5...20, step: 0.5)
            }
            VStack(alignment: .leading, spacing: 2) {
                Stepper("Parallel OCR workers: \(ocrWorkerCount)", value: $ocrWorkerCount, in: 1...12)
                Text("More workers process OCR faster (roughly halving time going 4 → 8), but raise the chance of provider rate-limit errors (429/503); those are auto-retried with backoff. 4 is safe; 6–8 is usually fine.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var rotationSection: some View {
        Section("Rotation Correction") {
            Picker("Detect rotation", selection: $rotationModeRaw) {
                ForEach(RotationMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text(rotationMode.detail).font(.caption).foregroundStyle(.secondary)
            Text("Time impact: Off / Local Vision add no LLM time. Single (default) makes one extra call per page that overlaps OCR — usually free time-wise. Majority makes three calls per page and can exceed OCR time on large batches, becoming the bottleneck (see the Time estimate).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var taggingSection: some View {
        Section {
            Text("Tagging mode is chosen in the Process Files view. These options apply to it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Collection ID + file renaming", isOn: $enableCollectionSegmentation)
            if enableCollectionSegmentation {
                Toggle("Confirm identifications before organizing", isOn: $confirmCollectionIDs)
                Toggle("Review document segmentation", isOn: $reviewDocumentSegmentation)
            }
            if taggingMode.enablesTagging && taggingMode != .copySource {
                Toggle("Export segment JSON metadata", isOn: $enableSegmentJSON)
                Toggle("Send previous page image (better segmentation, ~2× image cost)", isOn: $sendPreviousImage)
                if sendPreviousImage {
                    Text("Gives the model the previous page's full image as segmentation context, while keeping OCR parallel (Gemini/Anthropic).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if taggingMode == .automatic {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tag vocabulary (optional, one per line)").font(.caption)
                        TextEditor(text: $tagVocabulary).font(.caption).frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    }
                }
            }
            Toggle("Merge multi-page documents", isOn: $mergeDocuments)
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom prompt (optional)").font(.caption)
                TextEditor(text: $customOCRPrompt).font(.caption).frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        } header: {
            Text("Tagging & Segmentation")
        }
    }

    @ViewBuilder private var liveCaptureSection: some View {
        Section {
            Picker("When capturing", selection: $liveProcessingMode) {
                Text("Stage for later").tag("stage")
                Text("Process live").tag("live")
            }
            Text(liveProcessingMode == "live"
                 ? "Each captured segment is OCR'd, tagged, and turned into a PDF as you shoot (using the settings above); confirm collection names at the end."
                 : "Captures collect in Live Capture; send them to Process Files for a normal batch run.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Live Capture")
        }
    }

    private var gatewayModel: LLMModel? {
        guard gatewayInputCost >= 0, gatewayOutputCost >= 0 else { return nil }
        return GatewayConfig(baseURL: gatewayBaseURL, modelID: gatewayModelID,
                             displayName: gatewayDisplayName.isEmpty ? "Gateway" : gatewayDisplayName,
                             inputCostPer1M: gatewayInputCost, outputCostPer1M: gatewayOutputCost).asLLMModel()
    }
}
