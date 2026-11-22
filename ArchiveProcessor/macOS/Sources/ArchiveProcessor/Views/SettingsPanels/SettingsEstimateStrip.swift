import SwiftUI
import ArchiveCore

/// The estimate for 1,000 files, as a strip in Settings › Collection (W47.settings-panels; it was the fixed pane beside
/// the one long form).
struct SettingsEstimateStrip: View {
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
    @ObservedObject private var claudeUsage = ClaudeCLIUsage.shared

    private var claudeBinary: String? {
        ClaudeCLIBilling.binaryPath(tool: localAgentTool, override: localAgentBinaryPath)
    }
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision: Bool = false
    @AppStorage(DefaultsKeys.visionUseLLMJudgment) private var visionUseLLMJudgment: Bool = false
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput: Bool = false
    @AppStorage(DefaultsKeys.batchMode) private var batchMode: Bool = false
    @AppStorage(DefaultsKeys.imageResolutionPercent) private var imageScale: Double = 100
    @AppStorage(DefaultsKeys.standardImageSizeMB) private var standardImageSizeMB: Double = 3.0
    @AppStorage(DefaultsKeys.ocrWorkerCount) private var ocrWorkerCount: Int = 4
    @AppStorage(DefaultsKeys.rotationModeRaw) private var rotationModeRaw: String = RotationMode.standard.rawValue
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation: Bool = false
    @AppStorage(DefaultsKeys.sendPreviousImage) private var sendPreviousImage: Bool = false
    @AppStorage(DefaultsKeys.enableSegmentJSON) private var enableSegmentJSON: Bool = true
    @AppStorage(DefaultsKeys.contextCharCount) private var contextCharCount: Double = 0   // context slider removed; kept 0 (parallel OCR)
    @AppStorage(DefaultsKeys.outputDirectory) private var outputPath: String = ""
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @ObservedObject private var settingsStore = SettingsLayerStore.shared
    @State private var openRouterPricesRead = 0
    @AppStorage(OpenRouterListing.defaultsKey) private var openRouterListingData: Data?

    private var models: [LLMModel] {
        selectedProvider.models   // already includes this provider's custom models — don't concat (dupes)
    }

    /// The model for the current provider, read live from the shared store (see `ModelSelectionStore`)
    /// rather than mirrored into `@State`, so this pane and the Process Files window can never disagree
    /// about which model a run would use. The store's fallback also means the value is always a member
    /// of `models` — a provider switch or a deleted custom model can't leave the Picker blank or a
    /// ghost id in play, which is what `ensureValidModelSelection()` used to patch up by hand.
    private var selectedModel: LLMModel {
        get { modelStore.model(for: selectedProvider) }
        nonmutating set { modelStore.setModel(newValue, for: selectedProvider) }
    }

