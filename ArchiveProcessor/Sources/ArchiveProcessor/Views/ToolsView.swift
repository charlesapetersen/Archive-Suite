import SwiftUI

/// Standalone diagnostic tools (a top-level tab next to Process Files / Live Capture): compare OCR
/// output across models, and test how image resolution affects OCR. Both run one-off OCR calls via
/// `OCRProcessor.performResolutionTestCall` — independent of the main processing run.
struct ToolsView: View {
    @AppStorage("selectedProvider") private var selectedProvider: LLMProvider = .gemini
    @AppStorage("selectedThinking") private var selectedThinking: ThinkingLevel = .low
    @AppStorage("useGateway") private var useGateway: Bool = false
    @AppStorage("gatewayBaseURL") private var gatewayBaseURL: String = ""
    @AppStorage("gatewayModelID") private var gatewayModelID: String = ""
    @AppStorage("gatewayDisplayName") private var gatewayDisplayName: String = ""
    @AppStorage("gatewayInputCost") private var gatewayInputCost: Double = -1
    @AppStorage("gatewayOutputCost") private var gatewayOutputCost: Double = -1
    @AppStorage("imageResolutionPercent") private var imageScale: Double = 100

    @State private var selectedModel: LLMModel
    @State private var apiKey: String = ""

    @State private var showResolutionDropSheet = false
    @State private var showResolutionTest = false
    @State private var resolutionTestResults: [(scale: Int, text: String?)] = []
    @State private var resolutionTestImage: URL?
    @State private var isRunningResolutionTest = false

    @State private var showModelSelectionSheet = false
    @State private var showModelTestDropSheet = false
    @State private var showModelTestResults = false
    @State private var modelTestSelections: [ModelTestEntry] = []
    @State private var modelTestResults: [ModelTestResult] = []
    @State private var modelTestImage: URL?
    @State private var isRunningModelTest = false

    // Handles so the paid diagnostic loops can be cancelled when their sheet is dismissed (otherwise
    // they keep firing billable OCR calls for a closed view).
    @State private var resolutionTask: Task<Void, Never>?
    @State private var modelTestTask: Task<Void, Never>?

