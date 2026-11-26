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
            return "A reader the app downloads and runs on this Mac (Qwen3.5 9B or Qwen3-VL 8B) for harder pages and handwriting. Free and offline, one page at a time. Your own model server is in Settings › Advanced."
        case .cloud:
            return "Your API key for the highest accuracy on hard scans, handwriting and metadata, at the provider's price per page."
        case .cluster:
            return "Tells the app's picks you have a university Slurm cluster: bulk OCR runs prepared for it are imported in Process Files, and the finishing steps run on this Mac."
        }
    }

    /// Whether the stored choices are this preset's: for Local HD, a model the app runs or the user's own server on this Mac.
    @MainActor func matches(_ d: UserDefaults = .standard, cluster: Bool) -> Bool {
        let reader = ReaderChoice.current(d)
        switch self {
        case .fastFree: return reader == .appleVision
        case .localHD:
            if case .managed = reader { return true }
            return reader == .gateway && d.bool(forKey: DefaultsKeys.gatewayLocalModel)
        case .cloud:
            if case .direct = reader { return true }
            return false
        case .cluster: return cluster
        }
    }

    /// What Local HD does when chosen (W49.proc-local-ocr-onboarding): use a downloaded managed model, else the
    /// user's own server on this Mac, else offer the recommended download. It never rewrites the user's server fields.
    enum LocalHDPlan: Equatable {
        case managed(ManagedOCRModel)
        case ownServer
        case download(ManagedOCRModel)
        case unavailable
    }

    @MainActor static func localHDPlan(_ d: UserDefaults = .standard, offered: [ManagedOCRModel] = ManagedOCRModel.offered(),
                                       installed: (ManagedOCRModel) -> Bool = { ManagedLocalOCR.shared.state($0) == .installed })
        -> LocalHDPlan {
        if let m = offered.first(where: installed) ?? ManagedOCRModel.allCases.first(where: installed) { return .managed(m) }
        let base = d.string(forKey: DefaultsKeys.gatewayBaseURL) ?? ""
        let model = d.string(forKey: DefaultsKeys.gatewayModelID) ?? ""
        if d.bool(forKey: DefaultsKeys.gatewayLocalModel), LocalModelRoute.isLoopback(base), !model.isEmpty { return .ownServer }
        return offered.first.map { .download($0) } ?? .unavailable
    }

    /// Why the preset cannot be applied on this Mac, or nil when it can.
    @MainActor var unavailableReason: String? {
        if self == .localHD, Self.localHDPlan() == .unavailable {
            return "A reader on this Mac needs an Apple silicon Mac with at least 16 GB of memory."
        }
        return nil
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
            // A model still to download becomes the Reader too: the row starts its download first, and a run before it
            // finishes stops with "download it, or choose Apple Vision".
            switch Self.localHDPlan(d) {
            case .managed(let m), .download(let m): ReaderChoice.managed(m).apply(d)
            case .ownServer: ReaderChoice.gateway.apply(d)
            case .unavailable: break
            }
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
    @AppStorage(DefaultsKeys.gatewayManagedModel) private var gatewayManagedModel = ""
    @ObservedObject private var modelStore = ModelSelectionStore.shared
    @ObservedObject private var managedOCR = ManagedLocalOCR.shared
    /// The model Local HD would download, while its confirmation is up.
    @State private var downloading: ManagedOCRModel?

    var body: some View {
        _ = (useAppleVision, useGateway, useLocalAgent, gatewayLocalModel, gatewayManagedModel, modelStore.selectedModelIDs,
             managedOCR.states)
        let cluster = scope.store.resolver(for: nil).resolve(.cluster).value.bool ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(WorkflowPreset.allCases) { preset in
                    let on = preset.matches(cluster: cluster)
                    Button {
                        if preset == .localHD, !on, case .download(let m) = WorkflowPreset.localHDPlan(),
                           !Self.underWay(managedOCR.state(m)) { downloading = m }
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
        .confirmationDialog("Download \(downloading?.model.name ?? "the model") for Local HD?",
                            isPresented: Binding(get: { downloading != nil }, set: { if !$0 { downloading = nil } }),
                            titleVisibility: .visible, presenting: downloading) { m in
            Button("Download") {
                managedOCR.download(m)
                // Only a download that started makes the model the Reader (none starts while it is being removed).
                if Self.underWay(managedOCR.state(m)) { WorkflowPreset.localHD.apply(keyed: keyed, scope: scope) }
                downloading = nil
            }
        } message: { m in
            Text(m.sizeNote + " It comes from Hugging Face under the Apache 2.0 licence and becomes the Reader: a run can"
                 + " start once it has downloaded, and if the download is cancelled or fails, Apple Vision is the Reader"
                 + " again. Its progress is in Settings › Accounts.")
        }
    }

    /// A download already started (one ticked in the first-run interview) needs no second question.
    private static func underWay(_ state: ManagedLocalOCR.State) -> Bool {
        if case .installing = state { return true }
        return false
    }
}
