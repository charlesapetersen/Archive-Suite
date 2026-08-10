import SwiftUI

/// A quick 2-up preview (image page | OCR text page) invoked with Space from the navigation list —
/// a fast peek without opening the full document window. Cycles the selection with ←/→, copies
/// selected text (⌘C), can jump to the full viewer (⌘O), and dismisses with Space or Esc.
struct PreviewSheet: View {
    let selection: DocumentSelection
    @ObservedObject var nav: NavigationModel
    /// The PRESENTER's handle on this sheet's viewer model — set on appear, cleared on disappear.
    ///
    /// The sheet deliberately does not publish the model to the Document menu itself. A focused-SCENE
    /// value is not retracted when the view that set it is torn down (measured — see
    /// `NavigationWindowView.publishedPreviewViewer`), so the publication has to be owned by a view that
    /// outlives the sheet and can actively withdraw it. That is the nav window; this binding is how it
    /// learns which model to publish.
    @Binding var published: DocumentViewerModel?
    var onOpenFull: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// `supportsFind: false` — this sheet renders no find bar (the app's only one is in
    /// `DocumentWindowView`), and publishing the model to the scene enables every `.disabled(doc == nil)`
    /// item in the Document menu. Without the flag, `Find…`/`Find Next`/`Find Previous` look live here and
    /// do nothing (`W26.previewzoom-fu1`). ⌘O opens the full viewer, which does have find.
    @StateObject private var model = DocumentViewerModel(persists: false, supportsFind: false)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 940, height: 700)
        .onAppear {
            model.load(selection)
            published = model            // → the nav window publishes it to the scene while we are up
            DispatchQueue.main.async { model.leftController.focus() }
        }
        .onDisappear { published = nil }
        // ↑/↓ browse the underlying file list: move the nav selection, then re-load the preview to match.
        .onChange(of: nav.selection) { model.load(nav.documentSelection()) }
        // Space toggles the preview closed (Finder-style); Esc also closes via the Done button.
        .onKeyPress(.space) { dismiss(); return .handled }
        // NOTE: no `.focusedObject` / `.focusedSceneObject` here — see `published` above. `.focusedObject`
        // was the original (W26.previewzoom): it publishes only while the modified subtree holds SwiftUI
        // keyboard focus, and this pane is an AppKit `PDFView` behind `NSViewRepresentable`, which never
        // gives it, so every zoom/fit command stayed `.disabled(doc == nil)` with the sheet wide open.
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
            // ←/→ cycle the page pairs of this document, then across a multi-file selection opened together.
            Button { model.previous() } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.canGoPrevious)
                .help("Previous page in the selection (←)")
            Button { model.next() } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.canGoNext)
                .help("Next page in the selection (→)")
            Button { model.copyPlainSelection() } label: { Image(systemName: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: .command)
                .help("Copy selected text exactly (⌘C)")
            Button { model.copySelection() } label: { Image(systemName: "doc.on.doc.fill") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy selected text cleaned for prose (⌘⇧C)")
            Button("Open") { onOpenFull() }
                .keyboardShortcut("o", modifiers: .command)
                .help("Open in the full document window (⌘O)")
                .accessibilityIdentifier("ar.preview.open")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)   // Esc
                .help("Close preview (Esc or Space)")
                .accessibilityIdentifier("ar.preview.done")
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        if model.current == nil {
            ContentUnavailableView(model.loadError ?? "No document", systemImage: "doc.questionmark")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                // `.id(pageIdentity)` — a fresh PDFView per displayed pair/document (DV-3). Needed for the
                // image pane in particular: `updateNSView`'s reuse check compares page text, which is nil
                // on every image page, so without this the pane keeps showing the previous scan.
                PDFPaneView(page: model.imagePage, controller: model.leftController, id: "ar.preview.imagePane")
                    .id(model.pageIdentity)
                    .frame(maxWidth: .infinity)
                Divider()
                if model.hasTextPage {
                    PDFPaneView(page: model.textPage, controller: model.rightController, id: "ar.preview.textPane")
                        .id(model.pageIdentity)
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
                    .accessibilityIdentifier("ar.preview.textPane")
                } else {
                    ContentUnavailableView("No OCR text page", systemImage: "text.slash",
                                           description: Text(model.pairCount > 1
                                                             ? "This scan has no OCR text page."
                                                             : "This document has a single page."))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("ar.preview.noText")
                }
            }
        }
    }
}
