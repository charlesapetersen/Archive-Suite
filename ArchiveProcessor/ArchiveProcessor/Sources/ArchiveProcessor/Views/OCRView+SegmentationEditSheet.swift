import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Segmentation Edit Sheet (double-click from file pane)

struct SegmentationEditSheet: View {
    @ObservedObject var processor: OCRProcessor
    let fileIndex: Int
    let fileName: String
    let onDismiss: () -> Void

    @State private var selectedClassification: DocumentClassification = .documentStart

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Classification")
                .font(.title3)
                .fontWeight(.semibold)

            Text(fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("Classification", selection: $selectedClassification) {
                Text("1  Document Start").tag(DocumentClassification.documentStart)
                Text("2  Continuation").tag(DocumentClassification.documentContinuation)
                Text("3  Box Label").tag(DocumentClassification.boxLabel)
                Text("4  Folder Label").tag(DocumentClassification.folderLabel)
            }
            .pickerStyle(.radioGroup)
            .padding(.vertical, 4)

            // Show OCR text preview
            if processor.jobs.indices.contains(fileIndex),
               let text = processor.jobs[fileIndex].result?.text, !text.isEmpty {
                GroupBox("OCR Text Preview") {
                    ScrollView {
                        Text(String(text.prefix(500)))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            }

            HStack {
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") {
                    if processor.jobs.indices.contains(fileIndex) {
                        processor.updateClassification(at: fileIndex, to: selectedClassification)
                    }
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear {
            guard processor.jobs.indices.contains(fileIndex) else { onDismiss(); return }
            if let cls = processor.jobs[fileIndex].result?.classification ?? processor.jobs[fileIndex].classification {
                selectedClassification = cls
            }
        }
    }
}
