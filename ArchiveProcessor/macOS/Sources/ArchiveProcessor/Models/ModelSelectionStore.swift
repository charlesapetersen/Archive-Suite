import Foundation
import Combine

/// Shared persistence for the per-provider selected model and the output directory.
/// Both the Process Files window (`OCRView`) and the ⌘, Settings scene (`SettingsView`) read and
/// write these through here so they stay in sync via `UserDefaults`. Centralizes the key format
/// (`selectedModelId_<provider>`) and the load/default logic that both views previously duplicated.
///
/// ⚠️ **This is an `ObservableObject`, and that is the whole point.** Every *other* processing setting
/// is `@AppStorage` — a live UserDefaults observer — so changing one in the Settings window re-renders
/// the main window immediately. The selected model cannot be `@AppStorage` (its key is per-provider, so
/// it isn't known when the property wrapper is initialized), and a bare `UserDefaults.set` notifies
/// nobody. Each view therefore held it as plain `@State` seeded once in `init()`, and picking a new
/// model in Settings left the Process Files window on the previous one — a stale cost estimate, and a
/// run that actually called the *old* model. Views now observe `shared` and read through
/// `model(for:)`, so one write updates every window at once.
///
/// **Always write through `saveModel(_:for:)`** — never `UserDefaults.set(_, forKey: modelKey(for:))`
/// directly, or observers will not see the change and the staleness comes straight back.
///
/// `@MainActor` rather than `@unchecked Sendable`: every reader and writer is already main-isolated
/// (SwiftUI views, `@MainActor OCRProcessor`, the `@MainActor` test drivers), and the cached dictionary
/// is exactly the kind of state a stray background write would corrupt into a *wrong paid model*. The
/// annotation makes that a compile error instead of a convention. (The sibling stores predate this and
/// are still `@unchecked Sendable`; that is not a reason to loosen this one.)
@MainActor
final class ModelSelectionStore: ObservableObject {
    static let shared = ModelSelectionStore()

    /// `provider.rawValue` → that provider's selected model id. Published so every observing view
    /// re-renders on a change, whichever window (or applied profile) made it.
    @Published private(set) var selectedModelIDs: [String: String] = [:]

    private init() {
        selectedModelIDs = Self.readIDs()
    }

    /// UserDefaults key holding the selected model id for a given provider. `nonisolated` because it is
    /// pure string formatting AND because nonisolated readers genuinely need it —
    /// `SessionProcessingConfig.fromDefaults` (a `Sendable` struct's static, reachable off-main) resolves
    /// the model itself against a possibly-scratch `UserDefaults` and must not re-spell this key by hand.
    nonisolated static func modelKey(for provider: LLMProvider) -> String {
        "selectedModelId_\(provider.rawValue)"
    }

    /// The persisted model for a provider, falling back to that provider's first built-in model — which
    /// also covers a stale id left behind by a deleted custom model, so no caller can resolve a ghost.
    func model(for provider: LLMProvider) -> LLMModel {
        let id = selectedModelIDs[provider.rawValue] ?? ""
        return provider.models.first { $0.id == id } ?? provider.models[0]
    }

    /// Persist the selected model id for a provider and notify observers.
    func setModel(_ model: LLMModel, for provider: LLMProvider) {
        UserDefaults.standard.set(model.id, forKey: Self.modelKey(for: provider))
        var ids = selectedModelIDs
        ids[provider.rawValue] = model.id
        publish(ids)
    }

    /// Re-read every provider's id from `UserDefaults` and publish if anything moved. For the one writer
    /// that legitimately bypasses `setModel`: `ProcessingProfileStore.apply`, which writes a whole
    /// profile's keys in bulk. Always reads `.standard` — a caller that wrote some *other* suite simply
    /// finds nothing changed, which is why `apply` can call this unconditionally.
    func reloadFromDefaults() {
        publish(Self.readIDs())
    }

    /// Rewrite any provider whose stored id no longer resolves to a real model — the custom model behind
    /// it was deleted — to the fallback `model(for:)` is already returning.
    ///
    /// Without this the dead id sits in `UserDefaults` forever while every reader silently shows the
    /// fallback, and re-adding a custom model with the same id later (which `ManageModelsView` permits,
    /// since its duplicate check only sees models that currently exist) resurrects a selection the user
    /// deleted — the next run then bills at that model with no one having chosen it.
    func healUnresolvableSelections() {
        for provider in LLMProvider.allCases {
            guard let id = selectedModelIDs[provider.rawValue], !id.isEmpty,
                  !provider.models.contains(where: { $0.id == id }) else { continue }
            setModel(provider.models[0], for: provider)
        }
    }

    private static func readIDs() -> [String: String] {
        var ids: [String: String] = [:]
        for provider in LLMProvider.allCases {
            if let id = UserDefaults.standard.string(forKey: modelKey(for: provider)) {
                ids[provider.rawValue] = id
            }
        }
        return ids
    }

    /// Publish only on a real change — a no-op write must not re-render the (heavy) Process Files list.
    private func publish(_ ids: [String: String]) {
        guard ids != selectedModelIDs else { return }
        selectedModelIDs = ids
    }

    // MARK: - Static conveniences

    /// The persisted model for a provider. Kept as a static so non-view callers read the same resolution
    /// (and the same deleted-custom-model fallback) as the views.
    static func savedModel(for provider: LLMProvider) -> LLMModel {
        shared.model(for: provider)
    }

    /// Persist the selected model id for a provider.
    static func saveModel(_ model: LLMModel, for provider: LLMProvider) {
        shared.setModel(model, for: provider)
    }

    /// The persisted output directory if it still exists, otherwise the user's Downloads folder.
    /// `nonisolated` because it touches no actor state — plain UserDefaults, nothing published. (It is
    /// *not* needed for `OCRView.init`: conforming to `View` makes a type's members main-isolated, inits
    /// included, so that call would have been fine either way.)
    nonisolated static func savedOutputDirectory() -> URL? {
        if let path = UserDefaults.standard.string(forKey: DefaultsKeys.outputDirectory),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Persist the output directory (nil clears it).
    nonisolated static func saveOutputDirectory(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: DefaultsKeys.outputDirectory)
    }
}
