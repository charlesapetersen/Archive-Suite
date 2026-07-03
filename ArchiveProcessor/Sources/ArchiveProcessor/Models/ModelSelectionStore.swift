import Foundation

/// Shared persistence for the per-provider selected model and the output directory.
/// Both the Process Files window (`OCRView`) and the ⌘, Settings scene (`SettingsView`) read and
/// write these through here so they stay in sync via `UserDefaults`. Centralizes the key format
/// (`selectedModelId_<provider>`) and the load/default logic that both views previously duplicated.
enum ModelSelectionStore {
    /// UserDefaults key holding the selected model id for a given provider.
    static func modelKey(for provider: LLMProvider) -> String {
        "selectedModelId_\(provider.rawValue)"
    }

    /// The persisted model for a provider, falling back to that provider's first built-in model.
    static func savedModel(for provider: LLMProvider) -> LLMModel {
        let id = UserDefaults.standard.string(forKey: modelKey(for: provider)) ?? ""
        return provider.models.first { $0.id == id } ?? provider.models[0]
    }

    /// Persist the selected model id for a provider.
    static func saveModel(_ model: LLMModel, for provider: LLMProvider) {
        UserDefaults.standard.set(model.id, forKey: modelKey(for: provider))
    }

    /// The persisted output directory if it still exists, otherwise the user's Downloads folder.
    static func savedOutputDirectory() -> URL? {
        if let path = UserDefaults.standard.string(forKey: "outputDirectory"),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Persist the output directory (nil clears it).
    static func saveOutputDirectory(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: "outputDirectory")
    }
}
