import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - OCR Retry Sheet

struct OCRRetrySheet: View {
    @ObservedObject var processor: OCRProcessor

    /// Seeded by the presenting view from `OCRView.retrySeed` — the settings the RUN pinned
    /// (`activeRunConfig`), or the operator's own escalation from an earlier round of this same retry loop.
    /// These were previously hardcoded to Gemini + its first model, so the sheet offered to retry an
    /// Anthropic (or OpenAI, or Mistral) run on a provider the operator had not chosen — on that family's
    /// cheapest model, the least likely thing to succeed where the run just failed, with the *Gemini*
    /// Keychain key loaded to match.
    ///
    /// Deliberately `@State`, not bound to `ModelSelectionStore`: picking a heavier model to rescue some
    /// failed pages is a one-off, and must not rewrite the app-wide selection for the next run.
    ///
    /// ⚠️ In **gateway** or **Local Agent** mode these three controls are decorative — `retryOne` /
    /// the retry loop pass the run's `gateway`/`localAgent`, and `performOCRCall`'s backend precedence
    /// (localAgent → gateway → provider) never reads them. Tracked as W25.retry-backend; don't write a
    /// comment here claiming the picker and the call agree until that ships.
    @State private var selectedProvider: LLMProvider
    @State private var selectedModel: LLMModel
    @State private var selectedThinking: ThinkingLevel
    @State private var apiKey: String = ""

    init(processor: OCRProcessor, initialProvider: LLMProvider, initialModel: LLMModel,
         initialThinking: ThinkingLevel) {
        _processor = ObservedObject(wrappedValue: processor)
        _selectedProvider = State(initialValue: initialProvider)
        // Membership, not just a matching provider — see `ModelChoiceSheet.seedModel`.
        _selectedModel = State(initialValue: initialProvider.models.first { $0.id == initialModel.id }
                               ?? initialProvider.models[0])
        _selectedThinking = State(initialValue: initialThinking)
    }

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

            // Provider/Model selection for retry — shared picker (see ModelChoiceView).
            VStack(alignment: .leading, spacing: 12) {
                Text("Retry with")
                    .font(.headline)

                ModelChoiceView(provider: $selectedProvider, model: $selectedModel,
                                thinkingLevel: $selectedThinking, apiKey: $apiKey,
                                allowsAppleVision: selectedProvider == .appleVision)

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
                .disabled(selectedProvider != .appleVision && apiKey.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 550, idealWidth: 650, minHeight: 450, idealHeight: 550)
        .onAppear {
            apiKey = selectedProvider == .appleVision ? ""
                : (KeychainHelper.load(account: selectedProvider.rawValue) ?? "")
        }
    }
}
