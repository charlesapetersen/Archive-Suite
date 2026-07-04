import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - Document Segmentation Review Sheet

struct DocumentSegmentReviewSheet: View {
    @ObservedObject var processor: OCRProcessor
    @State private var thumbnailSize: CGFloat = 400
    @State private var focusedIndex: Int = 0

    /// Whether New-Document / Continuation options are offered (only when merging or tagging by segment).
    private var showDocClasses: Bool { processor.reviewShowsDocumentClasses }
    /// When true this is the dedicated rotation-review pass — show only the rotation control.
    private var rotationOnly: Bool { processor.reviewRotationOnly }

    private var newDocCount: Int {
        processor.documentReviewItems.filter { $0.classification == .documentStart }.count
    }

    private var continuationCount: Int {
        processor.documentReviewItems.filter { $0.classification == .documentContinuation }.count
    }

    private var boxCount: Int {
        processor.documentReviewItems.filter { $0.classification == .boxLabel }.count
    }

    private var folderCount: Int {
        processor.documentReviewItems.filter { $0.classification == .folderLabel }.count
    }

    private var removedCount: Int {
        processor.documentReviewItems.filter { $0.markedForRemoval }.count
    }

    private var footerSummary: String {
        let active = processor.documentReviewItems.filter { !$0.markedForRemoval }
        if rotationOnly {
            let rotated = active.filter { $0.rotationDegrees % 360 != 0 }.count
            let n = active.count
            return "\(n) page\(n == 1 ? "" : "s")" + (rotated > 0 ? ", \(rotated) rotated" : "")
        }
        var parts: [String] = []
        if showDocClasses {
            let n = active.filter { $0.classification == .documentStart }.count
            let c = active.filter { $0.classification == .documentContinuation }.count
            parts.append("\(n) new document\(n == 1 ? "" : "s")")
            parts.append("\(c) continuation\(c == 1 ? "" : "s")")
        } else {
            let docs = active.filter { $0.classification != .boxLabel && $0.classification != .folderLabel }.count
            parts.append("\(docs) document\(docs == 1 ? "" : "s")")
        }
        let boxes = active.filter { $0.classification == .boxLabel }.count
        let folders = active.filter { $0.classification == .folderLabel }.count
        if boxes > 0 { parts.append("\(boxes) box\(boxes == 1 ? "" : "es")") }
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        if removedCount > 0 { parts.append("\(removedCount) removed") }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(rotationOnly ? "Review Rotation" : "Document Segmentation Review")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(rotationOnly
                         ? "Keys: \u{2190}\u{2192} or [ ]=Rotate  \u{2191}\u{2193}=Navigate  Return=Confirm"
                         : (showDocClasses
                            ? "Keys: 1=New Doc  2=Continuation  3=Box  4=Folder  X=Remove  \u{2191}\u{2193}=Navigate  Return=Confirm"
                            : "Keys: 3=Box  4=Folder  X=Remove  \u{2191}\u{2193}=Navigate  Return=Confirm"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            // Thumbnail size slider
            HStack(spacing: 8) {
                Image(systemName: "photo.artframe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $thumbnailSize, in: 60...800, step: 10)
                Image(systemName: "photo.artframe")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("\(Int(thumbnailSize))px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // Document list
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(processor.documentReviewItems.indices, id: \.self) { idx in
                            DocumentReviewRow(
                                item: $processor.documentReviewItems[idx],
                                thumbnailSize: thumbnailSize,
                                isFocused: idx == focusedIndex,
                                showDocumentClasses: showDocClasses,
                                rotationOnly: rotationOnly
                            )
                            .id(idx)
                            .onTapGesture { focusedIndex = idx }
                        }
                    }
                    .padding()
                }
                .onChange(of: focusedIndex) { _, newIndex in
                    withAnimation {
                        scrollProxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text(footerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    confirmDiscardRun("Your review progress will be lost.") { processor.cancel() }
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                Button("Confirm") {
                    processor.confirmDocumentReview()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
        .frame(minWidth: 1000, idealWidth: 1900, maxWidth: .infinity, minHeight: 800, idealHeight: 1300, maxHeight: .infinity)
        .onKeyPress(.upArrow) {
            if focusedIndex > 0 { focusedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if focusedIndex < processor.documentReviewItems.count - 1 { focusedIndex += 1 }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                let current = processor.documentReviewItems[focusedIndex].rotationDegrees
                processor.documentReviewItems[focusedIndex].rotationDegrees = (current - 90 + 360) % 360
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].rotationDegrees = (processor.documentReviewItems[focusedIndex].rotationDegrees + 90) % 360
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1")) { _ in
            if !rotationOnly, showDocClasses, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .documentStart
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "2")) { _ in
            if !rotationOnly, showDocClasses, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .documentContinuation
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "xX")) { _ in
            if !rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].markedForRemoval.toggle()
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "3")) { _ in
            if !rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .boxLabel
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "4")) { _ in
            if !rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].classification = .folderLabel
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[")) { _ in
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                let current = processor.documentReviewItems[focusedIndex].rotationDegrees
                processor.documentReviewItems[focusedIndex].rotationDegrees = (current - 90 + 360) % 360
            }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "]")) { _ in
            if rotationOnly, focusedIndex < processor.documentReviewItems.count {
                processor.documentReviewItems[focusedIndex].rotationDegrees = (processor.documentReviewItems[focusedIndex].rotationDegrees + 90) % 360
            }
            return .handled
        }
        // Return confirms and moves past the dialog; Escape cancels the run. (The window is a bare
        // NSWindow, so the Confirm/Cancel button key-equivalents don't fire — handle keys here.)
        .onKeyPress(.return) { processor.confirmDocumentReview(); return .handled }
        .onKeyPress(.escape) { confirmDiscardRun("Your review progress will be lost.") { processor.cancel() }; return .handled }
    }
}

