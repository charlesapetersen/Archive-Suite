import SwiftUI

/// The one reader a run uses (W49.proc-settings-redesign-core, §5.1): Apple Vision or the macOS on-device model on this
/// Mac, the command-line agent on its own sign-in, the configured gateway, or a provider's model by API key. It stands
/// for the four mutually exclusive backend flags and the per-provider model, so no code path can see two at once.
enum ReaderChoice: Hashable {
    case appleVision
    case onDevice
    case localAgent
    case gateway
    case direct(LLMProvider, String)

    var tag: String {
        switch self {
        case .appleVision: return "appleVision"
        case .onDevice: return "onDevice"
        case .localAgent: return "localAgent"
        case .gateway: return "gateway"
        case .direct(let p, let id): return "direct|\(p.rawValue)|\(id)"
        }
    }

    init?(tag: String) {
        switch tag {
        case "appleVision": self = .appleVision
        case "onDevice": self = .onDevice
        case "localAgent": self = .localAgent
        case "gateway": self = .gateway
        default:
            let parts = tag.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[0] == "direct", let p = LLMProvider(rawValue: parts[1]) else { return nil }
            self = .direct(p, parts[2])
        }
    }

    /// The reader the stored flags name.
    @MainActor static func current(_ d: UserDefaults = .standard, store: ModelSelectionStore = .shared) -> ReaderChoice {
        if d.bool(forKey: DefaultsKeys.useAppleVision) {
            return store.model(for: .appleVision).id == OnDeviceModelClient.modelID ? .onDevice : .appleVision
        }
        if d.bool(forKey: DefaultsKeys.useLocalAgent) { return .localAgent }
        if d.bool(forKey: DefaultsKeys.useGateway) { return .gateway }
        let provider = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        let p = provider == .appleVision ? .gemini : provider
        // The store's fallback keeps the id a member of the menu; only an OpenRouter model that has left the listing
        // keeps its own id, shown as unavailable, so the run's stop is not a surprise.
        if store.unavailableOpenRouterSelection(for: p) != nil, let id = store.selectedModelIDs[p.rawValue] {
            return .direct(p, id)
        }
        return .direct(p, store.model(for: p).id)
    }

    /// Write the flags and model for this reader. Apple Vision has nothing to batch, so it turns batch mode off.
    @MainActor func apply(_ d: UserDefaults = .standard, store: ModelSelectionStore = .shared) {
        func flags(vision: Bool, agent: Bool, gateway: Bool) {
            d.set(vision, forKey: DefaultsKeys.useAppleVision)
            d.set(agent, forKey: DefaultsKeys.useLocalAgent)
            d.set(gateway, forKey: DefaultsKeys.useGateway)
        }
        switch self {
        case .appleVision, .onDevice:
            let id = self == .onDevice ? OnDeviceModelClient.modelID : LLMModel.appleVisionModels[0].id
            if let m = LLMProvider.appleVision.models.first(where: { $0.id == id }) { store.setModel(m, for: .appleVision) }
            flags(vision: true, agent: false, gateway: false)
            d.set(false, forKey: DefaultsKeys.batchMode)
        case .localAgent:
            flags(vision: false, agent: true, gateway: false)
        case .gateway:
            flags(vision: false, agent: false, gateway: true)
        case .direct(let p, let id):
            flags(vision: false, agent: false, gateway: false)
            d.set(p.rawValue, forKey: DefaultsKeys.selectedProvider)
            if let m = p.models.first(where: { $0.id == id }) { store.setModel(m, for: p) }
        }
    }
}

/// The Reader row: one grouped menu over every reader, with what the chosen one needs below it.
struct SettingsReaderPicker: View {
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel = false
    @AppStorage(DefaultsKeys.gatewayDisplayName) private var gatewayDisplayName = ""
    @AppStorage(DefaultsKeys.gatewayBaseURL) private var gatewayBaseURL = ""
    @AppStorage(DefaultsKeys.localAgentTool) private var localAgentTool: LocalAgentTool = .claude
    @AppStorage(DefaultsKeys.offerExperimentalRoutes) private var offerExperimental = false
    @AppStorage(OpenRouterListing.defaultsKey) private var openRouterListingData: Data?
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @ObservedObject private var customModelStore = CustomModelStore.shared
    /// Providers with a saved key, read on appear and on a key change, never while drawing.
    let keyed: Set<LLMProvider>
    @State private var openRouterPricesRead = 0