    private var unavailableOpenRouterSelection: String? {
        _ = openRouterListingData
        guard useAppleVision ? visionUseLLMJudgment : !useGateway && !useLocalAgent else { return nil }
        return modelStore.unavailableOpenRouterSelection(for: selectedProvider)
    }

    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }

    @AppStorage(DefaultsKeys.segmentationApproach) private var segmentationApproachRaw: String =
        SegmentationApproach.defaultApproach.rawValue

    /// Who segments with the current settings (W36.seg-opt-review).
    private var segmentationPlan: SegmentationPlan {
        SegmentationPlan.resolve(tagging: taggingMode,
                                 approach: SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach)
    }

    /// Which keys / `claude` the segmentation approaches can use; read in `reloadKeys`, never while rendering.
    @State private var segmentationRoutes = SegmentationRoutes.none

    /// The chosen approach's row at the cost pane's scale (1,000 files, read as 1,000 pages).
    private var segmentationRow: SegmentationRow? {
        guard let options = SegmentationOptionsStore.shared else { return nil }
        let approach = SegmentationApproach(rawValue: segmentationApproachRaw) ?? .defaultApproach
        return SegmentationRow.make(approach, options: options, pageCount: 1000,
                                    routes: segmentationRoutes.withClaudeBilling(claudeUsage.billing(for: claudeBinary)))
    }

    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .standard }

    /// The standard image size a run would actually use. Identical to `standardImageSizeMB` once the
    /// writers are normalized — it exists so the two places that *quote a size to the operator* can never
    /// go back to advertising a number the pipeline will not honour.
    private var effectiveStandardImageMB: Double {
        SessionProcessingConfig.normalizedImageMB(standardImageSizeMB, fallback: 3.0)
    }

    /// The run's rotation calls go to the remote gateway's model (W46.rotation-default), as `detectRotation` decides.
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

    private var outputFolder: URL? {
        _ = outputPath
        #if DEBUG
        if let folder = ProcessorUITestConfiguration.outputDirectory { return folder }
        #endif
        return ModelSelectionStore.savedOutputDirectory()
    }

    var body: some View {
        costPane
            .onAppear { segmentationRoutes = SegmentationRoutes.currentPreselecting() }
            .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
                segmentationRoutes = SegmentationRoutes.currentPreselecting()
            }
            .task(id: selectedProvider) {
                guard selectedProvider == .openrouter else { return }
                await OpenRouterListing.refreshAllIfStale()
                openRouterPricesRead += 1
            }
    }

    @ViewBuilder private var costPane: some View {
        let tagging = taggingMode.llmTags   // LLM tag/date calls (excludes Human / Copy-source / None)
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimate — 1,000 files").font(.headline)
            Text("~\(String(format: "%.2g", effectiveStandardImageMB)) MB each")
                .font(.caption2).foregroundStyle(.primary)

            if let warning = unavailableOpenRouterSelection {
                Text(warning)
                    .font(.caption).foregroundStyle(.primary)
            } else if useAppleVision {
                segmentationCostBlock
                appleVisionCostPane
            } else if useLocalAgent {
                segmentationCostBlock
                localAgentCostPane
            } else if !useGateway, selectedProvider == .openrouter, openRouterPricesRead >= 0,
                      OpenRouterRoute.isUnpriced(selectedModel) {
                Text(OpenRouterRoute.unpricedEstimateMessage)
                    .font(.caption).foregroundStyle(.primary)
            } else if let model = useGateway ? gatewayModel : selectedModel {
                let gateway = GatewayConfig.fromDefaults()
                let settings = settingsStore.resolver(at: outputFolder)
                let namesCallShare = EntityRunPolicy.estimatedCallShare(
                    taggingMode: taggingMode, gateway: gateway, usesLocalAgent: false, usesVision: false,
                    setting: { settings.resolve($0).value })
                let est = CostEstimator.estimate(
                    fileCount: 1000, model: model, enableTagging: tagging,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    preOCRedInput: preOCRedInput, sendPreviousImage: sendPreviousImage && segmentationPlan.usesPerPageClassifier,
                    contextCharCount: Int(contextCharCount), imageScale: imageScale / 100.0,
                    rotationMode: rotationMode, useGateway: useGateway,
                    imageTokenProvider: useGateway ? gatewayUpstreamProvider : nil, gatewayRotation: gatewayRotation,
                    measuredRoute: DateRoute.measuredRoute(gateway: gateway, usesLocalAgent: false),
                    dateImageEveryDocument: DateRoute.imageEveryDocument(settingsStore.resolver(for: nil)),
                    sidecars: enableSegmentJSON, namesCallShare: namesCallShare)
                let time = TimeEstimator.estimate(
                    fileCount: 1000, model: model, rotationMode: rotationMode,
                    sequentialOCR: contextCharCount > 0, enableTagging: tagging,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    preOCRedInput: preOCRedInput, useGateway: useGateway, ocrWorkers: ocrWorkerCount,
                    gatewayRotation: gatewayRotation)

                Divider().padding(.vertical, 2)
                Text("COST").font(.caption2).fontWeight(.bold).foregroundStyle(.primary)
                // Segmentation's window calls are in addition to OCR and are never batched (the engine sends
                // each window interactively), so they add the same dollars to both totals.
                let seg = segmentationRow?.apiDollars ?? 0
                costRow("Total", CostEstimate.money(est.totalStandard + seg), bold: true)
                if batchMode && !useGateway && !preOCRedInput {
                    costRow("Batch", CostEstimate.money(est.totalBatch + seg))
                }
                if !preOCRedInput { costRow("· OCR", est.ocrFormatted) }
                if est.rotationCost > 0 { costRow("· Rotation", est.rotationFormatted) }
                if tagging { costRow("· Tagging", est.taggingFormatted) }
                if est.datingCost > 0 { costRow("· Dating", est.datingFormatted) }
                if est.itemFieldCost > 0 { costRow("· Item fields", est.itemFieldFormatted) }
                if est.namesCost > 0 { costRow("· Names", est.namesFormatted) }
                if enableCollectionSegmentation { costRow("· Collection", est.collectionFormatted) }
                if let row = segmentationRow { costRow("· Segmentation", row.costSummary) }

                Divider().padding(.vertical, 2)
                Text("TIME (processing only)").font(.caption2).fontWeight(.bold).foregroundStyle(.primary)
                costRow("Total", time.totalFormatted, bold: true)
                if time.ocrSeconds > 0 { costRow("· OCR", time.ocrFormatted) }
                if time.rotationSeconds > 0 { costRow("· Rotation*", time.rotationFormatted) }
                if tagging { costRow("· Tagging", time.taggingFormatted) }
                if enableCollectionSegmentation { costRow("· Collection", time.collectionFormatted) }
                if time.rotationSeconds > 0 {
                    Text("*runs during OCR").font(.caption2).foregroundStyle(.primary)
                }
                if batchMode && !useGateway && !preOCRedInput {
                    Text("Batch mode returns asynchronously (minutes–hours); the time above is the equivalent interactive run.")
                        .font(.caption2).foregroundStyle(.orange)
                }

                Text("Approximate; varies with model, content & network.")
                    .font(.caption2).foregroundStyle(.primary)
            } else {
                Text("Enter gateway model pricing to estimate cost.").font(.caption).foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Expose the fixed pane as one read-only AX summary. Some macOS releases flatten the nested
        // caption rows inside a Form, but this stable parent still represents the text the operator sees.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.settings.costPane")
    }

    /// Billing detected for the selected CLI and the number of pages it reads at once.
    @ViewBuilder private var localAgentCostPane: some View {
        Divider().padding(.vertical, 2)
        Text("COST").font(.caption2).fontWeight(.bold).foregroundStyle(.primary)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "terminal").foregroundStyle(.secondary)
            Text(claudeUsage.costHeadline(binary: claudeBinary, tool: localAgentTool))
                .font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.settings.localAgentCost")
        Text(claudeUsage.costDetail(binary: claudeBinary, tool: localAgentTool))
            .font(.caption2).foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ap.settings.localAgentPacing")

        Divider().padding(.vertical, 2)
        Text("PACING").font(.caption2).fontWeight(.bold).foregroundStyle(.primary)
        Text("Runs one CLI agent turn per page, at most two pages at a time.")
            .font(.caption2).foregroundStyle(.primary)

    }

    /// Cost/pacing summary for the in-process Vision backend. Unlike the CLI path it neither consumes a
    /// subscription nor reaches a network service: it uses the Mac's performance cores directly.
    @ViewBuilder private var appleVisionCostPane: some View {
        Divider().padding(.vertical, 2)
        Text("COST").font(.caption2).fontWeight(.bold).foregroundStyle(.primary)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "cpu").foregroundStyle(.secondary)
            Text("Free — runs on this Mac.").font(.caption)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ap.settings.appleVisionCost")
        Text(visionUseLLMJudgment
             ? "Apple Vision transcribes locally. Only the resulting text is sent to the selected direct LLM for judgement; no image or Vision setting leaves this Mac."
             : "Apple Vision transcribes locally using the Mac's performance cores. It sends no image, text, or API key off this Mac.")
            .font(.caption2).foregroundStyle(.primary)
        if visionUseLLMJudgment && OpenRouterRoute.isUnpriced(selectedModel) {
            Text(OpenRouterRoute.unpricedEstimateMessage).font(.caption)
        }
        Divider().padding(.vertical, 2)
        Text("SCOPE").font(.caption2).fontWeight(.bold).foregroundStyle(.primary)
        Text(visionUseLLMJudgment
             ? "Vision stays free for transcription. The selected LLM is charged only for text-only classification, segmentation, dates, and generated tags."
             : "This backend transcribes only. Turn on Vision + LLM judgement in Settings › Reading to classify, segment, date, or generate tags.")
            .font(.caption2).foregroundStyle(.primary)
    }

    /// The segmentation approach's own cost, for the backends whose pane has no dollar total to add it to.
    @ViewBuilder private var segmentationCostBlock: some View {
        if let row = segmentationRow, row.approach.proposesBoundaries {
            Divider().padding(.vertical, 2)
            Text("SEGMENTATION").font(.caption2).fontWeight(.bold).foregroundStyle(.primary)
            costRow(row.label, row.costSummary)
        }
    }

    private func costRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.caption).fontWeight(bold ? .semibold : .regular)
        }
    }
}