struct DocumentReviewRow: View {
    @Binding var item: DocumentReviewItem
    let thumbnailSize: CGFloat
    var isFocused: Bool = false
    var showDocumentClasses: Bool = true
    /// Dedicated rotation-review pass: show only the rotation control, no classification/remove.
    var rotationOnly: Bool = false
    @State private var loadedImage: NSImage?

    private var rowBackground: Color {
        // Rotation-only review: we're checking orientation, not classification — keep every row
        // neutral so box/folder color themes don't distract.
        if rotationOnly { return Color.gray.opacity(0.10) }
        if item.markedForRemoval { return Color.secondary.opacity(0.10) }
        switch item.classification {
        case .boxLabel: return Color.red.opacity(0.12)
        case .folderLabel: return Color.purple.opacity(0.12)
        case .documentStart: return showDocumentClasses ? Color.blue.opacity(0.12) : Color.gray.opacity(0.10)
        case .documentContinuation: return showDocumentClasses ? Color.green.opacity(0.12) : Color.gray.opacity(0.10)
        case .none: return Color.gray.opacity(0.10)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail (rotated to match current rotation setting)
            thumbnail
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(item.markedForRemoval ? 0.4 : 1)

            // Classification radio buttons (hidden in the dedicated rotation-review pass).
            if !rotationOnly {
                VStack(alignment: .leading, spacing: 6) {
                    if showDocumentClasses {
                        radioButton(label: "1 New Document", selected: item.classification == .documentStart, color: .blue) {
                            item.classification = .documentStart
                        }
                        radioButton(label: "2 Continuation", selected: item.classification == .documentContinuation, color: .green) {
                            item.classification = .documentContinuation
                        }
                    } else {
                        // Segmentation is irrelevant here — a page is either a plain document or a box/folder label.
                        radioButton(label: "Document", selected: item.classification == .documentStart || item.classification == .documentContinuation || item.classification == nil, color: .gray) {
                            item.classification = .documentStart
                        }
                    }
                    radioButton(label: "3 Box", selected: item.classification == .boxLabel, color: .red) {
                        item.classification = .boxLabel
                    }
                    radioButton(label: "4 Folder", selected: item.classification == .folderLabel, color: .purple) {
                        item.classification = .folderLabel
                    }
                }
                .frame(width: 130)
                .disabled(item.markedForRemoval)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Filename
                Text(item.fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(item.markedForRemoval)
                    .frame(minWidth: 180, alignment: .leading)

                // Rotation radio buttons — only in the dedicated rotation-review pass.
                if rotationOnly {
                    HStack(spacing: 8) {
                        Text("Rotate:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        rotationRadio(label: "0°", degrees: 0)
                        rotationRadio(label: "90°", degrees: 90)
                        rotationRadio(label: "180°", degrees: 180)
                        rotationRadio(label: "270°", degrees: 270)
                    }
                }
            }

            Spacer()

            // Remove / restore button (segmentation review only).
            if !rotationOnly {
                Button {
                    item.markedForRemoval.toggle()
                } label: {
                    Image(systemName: item.markedForRemoval ? "arrow.uturn.backward.circle" : "trash")
                        .foregroundStyle(item.markedForRemoval ? Color.accentColor : .red)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help(item.markedForRemoval ? "Restore this photo" : "Remove this photo from output")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func rotationRadio(label: String, degrees: Int) -> some View {
        Button {
            item.rotationDegrees = degrees
        } label: {
            HStack(spacing: 3) {
                Image(systemName: item.rotationDegrees == degrees ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(item.rotationDegrees == degrees ? .orange : .secondary)
                    .font(.system(size: 10))
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(item.rotationDegrees == degrees ? .orange : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let loadedImage {
                // Show the entire image (fit, not fill/crop) so nothing is cut off during review.
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(Double(item.rotationDegrees)))
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
        // Decode off the main thread so filling the review pane never blocks the UI.
        .task(id: item.fileURL) {
            loadedImage = await Self.loadThumbnailAsync(url: item.fileURL, maxSize: 1000)
        }
    }

    /// Decode a thumbnail off the main actor (image case) and return an NSImage on the caller's
    /// actor — prevents a burst of synchronous decodes from beachballing the review pane.
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

