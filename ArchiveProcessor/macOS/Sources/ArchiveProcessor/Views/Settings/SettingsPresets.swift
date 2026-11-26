import SwiftUI

/// The four workflow presets of Settings › Processing (§5.1). A preset only fills choices that the rows below it show
/// and can change: the reader (and with it batch mode and tagging where the reader cannot tag), or the cluster answer.
/// None is stored: the highlighted card is the one the current choices match.
enum WorkflowPreset: String, CaseIterable, Identifiable {
    case fastFree, localHD, cloud, cluster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastFree: return "Fast & Free"
        case .localHD: return "Local HD"
        case .cloud: return "Cloud"
        case .cluster: return "Cluster"
        }
    }

    var subtitle: String {
        switch self {
        case .fastFree: return "Vision · $0"
        case .localHD: return "Mac model · $0"
        case .cloud: return "Best · API"
        case .cluster: return "Slurm / HPC"
        }
    }

    var symbol: String {
        switch self {
        case .fastFree: return "bolt"
        case .localHD: return "desktopcomputer"
        case .cloud: return "cloud"
        case .cluster: return "server.rack"
        }
    }

    var caption: String {
        switch self {
        case .fastFree:
            return "Apple Vision on typed and printed pages. Free, fast and completely offline; it transcribes only, so tagging is off unless a cloud model is chosen for the text."
        case .localHD:
            return "An open-weight model served on this Mac (LM Studio, Ollama or mlx-vlm) for harder pages. Free and offline, one page at a time; start the server first."
        case .cloud:
            return "Your API key for the highest accuracy on hard scans, handwriting and metadata, at the provider's price per page."
        case .cluster:
            return "Tells the app's picks you have a university Slurm cluster: bulk OCR runs prepared for it are imported in Process Files, and the finishing steps run on this Mac."
        }
    }

    /// Whether the stored choices are this preset's.
    @MainActor func matches(_ d: UserDefaults = .standard, cluster: Bool) -> Bool {
        let reader = ReaderChoice.current(d)
        switch self {
        case .fastFree: return reader == .appleVision
        case .localHD: return reader == .gateway && d.bool(forKey: DefaultsKeys.gatewayLocalModel)
        case .cloud:
            if case .direct = reader { return true }
            return false
        case .cluster: return cluster
        }
    }

    /// Why the preset cannot be applied on this Mac, or nil when it can.
    @MainActor var unavailableReason: String? {
        if self == .localHD, LocalModelRoute.picks(memoryGB: LocalModelRoute.thisMacMemoryGB).isEmpty {
            return "A local reading model needs at least 16 GB of memory."
        }
        return nil
    }

    /// The gateway the Local HD preset would replace: a configured address that is not on this Mac.
    @MainActor static func remoteGateway(_ d: UserDefaults = .standard) -> String? {
        let base = d.string(forKey: DefaultsKeys.gatewayBaseURL) ?? ""
        return base.isEmpty || LocalModelRoute.isLoopback(base) ? nil : base
    }

    /// Fill this preset's choices. `keyed` is the providers with a saved key. A preset already matched changes nothing.
    @MainActor func apply(_ d: UserDefaults = .standard, keyed: Set<LLMProvider>, scope: SettingsScopeModel) {
        if self != .cluster, matches(d, cluster: false) { return }
        let tagging = TaggingMode(rawValue: d.string(forKey: DefaultsKeys.taggingModeRaw) ?? "") ?? .automatic
        switch self {
        case .fastFree:
            ReaderChoice.appleVision.apply(d)
            d.set(false, forKey: DefaultsKeys.visionUseLLMJudgment)   // side effect: Vision alone transcribes
            // Vision alone cannot tag, so Start would stay off: the preset says so in its caption.
            if tagging != .none && tagging != .copySource { d.set(TaggingMode.none.rawValue, forKey: DefaultsKeys.taggingModeRaw) }
        case .localHD:
            let base = d.string(forKey: DefaultsKeys.gatewayBaseURL) ?? ""
            // Fill the local server's fields only where nothing local is set yet; a remote gateway is replaced only
            // after the row's confirmation.
            if base.isEmpty || !LocalModelRoute.isLoopback(base) || !d.bool(forKey: DefaultsKeys.gatewayLocalModel),
               let pick = LocalModelRoute.picks(memoryGB: LocalModelRoute.thisMacMemoryGB).first {
                let server = LocalModelRoute.Server.lmStudio
                d.set(server.baseURL, forKey: DefaultsKeys.gatewayBaseURL)   // side effect: the preset fills the server
                d.set(pick.modelID(for: server), forKey: DefaultsKeys.gatewayModelID)   // side effect
                d.set(pick.displayName, forKey: DefaultsKeys.gatewayDisplayName)   // side effect
                d.set(0.0, forKey: DefaultsKeys.gatewayInputCost)   // side effect
                d.set(0.0, forKey: DefaultsKeys.gatewayOutputCost)   // side effect
            }
            d.set(true, forKey: DefaultsKeys.gatewayLocalModel)   // side effect
            ReaderChoice.gateway.apply(d)
        case .cloud:
            // The provider in use if it has a key, with the model already chosen for it; else the first keyed one.
            let order: [LLMProvider] = [.gemini, .anthropic, .openai, .mistral, .openrouter]
            let current = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "")
            let provider = current.flatMap { keyed.contains($0) && $0 != .appleVision ? $0 : nil }
                ?? order.first(where: keyed.contains) ?? .gemini
            ReaderChoice.direct(provider, ModelSelectionStore.shared.model(for: provider).id).apply(d)
        case .cluster:
            let on = scope.store.resolver(for: nil).resolve(.cluster).value.bool ?? false
            scope.set(.cluster, .bool(!on))
        }
    }
}

