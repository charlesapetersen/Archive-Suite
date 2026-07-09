import SwiftUI
import AppKit

/// Final confirmation of every box/folder identification, shown after the document
/// segmentation (rotation) review. The user can reclassify anything that is actually a
/// document. Reclassifications are applied back into jobs by the processor.
struct BoxFolderConfirmSheet: View {
    @ObservedObject var processor: OCRProcessor

    private var boxCount: Int {
        processor.boxFolderConfirmItems.filter { $0.classification == .boxLabel }.count
    }
    private var folderCount: Int {
        processor.boxFolderConfirmItems.filter { $0.classification == .folderLabel }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Confirm Box & Folder Labels")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Verify each identification. Choose “Not a label” for anything that is actually a document.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(processor.boxFolderConfirmItems.indices, id: \.self) { idx in
                        BoxFolderConfirmRow(item: $processor.boxFolderConfirmItems[idx])
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Text("\(boxCount) box\(boxCount == 1 ? "" : "es"), \(folderCount) folder\(folderCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Confirm") {
                    processor.confirmBoxFolderReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
        .frame(minWidth: 700, idealWidth: 1000, maxWidth: .infinity, minHeight: 500, idealHeight: 800, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.styleMask.insert(.resizable)
            }
        }
    }
}

struct BoxFolderConfirmRow: View {
    @Binding var item: DocumentReviewItem

    private var rowBackground: Color {
        switch item.classification {
        case .boxLabel: return Color.red.opacity(0.10)
        case .folderLabel: return Color.purple.opacity(0.10)
        default: return Color.gray.opacity(0.08)
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            ArchiveThumbnail(url: item.fileURL, maxSize: 500, rotationDegrees: item.rotationDegrees)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 10) {
                Text(item.fileName)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Picker("", selection: Binding(
                    get: { item.classification ?? .documentStart },
                    set: { item.classification = $0 }
                )) {
                    Text("Box").tag(DocumentClassification.boxLabel)
                    Text("Folder").tag(DocumentClassification.folderLabel)
                    Text("Not a label (document)").tag(DocumentClassification.documentStart)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Spacer()
        }
        .padding(10)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
