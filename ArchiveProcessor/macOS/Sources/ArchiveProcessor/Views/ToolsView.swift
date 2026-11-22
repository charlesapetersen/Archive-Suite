import SwiftUI
import ArchiveCore

/// Standalone diagnostic tools (a top-level tab next to Process Files / Live Capture): compare OCR
/// output across models, and test how image resolution affects OCR. Both run one-off OCR calls via
/// `OCRProcessor.performResolutionTestCall` — independent of the main processing run.
struct ToolsView: View {
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.selectedThinking) private var selectedThinking: ThinkingLevel = .low
    @AppStorage(DefaultsKeys.useGateway) private var useGateway: Bool = false
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL: String = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID: String = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName: String = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1
    @AppStorage(DefaultsKeys.imageResolutionPercent) private var imageScale: Double = 100

    @ObservedObject private var modelStore = ModelSelectionStore.shared
    /// Observed, not read directly: `selectedModel` resolves against `provider.models`, which includes
    /// this store's custom models — so deleting the selected one has to re-render this tab too.
    @ObservedObject private var customModelStore = CustomModelStore.shared

    /// Read live from the shared store, so a diagnostic can never run against the model this tab was
    /// showing before the Settings window changed it (see `ModelSelectionStore`).
    ///
    /// Read-only by design: the one place this tab picks a model (the Compare Models winner) changes the
    /// provider at the same moment, so it writes `ModelSelectionStore.saveModel(_:for:)` with that
    /// provider explicitly rather than through a setter keyed on the `@AppStorage` provider.
    private var selectedModel: LLMModel { modelStore.model(for: selectedProvider) }

    @State private var apiKey: String = ""

    @State private var showResolutionDropSheet = false
    @State private var showResolutionTest = false
    @State private var resolutionTestResults: [(scale: Int, text: String?)] = []
    @State private var resolutionTestImage: URL?
    @State private var isRunningResolutionTest = false

    @State private var showHistory = false
    @State private var showContainerBackfill = false

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

    private var currentGatewayConfig: GatewayConfig? { GatewayConfig.fromDefaults() }
    private var currentLocalAgentConfig: LocalAgentConfig? { LocalAgentConfig.fromDefaults() }

    /// Re-read the Keychain key for the current provider/gateway. The model needs no reload — it is read
    /// live from `ModelSelectionStore`, keyed by the current provider.
    private func reloadKey() {
        apiKey = useGateway ? GatewayConfig.storedKey() : (KeychainHelper.load(account: selectedProvider.rawValue) ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tools").font(.title).fontWeight(.bold)
                Text("One-off diagnostics. They use your current API key (set in Settings, ⌘,).")
                    .font(.callout).foregroundStyle(.primary)

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
                    disabled: apiKey.isEmpty || (useGateway && currentGatewayConfig == nil) || isRunningResolutionTest
                ) { showResolutionDropSheet = true }

                toolCard(
                    title: "Processing History",
                    systemImage: "clock.arrow.circlepath",
                    detail: "Review past Process Files runs — provider/model, file counts, and each run's estimated cost. No API key needed.",
                    buttonTitle: "View History…",
                    disabled: false
                ) { showHistory = true }

                toolCard(
                    title: "Read Box and Folder Labels",
                    systemImage: "archivebox",
                    detail: "For a folder photographed before Archive Processor: read its box and folder photos and propose "
                        + "each document's box and folder, accepted folder by folder. Free with Apple Vision; a model "
                        + "for titles is optional.",
                    buttonTitle: "Read Labels in a Folder…",
                    disabled: false
                ) { showContainerBackfill = true }
                .accessibilityIdentifier("ap.tools.backfill")

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
        .onAppear { reloadKey() }
        // Stay in sync when the provider / gateway / key is changed in the Settings window while the Tools
        // tab remains visible (no tab switch → no onAppear), so a diagnostic never runs against the wrong
        // provider's key. A model change for the SAME provider needs no hook: `ModelSelectionStore`
        // publishes it, and `selectedModel` re-reads on the resulting render.
        .onChange(of: selectedProvider) { _, _ in reloadKey() }
        .onChange(of: useGateway) { _, _ in reloadKey() }
        .sheet(isPresented: $showContainerBackfill) {
            ContainerBackfillSheet(makeModel: Self.backfillModel) { showContainerBackfill = false }
        }
        .sheet(isPresented: $showHistory) {
            ProcessingHistoryView(onDismiss: { showHistory = false })
        }
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
                    // Write for the winning provider explicitly (not via `selectedModel`, whose setter is
                    // keyed on the @AppStorage provider that may not have landed yet) so the choice can't
                    // be filed under the previous provider.
                    ModelSelectionStore.saveModel(model, for: provider)
                    apiKey = useGateway ? GatewayConfig.storedKey() : (KeychainHelper.load(account: provider.rawValue) ?? "")
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
                    Text(detail).font(.caption).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Button(buttonTitle, action: action).disabled(disabled).padding(.top, 2)
                }
                Spacer()
            }
            .padding(8)
        }
    }

    /// A new window's model; under a UI test, on the test's scratch folder with canned reads.
    @MainActor private static func backfillModel() -> ContainerBackfillModel {
        let model = ContainerBackfillModel()
#if DEBUG
        if ProcessorUITestConfiguration.backfillFakeReads {
            model.readOverride = { marker in
                let n = Int(marker.fileName.prefix { $0.isNumber }) ?? 0
                let fields: ContainerFieldSet = marker.type == .box
                    ? ContainerFieldSet([.container: ContainerValue("Box \(n)", source: .label, reader: "uitest")])
                    : ContainerFieldSet([.folder: ContainerValue("\(n)", source: .label, reader: "uitest")])
                return ContainerBackfillCache.Entry(fields: fields, text: "")
            }
        }
        if let folder = ProcessorUITestConfiguration.backfillFolder { model.choose(folder) }
#endif
        return model
    }

    // MARK: Run logic (moved from OCRView; standalone OCR calls)

    private func runResolutionTest(imageURL: URL) {
        let gateway = currentGatewayConfig
        guard !useGateway || gateway != nil else { return }
        resolutionTask?.cancel()   // supersede any in-flight run so results can't interleave
        isRunningResolutionTest = true
        resolutionTestResults = []
        showResolutionTest = true
        let scales = [10, 20, 40, 60, 80, 100]
        let provider = selectedProvider
        let localAgent = currentLocalAgentConfig
        let model = gateway?.asLLMModel() ?? selectedModel
        let thinking: ThinkingLevel? = (!useGateway && selectedModel.supportsThinking) ? selectedThinking : nil
        let key = apiKey
        let runConfig = SessionProcessingConfig.fromProcessFilesRunStart()
        resolutionTask = Task {
            for scale in scales {
                if Task.isCancelled { break }
                let result = await OCRProcessor.performResolutionTestCall(
                    imageURL: imageURL, provider: provider, model: model,
                    thinkingLevel: thinking, apiKey: key,
                    imageScale: Double(scale) / 100.0, gatewayConfig: gateway, localAgent: localAgent,
                    rotationMode: runConfig.rotationMode, standardImageMB: runConfig.standardImageMB)
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
        let runConfig = SessionProcessingConfig.fromProcessFilesRunStart()
        modelTestTask = Task {
            for entry in entries {
                if Task.isCancelled { break }
                let result = await OCRProcessor.performResolutionTestCall(
                    imageURL: imageURL, provider: entry.provider, model: entry.model,
                    thinkingLevel: entry.model.supportsThinking ? .low : nil,
                    apiKey: entry.apiKey, imageScale: scale,
                    rotationMode: runConfig.rotationMode, standardImageMB: runConfig.standardImageMB)
                if Task.isCancelled { break }
                modelTestResults.append(ModelTestResult(
                    provider: entry.provider, model: entry.model,
                    text: result.text, errorMessage: result.errorMessage))
            }
            if !Task.isCancelled { isRunningModelTest = false }
        }
    }
}
