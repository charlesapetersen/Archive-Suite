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
    @AppStorage("rotationModeRaw") private var rotationModeRaw: String = RotationMode.llmMajority.rawValue

    @AppStorage("taggingModeRaw") private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage("enableCollectionSegmentation") private var enableCollectionSegmentation: Bool = false
    @AppStorage("confirmCollectionIDs") private var confirmCollectionIDs: Bool = false
    @AppStorage("reviewDocumentSegmentation") private var reviewDocumentSegmentation: Bool = false
    @AppStorage("enableSegmentJSON") private var enableSegmentJSON: Bool = true
    @AppStorage("sendPreviousImage") private var sendPreviousImage: Bool = false
    @AppStorage("contextCharCount") private var contextCharCount: Double = 200
    @AppStorage("tagVocabulary") private var tagVocabulary: String = ""
    @AppStorage("mergeDocuments") private var mergeDocuments: Bool = false
    @AppStorage("customOCRPrompt") private var customOCRPrompt: String = ""
    @AppStorage("liveProcessingMode") private var liveProcessingMode: String = "stage"

    @ObservedObject private var customModelStore = CustomModelStore.shared
    @State private var selectedModel: LLMModel
    @State private var apiKey: String = ""
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
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .llmMajority }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                providerSection
                apiKeySection
                inputSection
                rotationSection
                taggingSection
                liveCaptureSection
            }
            .formStyle(.grouped)
            .frame(minWidth: 400)

            Divider()
            costPane
                .frame(width: 210)
        }
        .frame(width: 660, height: 640)
        .onAppear { apiKey = KeychainHelper.load(account: useGateway ? "Gateway" : selectedProvider.rawValue) ?? "" }
        .sheet(isPresented: $showManageModels) { ManageModelsView() }
    }

    // MARK: Fixed cost pane (stays put while the form scrolls)

    @ViewBuilder private var costPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Estimated cost").font(.headline)
            Text("1,000 files (~3 MB each)").font(.caption).foregroundStyle(.secondary)
            Divider()
            let model = useGateway ? gatewayModel : selectedModel
            if let model {
                let est = CostEstimator.estimate(
                    fileCount: 1000, model: model,
                    enableTagging: taggingMode.enablesTagging && taggingMode != .copySource,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    preOCRedInput: preOCRedInput, sendPreviousImage: sendPreviousImage,
                    contextCharCount: Int(contextCharCount), imageScale: imageScale / 100.0)
                costRow("Standard", est.totalStandardFormatted, bold: true)
                if batchMode && !useGateway && !preOCRedInput {
                    costRow("Batch (~50% off)", est.totalBatchFormatted)
                }
                Divider()
                if !preOCRedInput { costRow("OCR", est.ocrFormatted) }
                if taggingMode.enablesTagging && taggingMode != .copySource { costRow("Tagging", est.taggingFormatted) }
                if enableCollectionSegmentation { costRow("Collection ID", est.collectionFormatted) }
                Spacer()
                Text("Recomputes as you change settings. Actual cost varies with content & resolution.")
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
            .onChange(of: useGateway) { _, g in apiKey = KeychainHelper.load(account: g ? "Gateway" : selectedProvider.rawValue) ?? "" }

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
                        apiKey = KeychainHelper.load(account: p.rawValue) ?? ""
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
            SecureField(useGateway ? "Gateway API key" : "\(selectedProvider.rawValue) API key", text: $apiKey)
                .onChange(of: apiKey) { _, k in
                    let account = useGateway ? "Gateway" : selectedProvider.rawValue
                    let trimmed = k.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { KeychainHelper.delete(account: account) } else { KeychainHelper.save(account: account, password: trimmed) }
                    NotificationCenter.default.post(name: .apiKeyChanged, object: nil)
                }
        } header: {
            Text(useGateway ? "Gateway API Key" : "API Key")
        } footer: {
            Label("Stored securely in the macOS Keychain.", systemImage: "lock.shield").font(.caption)
        }
    }

    @ViewBuilder private var inputSection: some View {
        Section("Input & Processing") {
            Toggle("Pre-OCRed PDF input", isOn: $preOCRedInput)
            Toggle("Batch mode (slower, ~50% cheaper)", isOn: $batchMode).disabled(useGateway)
            VStack(alignment: .leading) {
                HStack { Text("Image resolution"); Spacer(); Text("\(Int(imageScale))%").foregroundStyle(.secondary) }
                Slider(value: $imageScale, in: 5...100, step: 5)
            }
        }
    }

    @ViewBuilder private var rotationSection: some View {
        Section("Rotation Correction") {
            Picker("Detect rotation", selection: $rotationModeRaw) {
                ForEach(RotationMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text(rotationMode.detail).font(.caption).foregroundStyle(.secondary)
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
                VStack(alignment: .leading) {
                    HStack { Text("Context from previous page"); Spacer(); Text("\(Int(contextCharCount)) chars").foregroundStyle(.secondary) }
                    Slider(value: $contextCharCount, in: 0...1000, step: 50)
                }
                Toggle("Send previous page image (higher accuracy, higher cost)", isOn: $sendPreviousImage)
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
