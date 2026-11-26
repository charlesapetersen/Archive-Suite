import SwiftUI
import ArchiveCore

/// The one estimate in the Settings window (W49.proc-settings-redesign-core, §5.1): the cost and time of 1,000 pages
/// with exactly the choices the tabs show, as one line under Settings › Processing, with the breakdown one click away
/// and the Advisor sheet ("Compare routes & trade-offs…", `SettingsAdvisorSheet`) beside it, for the scope edited.
struct SettingsEstimateFooter: View {
    @EnvironmentObject private var scope: SettingsScopeModel
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.useGateway) private var useGateway: Bool = false
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL: String = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID: String = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName: String = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayUpstreamProvider) private var gatewayUpstreamProvider: LLMProvider = .anthropic
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent: Bool = false
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentTool: LocalAgentTool = .claude
    @AppStorage(DefaultsKeys.localAgentBinaryPath) private var localAgentBinaryPath = ""
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision: Bool = false
    @AppStorage(DefaultsKeys.visionUseLLMJudgment) private var visionUseLLMJudgment: Bool = false
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput: Bool = false
    @AppStorage(DefaultsKeys.batchMode) private var batchMode: Bool = false
    @AppStorage(DefaultsKeys.imageResolutionPercent) private var imageScale: Double = 100
    @AppStorage(DefaultsKeys.ocrWorkerCount) private var ocrWorkerCount: Int = 4
    @AppStorage(DefaultsKeys.rotationModeRaw) private var rotationModeRaw: String = RotationMode.standard.rawValue
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation: Bool = false
    @AppStorage(DefaultsKeys.sendPreviousImage) private var sendPreviousImage: Bool = false
    @AppStorage(DefaultsKeys.enableSegmentJSON) private var enableSegmentJSON: Bool = false
    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationApproachRaw: String =
        SegmentationApproach.defaultApproach.rawValue
    @AppStorage(OpenRouterListing.defaultsKey) private var openRouterListingData: Data?
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @ObservedObject private var claudeUsage = ClaudeCLIUsage.shared
    @State private var openRouterPricesRead = 0
    @State private var segmentationRoutes = SegmentationRoutes.none
    @State private var showDetails = false
    @State private var showSheet = false

    private var claudeBinary: String? { ClaudeCLIBilling.binaryPath(tool: localAgentTool, override: localAgentBinaryPath) }
    private var selectedModel: LLMModel { modelStore.model(for: selectedProvider) }
    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .standard }
    private var segmentationPlan: SegmentationPlan {
        SegmentationPlan.resolve(tagging: taggingMode,
                                 approach: SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach)
    }

    private var unavailableOpenRouterSelection: String? {
        _ = openRouterListingData
        guard useAppleVision ? visionUseLLMJudgment : !useGateway && !useLocalAgent else { return nil }
        return modelStore.unavailableOpenRouterSelection(for: selectedProvider)
    }

    private var segmentationRow: SegmentationRow? {
        guard let options = SegmentationOptionsStore.shared else { return nil }
        let approach = SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach
        return SegmentationRow.make(approach, options: options, pageCount: 1000,
                                    routes: segmentationRoutes.withClaudeBilling(claudeUsage.billing(for: claudeBinary)))
    }

    private var gatewayRotation: Bool {
        !useAppleVision && LLMRotationDetector.callsGateway(
            mode: rotationMode, gateway: useGateway ? GatewayConfig.fromDefaults() : nil, usesLocalAgent: useLocalAgent)
    }

    private var gatewayModel: LLMModel? {
        guard gatewayInputCost >= 0, gatewayOutputCost >= 0 else { return nil }
        return GatewayConfig(baseURL: gatewayBaseURL, modelID: gatewayModelID,
                             displayName: gatewayDisplayName.isEmpty ? "Gateway" : gatewayDisplayName,
                             inputCostPer1M: gatewayInputCost, outputCostPer1M: gatewayOutputCost).asLLMModel()
    }

    /// The figures for a paid reader, or nil for the readers with no dollar total.
    private struct Figures {
        var est: CostEstimate
        var time: TimeEstimate
        var segmentation: Double
        var batch: Bool
    }

    private var figures: Figures? {
        guard unavailableOpenRouterSelection == nil, !useAppleVision, !useLocalAgent,
              !(!useGateway && selectedProvider == .openrouter && openRouterPricesRead >= 0 && OpenRouterRoute.isUnpriced(selectedModel)),
              let model = useGateway ? gatewayModel : selectedModel else { return nil }
        let tagging = taggingMode.llmTags
        let gateway = GatewayConfig.fromDefaults()
        // The layers the run will read: the output folder's collection, whichever scope the window edits.
        let settings = scope.store.resolver(for: scope.doc)
        let namesCallShare = EntityRunPolicy.estimatedCallShare(
            taggingMode: taggingMode, gateway: gateway, usesLocalAgent: false, usesVision: false,
            setting: { settings.resolve($0).value })
        let est = CostEstimator.estimate(
            fileCount: 1000, model: model, enableTagging: tagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput, sendPreviousImage: sendPreviousImage && segmentationPlan.usesPerPageClassifier,
            contextCharCount: 0, imageScale: imageScale / 100.0,
            rotationMode: rotationMode, useGateway: useGateway,
            imageTokenProvider: useGateway ? gatewayUpstreamProvider : nil, gatewayRotation: gatewayRotation,
            measuredRoute: DateRoute.measuredRoute(gateway: gateway, usesLocalAgent: false),
            dateImageEveryDocument: DateRoute.imageEveryDocument(settings),
            sidecars: enableSegmentJSON || !preOCRedInput, namesCallShare: namesCallShare)
        let time = TimeEstimator.estimate(
            fileCount: 1000, model: model, rotationMode: rotationMode,
            sequentialOCR: false, enableTagging: tagging,
            enableCollectionSegmentation: enableCollectionSegmentation,
            preOCRedInput: preOCRedInput, useGateway: useGateway, ocrWorkers: ocrWorkerCount,
            gatewayRotation: gatewayRotation, usesLocalAgent: useLocalAgent)
        return Figures(est: est, time: time, segmentation: segmentationRow?.apiDollars ?? 0,
                       batch: batchMode && !useGateway && !preOCRedInput && model.provider.supportsBatch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The line a reader and the UI suite read as the estimate (`ap.settings.costPane`).
                Text(headline)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.costPane")
                Spacer(minLength: 4)
                Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                    .controlSize(.small)
                    .accessibilityIdentifier("ap.settings.estimate.details")
                Button("Compare routes & trade-offs…") { showSheet = true }
                    .controlSize(.small)
                    .accessibilityIdentifier("ap.settings.compareRoutes")
            }
            if showDetails { details }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.settings.estimate")
        .onAppear { segmentationRoutes = SegmentationRoutes.currentPreselecting() }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
            segmentationRoutes = SegmentationRoutes.currentPreselecting()
        }
        .task(id: selectedProvider) {
            guard selectedProvider == .openrouter else { return }
            await OpenRouterListing.refreshAllIfStale()
            openRouterPricesRead += 1
        }
        .sheet(isPresented: $showSheet) {
            SettingsAdvisorSheet(target: scope.effectiveScope == .collection ? scope.folder.map(SettingsAdvisor.Target.collection) ?? .general : .general) {
                showSheet = false
                scope.reload()
            }
        }
    }

    /// The one line: "1,000 pages: about $1.85 (batch $0.95) · about 14 min".
    private var headline: String {
        if let warning = unavailableOpenRouterSelection { return warning }
        if useAppleVision {
            if visionUseLLMJudgment && OpenRouterRoute.isUnpriced(selectedModel) { return OpenRouterRoute.unpricedEstimateMessage }
            return visionUseLLMJudgment
                ? "1,000 pages: reading free on this Mac; only the text goes to \(selectedProvider.rawValue) for the text-only steps."
                : "1,000 pages: free — Apple Vision reads on this Mac and sends nothing off it."
        }
        if useLocalAgent {
            return claudeUsage.costHeadline(binary: claudeBinary, tool: localAgentTool) + " "
                + claudeUsage.costDetail(binary: claudeBinary, tool: localAgentTool)
                + " Runs one CLI agent turn per page, at most two pages at a time."
        }
        if !useGateway, selectedProvider == .openrouter, openRouterPricesRead >= 0, OpenRouterRoute.isUnpriced(selectedModel) {
            return OpenRouterRoute.unpricedEstimateMessage
        }
        guard let f = figures else { return "Enter the gateway model's prices in Settings › Advanced to estimate its cost." }
        var line = "1,000 pages: about " + CostEstimate.money(f.est.totalStandard + f.segmentation)
        if f.batch { line += " (batch " + CostEstimate.money(f.est.totalBatch + f.segmentation) + ")" }
        return line + " · " + f.time.totalFormatted
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let f = figures {
                if !preOCRedInput { costRow("OCR", f.est.ocrFormatted) }
                if f.est.rotationCost > 0 { costRow("Rotation", f.est.rotationFormatted) }
                if taggingMode.llmTags { costRow("Tagging", f.est.taggingFormatted) }
                if f.est.datingCost > 0 { costRow("Dating", f.est.datingFormatted) }
                if f.est.itemFieldCost > 0 { costRow("Item fields", f.est.itemFieldFormatted) }
                if f.est.namesCost > 0 { costRow("Names", f.est.namesFormatted) }
                if enableCollectionSegmentation { costRow("Collection", f.est.collectionFormatted) }
                if let row = segmentationRow { costRow("Document breaks", row.costSummary) }
                costRow("Time, processing only", f.time.totalFormatted)
                if f.time.rotationSeconds > 0 { costRow("Rotation (during OCR)", f.time.rotationFormatted) }
                if f.batch {
                    Text("Batch mode returns later (minutes to hours); the time above is the equivalent interactive run.")
                        .font(.caption2).foregroundStyle(.primary)
                }
            } else {
                if let row = segmentationRow, row.approach.proposesBoundaries { costRow(row.label, row.costSummary) }
                if useAppleVision {
                    Text(visionUseLLMJudgment
                         ? "Vision stays free for transcription. The selected model is charged only for text-only classification, document breaks, dates and generated tags."
                         : "This reader transcribes only. Turn on the text-only cloud model under Reading to classify, find document breaks, date or tag.")
                        .font(.caption2).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Approximate; varies with model, content and network.")
                .font(.caption2).foregroundStyle(.primary)
        }
    }

    private func costRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.caption)
        }
    }
}
