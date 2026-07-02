import SwiftUI
import AppKit

/// Confirm the processing settings for a live-capture session. It edits the same shared stores the
/// Files tab uses (UserDefaults / Keychain), then snapshots them into the session's locked config
/// via `CaptureSession.chooseLive`.
struct LiveSessionSettingsSheet: View {
    @ObservedObject var session: CaptureSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var customModelStore = CustomModelStore.shared

    @AppStorage("selectedProvider") private var selectedProvider: LLMProvider = .gemini
    @AppStorage("selectedThinking") private var selectedThinking: ThinkingLevel = .low
    @AppStorage("taggingModeRaw") private var taggingModeRaw: String = TaggingMode.automatic.rawValue
    @AppStorage("rotationModeRaw") private var rotationModeRaw: String = RotationMode.llmMajority.rawValue
    @AppStorage("mergeDocuments") private var mergeDocuments: Bool = false

    @State private var selectedModel: LLMModel
    @State private var apiKey: String = ""
    @State private var outputDirectory: URL?

    init(session: CaptureSession) {
        _session = ObservedObject(wrappedValue: session)
        let provider = LLMProvider(rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? "") ?? .gemini
        let modelId = UserDefaults.standard.string(forKey: "selectedModelId_\(provider.rawValue)") ?? ""
        _selectedModel = State(initialValue: provider.models.first { $0.id == modelId } ?? provider.models[0])
        if let path = UserDefaults.standard.string(forKey: "outputDirectory"), FileManager.default.fileExists(atPath: path) {
            _outputDirectory = State(initialValue: URL(fileURLWithPath: path))
        } else {
            _outputDirectory = State(initialValue: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        }
    }

    private var models: [LLMModel] {
        selectedProvider.models + customModelStore.allCustomModels.filter { $0.provider == selectedProvider }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Session processing settings").font(.title2).fontWeight(.semibold)
                .padding([.top, .horizontal], 20)
            Text("These apply to every segment captured this session; they lock once the first segment is processed.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.bottom, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    row("Provider") {
                        Picker("", selection: Binding(
                            get: { selectedProvider },
                            set: { p in
                                let savedId = UserDefaults.standard.string(forKey: "selectedModelId_\(p.rawValue)") ?? ""
                                selectedModel = p.models.first { $0.id == savedId } ?? p.models[0]
                                apiKey = KeychainHelper.load(account: p.rawValue) ?? ""
                                selectedProvider = p
                            })) {
                            ForEach(LLMProvider.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 300)
                    }
                    row("Model") {
                        Picker("", selection: $selectedModel) {
                            ForEach(models) { m in
                                Text(customModelStore.isCustom(m) ? "\(m.displayName) (custom)" : m.displayName).tag(m)
                            }
                        }
                        .labelsHidden().frame(width: 300)
                        .onChange(of: selectedModel) { _, m in
                            UserDefaults.standard.set(m.id, forKey: "selectedModelId_\(selectedProvider.rawValue)")
                        }
                    }
                    if selectedModel.supportsThinking {
                        row("Thinking") {
                            Picker("", selection: $selectedThinking) {
                                ForEach(ThinkingLevel.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented).frame(width: 160)
                        }
                    }
                    row("API key") {
                        SecureField("Enter \(selectedProvider.rawValue) API key…", text: $apiKey)
                            .textFieldStyle(.roundedBorder).frame(width: 300)
                    }
                    row("Tagging") {
                        Picker("", selection: Binding(
                            get: { TaggingMode(rawValue: taggingModeRaw) ?? .automatic },
                            set: { taggingModeRaw = $0.rawValue })) {
                            ForEach(TaggingMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 240)
                    }
                    row("Rotation") {
                        Picker("", selection: Binding(
                            get: { RotationMode(rawValue: rotationModeRaw) ?? .llmMajority },
                            set: { rotationModeRaw = $0.rawValue })) {
                            ForEach(RotationMode.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden().frame(width: 300)
                    }
                    row("Merge") {
                        Toggle("Merge multi-page documents into one PDF", isOn: $mergeDocuments)
                    }
                    row("Output") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outputDirectory?.path ?? "—")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle)
                            Button("Choose…") { chooseOutput() }
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Confirm & use these settings") {
                    persist()
                    session.chooseLive(config: .fromDefaults())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || outputDirectory == nil)
            }
            .padding(20)
        }
        .frame(width: 580, height: 600)
        .onAppear { apiKey = KeychainHelper.load(account: selectedProvider.rawValue) ?? "" }
    }

    @ViewBuilder private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.callout).fontWeight(.medium).frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// Write the edited settings back to the shared stores so the Files tab and next session match.
    private func persist() {
        let account = selectedProvider.rawValue
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { KeychainHelper.delete(account: account) } else { KeychainHelper.save(account: account, password: key) }
        UserDefaults.standard.set(selectedModel.id, forKey: "selectedModelId_\(account)")
        if let out = outputDirectory { UserDefaults.standard.set(out.path, forKey: "outputDirectory") }
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            UserDefaults.standard.set(url.path, forKey: "outputDirectory")
        }
    }
}
