import Foundation

// A "processing profile" is a named snapshot of the app's DURABLE processing settings so a user can
// switch between reusable configurations (e.g. "Fast draft", "High-accuracy handwriting") in one click.
//
// Design notes:
// - A profile stores the *effective* value of each processing key (the stored value, or the same default
//   the views use when a key was never written) so that Apply reproduces the snapshot EXACTLY.
// - Values are captured/persisted through the SAME `DefaultsKeys` / `@AppStorage` / `ModelSelectionStore`
//   keys the rest of the app reads, so applying a profile updates the whole app (main window + Settings).
// - NO API keys are ever stored: keys live in the Keychain. A profile only references the provider by name.
// - Storage is a dictionary keyed by the UserDefaults key string (not a fixed struct) so that adding a new
//   processing setting later just extends `descriptors` — old saved profiles decode fine and Apply simply
//   leaves any not-yet-captured key at its current value. This avoids orphaning saved profiles on upgrade.

/// A single UserDefaults value, typed so it round-trips losslessly through JSON.
enum ProfileValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "bool":   self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":    self = .int(try c.decode(Int.self, forKey: .value))
        case "double": self = .double(try c.decode(Double.self, forKey: .value))
        default:       self = .string(try c.decode(String.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let b):   try c.encode("bool", forKey: .type);   try c.encode(b, forKey: .value)
        case .int(let i):    try c.encode("int", forKey: .type);    try c.encode(i, forKey: .value)
        case .double(let d): try c.encode("double", forKey: .type); try c.encode(d, forKey: .value)
        case .string(let s): try c.encode("string", forKey: .type); try c.encode(s, forKey: .value)
        }
    }
}

/// A named snapshot of the durable processing settings. NEVER contains API keys.
struct ProcessingProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// UserDefaults key string → captured value.
    var values: [String: ProfileValue] = [:]
    /// provider.rawValue → selected model id (the per-provider model, `selectedModelId_<provider>`).
    var modelIdByProvider: [String: String] = [:]
}

final class ProcessingProfileStore: ObservableObject, @unchecked Sendable {
    static let shared = ProcessingProfileStore()

    @Published private(set) var profiles: [ProcessingProfile] = []

    private init() { load() }

    // MARK: - Which settings a profile captures

    /// A durable processing key + the default the app uses when it has never been written. The default
    /// mirrors the `@AppStorage` defaults in `SettingsView`/`OCRView`; capturing the effective value
    /// (stored or default) is what lets Apply reproduce a snapshot exactly even from a fresh install.
    private struct Descriptor { let key: String; let def: ProfileValue }

    private static let descriptors: [Descriptor] = [
        .init(key: DefaultsKeys.selectedProvider, def: .string(LLMProvider.gemini.rawValue)),
        .init(key: DefaultsKeys.selectedThinking, def: .string(ThinkingLevel.low.rawValue)),

        .init(key: DefaultsKeys.useGateway, def: .bool(false)),
        .init(key: DefaultsKeys.gatewayBaseURL, def: .string("")),
        .init(key: DefaultsKeys.gatewayModelID, def: .string("")),
        .init(key: DefaultsKeys.gatewayDisplayName, def: .string("")),
        .init(key: DefaultsKeys.gatewayInputCost, def: .double(-1)),
        .init(key: DefaultsKeys.gatewayOutputCost, def: .double(-1)),
        .init(key: DefaultsKeys.gatewayUpstreamProvider, def: .string(LLMProvider.anthropic.rawValue)),

        .init(key: DefaultsKeys.batchMode, def: .bool(false)),
        .init(key: DefaultsKeys.preOCRedInput, def: .bool(false)),
        .init(key: DefaultsKeys.reOCRMultiPagePDF, def: .bool(false)),
        .init(key: DefaultsKeys.ocrWorkerCount, def: .int(4)),
        .init(key: DefaultsKeys.imageResolutionPercent, def: .double(100)),
        .init(key: DefaultsKeys.standardImageSizeMB, def: .double(3.0)),
        .init(key: DefaultsKeys.pdfImageSizeMB, def: .double(2.0)),
        .init(key: DefaultsKeys.textColumns, def: .int(1)),
        .init(key: DefaultsKeys.exportedImageSizeMB, def: .double(3.0)),
        .init(key: DefaultsKeys.outputImageFile, def: .bool(true)),
        .init(key: DefaultsKeys.contextCharCount, def: .double(0)),
        .init(key: DefaultsKeys.sendPreviousImage, def: .bool(false)),
        .init(key: DefaultsKeys.customOCRPrompt, def: .string("")),
        .init(key: DefaultsKeys.mergeDocuments, def: .bool(false)),
        .init(key: DefaultsKeys.writeLogFile, def: .bool(false)),

        .init(key: DefaultsKeys.rotationModeRaw, def: .string(RotationMode.llmSingle.rawValue)),
        .init(key: DefaultsKeys.reviewRotation, def: .bool(false)),

        .init(key: DefaultsKeys.taggingModeRaw, def: .string(TaggingMode.automatic.rawValue)),
        .init(key: DefaultsKeys.enableCollectionSegmentation, def: .bool(false)),
        .init(key: DefaultsKeys.confirmCollectionIDs, def: .bool(false)),
        .init(key: DefaultsKeys.reviewDocumentSegmentation, def: .bool(false)),
        .init(key: DefaultsKeys.enableSegmentJSON, def: .bool(true)),
        .init(key: DefaultsKeys.tagVocabulary, def: .string("")),

        .init(key: DefaultsKeys.liveProcessingMode, def: .string(LiveProcessingMode.stage.rawValue)),
    ]

