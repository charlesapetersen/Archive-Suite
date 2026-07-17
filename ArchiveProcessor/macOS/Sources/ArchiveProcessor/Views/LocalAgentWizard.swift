import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Guided, reusable onboarding wizard for the Local Agent CLI backend — the **no-API-key** analog of
/// `ProviderKeyWizard`. Driven by `LocalAgentSpec`, so one component serves Claude Code and Gemini CLI:
/// explain → install → sign in → (optional path/model) → Detect & Verify → plain-English status. On a
/// usable result it persists the verified config to the shared defaults the Settings pane binds.
struct LocalAgentWizard: View {
    let specs: [LocalAgentSpec]
    var onClose: () -> Void

    @State private var selection: String

    init(specs: [LocalAgentSpec] = LocalAgentSpec.onboardable, onClose: @escaping () -> Void = {}) {
        self.specs = specs
        self.onClose = onClose
        // Open on the tool the user already selected in Settings, if it has a spec; else the first.
        let current = UserDefaults.standard.string(forKey: DefaultsKeys.localAgentTool)
        _selection = State(initialValue: specs.first { $0.id == current }?.id ?? specs.first?.id ?? "")
    }

    private var selected: LocalAgentSpec? { specs.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Set up a Local Agent CLI").font(.title2).bold()
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if specs.count > 1 {
                Picker("", selection: $selection) {
                    ForEach(specs) { Text($0.displayName).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()
            }

            ScrollView {
                if let spec = selected {
                    LocalAgentStep(spec: spec).id(spec.id).padding([.horizontal, .bottom])
                }
            }
        }
        .frame(minWidth: 540, minHeight: 620)
    }
}

/// One CLI's guided step: explain → open the install page → sign in → (optional path/model) → Detect &
/// Verify (live) → plain-English status. No key field — the CLI authenticates with its own subscription.
private struct LocalAgentStep: View {
    let spec: LocalAgentSpec
    @Environment(\.openURL) private var openURL
    @State private var binaryPath: String = ""
    @State private var model: String = ""
    @State private var checking = false
    @State private var status: LocalAgentValidator.Status?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(spec.blurb).font(.callout).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(spec.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).").bold().frame(width: 18, alignment: .trailing)
                        Text(step)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            HStack {
                Button { openURL(spec.installURL) } label: {
                    Label("Install \(spec.displayName)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                if let docs = spec.docsURL {
                    Button { openURL(docs) } label: { Label("Docs", systemImage: "book") }
                        .buttonStyle(.bordered)
                }
            }

            noteRow("person.badge.key", spec.entitlementNote)
            noteRow("checkmark.shield", spec.tosNote)

            Divider().padding(.vertical, 4)

            Text("Verify \(spec.displayName)").font(.headline)
            TextField("CLI path (optional — auto-detected if blank)", text: $binaryPath)
                .textFieldStyle(.roundedBorder)
            TextField("Model (optional — CLI default if blank)", text: $model)
                .textFieldStyle(.roundedBorder)

            Button { detectAndVerify() } label: {
                if checking { ProgressView().controlSize(.small) } else { Text("Detect & Verify") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(checking)

            if let status { statusView(status) }

            Text("No API key needed — the CLI uses your existing subscription login.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            // Pre-fill from the current Settings config so the wizard reflects what's already set.
            if UserDefaults.standard.string(forKey: DefaultsKeys.localAgentTool) == spec.tool.rawValue {
                binaryPath = UserDefaults.standard.string(forKey: DefaultsKeys.localAgentBinaryPath) ?? ""
                model = UserDefaults.standard.string(forKey: DefaultsKeys.localAgentModel) ?? ""
            }
        }
    }

    private func noteRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func detectAndVerify() {
        let config = LocalAgentConfig(tool: spec.tool,
                                      binaryPath: binaryPath.trimmingCharacters(in: .whitespacesAndNewlines),
                                      modelOverride: model.isEmpty ? nil : model)
        checking = true
        status = nil
        Task { @MainActor in
            let result = await spec.detectAndVerify(config)
            checking = false
            status = result
            // On a usable result, persist the verified config to the shared defaults the Settings pane
            // binds (the wizard is launched from Local Agent mode, so the backend is already selected).
            if result.isUsable {
                UserDefaults.standard.set(spec.tool.rawValue, forKey: DefaultsKeys.localAgentTool)
                UserDefaults.standard.set(config.binaryPath, forKey: DefaultsKeys.localAgentBinaryPath)
                UserDefaults.standard.set(config.modelOverride ?? "", forKey: DefaultsKeys.localAgentModel)
            }
        }
    }

    @ViewBuilder private func statusView(_ s: LocalAgentValidator.Status) -> some View {
        let ok = s.isUsable
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(s.message(tool: spec.tool)).font(.callout)
            }
            switch s {
            case .cliNotFound:
                Button("Install \(spec.displayName)") { openURL(spec.installURL) }
            case .cliEntitlementMissing:
                if let docs = spec.docsURL { Button("See entitlement docs") { openURL(docs) } }
            default:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill((ok ? Color.green : Color.orange).opacity(0.12)))
    }
}