    init() {
        let provider = LLMProvider(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .gemini
        let modelId = UserDefaults.standard.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        _selectedModel = State(initialValue: provider.models.first { $0.id == modelId } ?? provider.models[0])
    }

    private var currentGatewayConfig: GatewayConfig? {
        guard useGateway, !gatewayBaseURL.isEmpty, !gatewayModelID.isEmpty else { return nil }
        return GatewayConfig(baseURL: gatewayBaseURL, modelID: gatewayModelID,
                             displayName: gatewayDisplayName.isEmpty ? "API Gateway" : gatewayDisplayName,
                             inputCostPer1M: gatewayInputCost >= 0 ? gatewayInputCost : nil,
                             outputCostPer1M: gatewayOutputCost >= 0 ? gatewayOutputCost : nil)
    }

    /// Re-read the selected model (for the current provider) and the matching Keychain key. Mirrors the
    /// init's resolution so switching provider/gateway in Settings updates the Tools diagnostics live.
    private func reloadModelAndKey() {
        let modelId = UserDefaults.standard.string(forKey: "selectedModelId_\(selectedProvider.rawValue)") ?? ""
        selectedModel = selectedProvider.models.first { $0.id == modelId } ?? selectedProvider.models[0]
        apiKey = KeychainHelper.load(account: useGateway ? "Gateway" : selectedProvider.rawValue) ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tools").font(.title).fontWeight(.bold)
                Text("One-off diagnostics. They use your current API key (set in Settings, ⌘,).")
                    .font(.callout).foregroundStyle(.secondary)

                toolCard(
                    title: "Compare Models",
                    systemImage: "rectangle.split.3x1",
                    detail: "Run the same image through several models/providers side by side and compare the OCR output.",
                    buttonTitle: "Compare Models…",
                    disabled: isRunningModelTest
                ) { showModelSelectionSheet = true }

                toolCard(
                    title: "Test Resolution",
                    systemImage: "arrow.down.right.and.arrow.up.left",
                    detail: "OCR one image at 10–100% resolution to see how downscaling affects accuracy and cost. Uses the current provider/model.",
                    buttonTitle: "Test Resolution…",
                    disabled: apiKey.isEmpty || isRunningResolutionTest
                ) { showResolutionDropSheet = true }

                if apiKey.isEmpty {
                    Label("Set an API key in Settings (⌘,) to run these.", systemImage: "key")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { reloadModelAndKey() }
        // Stay in sync when the provider / gateway / key is changed in the Settings window while the Tools
        // tab remains visible (no tab switch → no onAppear), so a diagnostic never runs against a stale
        // model id or the wrong provider's key. (Note: a model change for the SAME provider is persisted to
        // selectedModelId_<provider>, which isn't observed here — reopening the tab still refreshes it.)
        .onChange(of: selectedProvider) { _, _ in reloadModelAndKey() }
        .onChange(of: useGateway) { _, _ in reloadModelAndKey() }
        .sheet(isPresented: $showResolutionDropSheet) {
            ResolutionDropSheet { url in
                showResolutionDropSheet = false
                resolutionTestImage = url
                runResolutionTest(imageURL: url)
            } onDismiss: { showResolutionDropSheet = false }
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
                onDismiss: { showResolutionTest = false })
        }
        .sheet(isPresented: $showModelSelectionSheet) {
            ModelSelectionSheet(
                currentProvider: selectedProvider,
                onStart: { entries in
                    modelTestSelections = entries
                    showModelSelectionSheet = false
                    showModelTestDropSheet = true
                },
                onDismiss: { showModelSelectionSheet = false })
        }
        .sheet(isPresented: $showModelTestDropSheet) {
            ResolutionDropSheet { url in
                showModelTestDropSheet = false
                modelTestImage = url
                runModelTest(imageURL: url)
            } onDismiss: { showModelTestDropSheet = false }
        }
        .sheet(isPresented: $showModelTestResults) {
            ModelTestResultsSheet(
                imageURL: modelTestImage,
                results: modelTestResults,
                isRunning: isRunningModelTest,
                totalCount: modelTestSelections.count,
                onSelect: { provider, model in
                    modelTestTask?.cancel()   // user picked a model — stop the remaining paid test calls
                    selectedProvider = provider
                    selectedModel = model
                    UserDefaults.standard.set(model.id, forKey: "selectedModelId_\(provider.rawValue)")
                    apiKey = KeychainHelper.load(account: useGateway ? "Gateway" : provider.rawValue) ?? ""
                    showModelTestResults = false
                },
                onDismiss: { showModelTestResults = false })
        }
        // Cancel the paid diagnostic loops as soon as their sheet closes, and clear the running flag
        // unconditionally here (the in-loop reset is skipped on cancel, so it must be reset on close or
        // the tool card stays permanently disabled).
        .onChange(of: showResolutionTest) { _, shown in if !shown { resolutionTask?.cancel(); isRunningResolutionTest = false } }
        .onChange(of: showModelTestResults) { _, shown in if !shown { modelTestTask?.cancel(); isRunningModelTest = false } }
    }

    @ViewBuilder private func toolCard(title: String, systemImage: String, detail: String,
                                       buttonTitle: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage).font(.title2).foregroundStyle(.tint).frame(width: 30)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(buttonTitle, action: action).disabled(disabled).padding(.top, 2)
                }
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: Run logic (moved from OCRView; standalone OCR calls)

    private func runResolutionTest(imageURL: URL) {
        resolutionTask?.cancel()   // supersede any in-flight run so results can't interleave
        isRunningResolutionTest = true
        resolutionTestResults = []
        showResolutionTest = true
        let scales = [10, 20, 40, 60, 80, 100]
        let provider = selectedProvider
        let gateway = currentGatewayConfig
        let model = gateway?.asLLMModel() ?? selectedModel
        let thinking: ThinkingLevel? = (!useGateway && selectedModel.supportsThinking) ? selectedThinking : nil
        let key = apiKey
        resolutionTask = Task {
            for scale in scales {
                if Task.isCancelled { break }
                let result = await OCRProcessor.performResolutionTestCall(
                    imageURL: imageURL, provider: provider, model: model,
                    thinkingLevel: thinking, apiKey: key,
                    imageScale: Double(scale) / 100.0, gatewayConfig: gateway)
                if Task.isCancelled { break }
                resolutionTestResults.append((scale: scale, text: result.text))
            }
            if !Task.isCancelled { isRunningResolutionTest = false }
        }
    }

    private func runModelTest(imageURL: URL) {
        modelTestTask?.cancel()   // supersede any in-flight run so results can't interleave
        isRunningModelTest = true
        modelTestResults = []
        showModelTestResults = true
        let entries = modelTestSelections
        let scale = imageScale / 100.0
        modelTestTask = Task {
            for entry in entries {
                if Task.isCancelled { break }
                let result = await OCRProcessor.performResolutionTestCall(
                    imageURL: imageURL, provider: entry.provider, model: entry.model,
                    thinkingLevel: entry.model.supportsThinking ? .low : nil,
                    apiKey: entry.apiKey, imageScale: scale)
                if Task.isCancelled { break }
                modelTestResults.append(ModelTestResult(
                    provider: entry.provider, model: entry.model,
                    text: result.text, errorMessage: result.errorMessage))
            }
            if !Task.isCancelled { isRunningModelTest = false }
        }
    }
}
