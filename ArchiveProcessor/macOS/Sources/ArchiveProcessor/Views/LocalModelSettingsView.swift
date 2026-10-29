import SwiftUI

/// W41.app-local-models — the gateway's "model on this Mac" controls: which local server, the model recommended for
/// this Mac's memory, one click to fill the gateway fields, and a check that the server answers and lists the model.
/// Shown at the top of the API Gateway backend in Settings. The fields it fills stay editable below it.
struct LocalModelSettingsView: View {
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel: Bool = false
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL: String = ""
    @AppStorage(DefaultsKeys.gatewayModelID) private var gatewayModelID: String = ""
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName: String = ""
    @AppStorage(DefaultsKeys.gatewayInputCost) private var gatewayInputCost: Double = -1
    @AppStorage(DefaultsKeys.gatewayOutputCost) private var gatewayOutputCost: Double = -1

    @State private var server: LocalModelRoute.Server = .lmStudio
    @State private var pickID: String = ""
    @State private var checkStatus: String?
    @State private var checking = false

    private let memoryGB = LocalModelRoute.thisMacMemoryGB
    private var picks: [LocalModelRoute.Pick] { LocalModelRoute.picks(memoryGB: memoryGB) }
    private var pick: LocalModelRoute.Pick? { picks.first { $0.id == pickID } ?? picks.first }

    var body: some View {
        Toggle(isOn: $gatewayLocalModel) {
            HStack {
                Text("A model on this Mac")
                HelpButton(text: "The gateway is an open-weight model served on this Mac by LM Studio, Ollama or mlx-vlm. Pages are read one at a time with no key and no charge. A reply is capped at \(LocalModelRoute.maxTokens) tokens, and one that starts repeating itself is stopped as it arrives (on our Mac 3 of 99 pages looped). A looped or capped page is read once more with a repetition penalty; if that fails too, the page fails, and goes to a cloud escalation model only if you allow it below.")
            }
        }
        .accessibilityIdentifier("ap.settings.localModel")
        if gatewayLocalModel {
            if !gatewayBaseURL.isEmpty, !LocalModelRoute.isLoopback(gatewayBaseURL) {
                Text("The Gateway URL is not on this Mac. A remote gateway reads pages faster in parallel, and is not free: turn this off for it.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(LocalModelRoute.recommendationNote(memoryGB: memoryGB))
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ap.settings.localModelRecommendation")
            Text(LocalModelRoute.newspaperNote)
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
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
                if let pick, pick.id != picks.first?.id {
                    Text(pick.summary).font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button {
                    fill()
                } label: {
                    Label("Fill in \(server.rawValue) preset", systemImage: "desktopcomputer")
                }
                .disabled(pick == nil)
                .accessibilityIdentifier("ap.settings.localModelFill")
                Button(checking ? "Checking…" : "Check server") {
                    Task { await check() }
                }
                .disabled(checking || gatewayBaseURL.isEmpty)
            }
            if let checkStatus {
                Text(checkStatus).font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func fill() {
        guard let pick else { return }
        gatewayBaseURL = server.baseURL
        gatewayModelID = pick.modelID(for: server)
        gatewayDisplayName = pick.displayName
        gatewayInputCost = 0
        gatewayOutputCost = 0
        checkStatus = nil
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            let models = try await LocalModelRoute.listModels(baseURL: gatewayBaseURL)
            checkStatus = LocalModelRoute.checkSummary(models: models, modelID: gatewayModelID)
        } catch {
            checkStatus = "Nothing answered at \(gatewayBaseURL): start the server, or check its address. (\(error.localizedDescription))"
        }
    }
}