    // MARK: - Snapshot / Apply

    /// Capture the current durable processing settings into a new named profile (does not persist it).
    func snapshotCurrent(name: String) -> ProcessingProfile {
        let d = UserDefaults.standard
        var values: [String: ProfileValue] = [:]
        for desc in Self.descriptors {
            values[desc.key] = Self.read(desc, from: d)
        }
        var models: [String: String] = [:]
        for provider in LLMProvider.allCases {
            models[provider.rawValue] = ModelSelectionStore.savedModel(for: provider).id
        }
        return ProcessingProfile(name: name, values: values, modelIdByProvider: models)
    }

    /// Read the effective (stored-or-default) value for a descriptor, coerced to its declared type.
    private static func read(_ desc: Descriptor, from d: UserDefaults) -> ProfileValue {
        guard d.object(forKey: desc.key) != nil else { return desc.def }
        switch desc.def {
        case .bool:   return .bool(d.bool(forKey: desc.key))
        case .int:    return .int(d.integer(forKey: desc.key))
        case .double: return .double(d.double(forKey: desc.key))
        case .string: return .string(d.string(forKey: desc.key) ?? "")
        }
    }

    /// Write a profile's values back through the same UserDefaults / ModelSelectionStore keys the app
    /// reads, so `@AppStorage`-bound views (main window + Settings) update. Posts notifications so views
    /// holding derived `@State` (selected model, API-key fields) re-sync. NEVER touches the Keychain.
    func apply(_ profile: ProcessingProfile) {
        let d = UserDefaults.standard
        // Per-provider model ids first, so a subsequent provider change lands on the right model.
        for (providerRaw, modelId) in profile.modelIdByProvider {
            if let provider = LLMProvider(rawValue: providerRaw) {
                d.set(modelId, forKey: ModelSelectionStore.modelKey(for: provider))
            }
        }
        for (key, value) in profile.values {
            switch value {
            case .bool(let b):   d.set(b, forKey: key)
            case .int(let i):    d.set(i, forKey: key)
            case .double(let x): d.set(x, forKey: key)
            case .string(let s): d.set(s, forKey: key)
            }
        }
        NotificationCenter.default.post(name: .processingProfileApplied, object: nil)
        NotificationCenter.default.post(name: .apiKeyChanged, object: nil)   // provider may have changed → reload key fields
    }

    // MARK: - CRUD

    func saveCurrent(as name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles.append(snapshotCurrent(name: trimmed))
        persist()
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKeys.processingProfiles)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.processingProfiles),
              let decoded = try? JSONDecoder().decode([ProcessingProfile].self, from: data) else { return }
        profiles = decoded
    }
}
