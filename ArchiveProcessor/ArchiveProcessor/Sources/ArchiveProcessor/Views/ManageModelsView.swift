import SwiftUI

struct ManageModelsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CustomModelStore.shared
    @State private var showingAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Custom Models")
                .font(.headline)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if store.allCustomModels.isEmpty {
                VStack(spacing: 8) {
                    Text("No custom models added.")
                        .foregroundStyle(.secondary)
                    Text("Add models here when new Anthropic or Gemini models are released, without waiting for an app update.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal)
            } else {
                List {
                    ForEach(groupedByProvider, id: \.0) { provider, models in
                        Section(provider.rawValue) {
                            ForEach(models) { model in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.displayName)
                                            .font(.body)
                                        Text(model.id)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack(spacing: 12) {
                                            Text("In: $\(model.inputCostPer1M, specifier: "%.2f")/1M")
                                            Text("Out: $\(model.outputCostPer1M, specifier: "%.2f")/1M")
                                            if model.supportsThinking {
                                                Text("Thinking")
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(.blue.opacity(0.15))
                                                    .cornerRadius(3)
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) {
                                        store.removeById(model.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Add Model...") {
                    showingAddSheet = true
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 360)
        .sheet(isPresented: $showingAddSheet) {
            AddModelView()
        }
    }

    private var groupedByProvider: [(LLMProvider, [LLMModel])] {
        let grouped = Dictionary(grouping: store.allCustomModels, by: \.provider)
        return [LLMProvider.anthropic, .gemini]
            .filter { grouped[$0] != nil }
            .map { ($0, grouped[$0]!) }
    }
}

struct AddModelView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CustomModelStore.shared

    @State private var provider: LLMProvider = .anthropic
    @State private var modelId: String = ""
    @State private var displayName: String = ""
    @State private var supportsThinking: Bool = false
    @State private var inputCost: String = ""
    @State private var outputCost: String = ""
    @State private var errorMessage: String?

    private var availableProviders: [LLMProvider] { [.anthropic, .gemini] }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Custom Model")
                .font(.headline)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(availableProviders, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }

                TextField("Model ID", text: $modelId, prompt: Text("e.g. claude-sonnet-4-20260618"))
                TextField("Display Name", text: $displayName, prompt: Text("e.g. Claude Sonnet 4"))

                Toggle("Supports Thinking", isOn: $supportsThinking)

                TextField("Input cost ($/1M tokens)", text: $inputCost, prompt: Text("e.g. 3.00"))
                TextField("Output cost ($/1M tokens)", text: $outputCost, prompt: Text("e.g. 15.00"))

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .padding(.horizontal)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    addModel()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(modelId.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 380, height: 320)
    }

    private func addModel() {
        let trimmedId = modelId.trimmingCharacters(in: .whitespaces)
        guard !trimmedId.isEmpty else {
            errorMessage = "Model ID is required."
            return
        }

        let allExisting = provider.models
        if allExisting.contains(where: { $0.id == trimmedId }) {
            errorMessage = "A model with this ID already exists."
            return
        }

        let name = displayName.trimmingCharacters(in: .whitespaces)

        let model = LLMModel(
            id: trimmedId,
            displayName: name.isEmpty ? trimmedId : name,
            provider: provider,
            supportsThinking: supportsThinking,
            returnsMd: false,
            inputCostPer1M: Double(inputCost) ?? 0,
            outputCostPer1M: Double(outputCost) ?? 0,
            batchDiscount: 0.5
        )

        store.add(model)
        dismiss()
    }
}
