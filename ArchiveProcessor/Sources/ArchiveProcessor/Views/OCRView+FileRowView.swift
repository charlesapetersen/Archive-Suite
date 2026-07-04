import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - File Row

struct FileRowView: View {
    let url: URL
    let job: OCRJob?
    var showTags: Bool = false
    var isFocused: Bool = false
    /// Live Capture segmentation to show before a job exists (falls back to `job.classification`).
    var presetClassification: DocumentClassification? = nil
    @AppStorage("taggingModeRaw") private var taggingModeRaw: String = TaggingMode.automatic.rawValue

    /// Document start/continuation only mean something when the LLM segments (Automatic / Auto-date).
    /// In manual-segmentation, Human, No-tagging, and Copy-source modes those are user-defined or
    /// unused, so they shouldn't clutter the file pane. Box/folder markers always show.
    private func shows(_ c: DocumentClassification) -> Bool {
        if c == .documentStart || c == .documentContinuation {
            return (TaggingMode(rawValue: taggingModeRaw) ?? .automatic).llmSegments
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                statusIcon
                Text(url.lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let rotation = job?.result?.rotationDegrees, rotation != 0 {
                    Text("\(rotation)°")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if let classification = job?.classification ?? presetClassification, shows(classification) {
                    Text(classification.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(classificationColor(classification).opacity(0.15))
                        .foregroundStyle(classificationColor(classification))
                        .clipShape(Capsule())
                }
                if !showTags, let tags = job?.appliedTags, !tags.isEmpty {
                    Text(tags.prefix(2).joined(separator: " \u{00B7} "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if showTags, let tags = job?.appliedTags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.filter { $0 != "Red" && $0 != "Purple" }, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .padding(.leading, 24)
            }
            if let job = job, job.status == .failed, let msg = job.result?.errorMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(classificationBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: 2)
                .opacity(isFocused ? 1 : 0)
        )
    }

    private var classificationBackground: Color {
        guard let classification = job?.classification ?? presetClassification, shows(classification) else { return .clear }
        switch classification {
        case .documentStart: return .blue.opacity(0.06)
        case .documentContinuation: return .green.opacity(0.06)
        case .boxLabel: return .red.opacity(0.06)
        case .folderLabel: return .purple.opacity(0.06)
        }
    }

    private func classificationColor(_ c: DocumentClassification) -> Color {
        switch c {
        case .boxLabel: return .red
        case .folderLabel: return .purple
        case .documentStart: return .blue
        case .documentContinuation: return .gray
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job?.status {
        case .processing:
            ProgressView().scaleEffect(0.6)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .removed:
            Image(systemName: "trash.circle.fill").foregroundStyle(.secondary).font(.caption)
        default:
            Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
        }
    }
}

