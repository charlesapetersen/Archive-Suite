import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Model Test Results Sheet

struct ModelTestResultsSheet: View {
    let imageURL: URL?
    let results: [ModelTestResult]
    let isRunning: Bool
    let totalCount: Int
    let onSelect: (LLMProvider, LLMModel) -> Void
    let onDismiss: () -> Void

    @State private var showDiff = true

    /// The baseline is the most expensive model that returned text
    private var baselineResult: ModelTestResult? {
        results
            .filter { $0.text != nil }
            .max(by: { ($0.model.inputCostPer1M + $0.model.outputCostPer1M) < ($1.model.inputCostPer1M + $1.model.outputCostPer1M) })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Model Comparison")
                    .font(.headline)
                Spacer()
                if baselineResult != nil {
                    Toggle("Highlight differences", isOn: $showDiff)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Button("Done") { onDismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            if isRunning && results.isEmpty {
                Spacer()
                ProgressView("Running OCR on \(totalCount) models…")
                Spacer()
            } else {
                HSplitView {
                    // Left: original image
                    VStack {
                        Text("Original Image")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let url = imageURL, let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 250)
                    .padding(8)

                    // Right: results columns
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.offset) { idx, entry in
                                modelResultColumn(entry: entry, index: idx)
                            }
                            if isRunning {
                                ForEach(results.count..<totalCount, id: \.self) { _ in
                                    VStack {
                                        Text("…")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        ProgressView()
                                        Spacer()
                                    }
                                    .frame(minWidth: 200)
                                    .padding(8)
                                    .background(Color.secondary.opacity(0.05))
                                }
                            }
                        }
                    }
                    .frame(minWidth: 400)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .frame(idealWidth: 1300, idealHeight: 700)
    }

    private func modelResultColumn(entry: ModelTestResult, index: Int) -> some View {
        let isBaseline = baselineResult?.model.id == entry.model.id
        let diffResult: WordDiff.DiffResult? = {
            guard showDiff, !isBaseline, let baseline = baselineResult?.text, let text = entry.text else { return nil }
            return WordDiff.diff(baseline: baseline, candidate: text)
        }()

        return VStack(alignment: .leading, spacing: 4) {
            // Header: provider + model name
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.provider.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(entry.model.displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let diff = diffResult {
                        similarityBadge(diff.similarity)
                    }
                }
            }

            HStack {
                // Cost indicator
                Text(formatCost(entry.model))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Use") { onSelect(entry.provider, entry.model) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if isBaseline && showDiff {
                Text("Baseline (most expensive)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .italic()
            }

            // Diff stats
            if let diff = diffResult {
                HStack(spacing: 6) {
                    if diff.missing > 0 {
                        Label("\(diff.missing)", systemImage: "minus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    if diff.added > 0 {
                        Label("\(diff.added)", systemImage: "plus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    if diff.changed > 0 {
                        Label("\(diff.changed)", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Divider()

            // Text content
            ScrollView {
                if let text = entry.text {
                    if let diff = diffResult {
                        Text(WordDiff.buildAttributedString(from: diff.elements))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if let err = entry.errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fontWeight(.semibold)
                        Text(err)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No text returned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
        .frame(width: 240)
        .padding(8)
        .background(index % 2 == 0 ? Color.secondary.opacity(0.05) : Color.clear)
    }

    private func similarityBadge(_ similarity: Double) -> some View {
        let pct = Int(round(similarity * 100))
        let color: Color = similarity >= 0.95 ? .green
            : similarity >= 0.85 ? .yellow
            : similarity >= 0.70 ? .orange
            : .red
        return Text("\(pct)%")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func formatCost(_ model: LLMModel) -> String {
        let total = model.inputCostPer1M + model.outputCostPer1M
        if total < 1.0 {
            return String(format: "$%.3f/M tokens", total)
        } else {
            return String(format: "$%.2f/M tokens", total)
        }
    }
}

