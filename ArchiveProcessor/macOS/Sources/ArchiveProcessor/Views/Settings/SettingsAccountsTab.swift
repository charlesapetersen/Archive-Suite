import SwiftUI
import ArchiveCore

/// Settings › Accounts (W49.proc-settings-redesign-core, §5.4): every model downloaded to this Mac in one place, the
/// Claude and ChatGPT subscriptions signed in to directly, and the API keys in the Keychain.
struct SettingsAccountsTab: View {
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentTool: LocalAgentTool = .claude
    @AppStorage(DefaultsKeys.localAgentBinaryPath) private var localAgentBinaryPath = ""
    @AppStorage(DefaultsKeys.localAgentModel) private var localAgentModel = ""
    @ObservedObject private var gemma = ManagedGemma.shared
    @ObservedObject private var managedOCR = ManagedLocalOCR.shared
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.gatewayManagedModel) private var gatewayManagedModel = ""
    @State private var confirmOCRDownload: ManagedOCRModel?
    @State private var confirmOCRRemove: ManagedOCRModel?
    @ObservedObject private var claudeUsage = ClaudeCLIUsage.shared
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var mistralKey = ""
    @State private var openaiKey = ""
    @State private var openrouterKey = ""
    @State private var gatewayKey = ""
    @State private var localAgentStatus = ""
    @State private var localAgentChecking = false
    @State private var showKeyWizard = false
    @State private var showLocalAgentWizard = false
    @State private var confirmGemmaDownload = false
    @State private var segmentationRoutes = SegmentationRoutes.none

    private var claudeBinary: String? { ClaudeCLIBilling.binaryPath(tool: localAgentTool, override: localAgentBinaryPath) }

    var body: some View {
        Form {
            localModelsSection
            subscriptionsSection
            apiKeySection
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadKeys)
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in reloadKeys() }
        .sheet(isPresented: $showLocalAgentWizard) { LocalAgentWizard { showLocalAgentWizard = false } }
        .sheet(isPresented: $showKeyWizard) { ProviderKeyWizard { showKeyWizard = false } }
        .confirmationDialog(gemma.installed ? "Retry Gemma setup?" : "Download Gemma 3 12B?",
                            isPresented: $confirmGemmaDownload, titleVisibility: .visible) {
            Button(gemma.installed ? "Retry Setup" : "Download") { gemma.download() }
        } message: {
            Text(ManagedGemma.sizeNote)
        }
        .confirmationDialog("Download \(confirmOCRDownload?.model.name ?? "the model")?",
                            isPresented: Binding(get: { confirmOCRDownload != nil }, set: { if !$0 { confirmOCRDownload = nil } }),
                            titleVisibility: .visible, presenting: confirmOCRDownload) { m in
            Button("Download") { managedOCR.download(m) }
        } message: { m in
            Text(m.sizeNote + " It comes from Hugging Face under the Apache 2.0 licence. Apple Vision stays available.")
        }
        .confirmationDialog("Remove \(confirmOCRRemove?.model.name ?? "the model")?",
                            isPresented: Binding(get: { confirmOCRRemove != nil }, set: { if !$0 { confirmOCRRemove = nil } }),
                            titleVisibility: .visible, presenting: confirmOCRRemove) { m in
            Button("Remove", role: .destructive) { Task { await managedOCR.remove(m) } }
        } message: { m in
            Text("Deletes its files (up to \(Int(m.model.downloadGB.rounded())) GB) from this Mac. If it is the Reader, Apple Vision becomes the Reader. You can download it again later.")
        }
    }

    // MARK: Managed page readers (W49.proc-managed-local-ocr)

    @ViewBuilder private func managedOCRRow(_ m: ManagedOCRModel, recommended: Bool) -> some View {
        let state = managedOCR.state(m)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("\(m.pick.name), \(m.pick.precision) (page reader\(recommended ? ", recommended" : ""))") {
                HStack(spacing: 8) {
                    switch state {
                    case .notInstalled, .failed:
                        Button(state == .notInstalled ? "Download…" : "Try Again…") { confirmOCRDownload = m }
                            .accessibilityIdentifier("ap.managedOCR.download.\(m.shortID)")
                        if managedOCR.partial.contains(m) {
                            Button("Remove…") { confirmOCRRemove = m }
                                .accessibilityIdentifier("ap.managedOCR.remove.\(m.shortID)")
                        }
                    case .removing:
                        ProgressView().controlSize(.small)
                    case .installing(_, let share):
                        if let share {
                            ProgressView(value: share).frame(width: 120)
                            Text("\(Int(share * 100))%").font(.caption).monospacedDigit()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Button("Cancel") { managedOCR.cancel(m) }
                            .accessibilityIdentifier("ap.managedOCR.cancel.\(m.shortID)")
                    case .installed:
                        if useGateway && gatewayManagedModel == m.rawValue {
                            Text("The Reader").foregroundStyle(.primary)
                        } else {
                            Button("Use as Reader") { managedOCR.use(m) }
                                .accessibilityIdentifier("ap.managedOCR.use.\(m.shortID)")
                        }
                        Button("Remove…") { confirmOCRRemove = m }
                            .accessibilityIdentifier("ap.managedOCR.remove.\(m.shortID)")
                    }
                }
            }
            Group {
                switch state {
                case .installing(let status, _): Text(status)
                case .failed(let why): Text(why)
                case .removing: Text("Removing…")
                case .notInstalled: Text(managedOCR.partial.contains(m)
                                         ? m.sizeNote + " Part of a download is on this Mac; Download resumes it."
                                         : m.sizeNote)
                case .installed: EmptyView()
                }
                Text(m.pick.summary)
            }
            .font(.caption).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.managedOCR.\(m.shortID)")
    }

    /// Reload the key fields from the Keychain: on appear, and whenever a key changes (the guided wizard saves one).
    private func reloadKeys() {
        anthropicKey = KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? ""
        geminiKey = KeychainHelper.load(account: LLMProvider.gemini.rawValue) ?? ""
        mistralKey = KeychainHelper.load(account: LLMProvider.mistral.rawValue) ?? ""
        openaiKey = KeychainHelper.load(account: LLMProvider.openai.rawValue) ?? ""
        openrouterKey = KeychainHelper.load(account: LLMProvider.openrouter.rawValue) ?? ""
        gatewayKey = KeychainHelper.load(account: "Gateway") ?? ""
        segmentationRoutes = SegmentationRoutes.currentPreselecting()
    }

    // MARK: Local models

    @ViewBuilder private var localModelsSection: some View {
        Section {
            LabeledContent("Apple Vision (built in)") {
                Text("Ready · typed and printed pages").foregroundStyle(.primary)
            }
            let offered = ManagedOCRModel.offered()
            ForEach(offered) { m in managedOCRRow(m, recommended: m == offered.first) }
            if offered.isEmpty {
                Text("Page readers to download need an Apple silicon Mac with at least 16 GB of memory. Apple Vision reads pages on this Mac.")
                    .font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Gemma 3 12B (box and folder labels)") {
                    if gemma.installed, gemma.runtimeStatus == nil {
                        Text("Installed").foregroundStyle(.primary)
                    } else if ManagedGemma.supported {
                        if gemma.installing {
                            Button("Pause Download") { gemma.pauseDownload() }
                        } else {
                            Button(gemma.installed ? "Retry Setup…" : "Download…") { confirmGemmaDownload = true }
                                .accessibilityIdentifier("ap.gemma.settingsDownload")
                        }
                    } else {
                        Text("Not available on this Mac").foregroundStyle(.primary)
                    }
                }
                Group {
                    if let status = gemma.runtimeStatus { Text(status) }
                    else if !gemma.installed && ManagedGemma.supported { Text(ManagedGemma.sizeNote) }
                    else if !ManagedGemma.supported { Text(ManagedGemma.requirements) }
                    if let status = gemma.installStatus { Text(status) }
                    Link("Gemma terms", destination: ManagedGemmaBanner.termsURL)
                }
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Newspaper layout helper")
                NewspaperLayoutDownloadRow()
            }
            Text("App-managed models run one at a time, so a download never doubles the memory a run needs. The hand placer and the scanned-newspaper detector are with their switches in Settings › Advanced.")
                .font(.caption2).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Local models on this Mac (\(Int(SettingsLayerStore.thisMacMemoryGB.rounded())) GB memory)")
        }
        .accessibilityIdentifier("ap.settings.localModels")
    }

    // MARK: Subscriptions

    @ViewBuilder private var subscriptionsSection: some View {
        Section("Subscriptions — no per-page fee") {
            Picker(selection: $localAgentTool) {
                ForEach(LocalAgentTool.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                HelpLabel("Command-line agent", help: "Which locally installed CLI reads pages when it is the Reader. Each uses its own sign-in. Claude Code bills its API key if it is signed in with one. Only Claude Code is verified on this machine so far.")
            }
            .accessibilityIdentifier("ap.settings.localAgentToolPicker")
            Text(claudeUsage.costHeadline(binary: claudeBinary, tool: localAgentTool))
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ap.settings.localAgentStatus")
            HStack {
                Button {
                    runLocalAgentDetectVerify()
                } label: {
                    Label(localAgentChecking ? "Checking…" : "Detect & Verify", systemImage: "checkmark.seal")
                }
                .disabled(localAgentChecking)
                .help("Checks that the CLI is installed and signed in by running one tiny prompt. It sends no document. Claude Code can charge for the prompt if it is signed in with an API key.")
                Button { showLocalAgentWizard = true } label: {
                    Label("Set up (guided)…", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("ap.settings.localAgentGuidedSetup")
                .help("Step-by-step setup for Claude Code or the Gemini CLI: install, sign in with your subscription, verify.")
            }
            if !localAgentStatus.isEmpty {
                Text(localAgentStatus).font(.caption).foregroundStyle(.primary)
            }
            Text("The CLI uses its own sign-in; Archive Processor never asks for its credentials. Its path and model are in Settings › Advanced.")
                .font(.caption2).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("ChatGPT plan (for document breaks)")
                ChatGPTPlanControls(routes: $segmentationRoutes)
            }
            .accessibilityIdentifier("ap.settings.chatGPTPlan")
        }
    }

    /// Run detect-and-verify off the main actor and show the plain-English result. Spawns the CLI only on an explicit
    /// click; sends no document.
    private func runLocalAgentDetectVerify() {
        let config = LocalAgentConfig(tool: localAgentTool, binaryPath: localAgentBinaryPath,
                                      modelOverride: localAgentModel.isEmpty ? nil : localAgentModel)
        localAgentChecking = true
        localAgentStatus = ""
        Task { @MainActor in
            let status = await LocalAgentValidator.detectAndVerify(config: config)
            localAgentStatus = status.message(tool: config.tool)
            localAgentChecking = false
            _ = await claudeUsage.refresh(binary: claudeBinary, force: true)
        }
    }

    // MARK: API keys

    @ViewBuilder private var apiKeySection: some View {
        Section {
            Button { showKeyWizard = true } label: {
                Label("Guided key setup — Gemini, Mistral & OpenAI", systemImage: "wand.and.stars")
            }
            .accessibilityIdentifier("ap.settings.guidedKeySetup")
            keyField("Gemini", account: LLMProvider.gemini.rawValue, text: $geminiKey)
            keyField("Anthropic", account: LLMProvider.anthropic.rawValue, text: $anthropicKey)
            keyField("OpenAI", account: LLMProvider.openai.rawValue, text: $openaiKey)
            keyField("Mistral", account: LLMProvider.mistral.rawValue, text: $mistralKey)
            keyField("OpenRouter", account: LLMProvider.openrouter.rawValue, text: $openrouterKey)
            keyField("Gateway", account: "Gateway", text: $gatewayKey)
        } header: {
            HelpLabel("API keys (stored in the macOS Keychain)", help: "New here? “Guided key setup” creates a Gemini, Mistral or OpenAI key step by step, with a live check that it works. Gemini and Mistral have free tiers; OpenAI is pay-as-you-go. Or paste a key below. Each key is stored in the macOS Keychain; you only need one provider.")
        }
    }

    @ViewBuilder private func keyField(_ label: String, account: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            // The title is only the accessibility label; the field draws bordered with an empty-state prompt, so an
            // unset key does not read like a stored one (W40.fix-processor-settings-fields).
            SecureField("\(label) API key", text: text, prompt: Text("Not set — paste a key"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .onChange(of: text.wrappedValue) { _, k in
                    let t = k.trimmingCharacters(in: .whitespaces)
                    // Ignore programmatic reloads: a value that already matches the Keychain is not saved again.
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
            KeyStatusChip(account: account, hasKey: !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    enum KeyChip: String { case saveFailed, validated, saved, none }

    static func keyChip(hasKey: Bool, validated: Bool, saveFailed: Bool) -> KeyChip {
        if saveFailed { return .saveFailed }
        guard hasKey else { return .none }
        return validated ? .validated : .saved
    }
}

private struct KeyStatusChip: View {
    let hasKey: Bool
    @AppStorage private var validated: Bool
    @AppStorage private var saveFailed: Bool

    init(account: String, hasKey: Bool) {
        self.hasKey = hasKey
        _validated = AppStorage(wrappedValue: false, "keyValidated_\(account)")
        _saveFailed = AppStorage(wrappedValue: false, "keySaveFailed_\(account)")
    }

    var body: some View {
        switch SettingsAccountsTab.keyChip(hasKey: hasKey, validated: validated, saveFailed: saveFailed) {
        case .saveFailed:
            // The words in primary, the warning colour on the icon only: red caption text measured 3.33:1 in the
            // light window's accessibility audit.
            Label {
                Text("Save failed").foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .labelStyle(.titleAndIcon).font(.caption)
        case .validated:
            Label("Validated", systemImage: "checkmark.seal.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.primary)
        case .saved:
            Text("Saved").font(.caption).foregroundStyle(.primary)
        case .none:
            EmptyView()
        }
    }
}
