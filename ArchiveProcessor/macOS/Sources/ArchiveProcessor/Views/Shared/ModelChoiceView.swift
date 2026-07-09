import SwiftUI

/// Reusable provider/model/thinking/key picker, extracted verbatim from `OCRRetrySheet` so the retry
/// sheet and the new per-item `retryWithModel` action share one picker (no duplicate). An optional
/// rotation stepper rides along for the `changeRotation` action.
struct ModelChoiceView: View {
    @Binding var provider: LLMProvider
    @Binding var model: LLMModel
    @Binding var thinkingLevel: ThinkingLevel
    @Binding var apiKey: String
    /// When non-nil, show a 0/90/180/270 rotation stepper (for the rotate-&-re-run action).
    var rotation: Binding<Int>? = nil

    private var currentModels: [LLMModel] { provider.models }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: Binding(
                get: { provider },
                set: { newProvider in
                    model = newProvider.models[0]
                    apiKey = KeychainHelper.load(account: newProvider.rawValue) ?? ""
                    provider = newProvider
                }
            )) {
                ForEach(LLMProvider.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            Picker("Model", selection: $model) {
                ForEach(currentModels) { m in
                    Text(m.displayName).tag(m)
                }
            }

            if model.supportsThinking {
                Picker("Thinking", selection: $thinkingLevel) {
                    ForEach(ThinkingLevel.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }

            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            if let rotation {
                Stepper(value: rotation, in: 0...270, step: 90) {
                    Text("Rotation: \(rotation.wrappedValue)°")
                }
            }
        }
    }
}

/// Sheet wrapper around `ModelChoiceView` presented by the per-item `retryWithModel` / `changeRotation`
/// actions in both panes. Seeds provider from the caller's current choice; returns the picked settings.
struct ModelChoiceSheet: View {
    let title: String
    let subtitle: String?
    var includeRotation: Bool = false
    var fileCountForEstimate: Int? = nil
    let onApply: (LLMProvider, LLMModel, ThinkingLevel?, String, Int?) -> Void
    let onCancel: () -> Void

    @State private var provider: LLMProvider
    @State private var model: LLMModel
    @State private var thinking: ThinkingLevel = .low
    @State private var apiKey: String
    @State private var rotation: Int

    init(title: String, subtitle: String? = nil, includeRotation: Bool = false,
         fileCountForEstimate: Int? = nil, initialProvider: LLMProvider,
         initialRotation: Int = 0,
         onApply: @escaping (LLMProvider, LLMModel, ThinkingLevel?, String, Int?) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.includeRotation = includeRotation
        self.fileCountForEstimate = fileCountForEstimate
        self.onApply = onApply
        self.onCancel = onCancel
        _provider = State(initialValue: initialProvider)
        _model = State(initialValue: initialProvider.models.first ?? LLMModel.geminiModels[0])
        _apiKey = State(initialValue: KeychainHelper.load(account: initialProvider.rawValue) ?? "")
        _rotation = State(initialValue: ((initialRotation % 360) + 360) % 360)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2).fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                ModelChoiceView(provider: $provider, model: $model, thinkingLevel: $thinking,
                                apiKey: $apiKey, rotation: includeRotation ? $rotation : nil)
                if let count = fileCountForEstimate {
                    let estimate = CostEstimator.estimate(
                        fileCount: count, model: model, enableTagging: false,
                        sendPreviousImage: false, contextCharCount: 0)
                    Text("Estimated cost: \(estimate.ocrFormatted)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Retry") {
                    onApply(provider, model, model.supportsThinking ? thinking : nil, apiKey,
                            includeRotation ? rotation : nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 560)
    }
}
