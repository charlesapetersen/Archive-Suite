import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Collection Review Sheet

struct CollectionReviewSheet: View {
    @ObservedObject var processor: OCRProcessor

    private var hasBoxes: Bool {
        !processor.collectionReviewItems.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Collection Names")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if hasBoxes {
                        Text("Verify and correct collection names for each box. Files between boxes are automatically assigned to the preceding box's collection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No box labels were identified. Enter a name for this collection.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding()

            Divider()

            if hasBoxes {
                // Box list with editable collection names
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(processor.collectionReviewItems.indices, id: \.self) { idx in
                            CollectionReviewRow(item: $processor.collectionReviewItems[idx])
                        }
                    }
                    .padding()
                }
            } else {
                // No boxes — show collection name text field
                VStack(spacing: 12) {
                    Spacer()
                    Text("Collection Name")
                        .font(.headline)
                    TextField("Enter collection name", text: $processor.noBoxCollectionName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 400)
                    Text("All \(processor.jobs.count) files will be organized into this collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Footer
            HStack {
                if hasBoxes {
                    Text("\(processor.collectionReviewItems.count) box\(processor.collectionReviewItems.count == 1 ? "" : "es")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Confirm and Organize") {
                    processor.confirmCollectionReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
        .frame(minWidth: 700, idealWidth: 1000, maxWidth: .infinity, minHeight: hasBoxes ? 500 : 250, idealHeight: hasBoxes ? 700 : 300, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApp.keyWindow {
                    window.styleMask.insert(.resizable)
                }
            }
        }
    }
}

struct CollectionReviewRow: View {
    @Binding var item: CollectionReviewItem
    @State private var loadedImage: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail
            thumbnail
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Filename
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Box")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(Capsule())
            }
            .frame(minWidth: 180, alignment: .leading)

            Spacer()

            // Collection name (editable)
            TextField("Collection name", text: $item.collectionName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit {
                    item.collectionName = CollectionSegmenter.normalizeCollectionName(item.collectionName)
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.red.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
            }
        }
        // Decode off the main thread so the collection-review pane fills without stalling.
        .task(id: item.fileURL) {
            loadedImage = await Self.loadThumbnailAsync(url: item.fileURL, maxSize: 500)
        }
    }

    private static func loadThumbnailAsync(url: URL, maxSize: Int) async -> NSImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFKit.PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return page.thumbnail(of: NSSize(width: maxSize, height: maxSize), for: .mediaBox)
        }
        return await ArchiveThumbnail.loadImageThumbnail(url: url, maxSize: maxSize)
    }

    private func radioButton(label: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? color : .secondary)
                    .font(.system(size: 12))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(selected ? color : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

