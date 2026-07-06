import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - OCR Retry Sheet

struct OCRRetrySheet: View {
    @ObservedObject var processor: OCRProcessor

    @State private var selectedProvider: LLMProvider = .gemini
    @State private var selectedModel: LLMModel = LLMModel.geminiModels[0]
    @State private var selectedThinking: ThinkingLevel = .low
    @State private var apiKey: String = ""

    private var currentModels: [LLMModel] { selectedProvider.models }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OCR Failures")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(processor.failedFileIndices.count) file(s) failed to produce OCR text. You can retry with a different provider or model, or continue without them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Failed files list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(processor.failedFileIndices, id: \.self) { index in
                        let job = processor.jobs[index]
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                                .font(.caption)
                            Text(job.sourceURL.lastPathComponent)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let msg = job.result?.errorMessage {
                                Text(String(msg.prefix(50)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxHeight: 200)

            Divider()

            // Provider/Model selection for retry
            VStack(alignment: .leading, spacing: 12) {
                Text("Retry with")
                    .font(.headline)

                Picker("Provider", selection: Binding(
                    get: { selectedProvider },
                    set: { newProvider in
                        selectedModel = newProvider.models[0]
                        apiKey = KeychainHelper.load(account: newProvider.rawValue) ?? ""
                        selectedProvider = newProvider
                    }
                )) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Model", selection: $selectedModel) {
                    ForEach(currentModels) { m in
                        Text(m.displayName).tag(m)
                    }
                }

                if selectedModel.supportsThinking {
                    Picker("Thinking", selection: $selectedThinking) {
                        ForEach(ThinkingLevel.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                // Cost estimate
                let retryEstimate = CostEstimator.estimate(
                    fileCount: processor.failedFileIndices.count,
                    model: selectedModel,
                    enableTagging: false,
                    sendPreviousImage: false,
                    contextCharCount: 0
                )
                Text("Estimated cost: \(retryEstimate.ocrFormatted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Actions
            HStack {
                Button("Continue Without Retrying") {
                    processor.continueWithoutRetry()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Retry \(processor.failedFileIndices.count) File(s)") {
                    processor.retryFailedFiles(
                        provider: selectedProvider,
                        model: selectedModel,
                        thinkingLevel: selectedModel.supportsThinking ? selectedThinking : nil,
                        apiKey: apiKey
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 550, idealWidth: 650, minHeight: 450, idealHeight: 550)
        .onAppear {
            apiKey = KeychainHelper.load(account: selectedProvider.rawValue) ?? ""
        }
    }
}