    private var choice: ReaderChoice {
        _ = (useAppleVision, useGateway, useLocalAgent, selectedProvider)
        return ReaderChoice.current(store: modelStore)
    }

    private var selection: Binding<String> {
        Binding(get: { choice.tag }, set: { ReaderChoice(tag: $0)?.apply(store: modelStore) })
    }

    private var unavailableOpenRouterSelection: String? {
        _ = openRouterListingData
        guard case .direct(let p, _) = choice else { return nil }
        return modelStore.unavailableOpenRouterSelection(for: p)
    }

    private var gatewayName: String {
        if gatewayBaseURL.isEmpty { return "Gateway (set up in Advanced)" }
        let name = gatewayDisplayName.isEmpty ? "Gateway" : gatewayDisplayName
        return gatewayLocalModel ? "\(name) (local server on this Mac)" : "\(name) (gateway)"
    }

    var body: some View {
        Picker(selection: selection) {
            Section("This Mac — free, offline") {
                Text("Apple Vision (on this Mac)").tag(ReaderChoice.appleVision.tag)
                if offerExperimental || choice == .onDevice {
                    Text("macOS on-device model (experimental)").tag(ReaderChoice.onDevice.tag)
                }
                if gatewayLocalModel { Text(gatewayName).tag(ReaderChoice.gateway.tag) }
            }
            Section("Subscription — no per-page fee") {
                Text("\(localAgentTool.displayName) on its own sign-in").tag(ReaderChoice.localAgent.tag)
            }
            Section("Cloud API — pay per page") {
                if !gatewayLocalModel { Text(gatewayName).tag(ReaderChoice.gateway.tag) }
                if let id = unavailableOpenRouterSelection.flatMap({ _ in modelStore.selectedModelIDs[LLMProvider.openrouter.rawValue] }) {
                    Text("\(id) (unavailable)").tag(ReaderChoice.direct(.openrouter, id).tag)
                }
                ForEach(LLMProvider.allCases.filter { $0 != .appleVision }) { p in
                    ForEach(p.models) { m in
                        Text(directLabel(p, m)).tag(ReaderChoice.direct(p, m.id).tag)
                    }
                }
            }
        } label: {
            HelpLabel("Reader", help: "Which reader turns each page image into text. Apple Vision reads on this Mac at no cost and sends nothing off it. A subscription CLI reads with its own sign-in. A cloud model reads with your API key, at its price per page; the estimate below follows the choice. Exactly one reader is active at a time.")
        }
        .accessibilityIdentifier("ap.settings.readerPicker")
        if case .direct(let p, _) = choice {
            if !keyed.contains(p) {
                Text("No \(p.rawValue) key is saved yet: add one in Settings › Accounts before you start a run.")
                    .font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.readerNeedsKey")
            }
            if p == .openrouter { openRouterModelNote }
        } else if choice == .gateway {
            Text(gatewayBaseURL.isEmpty
                 ? "Set the gateway's address and model in Settings › Advanced › Custom endpoints."
                 : "The gateway's address, model and prices are in Settings › Advanced; its key is in Settings › Accounts.")
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ap.settings.gatewayHome")
        } else if choice == .localAgent {
            Text("The command-line agent, its sign-in and its check are in Settings › Accounts.")
                .font(.caption).foregroundStyle(.primary)
                .accessibilityIdentifier("ap.settings.localAgentHome")
        }
    }

    private func directLabel(_ p: LLMProvider, _ m: LLMModel) -> String {
        var label = "\(p.rawValue) · \(m.displayName)"
        if customModelStore.isCustom(m) { label += " (custom)" }
        if !keyed.contains(p) { label += " — add key in Accounts" }
        return label
    }

    private var openRouterModelNote: some View {
        let model = modelStore.model(for: .openrouter)
        return Text(unavailableOpenRouterSelection
                    ?? (openRouterPricesRead >= 0
                        ? (OpenRouterRoute.forModel(model.id)?.settingsNote ?? OpenRouterRoute.unmeasuredNote(model))
                        : ""))
            .font(.caption).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(unavailableOpenRouterSelection == nil
                                     ? "ap.settings.openRouterRoute" : "ap.settings.openRouterUnavailable")
            .task {
                await OpenRouterListing.refreshAllIfStale()
                openRouterPricesRead += 1
            }
    }
}
