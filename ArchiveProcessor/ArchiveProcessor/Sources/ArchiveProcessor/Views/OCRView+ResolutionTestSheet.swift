import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Resolution Test Sheet

struct ResolutionTestSheet: View {
    let imageURL: URL?
    let results: [(scale: Int, text: String?)]
    let isRunning: Bool
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void

    @State private var showDiff = true

    /// The 100% result text, used as diff baseline
    private var baselineText: String? {
        results.first(where: { $0.scale == 100 })?.text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Resolution Test")
                    .font(.headline)
                Spacer()
                if baselineText != nil {
                    Toggle("Highlight differences", isOn: $showDiff)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
            }
            .padding()

            if isRunning && results.isEmpty {
                Spacer()
                ProgressView("Running OCR at 6 resolution levels…")
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
                                resolutionColumn(scale: entry.scale, text: entry.text, index: idx)
                            }
                            if isRunning {
                                let scales = [10, 20, 40, 60, 80, 100]
                                ForEach(results.count..<6, id: \.self) { idx in
                                    VStack {
                                        Text("\(scales[idx])%")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        ProgressView()
                                        Spacer()
                                    }
                                    .frame(minWidth: 180)
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
        .frame(idealWidth: 1200, idealHeight: 700)
    }

    private func resolutionColumn(scale: Int, text: String?, index: Int) -> some View {
        let diffResult: WordDiff.DiffResult? = {
            guard showDiff, scale != 100, let baseline = baselineText, let text = text else { return nil }
            return WordDiff.diff(baseline: baseline, candidate: text)
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(scale)%")
                    .font(.caption)
                    .fontWeight(.semibold)
                if let diff = diffResult {
                    similarityBadge(diff.similarity)
                }
                Spacer()
                Button("Use") { onSelect(scale) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if let diff = diffResult {
                HStack(spacing: 8) {
                    if diff.missing > 0 {
                        Label("\(diff.missing) missing", systemImage: "minus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    if diff.added > 0 {
                        Label("\(diff.added) added", systemImage: "plus.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.blue)
                    }
                    if diff.changed > 0 {
                        Label("\(diff.changed) changed", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
            }
            if scale == 100 && showDiff {
                Text("Baseline")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .italic()
            }
            Divider()
            ScrollView {
                if let text = text {
                    if let diff = diffResult {
                        diffHighlightedText(diff)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text("No text returned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
        }
        .frame(width: 220)
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

    private func diffHighlightedText(_ diff: WordDiff.DiffResult) -> some View {
        Text(WordDiff.buildAttributedString(from: diff.elements))
            .textSelection(.enabled)
    }
}