/// The four preset cards in a row.
struct WorkflowPresetRow: View {
    let keyed: Set<LLMProvider>
    @EnvironmentObject private var scope: SettingsScopeModel
    // Read so a change of reader redraws the highlight.
    @AppStorage(DefaultsKeys.useAppleVision) private var useAppleVision = false
    @AppStorage(DefaultsKeys.useGateway) private var useGateway = false
    @AppStorage(DefaultsKeys.useLocalAgent) private var useLocalAgent = false
    @AppStorage(DefaultsKeys.gatewayLocalModel) private var gatewayLocalModel = false
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    /// The remote gateway the Local HD preset would replace, while its confirmation is up.
    @State private var replacing: String?

    var body: some View {
        _ = (useAppleVision, useGateway, useLocalAgent, gatewayLocalModel, modelStore.selectedModelIDs)
        let cluster = scope.store.resolver(for: nil).resolve(.cluster).value.bool ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(WorkflowPreset.allCases) { preset in
                    let on = preset.matches(cluster: cluster)
                    Button {
                        if preset == .localHD, !on, let remote = WorkflowPreset.remoteGateway() { replacing = remote }
                        else { preset.apply(keyed: keyed, scope: scope) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(preset.title, systemImage: preset.symbol).font(.callout.weight(.semibold))
                            Text(preset.subtitle).font(.caption).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(on ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: on ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(preset.unavailableReason != nil)
                    .help(preset.unavailableReason ?? preset.caption)
                    .accessibilityLabel("\(preset.title) preset, \(preset.subtitle)")
                    .accessibilityHint(preset.caption)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("ap.settings.preset.\(preset.rawValue)")
                }
            }
            if let current = WorkflowPreset.allCases.first(where: { $0 != .cluster && $0.matches(cluster: cluster) }) {
                Text(current.caption).font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.settings.preset.caption")
            } else {
                Text("Your reader matches no preset: it is set by hand below.")
                    .font(.caption2).foregroundStyle(.primary)
                    .accessibilityIdentifier("ap.settings.preset.caption")
            }
        }
        .confirmationDialog("Replace your gateway with a server on this Mac?",
                            isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace") { WorkflowPreset.localHD.apply(keyed: keyed, scope: scope); replacing = nil }
        } message: {
            Text("Local HD reads with a model served on this Mac. Your gateway at \(replacing ?? "") and its model and prices are replaced; you can set them again in Settings › Advanced.")
        }
    }
}
