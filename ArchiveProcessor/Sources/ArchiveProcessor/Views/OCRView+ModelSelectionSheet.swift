import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Model Selection Sheet

struct ModelSelectionSheet: View {
    let currentProvider: LLMProvider
    let onStart: ([ModelTestEntry]) -> Void
    let onDismiss: () -> Void

    @State private var selections: [String: Bool] = [:]  // model.id -> selected
    @State private var apiKeys: [String: String] = [:]    // provider.rawValue -> key

    private var allModels: [(provider: LLMProvider, model: LLMModel)] {
        LLMProvider.allCases.flatMap { provider in
            provider.models.map { (provider: provider, model: $0) }
        }
    }

    /// Models sorted by cost descending (most expensive first)
    private var sortedModels: [(provider: LLMProvider, model: LLMModel)] {
        allModels.sorted { $0.model.inputCostPer1M + $0.model.outputCostPer1M > $1.model.inputCostPer1M + $1.model.outputCostPer1M }
    }

    private var selectedEntries: [ModelTestEntry] {
        // Return selected models sorted by cost descending (most expensive = baseline first)
        sortedModels
            .filter { selections[$0.model.id] == true }
            .compactMap { pair in
                guard let key = apiKeys[pair.provider.rawValue], !key.isEmpty else { return nil }
                return ModelTestEntry(provider: pair.provider, model: pair.model, apiKey: key)
            }
    }

    private var missingKeys: Set<String> {
        var providers = Set<String>()
        for pair in allModels where selections[pair.model.id] == true {
            let key = apiKeys[pair.provider.rawValue] ?? ""
            if key.isEmpty { providers.insert(pair.provider.rawValue) }
        }
        return providers
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Models to Compare")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(LLMProvider.allCases) { provider in
                        providerSection(provider)
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                let count = selectedEntries.count
                Text("\(count) model\(count == 1 ? "" : "s") selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !missingKeys.isEmpty {
                    Text("— missing API key for: \(missingKeys.sorted().joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Select Image…") {
                    UserDefaults.standard.set(selections, forKey: DefaultsKeys.modelTestSelections)
                    onStart(selectedEntries)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntries.count < 2)
            }
            .padding()
        }
        .frame(width: 500, height: 520)
        .onAppear {
            // Load saved API keys for all providers
            for provider in LLMProvider.allCases {
                apiKeys[provider.rawValue] = KeychainHelper.load(account: provider.rawValue) ?? ""
            }
            // Restore previously saved model selections, or default to current provider's first model
            if let saved = UserDefaults.standard.dictionary(forKey: DefaultsKeys.modelTestSelections) as? [String: Bool], !saved.isEmpty {
                selections = saved
            } else if let firstModel = currentProvider.models.first {
                selections[firstModel.id] = true
            }
        }
    }

    private func providerSection(_ provider: LLMProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(provider.rawValue)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                let key = Binding(
                    get: { apiKeys[provider.rawValue] ?? "" },
                    set: { apiKeys[provider.rawValue] = $0 }
                )
                SecureField("API Key", text: key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .font(.caption)
            }

            ForEach(provider.models) { model in
                let isOn = Binding(
                    get: { selections[model.id] ?? false },
                    set: { selections[model.id] = $0 }
                )
                HStack {
                    Toggle(model.displayName, isOn: isOn)
                        .font(.caption)
                    Spacer()
                    Text(formatCost(model))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
            }
        }
    }

    private func formatCost(_ model: LLMModel) -> String {
        let total = model.inputCostPer1M + model.outputCostPer1M
        if total < 1.0 {
            return String(format: "$%.3f/M", total)
        } else {
            return String(format: "$%.2f/M", total)
        }
    }
}

