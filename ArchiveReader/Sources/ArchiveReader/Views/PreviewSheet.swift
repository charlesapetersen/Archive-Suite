import SwiftUI

/// A quick 2-up preview (image page | OCR text page) invoked with Space from the navigation list —
/// a fast peek without opening the full document window. Cycles the selection with ←/→, copies
/// selected text (⌘C), can jump to the full viewer (⌘O), and dismisses with Space or Esc.
struct PreviewSheet: View {
    let selection: DocumentSelection
    var onOpenFull: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DocumentViewerModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 940, height: 700)
        .onAppear { model.load(selection) }
        // Space toggles the preview closed (Finder-style); Esc also closes via the Done button.
        .onKeyPress(.space) { dismiss(); return .handled }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye")
            Text(model.title).lineLimit(1).truncationMode(.middle).font(.headline)
            if !model.positionLabel.isEmpty {
                Text(model.positionLabel).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.previous() } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.index <= 0)
                .help("Previous document (←)")
            Button { model.next() } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.index >= model.urls.count - 1)
                .help("Next document (→)")
            Button { model.copySelection() } label: { Image(systemName: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy selected text, cleaned for prose (⌘C)")
            Button("Open") { onOpenFull() }
                .keyboardShortcut("o", modifiers: .command)
                .help("Open in the full document window (⌘O)")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)   // Esc
                .help("Close preview (Esc or Space)")
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        if model.current == nil {
            ContentUnavailableView(model.loadError ?? "No document", systemImage: "doc.questionmark")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                PDFPaneView(page: model.imagePage, controller: model.leftController)
                    .frame(maxWidth: .infinity)
                Divider()
                if model.hasTextPage {
                    PDFPaneView(page: model.textPage, controller: model.rightController)
                        .frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView("No OCR text page", systemImage: "text.slash",
                                           description: Text("This document has a single page."))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
