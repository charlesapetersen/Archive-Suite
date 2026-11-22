import SwiftUI
import ArchiveCore

/// Settings › Reading (W47.settings-panels): the reading card, the backend, provider and model, kind routing, the
/// cascade, Apple Vision's options, and the layout and image-input rules with the newspaper download.
struct SettingsReadingPanel: View {
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.selectedThinking) private var selectedThinking: ThinkingLevel = .low
    @AppStorage(DefaultsKeys.useGateway) private var useGateway: Bool = false
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL: String = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID: String = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName: String = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayUpstreamProvider) private var gatewayUpstreamProvider: LLMProvider = .anthropic
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel: Bool = false
    @AppStorage(DefaultsKeys.gatewayLocalEscalates) private var gatewayLocalEscalates: Bool = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent: Bool = false
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision: Bool = false
    @AppStorage(DefaultsKeys.visionUseLLMJudgment) private var visionUseLLMJudgment: Bool = false
    @AppStorage(DefaultsKeys.visionLanguages) private var visionLanguages: String = "en-US"
    @AppStorage(DefaultsKeys.visionFastRecognition) private var visionFastRecognition: Bool = false
    @AppStorage(DefaultsKeys.visionMinimumConfidence) private var visionMinimumConfidence: Double = 0
    @AppStorage(DefaultsKeys.visionCustomVocabulary) private var visionCustomVocabulary: String = ""
    @AppStorage(DefaultsKeys.ocrPostCorrection) private var ocrPostCorrection = false
    @AppStorage(DefaultsKeys.ocrCascadeRoute) private var ocrCascadeRoute: String = ""
    @AppStorage(DefaultsKeys.ocrCascadeOnDisagreement) private var ocrCascadeOnDisagreement: Bool = false
    @AppStorage(DefaultsKeys.ocrPageKindRouting) private var ocrPageKindRouting: Bool = false
    @AppStorage(DefaultsKeys.ocrHandwritingOnTyped) private var ocrHandwritingOnTyped: Bool = true
    @AppStorage(DefaultsKeys.batchMode) private var batchMode: Bool = false
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation: Bool = false
    @ObservedObject private var customModelStore = CustomModelStore.shared
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var mistralKey = ""
    @State private var openaiKey = ""
    @State private var openrouterKey = ""
    @State private var openRouterPricesRead = 0
    @State private var showManageModels = false

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

    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }

    var body: some View {
        Form {
            Section {
                SettingsStageCards(cards: ["reading"])
            } header: { Text("The app's pick") }
            SettingsLevelSection(Self.providerRows) { providerSection }
            SettingsLevelSection([.postCorrection]) {
                Section("After reading") {
                    SettingsLevelRows(.postCorrection) {
                        Toggle("Correct OCR against the page image", isOn: $ocrPostCorrection)
                            .accessibilityIdentifier("ap.settings.postCorrection")
                        Text("Adds one paid request per eligible page. Sends the page image and its reading to Qwen3.6 27B via OpenRouter (Chutes), using your OpenRouter key. Available for standard Process Files runs with a direct API or Apple Vision. Batch jobs, gateway and CLI reads, imported text, multi-page PDF rebuilds, custom OCR prompts, and pages read in regions are excluded. The output collection’s sharing settings can block this step.")
                        Text("In tests on middle-accuracy readings, correction tied re-reading with the same model on the 96-page set (−0.42 accuracy points, 95% interval −1.47 to +0.64). It gained 1.47 points on 120 public readings (95% interval +0.55 to +2.63). Compared with the starting text, correction worsened 4 of 57 and 10 of 120 readings. The tests used the Sherlock FP8 model.")
                            .accessibilityIdentifier("ap.settings.postCorrection.results")
                        if ocrPostCorrection && openrouterKey.isEmpty {
                            Text("Save an OpenRouter key in Settings › Accounts to use this stage.")
                        }
                    }
                    .font(.callout)
                }
            }
            Section {
                SettingsStageCards(rules: ["ocr-input", "layout"])
            } header: { Text("The image read and the reading order") }
        }
        .formStyle(.grouped)
        .onAppear { reloadKeys() }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in reloadKeys() }
        .sheet(isPresented: $showManageModels) { ManageModelsView() }
    }

    /// The key fields' values, for the cascade's "no key" warning (the fields themselves are in Accounts).
    private func reloadKeys() {
        anthropicKey = KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? ""
        geminiKey = KeychainHelper.load(account: LLMProvider.gemini.rawValue) ?? ""
        mistralKey = KeychainHelper.load(account: LLMProvider.mistral.rawValue) ?? ""
        openaiKey = KeychainHelper.load(account: LLMProvider.openai.rawValue) ?? ""
        openrouterKey = KeychainHelper.load(account: LLMProvider.openrouter.rawValue) ?? ""
    }

    /// The four mutually-exclusive OCR backends, surfaced as ONE picker over their persisted flags.
    /// Centralizing the XOR in this Binding means no downstream code path can observe conflicting modes.
    private enum OCRBackendMode: Hashable { case direct, gateway, localAgent, appleVision }
    private var backendMode: Binding<OCRBackendMode> {
        Binding(
            get: {
                if useAppleVision { return .appleVision }
                return useLocalAgent ? .localAgent : (useGateway ? .gateway : .direct)
            },
            set: { mode in
                useGateway = (mode == .gateway)
                useLocalAgent = (mode == .localAgent)
                // Picked here, the Mac's reader is Vision; the on-device model is chosen on the reading card only.
                if mode == .appleVision, !useAppleVision {
                    modelStore.setModel(LLMModel.appleVisionModels[0], for: .appleVision)
                }
                useAppleVision = (mode == .appleVision)
                if mode == .appleVision {
                    batchMode = false   // side effect: Apple Vision has nothing to batch (the switch is in Pages and output)
                }
            }
        )
    }

    /// The rows of Provider & Model, by level (W47.settings-level-switch): at Basic the reading card's pick is all.
    private static let providerRows: [SettingsLevels.Row] = [
        .backend, .providerModel, .thinking, .cascade, .cascadeDisagreement, .pageKind, .handwritingOnTyped,
        .visionLanguages, .visionTuning, .visionJudgement, .gatewayLocal, .gatewayFields, .customModels,
    ]

    @ViewBuilder private var providerSection: some View {
        Section("Provider & Model") {
            Picker(selection: backendMode) {
                Text("Direct API").tag(OCRBackendMode.direct)
                Text("API Gateway").tag(OCRBackendMode.gateway)
                Text("Local CLI Agent").tag(OCRBackendMode.localAgent)
                Text(modelStore.model(for: .appleVision).id == OnDeviceModelClient.modelID
                     ? "macOS on-device model (on this Mac)" : "Apple Vision (on this Mac)").tag(OCRBackendMode.appleVision)
            } label: {
                HStack {
                    Text("OCR backend")
                    HelpButton(text: "Direct API calls the provider directly. API Gateway routes OCR through a custom OpenAI-compatible endpoint. Local CLI Agent runs OCR through a signed-in CLI using your subscription. Apple Vision transcribes locally with macOS Vision: no API key, network request, or per-page charge. Exactly one backend is active at a time.")
                }
            }
            .accessibilityIdentifier("ap.settings.backendPicker")
            .settingsLevel(.backend)

            if useGateway {
                Text("The gateway's key is in Settings › Accounts.").font(.caption).foregroundStyle(.primary)
                SettingsLevelRows(.gatewayLocal) {
                    LocalModelSettingsView()   // W41.app-local-models
                    HStack {
                        Button {
                            applyOpenAIGatewayPreset()
                        } label: {
                            Label("Fill in OpenAI preset", systemImage: "sparkles")
                        }
                        HelpButton(text: "One-click fill for OpenAI's public API: sets the Gateway URL to https://api.openai.com/v1, a cost-effective OpenAI model, a display name, and its pricing. Paste your OpenAI key into the Gateway key field in Settings › Accounts. The gateway sends standard chat-completions requests, so this fills a non-reasoning model; for GPT-5 reasoning models pick OpenAI under the Direct API mode instead. For Azure OpenAI or another OpenAI-compatible proxy, apply this then edit the Gateway URL to your endpoint.")
                    }
                    if gatewayLocalModel {   // a local model's looped page needs a fallback, if the user allows the cloud
                        Toggle(isOn: $gatewayLocalEscalates) {
                            HStack {
                                Text("Send pages it fails to the escalation model")
                                HelpButton(text: "A page the local model loops on, cuts off or cannot answer is read again by the model you pick below, in the cloud, at that model's price. Off, such a page fails and stays on this Mac.")
                            }
                        }
                        .accessibilityIdentifier("ap.settings.localModelEscalates")
                        if gatewayLocalEscalates { cascadeControls }
                    }
                }
                SettingsLevelRows(.gatewayFields) { gatewayFields }
            } else if useLocalAgent {
                Text("The command-line agent, its model and its check are in Settings › Accounts.")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityIdentifier("ap.settings.localAgentHome")
            } else if useAppleVision {
                appleVisionControls
            } else {
                SettingsLevelRows(.providerModel) {
                    // Plain `$selectedProvider`: the model follows automatically, because `selectedModel`
                    // reads the store keyed by whatever the provider currently is.
                    Picker(selection: $selectedProvider) {
                        ForEach(LLMProvider.allCases.filter { $0 != .appleVision }) { Text($0.rawValue).tag($0) }
                    } label: {
                        HStack {
                            Text("Provider")
                            HelpButton(text: "Which LLM service performs OCR and tagging. Each has its own models, pricing, and API key.")
                        }
                    }
                    .accessibilityIdentifier("ap.settings.providerPicker")
                    Picker(selection: Binding(get: { selectedModel }, set: { selectedModel = $0 })) {
                        ForEach(models) { m in
                            Text(customModelStore.isCustom(m) ? "\(m.displayName) (custom)" : m.displayName).tag(m)
                        }
                    } label: {
                        HStack {
                            Text("Model")
                            HelpButton(text: "The model used for OCR and tagging. Fast, cheap models (e.g. Flash Lite) handle most archival documents well; larger models may read difficult handwriting or dense layouts better, at higher cost and time.")
                        }
                    }
                    if selectedProvider == .openrouter {
                        // `openRouterPricesRead` re-renders the note and the model list once OpenRouter's endpoint prices
                        // (W42.int-s2) and its model listing (W41.app-openrouter-unmeasured) have been read.
                        Text(openRouterPricesRead >= 0
                             ? (OpenRouterRoute.forModel(selectedModel.id)?.settingsNote ?? OpenRouterRoute.unmeasuredNote(selectedModel))
                             : "")
                            .font(.caption).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("ap.settings.openRouterRoute")
                            .task {
                                await OpenRouterListing.refreshAllIfStale()
                                openRouterPricesRead += 1
                            }
                    }
                }
                // What reads which pages best is the reading card at the top of this panel (W47.settings-panels), in
                // place of the guide that sat here (W41.app-ocr-hierarchy); its "Read with this" sets the model above.
                if selectedModel.supportsThinking {
                    Picker(selection: $selectedThinking) {
                        ForEach(ThinkingLevel.allCases) { Text($0.rawValue).tag($0) }
                    } label: {
                        HStack {
                            Text("Thinking")
                            HelpButton(text: "Extended reasoning for models that support it. High can improve hard pages but costs more and is slower. Tagging always runs without thinking.")
                        }
                    }
                    .settingsLevel(.thinking)
                }
                cascadeControls
                pageKindControls
                Button("Manage custom models…") { showManageModels = true }
                    .settingsLevel(.customModels, changed: !customModelStore.allCustomModels.isEmpty)
            }
        }
    }

    /// The gateway's raw fields: its address, model, name, prices and cost profile (Advanced; the presets fill them).
    @ViewBuilder private var gatewayFields: some View {
        HStack {
            SettingsField("Gateway URL") {
                TextField("Gateway URL", text: $gatewayBaseURL, prompt: Text("https://…/v1"))
                    .onSubmit { gatewayBaseURL = GatewayConfig.normalizedBaseURL(gatewayBaseURL) }
            }
            HelpButton(text: "The gateway's base address, ending at the API version, e.g. https://aiapi-prod.stanford.edu/v1 or https://api.openai.com/v1. The app adds /chat/completions itself; a pasted full endpoint has that ending dropped.")
        }
        SettingsField("Model ID") {
            TextField("Model ID", text: $gatewayModelID, prompt: Text("The model name the gateway expects"))
        }
        SettingsField("Display name") {
            TextField("Display name", text: $gatewayDisplayName, prompt: Text("Shown in PDF headers"))
        }
        SettingsField("Input $/1M tokens") {
            TextField("Input $/1M tokens", value: Binding(get: { gatewayInputCost >= 0 ? gatewayInputCost : nil }, set: { gatewayInputCost = $0 ?? -1 }), format: .number, prompt: Text("For the cost estimate"))
        }
        SettingsField("Output $/1M tokens") {
            TextField("Output $/1M tokens", value: Binding(get: { gatewayOutputCost >= 0 ? gatewayOutputCost : nil }, set: { gatewayOutputCost = $0 ?? -1 }), format: .number, prompt: Text("For the cost estimate"))
        }
        Picker(selection: $gatewayUpstreamProvider) {
            ForEach(LLMProvider.allCases.filter { $0 != .appleVision }) { Text($0.rawValue).tag($0) }
        } label: {
            HStack {
                Text("Cost profile")
                HelpButton(text: "Which provider's per-image token cost to assume for the cost/time estimate. Set this to the model family your gateway actually fronts — a Gemini-class model uses ~6.7× more image tokens than Anthropic, so the wrong profile makes the estimate far off. Estimate only; does not affect the actual request.")
            }
        }
    }

    /// W41.app-ocr-cascade — where a page the run's model fails goes (`OCRCascade`). Off by default.
    @ViewBuilder private var cascadeControls: some View {
        SettingsLevelRows(.cascade) {
            Picker(selection: $ocrCascadeRoute) {
                Text("Off").tag("")
                // Keyed by route ID: a model ID alone is not unique across providers.
                ForEach(OCRCascade.candidates.map { (OCRCascade.routeID(for: $0), $0) }, id: \.0) { routeID, m in
                    Text("\(m.provider.rawValue) · \(m.displayName)").tag(routeID)
                }
            } label: {
                HStack {
                    Text("Escalate failed pages to")
                    HelpButton(text: "Read every page with the model above, and send a page it fails on (a refusal, a reply cut off at the token limit, an unparsable reply, a server error) to this stronger model. On the bench's 96 pages this beat one model alone at every budget up to $5 per 1,000 pages, and few pages fail, so the stronger model reads few. Where accuracy matters more than price, one strong model alone is still best. Each page records which model's text was kept. Uses that provider's API key.")
                }
            }
            .accessibilityIdentifier("ap.settings.cascadeRoute")
            if let target = OCRCascade(routeID: ocrCascadeRoute).escalationModel {
                if OCRCascade.routeID(for: target) == OCRCascade.routeID(for: selectedModel) {
                    Text("That is the model above, so nothing is escalated.")
                        .font(.caption).foregroundStyle(.primary)
                } else if storedKey(for: target.provider).isEmpty {
                    Text("No \(target.provider.rawValue) key is saved: escalated pages will fail until one is.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        if OCRCascade(routeID: ocrCascadeRoute).escalationModel != nil {
            Toggle(isOn: $ocrCascadeOnDisagreement) {
                HStack {
                    Text("Also escalate pages whose word count disagrees with Apple Vision's")
                    HelpButton(text: "Experimental. Apple Vision also reads each page on this Mac (free, about a second), and a page whose word count differs from it by more than half again is sent on too. It finds many poor readings, but on the bench's pages its gain over escalating failures alone was not consistent, and it escalates about one page in ten.")
                }
            }
            .accessibilityIdentifier("ap.settings.cascadeDisagreement")
            .settingsLevel(.cascadeDisagreement)
        }
    }

    /// W41.app-page-kind — tell each page's kind on this Mac and preselect its reader from the bench's guidance (`OCRPageGuidance`). Off by default.
    @ViewBuilder private var pageKindControls: some View {
        Toggle(isOn: $ocrPageKindRouting) {
            HStack {
                Text("Choose each page's reader by its kind")
                HelpButton(text: "Before a run, this Mac tells each dropped photo's kind (handwritten, typewritten, printed, or a form or table) with Apple Vision, free, and the file list preselects the best measured model for that kind that you have a key for (the settings sheet’s reading card shows the figures). A page whose kind it is not sure of, or whose pick you have no key for, keeps the model above. You can change the reader for one page, or for the whole batch, in the file list, and the cost estimate follows. On the owner's bench pages it told the kind right on 137 of 141 (about 0.6 s a page), and routing by its calls read 1 NES point below choosing by the true kinds. Each page records its kind and the model that read it. Not for batch runs, the gateway, the Local Agent or Apple Vision, and PDFs keep the model above. Needs macOS 26.")
            }
        }
        .accessibilityIdentifier("ap.settings.pageKindRouting")
        .settingsLevel(.pageKind)
        // W46.mixed-route-setting: one switch on every typed or printed page; on by default, with or without the
        // pre-flag (W47.wh-mixed-preflag-default, owner call 24, replacing call 3's off).
        Toggle(isOn: $ocrHandwritingOnTyped) {
            HStack {
                Text("Read handwriting on typed pages (signatures, dates, notes in the margin)")
                HelpButton(text: "Sends every typewritten or printed page to the reader picked for handwriting, so a signature, a handwritten date or a note in the margin is read with the typed text. Without the mixed-page pre-flag it acts on every typed or printed page. With the pre-flag downloaded (below), only the pages it flags as carrying handwriting are sent: on the bench's 2,000 pages, judged against the owner's answers (any handwriting, a signature included), it found about 51–60% of the typed and printed pages with handwriting, and 70% of the pages it flagged had some; over the pages nobody checked the exact bounds are 18–95% of flagged pages and 7–97% of pages with handwriting. The page-kind check alone finds 12–14%. A page it does not flag keeps its kind's reader, so its handwriting may go unread. Measured level on typed pages, not measured on mixed pages: on the bench's 78 typed and printed pages the handwriting readers read the typed text no worse than Apple Vision on average (for the Mac reader a tie, 14 of 78 pages more than 2 points lower); on the 2 mixed pages scored, worse. Cost: hosted, about $0.002–0.004 a page; the estimate shows what it adds to your batch. Time: on an M3 Pro Mac with 18 GB the Mac handwriting reader took about 25 seconds a typed page where Apple Vision took 0.2, about 140 times as long; a hosted handwriting reader about 9 to 22 seconds a page, waiting on the service rather than this Mac. Acts only with “Choose each page's reader by its kind” on, since it uses the kind this Mac tells. Your own choice for a page or a batch in the file list wins. On by default; turn it off to keep typed and printed pages on their kind's reader.")
            }
        }
        .disabled(!ocrPageKindRouting)
        .padding(.leading, 18)
        .accessibilityIdentifier("ap.settings.handwritingOnTyped")
        .settingsLevel(.handwritingOnTyped)
        // W47.wh-mixed-preflag: ATRIUM as the switch's pre-flag, an optional download with its licence (calls 12, 15).
        MixedPagePreflagDownloadRow()
            .padding(.leading, 36)
            .settingsLevel(.downloads)
    }

    /// The key field's current value for a provider (loaded from the Keychain once, with the fields above).
    private func storedKey(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return anthropicKey
        case .gemini: return geminiKey
        case .mistral: return mistralKey
        case .openai: return openaiKey
        case .openrouter: return openrouterKey
        case .appleVision: return ""
        }
    }

    /// Local Vision controls. The language, speed, confidence, and vocabulary knobs are intentionally
    /// exposed here rather than hidden as constants: they materially affect what on-device OCR returns.
    @ViewBuilder private var appleVisionControls: some View {
        Text("Free on-device transcription with macOS Vision. It does not use an API key or send images over the network.")
            .font(.caption).foregroundStyle(.primary)
        SettingsField("Languages") {
            TextField("Languages", text: $visionLanguages, prompt: Text("Auto-detect or enter en-US, fr-FR"))
                .accessibilityIdentifier("ap.settings.visionLanguages")
        }
        .settingsLevel(.visionLanguages)
        SettingsLevelRows(.visionTuning) { visionTuning }
        SettingsLevelRows(.visionJudgement) {
            Toggle("Use an LLM for text-only judgement", isOn: $visionUseLLMJudgment)
                .accessibilityIdentifier("ap.settings.visionUseLLMJudgment")
            if visionUseLLMJudgment {
                Picker("Judgement provider", selection: $selectedProvider) {
                    ForEach(LLMProvider.allCases.filter { $0 != .appleVision }) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("ap.settings.visionJudgmentProviderPicker")
                Picker("Judgement model", selection: Binding(get: { selectedModel }, set: { selectedModel = $0 })) {
                    ForEach(models) { model in
                        Text(customModelStore.isCustom(model) ? "\(model.displayName) (custom)" : model.displayName).tag(model)
                    }
                }
                .accessibilityIdentifier("ap.settings.visionJudgmentModelPicker")
                if selectedModel.supportsThinking {
                    Picker("Judgement thinking", selection: $selectedThinking) {
                        ForEach(ThinkingLevel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .settingsLevel(.thinking)
                }
                Text("Vision performs every image read locally. Only its extracted text is sent to this LLM for classification, segmentation, dates, and tags. Add this provider's API key in Settings › Accounts.")
                    .font(.caption2).foregroundStyle(.primary)
            }
        }
        if !visionUseLLMJudgment {
            Text("Transcription-only is fully offline and free. Use No tagging or Copy source file tags in Process Files.")
                .font(.caption2).foregroundStyle(.primary)
            // W40.fix-processor-settings-backend-mismatch — the line above used to sit beside a Tagging mode that
            // needs an LLM, with nothing saying the run could not start. Say so, and offer the switch.
            if taggingMode != .none && taggingMode != .copySource {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tagging is set to \(taggingMode.displayName), which Apple Vision cannot do on its own, so Start stays off.")
                        .font(.caption2).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.settings.visionTaggingConflict")
                    Spacer()
                    Button("Use No tagging") { taggingModeRaw = TaggingMode.none.rawValue }   // side effect: a fix for the conflict above
                        .accessibilityIdentifier("ap.settings.visionUseNoTagging")
                }
            }
            if enableCollectionSegmentation {
                Text("Collection ID needs an LLM as well. Turn it off in Settings › Documents, or turn on LLM judgement.")
                    .font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Vision's recognition knobs: speed, confidence and vocabulary (Advanced: none is measured on the bench).
    @ViewBuilder private var visionTuning: some View {
        Toggle("Fast recognition", isOn: $visionFastRecognition)
            .accessibilityIdentifier("ap.settings.visionFastRecognition")
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Minimum confidence")
                Spacer()
                Text("\(Int((visionMinimumConfidence * 100).rounded()))%")
                    .foregroundStyle(.primary)
            }
            Slider(value: $visionMinimumConfidence, in: 0...1, step: 0.05)
                .accessibilityIdentifier("ap.settings.visionMinimumConfidence")
        }
        TextEditor(text: $visionCustomVocabulary)
            .font(.caption)
            .frame(height: 58)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            .accessibilityIdentifier("ap.settings.visionCustomVocabulary")
        Text("Custom vocabulary — one word per line or comma-separated.")
            .font(.caption2).foregroundStyle(.primary)
    }

    /// One-click "OpenAI" gateway preset — prefills the public OpenAI endpoint plus a default OpenAI model
    /// and its pricing, read from the single source of truth (`LLMModel.openaiModels`), so a verified
    /// model-ID/price change there flows through here automatically. A custom base URL covers Azure OpenAI /
    /// OpenAI-compatible proxies — apply this, then edit the Gateway URL to that endpoint.
    ///
    /// Model choice: the gateway path builds a plain `OpenAICompatibleClient` that sends `max_tokens` (it does
    /// NOT apply the reasoning-model param adapter — that lives on the native `.openai` provider), and OpenAI
    /// reasoning models reject `max_tokens`. So this defaults to the cheapest **non-reasoning** OpenAI model,
    /// which the gateway request works with as-is; GPT-5 reasoning models go through the Direct API provider.
    private func applyOpenAIGatewayPreset() {
        gatewayLocalModel = false   // OpenAI is remote
        gatewayBaseURL = "https://api.openai.com/v1"
        gatewayDisplayName = "OpenAI"
        gatewayUpstreamProvider = .openai
        if let m = Self.openAIGatewayPresetModel {
            gatewayModelID = m.id
            gatewayInputCost = m.inputCostPer1M
            gatewayOutputCost = m.outputCostPer1M
        }
    }

    /// The model "Fill in OpenAI preset" puts in the gateway's fields (W49.proc-suspects-messages: the driver's
    /// `PROCESSFILES_GATEWAY_PRESET=openai` takes it from here).
    static var openAIGatewayPresetModel: LLMModel? {
        LLMModel.openaiModels.first(where: { !$0.supportsThinking }) ?? LLMModel.openaiModels.first
    }
}
