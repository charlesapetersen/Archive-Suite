import SwiftUI
import ArchiveCore

/// Settings › Accounts (W47.settings-panels): the API keys and their status, the gateway key, the Claude and ChatGPT
/// plans, and the command-line agent's setup.
struct SettingsAccountsPanel: View {
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentTool: LocalAgentTool = .claude
    @AppStorage(DefaultsKeys.localAgentBinaryPath) private var localAgentBinaryPath: String = ""
    @AppStorage(DefaultsKeys.localAgentModel) private var localAgentModel: String = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var mistralKey = ""
    @State private var openaiKey = ""
    @State private var openrouterKey = ""
    @State private var gatewayKey = ""
    @State private var localAgentStatus = ""       // Detect & Verify result message (empty = not yet run)
    @State private var localAgentChecking = false
    @State private var showKeyWizard = false
    @State private var showLocalAgentWizard = false

    @State private var showPlanQuestions = false

    var body: some View {
        Form {
            apiKeySection
            Section {
                LabeledContent("Claude and ChatGPT plans") {
                    Button("Check and sign in…") { showPlanQuestions = true }
                        .accessibilityIdentifier("ap.settings.planSignIn")
                }
                .help("The plans are asked about, checked and signed in to with the setup questions.")
            } header: { Text("Plans") }
            SettingsLevelSection([.cliAgent, .cliFields]) {
                Section {
                    localAgentControls
                } header: { Text("Command-line agent") }
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadKeys() }
        .onReceive(NotificationCenter.default.publisher(for: .apiKeyChanged)) { _ in reloadKeys() }
        .sheet(isPresented: $showLocalAgentWizard) {
            LocalAgentWizard { showLocalAgentWizard = false }
        }
        .sheet(isPresented: $showPlanQuestions) { GeneralInterviewView { showPlanQuestions = false } }
    }

    /// Reload the key fields from the Keychain — on appear and whenever a key changes (e.g. the guided
    /// wizard saves one), so the SecureFields stay in sync with the "Validated"/"Saved" chips.
    private func reloadKeys() {
        anthropicKey = KeychainHelper.load(account: LLMProvider.anthropic.rawValue) ?? ""
        geminiKey = KeychainHelper.load(account: LLMProvider.gemini.rawValue) ?? ""
        mistralKey = KeychainHelper.load(account: LLMProvider.mistral.rawValue) ?? ""
        openaiKey = KeychainHelper.load(account: LLMProvider.openai.rawValue) ?? ""
        openrouterKey = KeychainHelper.load(account: LLMProvider.openrouter.rawValue) ?? ""
        gatewayKey = KeychainHelper.load(account: "Gateway") ?? ""
    }

    /// The Local Agent backend's tool, path and model, and its check (the backend itself is chosen in Settings › Reading).
    /// Detect & Verify is inert until tapped.
    @ViewBuilder private var localAgentControls: some View {
        SettingsLevelRows(.cliAgent) {
            Picker(selection: $localAgentTool) {
                ForEach(LocalAgentTool.allCases, id: \.self) { Text($0.displayName).tag($0) }
            } label: {
                HStack {
                    Text("CLI tool")
                    HelpButton(text: "Which locally installed CLI performs OCR and tagging. Each uses its own sign-in. Claude Code bills its API key if it is signed in with one. Only Claude Code is verified on this machine so far; Gemini/Codex support is best-effort pending their setup check.")
                }
            }
            .accessibilityIdentifier("ap.settings.localAgentToolPicker")
        }
        SettingsLevelRows(.cliFields) {
            SettingsField("CLI path") {
                TextField("CLI path", text: $localAgentBinaryPath, prompt: Text("Optional — auto-detected if blank"))
            }
            SettingsField("Model") {
                TextField("Model", text: $localAgentModel, prompt: Text("Optional — the CLI's default if blank"))
            }
        }
        SettingsLevelRows(.cliAgent, changed: SettingsLevels.changed(.cliAgent) || SettingsLevels.changed(.cliFields)) {
            HStack {
                Button {
                    runLocalAgentDetectVerify()
                } label: {
                    Label(localAgentChecking ? "Checking…" : "Detect & Verify", systemImage: "checkmark.seal")
                }
                .disabled(localAgentChecking)
                HelpButton(text: "Checks that the selected CLI is installed and signed in by running one tiny prompt through it. The check sends no document. Claude Code can charge for the prompt if it is signed in with an API key.")
                Button { showLocalAgentWizard = true } label: {
                    Label("Set up (guided)…", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("ap.settings.localAgentGuidedSetup")
                HelpButton(text: "Step-by-step setup for Claude Code or the Gemini CLI: how to install, sign in with your subscription, and verify — no API key needed.")
            }
            if !localAgentStatus.isEmpty {
                Text(localAgentStatus).font(.caption).foregroundStyle(.primary)
            }
            Text("The CLI uses its own sign-in. Archive Processor does not ask for its credentials.")
                .font(.caption).foregroundStyle(.primary)
        }
    }

    /// Run detect-and-verify off the main actor and surface the plain-English result. Spawns the CLI
    /// only on explicit user action; sends no document (a trivial prompt round-trip).
    private func runLocalAgentDetectVerify() {
        let config = LocalAgentConfig(tool: localAgentTool,
                                      binaryPath: localAgentBinaryPath,
                                      modelOverride: localAgentModel.isEmpty ? nil : localAgentModel)
        localAgentChecking = true
        localAgentStatus = ""
        Task { @MainActor in
            let status = await LocalAgentValidator.detectAndVerify(config: config)
            localAgentStatus = status.message(tool: config.tool)
            localAgentChecking = false
        }
    }

    @ViewBuilder private var apiKeySection: some View {
        Section {
            Button { showKeyWizard = true } label: {
                Label("Set up keys (guided) — Gemini, Mistral & OpenAI", systemImage: "wand.and.stars")
            }
            .accessibilityIdentifier("ap.settings.guidedKeySetup")
            keyField("Anthropic", account: LLMProvider.anthropic.rawValue, text: $anthropicKey)
            keyField("Gemini", account: LLMProvider.gemini.rawValue, text: $geminiKey)
            keyField("Mistral", account: LLMProvider.mistral.rawValue, text: $mistralKey)
            keyField("OpenAI", account: LLMProvider.openai.rawValue, text: $openaiKey)
            keyField("OpenRouter", account: LLMProvider.openrouter.rawValue, text: $openrouterKey)
            keyField("Gateway", account: "Gateway", text: $gatewayKey)
        } header: {
            HStack {
                Text("API Keys")
                HelpButton(text: "New here? Tap “Set up keys (guided)” to create your own Gemini, Mistral, or OpenAI key step by step, with a live check that it works. Gemini and Mistral have free tiers; OpenAI is pay-as-you-go. Or paste a key directly below. Each key is stored securely in the macOS Keychain; you only need one provider.")
            }
        }
        .sheet(isPresented: $showKeyWizard) {
            ProviderKeyWizard { showKeyWizard = false }
        }
    }

    @ViewBuilder private func keyField(_ label: String, account: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            // The title is only the accessibility label; the field draws bordered with an empty-state prompt,
            // so an unset key no longer reads like a stored one (W40.fix-processor-settings-fields).
            SecureField("\(label) API key", text: text, prompt: Text("Not set — paste a key"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
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
        switch SettingsAccountsPanel.keyChip(hasKey: hasKey, validated: validated, saveFailed: saveFailed) {
        case .saveFailed:
            Label("Save failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.red)
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
