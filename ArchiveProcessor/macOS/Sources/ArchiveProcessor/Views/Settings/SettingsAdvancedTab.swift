import SwiftUI
import ArchiveCore

/// Settings › Advanced (W49.proc-settings-redesign-core, §5.5): the lower-scoring and experimental choices (owner call
/// 15, all kept, off by default), the optional heavy downloads, custom endpoints and the raw fields, and the tuning
/// switches. Each group says why it is here; any of them in use is named on Settings › Processing.
struct SettingsAdvancedTab: View {
    @EnvironmentObject private var scope: SettingsScopeModel
    @AppStorage(DefaultsKeys.offerExperimentalRoutes) private var offerExperimental = false
    @AppStorage(DefaultsKeys.ocrPostCorrection) private var ocrPostCorrection = false
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.selectedThinking) private var selectedThinking: ThinkingLevel = .low
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayUpstreamProvider) private var gatewayUpstreamProvider: LLMProvider = .anthropic
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel = false
    @AppStorage(DefaultsKeys.gatewayLocalEscalates) private var gatewayLocalEscalates = false
    @AppStorage(DefaultsKeys.localAgentBinaryPath) private var localAgentBinaryPath = ""
    @AppStorage(DefaultsKeys.localAgentModel) private var localAgentModel = ""
    @AppStorage(DefaultsKeys.customOCRPrompt) private var customOCRPrompt = ""
    @AppStorage(DefaultsKeys.ocrCascadeRoute) private var ocrCascadeRoute = ""
    @AppStorage(DefaultsKeys.ocrCascadeOnDisagreement) private var ocrCascadeOnDisagreement = false
    @AppStorage(DefaultsKeys.visionFastRecognition) private var visionFastRecognition = false
    @AppStorage(DefaultsKeys.visionMinimumConfidence) private var visionMinimumConfidence: Double = 0
    @AppStorage(DefaultsKeys.visionCustomVocabulary) private var visionCustomVocabulary = ""
    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput = false
    @AppStorage(DefaultsKeys.sendPreviousImage) private var sendPreviousImage = false
    @AppStorage(DefaultsKeys.imageResolutionPercent) private var imageScale: Double = 100
    @AppStorage(DefaultsKeys.standardImageSizeMB) private var standardImageSizeMB: Double = 3.0
    @AppStorage(DefaultsKeys.ocrWorkerCount) private var ocrWorkerCount: Int = 4
    @AppStorage(DefaultsKeys.enableSegmentJSON) private var enableSegmentJSON = false
    @AppStorage(DefaultsKeys.writeLogFile) private var writeLogEnabled = false
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @State private var keyed: Set<LLMProvider> = []
    @State private var showManageModels = false
    @State private var server: LocalModelRoute.Server = .lmStudio
    @State private var pickID = ""
    @State private var checkStatus: String?
    @State private var checking = false
    @State private var confirmReset = false

    private typealias SizingBounds = SessionProcessingConfig.Bounds
    private var selectedModel: LLMModel { modelStore.model(for: selectedProvider) }
    private let memoryGB = LocalModelRoute.thisMacMemoryGB
    private var picks: [LocalModelRoute.Pick] { LocalModelRoute.picks(memoryGB: memoryGB) }
    private var pick: LocalModelRoute.Pick? { picks.first { $0.id == pickID } ?? picks.first }

    var body: some View {
        Form {
            experimentalSection
            downloadsSection
            endpointsSection
            tuningSection
            Section {
                HStack {
                    Spacer()
                    Button("Reset all Advanced settings…") { confirmReset = true }
                        .accessibilityIdentifier("ap.settings.advanced.resetAll")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            keyed = Set(LLMProvider.allCases.filter { $0 != .appleVision && KeychainHelper.exists(account: $0.rawValue) })
            SessionProcessingConfig.normalizeSizingDefaults()
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in
            keyed = Set(LLMProvider.allCases.filter { $0 != .appleVision && KeychainHelper.exists(account: $0.rawValue) })
        }
        .onChange(of: standardImageSizeMB) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
        .onChange(of: ocrWorkerCount) { _, _ in SessionProcessingConfig.normalizeSizingDefaults() }
        .sheet(isPresented: $showManageModels) { ManageModelsView() }
        .confirmationDialog("Reset all Advanced settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                for g in SettingsAdvanced.groups {
                    SettingsAdvanced.reset(g)
                    // The Output tab's PDF form shares the searchable key: only a per-format list is this tab's.
                    if SettingsAdvanced.changed(g, resolver: scope.resolver) {
                        g.layered.forEach(scope.reset)
                    }
                }
            }
        } message: {
            Text("Every setting on this tab goes back to its default, including any text typed in it; a collection's own switches are reset in the layer you are editing. The gateway's address and fields stay as they are.")
        }
    }

    private func why(_ id: String) -> some View {
        Text("Advanced: \(SettingsAdvanced.group(id)?.why ?? "").")
            .font(.caption2).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ap.settings.advanced.why.\(id)")
    }

    // MARK: 1. Lower-scoring and experimental

    @ViewBuilder private var experimentalSection: some View {
        Section("Lower-scoring and experimental choices") {
            Toggle(isOn: $offerExperimental) {
                HelpLabel("Offer lower-scoring and experimental choices", help: "Lists, in the Reader menu, the settings sheet and Re-OCR, the readers and routes that scored below what ships — such as the macOS on-device model (42.4 against Apple Vision's 83.1 on the 96 bench pages) — and the trained models checked on a small held-out set. Each says why it is lower. The app's own picks never use them.")
            }
            .accessibilityIdentifier("ap.settings.offerExperimental")
            why("experimental")
            Toggle("Correct OCR against the page image", isOn: $ocrPostCorrection)
                .accessibilityIdentifier("ap.settings.postCorrection")
            Text("One extra paid OpenRouter request per eligible page, with the image and its reading. Tied on the 96 bench pages (−0.42 points, 95% interval −1.47 to +0.64); +1.47 points on 120 public readings (+0.55 to +2.63). Compared with the starting text, it worsened 4 of 57 and 10 of 120 readings.")
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ap.settings.postCorrection.results")
            if ocrPostCorrection && !keyed.contains(.openrouter) {
                Text("Save an OpenRouter key in Settings › Accounts to use this stage.")
                    .font(.caption).foregroundStyle(.primary)
            }
            SheetDisclosure("Which pages qualify", identifier: "ap.settings.postCorrection.details") {
                Text("Uses Qwen3.6 27B via OpenRouter (Chutes) with your OpenRouter key, in standard Process Files runs with a direct API or Apple Vision. Batch jobs, gateway and CLI reads, imported text, multi-page PDF rebuilds, custom OCR prompts and pages read in regions are excluded. The collection's sharing settings can block this step.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            why("post-correction")
            LayeredToggle("Search page images for dates on this Mac (Qwen3-VL 8B)", key: .dateLocalImage)
            why("date-local-image")
            LayeredToggle("Find names on this Mac (every result marked low confidence)", key: .lowConfidenceNames)
            why("low-confidence-names")
            LayeredToggle("Find scanned newspapers' columns with DocLayout-YOLO", key: .scanNewspapersDocLayoutYOLO)
            Text("+4.6 points on 15 scanned newspapers; photographed newspapers keep PP-DocLayoutV3.")
                .font(.caption2).foregroundStyle(.primary)
            ScanNewspaperLayoutDownloadRow()
            why("scan-newspapers")
        }
    }

    // MARK: 2. Optional heavy downloads

    @ViewBuilder private var downloadsSection: some View {
        Section("Optional heavy downloads") {
            LayeredToggle(key: .placeHandOnImage) {
                HelpLabel("Place handwritten text directly on the page image", help: "Places each handwritten line's reading on the page image with hand-blla-ctc, so it can be searched and selected there. Handwritten pages already get a full text page either way.")
            }
            HandPlacerDownloadRow()
            why("place-hand")
        }
    }

    // MARK: 3. Custom endpoints and raw fields

    @ViewBuilder private var endpointsSection: some View {
        Section("Custom endpoints, local servers and the CLI") {
            Text(useGateway ? "The Reader is this gateway now." : "Choose the gateway as the Reader in Settings › Processing to read with it.")
                .font(.caption).foregroundStyle(.primary)
            Toggle(isOn: $gatewayLocalModel) {
                HelpLabel("The gateway is a model on this Mac", help: "An open-weight model served on this Mac by LM Studio, Ollama or mlx-vlm. Pages are read one at a time with no key and no charge. A reply is capped at \(LocalModelRoute.maxTokens) tokens, and one that starts repeating itself is stopped as it arrives. A looped or capped page is read once more with a repetition penalty; if that fails too, the page fails, and goes to a cloud escalation model only if you allow it.")
            }
            .accessibilityIdentifier("ap.settings.localModel")
            if gatewayLocalModel { localServerRows }
            SettingsField("Gateway URL") {
                TextField("Gateway URL", text: $gatewayBaseURL, prompt: Text("https://…/v1"))
                    .onSubmit { gatewayBaseURL = GatewayConfig.normalizedBaseURL(gatewayBaseURL) }
            }
            .help("The gateway's base address, ending at the API version, e.g. https://aiapi-prod.stanford.edu/v1. The app adds /chat/completions itself.")
            SettingsField("Model ID") {
                TextField("Model ID", text: $gatewayModelID, prompt: Text("The model name the gateway expects"))
            }
            SettingsField("Display name") {
                TextField("Display name", text: $gatewayDisplayName, prompt: Text("Shown in PDF headers"))
            }
            SettingsField("Input $/1M tokens") {
                TextField("Input $/1M tokens", value: Binding(get: { gatewayInputCost >= 0 ? gatewayInputCost : nil },
                                                               set: { gatewayInputCost = $0 ?? -1 }),
                          format: .number, prompt: Text("For the cost estimate"))
            }
            SettingsField("Output $/1M tokens") {
                TextField("Output $/1M tokens", value: Binding(get: { gatewayOutputCost >= 0 ? gatewayOutputCost : nil },
                                                                set: { gatewayOutputCost = $0 ?? -1 }),
                          format: .number, prompt: Text("For the cost estimate"))
            }
            Picker(selection: $gatewayUpstreamProvider) {
                ForEach(LLMProvider.allCases.filter { $0 != .appleVision }) { Text($0.rawValue).tag($0) }
            } label: {
                HelpLabel("Cost profile", help: "Which provider's per-image token cost the estimate assumes. Set it to the model family your gateway fronts: a Gemini-class model uses about 6.7× more image tokens than Anthropic. Estimate only; it does not change the request.")
            }
            HStack {
                Button { applyOpenAIGatewayPreset() } label: { Label("Fill in OpenAI preset", systemImage: "sparkles") }
                HelpButton(text: "Fills in OpenAI’s public API address, \(Self.openAIGatewayPresetModel.displayName), and its pricing. The model supports reasoning and uses its OpenAI default. To choose a reasoning level, read with an OpenAI key directly instead. Enter your OpenAI key under Gateway in Settings › Accounts. For a different gateway, enter the URL and model ID it provides.")
                    .accessibilityIdentifier("ap.settings.openAIPresetHelp")
            }
            SettingsField("CLI path") {
                TextField("CLI path", text: $localAgentBinaryPath, prompt: Text("Optional — auto-detected if blank"))
            }
            SettingsField("CLI model") {
                TextField("CLI model", text: $localAgentModel, prompt: Text("Optional — the CLI's default if blank"))
            }
            why("cli-fields")
            VStack(alignment: .leading, spacing: 4) {
                Text("Local segmenter server")
                LocalSegmenterControls()
            }
            why("local-segmenter")
            Button("Manage custom models…") { showManageModels = true }
            VStack(alignment: .leading, spacing: 4) {
                HelpLabel("Custom OCR prompt", help: "Extra instructions appended to the OCR prompt — e.g. “This collection is 1950s legal correspondence.”")
                TextEditor(text: $customOCRPrompt).font(.caption).frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityIdentifier("ap.settings.customPrompt")
            }
            why("custom-prompt")
        }
    }

    @ViewBuilder private var localServerRows: some View {
        if !gatewayBaseURL.isEmpty, !LocalModelRoute.isLoopback(gatewayBaseURL) {
            Text("The Gateway URL is not on this Mac. A remote gateway reads pages faster in parallel, and is not free: turn this off for it.")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(LocalModelRoute.recommendationNote(memoryGB: memoryGB))
            .font(.caption).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ap.settings.localModelRecommendation")
        Picker("Server", selection: $server) {
            ForEach(LocalModelRoute.Server.allCases) { Text($0.rawValue).tag($0) }
        }
        if !picks.isEmpty {
            Picker("Model", selection: Binding(get: { pick?.id ?? "" }, set: { pickID = $0 })) {
                ForEach(picks) { p in
                    Text(p.id == picks.first?.id ? "\(p.name), \(p.precision) (recommended)" : "\(p.name), \(p.precision)")
                        .tag(p.id)
                }
            }
        }
        HStack {
            Button { fillLocalServer() } label: { Label("Fill in \(server.rawValue) preset", systemImage: "desktopcomputer") }
                .disabled(pick == nil)
                .accessibilityIdentifier("ap.settings.localModelFill")
            Button(checking ? "Checking…" : "Check server") { Task { await checkLocalServer() } }
                .disabled(checking || gatewayBaseURL.isEmpty)
        }
        if let checkStatus {
            Text(checkStatus).font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        Toggle(isOn: $gatewayLocalEscalates) {
            HelpLabel("Send pages it fails to the escalation model", help: "A page the local model loops on, cuts off or cannot answer is read again by the escalation model below, in the cloud, at that model's price. Off, such a page fails and stays on this Mac.")
        }
        .accessibilityIdentifier("ap.settings.localModelEscalates")
    }

    // MARK: 4. Tuning and diagnostics

    @ViewBuilder private var tuningSection: some View {
        Section("Pipeline tuning and diagnostics") {
            Picker("Thinking level", selection: $selectedThinking) {
                ForEach(ThinkingLevel.allCases) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("ap.settings.thinking")
            if !selectedModel.supportsThinking {
                Text("The Reader's model has no thinking level; this applies to the models that support it.")
                    .font(.caption2).foregroundStyle(.primary)
            }
            why("thinking")
            cascadeRows
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Vision tuning")
                Toggle("Fast recognition", isOn: $visionFastRecognition)
                    .accessibilityIdentifier("ap.settings.visionFastRecognition")
                HStack {
                    Text("Minimum confidence")
                    Spacer()
                    Text("\(Int((visionMinimumConfidence * 100).rounded()))%")
                }
                Slider(value: $visionMinimumConfidence, in: 0...1, step: 0.05)
                    .accessibilityIdentifier("ap.settings.visionMinimumConfidence")
                TextEditor(text: $visionCustomVocabulary)
                    .font(.caption).frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityIdentifier("ap.settings.visionCustomVocabulary")
                Text("Custom vocabulary — one word per line or comma-separated.").font(.caption2)
            }
            why("vision-tuning")
            Toggle(isOn: $preOCRedInput) {
                HelpLabel("Pre-OCRed PDF input", help: "Process PDFs that already contain text, from a prior run or another tool: no reading calls; the embedded text is used for tagging and collection ID. Off, a dropped multi-page PDF is split into its pages, each is read again, and one PDF is rebuilt.")
            }
            .accessibilityIdentifier("ap.settings.preOCRed")
            why("pre-ocred")
            SearchableFormatControls(
                forms: SettingsSheetModel.FormsRow(entries: scope.resolve(.searchableFor).value.strings ?? [],
                                                   source: scope.resolve(.searchableFor).layer == nil
                                                       ? "Default" : scope.resolve(.searchableFor).sourceText),
                setEntries: { scope.set(.searchableFor, .strings($0)) })   // side effect: the Output PDF form's per-format editor
            why("searchable")
            Toggle(isOn: $sendPreviousImage) {
                HelpLabel("Send previous page image", help: "Gives the model the previous page's image as context for document breaks (about twice the image cost). Used only when the reader's own per-page tags find the breaks (Automatic tagging with Full manual breaks). Gemini and Anthropic only.")
            }
            why("previous-image")
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Image send size")
                    Spacer()
                    Text("\(Int(imageScale))% of standard").foregroundStyle(.primary)
                }
                Slider(value: $imageScale, in: 5...100, step: 5)
                    .accessibilityIdentifier("ap.settings.imageScale")
                HStack {
                    Text("Standard image size")
                    Spacer()
                    TextField("Standard image size", value: $standardImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                    Text("MB")
                    Stepper("Standard image size", value: $standardImageSizeMB, in: SizingBounds.imageMB, step: 0.5).labelsHidden()
                }
            }
            .disabled(preOCRedInput)
            why("image-size")
            workersRow
            why("workers")
            Toggle(isOn: $enableSegmentJSON) {
                HelpLabel("Export segment JSON", help: "Writes a .json file beside each PDF for other tools. The catalogue record keeps the dates, names and item fields either way; only this file holds the low-confidence name mentions an OCR-only run finds.")
            }
            .accessibilityIdentifier("ap.settings.segmentJSON")
            why("segment-json")
            Toggle(isOn: $writeLogEnabled) {
                HelpLabel("Write a processing log file", help: "After a run, write a plain-text log to the output folder summarizing it and listing any files that failed, with the reason.")
            }
            .accessibilityIdentifier("ap.settings.logFile")
            why("log-file")
        }
    }

    /// Where a page the run's model fails goes (`OCRCascade`, W41.app-ocr-cascade). Off by default.
    @ViewBuilder private var cascadeRows: some View {
        Picker(selection: $ocrCascadeRoute) {
            Text("Off").tag("")
            // Keyed by route ID: a model ID alone is not unique across providers.
            ForEach(OCRCascade.candidates.map { (OCRCascade.routeID(for: $0), $0) }, id: \.0) { routeID, m in
                Text("\(m.provider.rawValue) · \(m.displayName)").tag(routeID)
            }
        } label: {
            HelpLabel("Escalate failed pages to", help: "A page the Reader fails on (a refusal, a reply cut off, an unparsable reply, a server error) is read again by this stronger model. On the bench's 96 pages this beat one model alone at every budget up to $5 per 1,000 pages. Uses that provider's API key.")
        }
        .accessibilityIdentifier("ap.settings.cascadeRoute")
        if let target = OCRCascade(routeID: ocrCascadeRoute).escalationModel {
            if !useAppleVision, !useGateway, !useLocalAgent,
               OCRCascade.routeID(for: target) == OCRCascade.routeID(for: selectedModel) {
                Text("That is the Reader's own model, so nothing is escalated.").font(.caption)
            } else if !keyed.contains(target.provider) {
                Text("No \(target.provider.rawValue) key is saved: escalated pages will fail until one is.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        Toggle(isOn: $ocrCascadeOnDisagreement) {
            HelpLabel("Also escalate pages whose word count disagrees with Apple Vision's", help: "Experimental. Apple Vision also reads each page on this Mac, and a page whose word count differs by more than half again is sent on too. On the bench its gain over escalating failures alone was not consistent; it escalates about one page in ten. Needs an escalation model above.")
        }
        .disabled(OCRCascade(routeID: ocrCascadeRoute).escalationModel == nil && !ocrCascadeOnDisagreement)
        .accessibilityIdentifier("ap.settings.cascadeDisagreement")
        why("cascade")
    }

    /// Apple Vision sizes its workers from the Mac's performance cores and the Local Agent never runs more than two CLI
    /// calls at once, so neither reads the stepper; show what the run will use.
    @ViewBuilder private var workersRow: some View {
        if useAppleVision {
            LabeledContent("Parallel OCR workers", value: "\(VisionClient.recommendedConcurrency), one per performance core")
                .accessibilityIdentifier("ap.settings.ocrWorkersFixed")
        } else if useLocalAgent {
            LabeledContent("Parallel OCR workers", value: "At most 2, set by the CLI cap")
                .accessibilityIdentifier("ap.settings.ocrWorkersFixed")
        } else {
            HStack {
                HelpLabel("Parallel OCR workers: \(ocrWorkerCount)", help: "More workers read faster (roughly halving the time from 4 to 8) but raise the chance of rate-limit errors, which are retried with backoff. 4 is safe; 6–8 is usually fine.")
                Spacer()
                Stepper("Parallel OCR workers", value: $ocrWorkerCount, in: SizingBounds.ocrWorkers).labelsHidden()
                    .accessibilityIdentifier("ap.settings.ocrWorkers")
            }
        }
    }

    private func fillLocalServer() {
        guard let pick else { return }
        gatewayBaseURL = server.baseURL
        gatewayModelID = pick.modelID(for: server)
        gatewayDisplayName = pick.displayName
        gatewayInputCost = 0
        gatewayOutputCost = 0
        checkStatus = nil
    }

    private func checkLocalServer() async {
        checking = true
        defer { checking = false }
        do {
            let models = try await LocalModelRoute.listModels(baseURL: gatewayBaseURL)
            checkStatus = LocalModelRoute.checkSummary(models: models, modelID: gatewayModelID)
        } catch {
            checkStatus = "Nothing answered at \(gatewayBaseURL): start the server, or check its address. (\(error.localizedDescription))"
        }
    }

    /// Start with the same default OpenAI model and prices as a direct OpenAI key.
    private func applyOpenAIGatewayPreset() {
        let model = Self.openAIGatewayPresetModel
        gatewayLocalModel = false
        gatewayBaseURL = OpenAICompatibleClient.openAIBaseURL
        gatewayDisplayName = "OpenAI"
        gatewayUpstreamProvider = .openai
        gatewayModelID = model.id
        gatewayInputCost = model.inputCostPer1M
        gatewayOutputCost = model.outputCostPer1M
    }

    static var openAIGatewayPresetModel: LLMModel { LLMModel.openaiModels[0] }
}

/// The `local` approach's server and model (W41.app-local-seg), with a check that the server answers. Settings ›
/// Advanced: raw fields, whose defaults are the measured ones.
struct LocalSegmenterControls: View {
    @AppStorage(DefaultsKeys.localSegmenterBaseURL) private var baseURL = LocalSegmenter.defaultBaseURL
    @AppStorage(DefaultsKeys.localSegmenterModelID) private var modelID = LocalSegmenter.defaultModelID
    @State private var checkResult: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Server", text: $baseURL, prompt: Text(LocalSegmenter.defaultBaseURL))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .accessibilityIdentifier("ap.segmentation.local.server")
            TextField("Model", text: $modelID, prompt: Text(LocalSegmenter.defaultModelID))
                .textFieldStyle(.roundedBorder).controlSize(.small)
                .accessibilityIdentifier("ap.segmentation.local.model")
            HStack {
                Button(checking ? "Checking…" : "Check server") { check() }
                    .controlSize(.small).disabled(checking)
                    .accessibilityIdentifier("ap.segmentation.local.check")
                if let checkResult {
                    Text(checkResult).font(.caption2).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(LocalSegmenter.startHint).font(.caption2).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check() {
        checking = true
        // What a run would use: the same trimming and defaults.
        let url = LocalSegmenter.baseURL(), model = LocalSegmenter.modelID()
        Task {
            let text: String
            do {
                let models = try await LocalModelRoute.listModels(baseURL: url)
                // mlx-vlm downloads a model it does not list yet on its first request, so an unlisted one is no fault
                // yet; the run loads it before the first window and stops with the server's reason if it cannot.
                text = models.contains(model) ? "The server answers and has \(model). Ready."
                    : "The server answers but does not list \(model). A run first tries to load it (downloading about "
                        + "2.5 GB if needed) and stops with the reason if it cannot."
            } catch {
                text = "No server answers at \(url): \(error.localizedDescription)"
            }
            await MainActor.run { checkResult = text; checking = false }
        }
    }
}
