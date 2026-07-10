import SwiftUI

/// A quick 2-up preview (image page | OCR text page) invoked with Space from the navigation list —
/// a fast peek without opening the full document window. Cycles the selection with ←/→, copies
/// selected text (⌘C), can jump to the full viewer (⌘O), and dismisses with Space or Esc.
struct PreviewSheet: View {
    let selection: DocumentSelection
    @ObservedObject var nav: NavigationModel
    var onOpenFull: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DocumentViewerModel(persists: false)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 940, height: 700)
        .onAppear {
            model.load(selection)
            DispatchQueue.main.async { model.leftController.focus() }
        }
        // ↑/↓ browse the underlying file list: move the nav selection, then re-load the preview to match.
        .onChange(of: nav.selection) { model.load(nav.documentSelection()) }
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
            // ↑/↓ move up/down the file list (live preview follows the selection).
            Button { nav.moveSelectionInList(-1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: [])
                .help("Previous file in the list (↑)")
            Button { nav.moveSelectionInList(1) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [])
                .help("Next file in the list (↓)")
            // ←/→ cycle within a multi-file selection that was opened together.
            Button { model.previous() } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(model.index <= 0)
                .help("Previous document in the selection (←)")
            Button { model.next() } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(model.index >= model.urls.count - 1)
                .help("Next document in the selection (→)")
            Button { model.copyPlainSelection() } label: { Image(systemName: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy selected text exactly (⌘C)")
            Button { model.copySelection() } label: { Image(systemName: "doc.on.doc.fill") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy selected text cleaned for prose (⌘⇧C)")
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
                } else if let text = model.embeddedText {
                    ScrollView {
                        Text(text)
                            .textSelection(.enabled)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
