import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted when the API key changes in Settings, so the main window reloads it from the Keychain.
    static let apiKeyChanged = Notification.Name("APIKeyChanged")
}

/// A small clickable "?" that reveals an explanation in a popover (also shown on hover), so the
/// settings rows stay uncluttered.
struct HelpButton: View {
    let text: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// The app's durable settings, shown in a native Settings window (⌘,). Settings are shared with the
/// Process Files view via the same `@AppStorage`/UserDefaults keys (auto-synced) plus the Keychain
/// for the API key. The tagging-mode dropdown and the output folder stay in the main UI; the
/// model-comparison/resolution tools live in the Tools tab.
///
/// Layout: a scrolling settings form on the left, with a **fixed cost-estimate pane on the right**
/// that stays visible so cost effects of each change are immediately apparent.
struct SettingsView: View {
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.selectedThinking) private var selectedThinking: ThinkingLevel = .low
    @AppStorage(DefaultsKeys.useGateway) private var useGateway: Bool = false
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL: String = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID: String = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName: String = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayUpstreamProvider) private var gatewayUpstreamProvider: LLMProvider = .anthropic

    @AppStorage(DefaultsKeys.preOCRedInput) private var preOCRedInput: Bool = false
    @AppStorage(DefaultsKeys.reOCRMultiPagePDF) private var reOCRMultiPagePDF: Bool = false
    @AppStorage(DefaultsKeys.batchMode) private var batchMode: Bool = false
    @AppStorage(DefaultsKeys.imageResolutionPercent) private var imageScale: Double = 100
    @AppStorage(DefaultsKeys.standardImageSizeMB) private var standardImageSizeMB: Double = 3.0
    @AppStorage(DefaultsKeys.outputImageFile) private var outputImageFile: Bool = true
    @AppStorage(DefaultsKeys.pdfImageSizeMB) private var pdfImageSizeMB: Double = 2.0
    @AppStorage(DefaultsKeys.exportedImageSizeMB) private var exportedImageSizeMB: Double = 3.0
    @AppStorage(DefaultsKeys.textColumns) private var textColumns: Int = 1
    @AppStorage(DefaultsKeys.writeLogFile) private var writeLogEnabled: Bool = false
    @AppStorage(DefaultsKeys.ocrWorkerCount) private var ocrWorkerCount: Int = 4
    @AppStorage(DefaultsKeys.rotationModeRaw) private var rotationModeRaw: String = RotationMode.llmSingle.rawValue
    @AppStorage(DefaultsKeys.reviewRotation) private var reviewRotation: Bool = false

    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage(DefaultsKeys.enableCollectionSegmentation) private var enableCollectionSegmentation: Bool = false
    @AppStorage(DefaultsKeys.confirmCollectionIDs) private var confirmCollectionIDs: Bool = false
    @AppStorage(DefaultsKeys.reviewDocumentSegmentation) private var reviewDocumentSegmentation: Bool = false
    @AppStorage(DefaultsKeys.enableSegmentJSON) private var enableSegmentJSON: Bool = true
    @AppStorage(DefaultsKeys.sendPreviousImage) private var sendPreviousImage: Bool = false
    @AppStorage(DefaultsKeys.contextCharCount) private var contextCharCount: Double = 0   // context slider removed; kept 0 (parallel OCR)
    @AppStorage(DefaultsKeys.tagVocabulary) private var tagVocabulary: String = ""
    @AppStorage(DefaultsKeys.mergeDocuments) private var mergeDocuments: Bool = false
    @AppStorage(DefaultsKeys.customOCRPrompt) private var customOCRPrompt: String = ""
    @AppStorage(DefaultsKeys.liveProcessingMode) private var liveProcessingMode: String = LiveProcessingMode.stage.rawValue
    @AppStorage(DefaultsKeys.driveClientId) private var driveClientId: String = ""

    @ObservedObject private var customModelStore = CustomModelStore.shared
    @ObservedObject private var profileStore = ProcessingProfileStore.shared
    @State private var selectedModel: LLMModel
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var mistralKey = ""
    @State private var gatewayKey = ""
    @State private var showKeyWizard = false
    @State private var showManageModels = false
    // Cloud-relay Google sign-in (transport = cloud). The secret lives in the Keychain, not @AppStorage.
    @State private var driveClientSecret = ""
    @State private var driveSignedIn = false
    @State private var signingIn = false
    @State private var driveStatus = ""
    @State private var driveAuth: DriveAuth? = nil   // retains the auth object across the async loopback flow
    // Processing profiles (named snapshots of the durable processing settings)
    @State private var showSaveProfileAlert = false
    @State private var newProfileName = ""
    @State private var renamingProfileID: UUID? = nil
    @State private var renameProfileName = ""

    init() {
        let provider = LLMProvider(rawValue: UserDefaults.standard.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        _selectedModel = State(initialValue: ModelSelectionStore.savedModel(for: provider))
    }

    private var models: [LLMModel] {
        selectedProvider.models   // already includes this provider's custom models — don't concat (dupes)
    }

    /// Keep `selectedModel` valid: after a provider switch or a custom-model deletion, if the current
    /// selection is no longer in the list the Picker shows blank and processing would use a ghost model
    /// id — so re-point to the same id (fields may have changed) or fall back to the saved/first model.
    private func ensureValidModelSelection() {
        if let match = models.first(where: { $0.id == selectedModel.id }) {
            if match != selectedModel { selectedModel = match }
        } else {
            selectedModel = ModelSelectionStore.savedModel(for: selectedProvider)
        }
    }
    private var taggingMode: TaggingMode { TaggingMode(rawValue: taggingModeRaw) ?? .automatic }
    private var rotationMode: RotationMode { RotationMode(rawValue: rotationModeRaw) ?? .llmSingle }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                profilesSection
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
        .onAppear { reloadKeys() }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in reloadKeys() }
        .onReceive(NotificationCenter.default.publisher(for: .processingProfileApplied)) { _ in
            // A profile just wrote new values into UserDefaults. @AppStorage picks up the scalar settings
            // automatically; re-sync the derived @State (selected model, key fields) that don't.
            selectedModel = ModelSelectionStore.savedModel(for: selectedProvider)
            reloadKeys()
        }
        .sheet(isPresented: $showManageModels) { ManageModelsView() }
        .alert("Save Processing Profile", isPresented: $showSaveProfileAlert) {
            TextField("Profile name", text: $newProfileName)
            Button("Save") { profileStore.saveCurrent(as: newProfileName) }
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save the current processing settings as a reusable profile. API keys are never included.")
        }
        .alert("Rename Profile", isPresented: Binding(get: { renamingProfileID != nil }, set: { if !$0 { renamingProfileID = nil } })) {
            TextField("Profile name", text: $renameProfileName)
            Button("Rename") { if let id = renamingProfileID { profileStore.rename(id, to: renameProfileName) }; renamingProfileID = nil }
                .disabled(renameProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { renamingProfileID = nil }
        }
    }

    @ViewBuilder private var profilesSection: some View {
        Section {
            if profileStore.profiles.isEmpty {
                Text("No saved profiles yet. Save the current settings to switch between reusable configurations in one click.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(profileStore.profiles) { profile in
                    HStack {
                        Text(profile.name).lineLimit(1)
                        Spacer()
                        Button("Apply") { profileStore.apply(profile) }
                            .buttonStyle(.bordered)
                        Menu {
                            Button("Rename…") { renameProfileName = profile.name; renamingProfileID = profile.id }
                            Button("Delete", role: .destructive) { profileStore.delete(profile.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            Button {
                newProfileName = ""
                showSaveProfileAlert = true
            } label: {
                Label("Save current settings as a profile…", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("Profiles")
                HelpButton(text: "A profile is a named snapshot of these processing settings — provider, model (per provider), thinking level, tagging & rotation modes, batch, resolution/size targets, gateway configuration, live-capture mode, and more. Save the current settings, then Apply a profile any time to restore them everywhere. API keys are never stored in a profile (they stay in the Keychain); a profile only references the provider. The output folder is also left unchanged.")
            }
        }
    }

    /// Reload the key fields from the Keychain — on appear and whenever a key changes (e.g. the guided
    /// wizard saves one), so the SecureFields stay in sync with the "Validated"/"Saved" chips.
    private func reloadKeys() {
        anthropicKey = KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? ""
        geminiKey = KeychainHelper.load(account: LLMProvider.gemini.rawValue) ?? ""
        mistralKey = KeychainHelper.load(account: LLMProvider.mistral.rawValue) ?? ""
        gatewayKey = KeychainHelper.load(account: "Gateway") ?? ""
    }

    // MARK: Fixed cost pane (stays put while the form scrolls)

    @ViewBuilder private var costPane: some View {
        let tagging = taggingMode.llmTags   // LLM tag/date calls (excludes Human / Copy-source / None)
        VStack(alignment: .leading, spacing: 6) {
            Text("Estimate — 1,000 files").font(.headline)
            Text("~\(String(format: "%.2g", standardImageSizeMB)) MB each")
                .font(.caption2).foregroundStyle(.secondary)

            let model = useGateway ? gatewayModel : selectedModel
            if let model {
                let est = CostEstimator.estimate(
                    fileCount: 1000, model: model, enableTagging: tagging,
                    enableCollectionSegmentation: enableCollectionSegmentation,
                    preOCRedInput: preOCRedInput, sendPreviousImage: sendPreviousImage && taggingMode.llmSegments,
                    contextCharCount: Int(contextCharCount), imageScale: imageScale / 100.0,
                    rotationMode: rotationMode, useGateway: useGateway,
                    imageTokenProvider: useGateway ? gatewayUpstreamProvider : nil)
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
                if batchMode && !useGateway && !preOCRedInput {
                    Text("Batch mode returns asynchronously (minutes–hours); the time above is the equivalent interactive run.")
                        .font(.caption2).foregroundStyle(.orange)
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
            Picker(selection: $useGateway) {
                Text("Direct API").tag(false)
                Text("API Gateway").tag(true)
            } label: {
                HStack {
                    Text("API mode")
                    HelpButton(text: "Direct API calls the provider directly. API Gateway routes OCR through a custom OpenAI-compatible endpoint — enter its base URL, model ID, a display name for PDF headers, and optionally per-token pricing (used only for the cost/time estimate). Useful for self-hosted or institutional proxies.")
                }
            }

            if useGateway {
                TextField("Gateway URL", text: $gatewayBaseURL)
                TextField("Model ID", text: $gatewayModelID)
                TextField("Display name (for PDF headers)", text: $gatewayDisplayName)
                TextField("Input $/1M tokens", value: Binding(get: { gatewayInputCost >= 0 ? gatewayInputCost : nil }, set: { gatewayInputCost = $0 ?? -1 }), format: .number)
                TextField("Output $/1M tokens", value: Binding(get: { gatewayOutputCost >= 0 ? gatewayOutputCost : nil }, set: { gatewayOutputCost = $0 ?? -1 }), format: .number)
                Picker(selection: $gatewayUpstreamProvider) {
                    ForEach(LLMProvider.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    HStack {
                        Text("Cost profile")
                        HelpButton(text: "Which provider's per-image token cost to assume for the cost/time estimate. Set this to the model family your gateway actually fronts — a Gemini-class model uses ~6.7× more image tokens than Anthropic, so the wrong profile makes the estimate far off. Estimate only; does not affect the actual request.")
                    }
                }
            } else {
                Picker(selection: Binding(
                    get: { selectedProvider },
                    set: { p in
                        selectedModel = ModelSelectionStore.savedModel(for: p)
                        selectedProvider = p
                    })) {
                    ForEach(LLMProvider.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    HStack {
                        Text("Provider")
                        HelpButton(text: "Which LLM service performs OCR and tagging. Each has its own models, pricing, and API key.")
                    }
                }
                Picker(selection: $selectedModel) {
                    ForEach(models) { m in
                        Text(customModelStore.isCustom(m) ? "\(m.displayName) (custom)" : m.displayName).tag(m)
                    }
                } label: {
                    HStack {
                        Text("Model")
                        HelpButton(text: "The model used for OCR and tagging. Fast, cheap models (e.g. Flash Lite) handle most archival documents well; larger models may read difficult handwriting or dense layouts better, at higher cost and time.")
                    }
                }
                .onChange(of: selectedModel) { _, m in
                    ModelSelectionStore.saveModel(m, for: selectedProvider)
                }
                .onChange(of: selectedProvider) { _, _ in ensureValidModelSelection() }
                .onChange(of: customModelStore.allCustomModels) { _, _ in ensureValidModelSelection() }
                if selectedModel.supportsThinking {
                    Picker(selection: $selectedThinking) {
                        ForEach(ThinkingLevel.allCases) { Text($0.rawValue).tag($0) }
                    } label: {
                        HStack {
                            Text("Thinking")
                            HelpButton(text: "Extended reasoning for models that support it. High can improve hard pages but costs more and is slower. Tagging always runs without thinking.")
                        }
                    }
                }
                Button("Manage custom models…") { showManageModels = true }
            }
        }
    }

    @ViewBuilder private var apiKeySection: some View {
        Section {
            Button { showKeyWizard = true } label: {
                Label("Set up keys (guided) — Gemini & Mistral", systemImage: "wand.and.stars")
            }
            keyField("Anthropic", account: LLMProvider.anthropic.rawValue, text: $anthropicKey)
            keyField("Gemini", account: LLMProvider.gemini.rawValue, text: $geminiKey)
            keyField("Mistral", account: LLMProvider.mistral.rawValue, text: $mistralKey)
            if useGateway { keyField("Gateway", account: "Gateway", text: $gatewayKey) }
        } header: {
            HStack {
                Text("API Keys")
                HelpButton(text: "New here? Tap “Set up keys (guided)” to create your own free Gemini or Mistral key step by step, with a live check that it works. Or paste a key directly below. Each key is stored securely in the macOS Keychain; you only need one provider.")
            }
        }
        .sheet(isPresented: $showKeyWizard) {
            ProviderKeyWizard { showKeyWizard = false }
        }
    }

    @ViewBuilder private func keyField(_ label: String, account: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            SecureField("\(label) API key", text: text)
                .onChange(of: text.wrappedValue) { _, k in
                    let t = k.trimmingCharacters(in: .whitespaces)
                    // Ignore programmatic reloads (e.g. after the wizard saves, or on appear): if the value
                    // already matches the Keychain, don't re-save, clear the Validated flag, or loop notices.
                    if t == (KeychainHelper.load(account: account) ?? "") { return }
                    if t.isEmpty {
                        KeychainHelper.delete(account: account)
                        UserDefaults.standard.set(false, forKey: "keySaveFailed_\(account)")
                    } else {
                        let ok = KeychainHelper.save(account: account, password: t)
                        UserDefaults.standard.set(!ok, forKey: "keySaveFailed_\(account)")   // surface a failed write
                    }
                    UserDefaults.standard.set(false, forKey: "keyValidated_\(account)")   // manual edit → needs re-validation
                    NotificationCenter.default.post(name: .apiKeyChanged, object: nil)
                }
            keyStatusChip(account: account, hasKey: !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Small status chip: green "Validated" once the guided wizard's live check passed, else "Saved".
    @ViewBuilder private func keyStatusChip(account: String, hasKey: Bool) -> some View {
        if hasKey && UserDefaults.standard.bool(forKey: "keySaveFailed_\(account)") {
            Label("Save failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.red)
        } else if UserDefaults.standard.bool(forKey: "keyValidated_\(account)") {
            Label("Validated", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.green)
        } else if hasKey {
            Text("Saved").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var inputSection: some View {
        Section("Input & Processing") {
            Toggle(isOn: $preOCRedInput) {
                HStack {
                    Text("Pre-OCRed PDF input")
                    HelpButton(text: "Process PDFs that already contain OCR text (e.g. from a prior run or another tool). Skips OCR API calls and uses the embedded text for tagging and collection ID.")
                }
            }
            .onChange(of: preOCRedInput) { _, on in if on { reOCRMultiPagePDF = false } }
            Toggle(isOn: $reOCRMultiPagePDF) {
                HStack {
                    Text("Re-OCR multi-page PDF")
                    HelpButton(text: "Split an existing multi-page PDF into its pages, re-run OCR on each page image, and rebuild ONE PDF whose pages alternate image, OCR-text, image, OCR-text… (each source page → its image page + a selectable OCR-text page). Unlike “Pre-OCRed PDF input”, this re-OCRs each rendered page instead of reading an existing text layer. It is a pure document transform: tagging and collection options don’t apply, and the input PDF is never overwritten.")
                }
            }
            .onChange(of: reOCRMultiPagePDF) { _, on in if on { preOCRedInput = false } }
            Toggle(isOn: $batchMode) {
                HStack {
                    Text("Batch mode (slower, ~50% cheaper)")
                    HelpButton(text: "Batch jobs are queued and returned asynchronously — results can take minutes to hours — in exchange for ~50% lower cost. Not available with an API Gateway or pre-OCRed input.\n\nGemini caveat: Gemini batch jobs occasionally get stuck in a pending state due to known Google API reliability issues. If a batch doesn't complete within a few hours, cancel and retry, or switch to non-batch mode.")
                }
            }
            .disabled(useGateway || preOCRedInput || reOCRMultiPagePDF)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Image resolution")
                    HelpButton(text: "A size target, not a fixed dimension %. At \(Int(imageScale))% it targets \(String(format: "%.2g", imageScale / 100 * standardImageSizeMB)) MB per image — larger files are downscaled more, while files already at/under target are left full-resolution. Not used for pre-OCRed input (no images are sent).")
                    Spacer()
                    Text("\(Int(imageScale))% of standard").foregroundStyle(.secondary)
                }
                Slider(value: $imageScale, in: 5...100, step: 5)
            }
            .disabled(preOCRedInput)
            HStack {
                Text("Standard image size")
                HelpButton(text: "The reference size the resolution slider targets (default 3 MB). Set it to your collection's typical image size.")
                Spacer()
                TextField("", value: $standardImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 52).multilineTextAlignment(.trailing)
                Text("MB").foregroundStyle(.secondary)
                Stepper("", value: $standardImageSizeMB, in: 0.5...20, step: 0.5).labelsHidden()
            }
            .disabled(preOCRedInput)
            Toggle(isOn: $outputImageFile) {
                HStack {
                    Text("Also export a separate image file (two files)")
                    HelpButton(text: "On: each document is saved as BOTH a PDF (image page + OCR text page) and a separate image file. Off: only the PDF is saved (one file). The two images are sized independently below and separately from the image sent to the LLM.")
                }
            }
            .disabled(preOCRedInput || reOCRMultiPagePDF)
            HStack {
                Text("PDF image size")
                HelpButton(text: "Target size for the image embedded in each output PDF (default 2 MB). Independent of both the image sent to the LLM and the source resolution — larger images are downscaled toward this target, while smaller ones are embedded as-is. Not used for pre-OCRed input.")
                Spacer()
                TextField("", value: $pdfImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 52).multilineTextAlignment(.trailing)
                Text("MB").foregroundStyle(.secondary)
                Stepper("", value: $pdfImageSizeMB, in: 0.5...20, step: 0.5).labelsHidden()
            }
            .disabled(preOCRedInput)
            HStack {
                Text("Text columns")
                HelpButton(text: "Number of columns for the OCR text page (page 2) of each output PDF. Use 2 or 3 for multi-column sources like newspapers. Default: 1 (single-column).")
                Spacer()
                Picker("", selection: $textColumns) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            .disabled(preOCRedInput)
            HStack {
                Text("Exported image size")
                HelpButton(text: "Target size for the separately-exported image file (default 3 MB). Independent of the camera/source resolution — larger images are downscaled toward this target, while already-small JPEGs are kept byte-for-byte. Only applies when \"Also export a separate image file\" is on.")
                Spacer()
                TextField("", value: $exportedImageSizeMB, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 52).multilineTextAlignment(.trailing)
                Text("MB").foregroundStyle(.secondary)
                Stepper("", value: $exportedImageSizeMB, in: 0.5...20, step: 0.5).labelsHidden()
            }
            .disabled(!outputImageFile || preOCRedInput)
            HStack {
                Text("Parallel OCR workers: \(ocrWorkerCount)")
                HelpButton(text: "More workers process OCR faster (roughly halving time going 4 → 8), but raise the chance of provider rate-limit errors (429/503); those are auto-retried with backoff. 4 is safe; 6–8 is usually fine.")
                Spacer()
                Stepper("", value: $ocrWorkerCount, in: 1...12).labelsHidden()
            }
            Toggle(isOn: $writeLogEnabled) {
                HStack {
                    Text("Write a processing log file")
                    HelpButton(text: "On: after a run, write a plain-text log to the output folder summarizing the run and listing any files that failed to produce OCR text (with the error reason). Off (default): no log file is written.")
                }
            }
        }
    }

    @ViewBuilder private var rotationSection: some View {
        Section {
            Picker(selection: $rotationModeRaw) {
                ForEach(RotationMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            } label: {
                HStack {
                    Text("Detect rotation")
                    HelpButton(text: "\(rotationMode.detail)\n\nTime impact: Off / Local Vision add no LLM time. Single (default) makes one extra call per page that overlaps OCR — usually free time-wise. Majority makes three calls per page and can exceed OCR time on large batches, becoming the bottleneck (see the Time estimate).")
                }
            }
            .disabled(preOCRedInput)
            Toggle(isOn: $reviewRotation) {
                HStack {
                    Text("Review rotation")
                    HelpButton(text: "Pause for a quick, dedicated pass to check and fix each page's orientation before output — separate from (and before) the tagging/segmentation review, since rotation is a fast, mindless check. Runs in every tagging mode, including fully-manual. For Process Live, this pass runs once at Finish, over all captured pages. The chosen rotation is applied to both the PDF and the exported image. Requires a rotation-detection mode above (turn Detect rotation off to disable).")
                }
            }
            .disabled(rotationMode == .off || preOCRedInput)
        } header: { Text("Rotation Correction") }
    }

    @ViewBuilder private var taggingSection: some View {
        Section {
            Picker(selection: $taggingModeRaw) {
                ForEach(TaggingMode.allCases) { Text($0.displayName).tag($0.rawValue) }
            } label: {
                HStack {
                    Text("Tagging mode")
                    HelpButton(text: "\(taggingMode.detail)\n\nLinked to the Tagging dropdown in Process Files — changing either updates both. Shown here so you can see the cost/time effect of each mode.")
                }
            }
            Toggle(isOn: $enableCollectionSegmentation) {
                HStack {
                    Text("Collection ID + file renaming")
                    HelpButton(text: "Identify archival collections from box-label photos and organize outputs into per-collection folders with sequential names (e.g. “00001 Collection Name.pdf”).")
                }
            }
            if enableCollectionSegmentation {
                Toggle(isOn: $confirmCollectionIDs) {
                    HStack {
                        Text("Confirm identifications before organizing")
                        HelpButton(text: "Pause before filing so you can review and correct the collection names the model extracted from box labels.")
                    }
                }
                Toggle(isOn: $reviewDocumentSegmentation) {
                    HStack {
                        Text("Review document segmentation")
                        HelpButton(text: "Pause after OCR to review and correct each page's classification (document start / continuation / box / folder) before tagging. Only applies when the model does the segmentation (Automatic / Auto-date).")
                    }
                }
                .disabled(!taggingMode.llmSegments)
            }
            if taggingMode.enablesTagging && taggingMode != .copySource {
                Toggle(isOn: $enableSegmentJSON) {
                    HStack {
                        Text("Export segment JSON metadata")
                        HelpButton(text: "Write a .json sidecar per document with structured metadata (date, subjects, author/recipient, body text) next to the PDF.")
                    }
                }
                Toggle(isOn: $sendPreviousImage) {
                    HStack {
                        Text("Send previous page image")
                        HelpButton(text: "Gives the model the previous page's full image as segmentation context (~2× image cost) while keeping OCR parallel. Only used when the model does the segmentation (Automatic / Auto-date); in manual-segmentation or pre-OCRed modes it's ignored, so it adds no cost. Gemini/Anthropic only.")
                    }
                }
                .disabled(!taggingMode.llmSegments || preOCRedInput)
                if taggingMode == .automatic {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Tag vocabulary (optional)").font(.caption)
                            HelpButton(text: "One tag per line. When set, the model chooses subject tags only from this controlled vocabulary. Leave blank for free-form tagging.")
                            Spacer()
                            Button("Import from CSV…") { importTagVocabularyCSV() }
                                .font(.caption)
                                .help("Load a controlled vocabulary from a .csv or .txt file (comma- or line-separated). You can also drag a file onto the box below.")
                        }
                        TextEditor(text: $tagVocabulary).font(.caption).frame(height: 60)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in loadTagVocabularyFromDrop(providers) }
                    }
                }
            }
            Toggle(isOn: $mergeDocuments) {
                HStack {
                    Text("Merge multi-page documents")
                    HelpButton(text: "Combine a document's continuation pages into one multi-page PDF (each page's image followed by its text) instead of a separate PDF per page.")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Custom prompt (optional)").font(.caption)
                    HelpButton(text: "Extra instructions appended to the OCR prompt — e.g. “This collection is 1950s legal correspondence.” Helps with unusual documents, languages, or formats.")
                }
                TextEditor(text: $customOCRPrompt).font(.caption).frame(height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            }
        } header: {
            Text("Tagging & Segmentation")
        }
    }

    @ViewBuilder private var liveCaptureSection: some View {
        Section {
            Picker(selection: $liveProcessingMode) {
                Text("Stage for later").tag(LiveProcessingMode.stage.rawValue)
                Text("Process live").tag(LiveProcessingMode.live.rawValue)
            } label: {
                HStack {
                    Text("When capturing")
                    HelpButton(text: "Stage for later: captures collect in Live Capture; send them to Process Files for a normal batch run.\n\nProcess live: each captured segment is OCR'd, tagged, and turned into a PDF as you shoot (using the settings here); confirm collection names at the end.")
                }
            }

            // The Mac ALWAYS listens on the LAN and ADDITIONALLY relays through Google Drive whenever it's
            // signed in — there is no transport picker to misconfigure (A5). Sign-in below is pure
            // enablement: the pairing QR then carries a relay code too, so a phone can pick Wired, Wi-Fi, or
            // Cloud from the SAME scan. Leave the Drive fields blank to run LAN/USB only.
            VStack(alignment: .leading, spacing: 8) {
                Text("Cloud relay (Google Drive) — optional")
                    .font(.caption).fontWeight(.medium)
                HStack {
                    Text("Google client ID").font(.caption)
                    HelpButton(text: "The OAuth Desktop-app client ID for the Drive relay (from your Google Cloud project, ending in .apps.googleusercontent.com). Stored in app settings; the matching secret goes in the Keychain.")
                    Spacer()
                }
                TextField("…apps.googleusercontent.com", text: $driveClientId)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Client secret").font(.caption)
                    HelpButton(text: "The OAuth Desktop-app client secret (GOCSPX-…). Saved to the macOS Keychain, never written to disk or settings.")
                    Spacer()
                }
                SecureField("GOCSPX-…", text: $driveClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: driveClientSecret) { _, v in _ = KeychainHelper.save(account: "DriveClientSecret", password: v) }
                HStack(spacing: 10) {
                    Button(driveSignedIn ? "Re-sign in" : "Sign in to Google Drive") { signInToDrive() }
                        .disabled(driveClientId.isEmpty || driveClientSecret.isEmpty || signingIn)
                    if signingIn { ProgressView().controlSize(.small) }
                    if driveSignedIn {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        Button("Sign out") { signOutDrive() }.font(.caption)
                    }
                    Spacer()
                }
                if !driveStatus.isEmpty {
                    Text(driveStatus).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Sign in with the same Google account on the Mac and the phone. Then Start in Live Capture — the Mac watches Drive automatically while a session is active, and the phone can pick Cloud when it scans the QR.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .onAppear { loadDriveState() }
        } header: {
            Text("Live Capture")
        }
    }

    private func loadDriveState() {
        driveClientSecret = KeychainHelper.load(account: "DriveClientSecret") ?? ""
        driveSignedIn = KeychainHelper.load(account: "DriveRefreshToken") != nil
    }

    /// Owner-gated interactive Google sign-in for the Drive relay: opens the browser + loopback flow, then
    /// stores the refresh token in the Keychain (via `DriveAuth`). The secret is persisted first so the
    /// running `CaptureSession.cloudRelay` reads the same credentials.
    private func signInToDrive() {
        _ = KeychainHelper.save(account: "DriveClientSecret", password: driveClientSecret)
        signingIn = true
        driveStatus = "Opening Google sign-in in your browser — approve access, then return here."
        let auth = DriveAuth(clientId: driveClientId.trimmingCharacters(in: .whitespaces), clientSecret: driveClientSecret)
        driveAuth = auth   // signIn captures self weakly; hold a strong ref until the redirect completes
        auth.signIn { result in
            // Reduce to a Sendable String? BEFORE the actor hop (the Error itself isn't Sendable).
            let errorMessage: String? = { if case .failure(let e) = result { return e.localizedDescription }; return nil }()
            Task { @MainActor in
                signingIn = false
                if let errorMessage {
                    driveSignedIn = false
                    driveStatus = "Sign-in failed: \(errorMessage)"
                } else {
                    driveSignedIn = true
                    driveStatus = "Signed in to Google Drive."
                }
            }
        }
    }

    private func signOutDrive() {
        DriveAuth(clientId: driveClientId, clientSecret: driveClientSecret).signOut()
        driveSignedIn = false
        driveStatus = "Signed out."
    }

    private var gatewayModel: LLMModel? {
        guard gatewayInputCost >= 0, gatewayOutputCost >= 0 else { return nil }
        return GatewayConfig(baseURL: gatewayBaseURL, modelID: gatewayModelID,
                             displayName: gatewayDisplayName.isEmpty ? "Gateway" : gatewayDisplayName,
                             inputCostPer1M: gatewayInputCost, outputCostPer1M: gatewayOutputCost).asLLMModel()
    }

    // MARK: - Tag-vocabulary CSV import

    /// Open a .csv/.txt file and load it into the controlled tag vocabulary (one tag per line).
    private func importTagVocabularyCSV() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .text]
        panel.message = "Choose a CSV or text file of subject tags (comma- or line-separated)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadTagVocabulary(from: url)
    }

    /// Handle a file dropped onto the vocabulary editor. Returns true if a file was accepted.
    private func loadTagVocabularyFromDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { loadTagVocabulary(from: url) }
        }
        return true
    }

    /// Parse a CSV/text file into a newline-separated vocabulary: split on newlines and commas,
    /// trim, drop blanks, de-dupe case-insensitively (keep first-seen), preserve order.
    private func loadTagVocabulary(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var seen = Set<String>()
        var tags: [String] = []
        for token in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," }) {
            let tag = token.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { continue }
            tags.append(tag)
        }
        guard !tags.isEmpty else { return }
        tagVocabulary = tags.joined(separator: "\n")
    }
}
