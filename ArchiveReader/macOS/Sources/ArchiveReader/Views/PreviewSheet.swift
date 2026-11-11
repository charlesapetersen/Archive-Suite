import AppKit
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
    /// The sheet's size, from `fittedSize(in:)` over the presenting window's content size.
    var size: CGSize
    var onOpenFull: () -> Void

    /// The preferred size, shrunk to leave a margin inside the window the sheet hangs from, so it never
    /// overhangs it (W40.fix-reader-preview-sheet-oversize: 940×700 over a 900×612 window). A zero size means
    /// the window has not been measured yet; the preferred size stands until it is.
    static let preferredSize = CGSize(width: 940, height: 700)
    static func fittedSize(in window: CGSize) -> CGSize { SheetSizing.fitted(preferredSize, in: window) }

    @Environment(\.dismiss) private var dismiss
    /// `supportsFind: false` — this sheet renders no find bar (the app's only one is in
    /// `DocumentWindowView`), and publishing the model to the scene enables every `.disabled(doc == nil)`
    /// item in the Document menu. Without the flag, `Find…`/`Find Next`/`Find Previous` look live here and
    /// do nothing (`W26.previewzoom-fu1`). ⌘O opens the full viewer, which does have find.
    @StateObject private var model = DocumentViewerModel(persists: false, supportsFind: false, reportsSwitches: false)
    /// The image pages drawn ahead of time, so the image arrives with the text (W40.fix-reader-preview-image-speed).
    @ObservedObject private var prefetcher = PreviewImagePrefetcher.shared
    /// The sheet remembers its own thumbnail sidebar, apart from the document window's.
    @AppStorage("ar.preview.thumbnailsVisible") private var thumbnailsVisible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document preview")
        .accessibilityIdentifier("ar.preview.content")
        .archiveLinkCopyError(model: model)
        .onAppear {
            model.showingThumbnails = thumbnailsVisible
            model.load(selection)
            published = model            // → the nav window publishes it to the scene while we are up
            DispatchQueue.main.async { model.leftController.focus() }
        }
        .onDisappear { published = nil; nav.endFileOnView(by: model) }
        .onChange(of: model.showingThumbnails) { _, visible in thumbnailsVisible = visible }
        // ↑/↓ browse the underlying file list: move the nav selection, then re-load the preview to match. After
        // ⇧↑/⇧↓ it opens on the row just added (the cursor), not on the run's first file.
        .onChange(of: nav.selection) { model.load(nav.documentSelection(), showing: nav.selectionCursorPath) }
        // The list marks the file shown here "on view" (W40.reader-selection-current).
        .onChange(of: model.currentFilePath, initial: true) { nav.noteFileOnView(model.currentFilePath, by: model) }
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
                Text(model.positionLabel).foregroundStyle(.primary)
            }
            Spacer()
            // ↑/↓ move up/down the file list (live preview follows the selection); with ⇧ they extend the selection
            // from its anchor, as in the list (W40.reader-selection-current). One button per direction reads ⇧ from the
            // event: SwiftUI hands ⇧↓ to the unmodified ↓ shortcut (measured in the VM), so a separate ⇧↓ shortcut
            // never fired. ⇧-clicking a chevron extends too.
            Button { browse(-1) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut(.previewPreviousFile)
                .help(ReaderCommand.previewPreviousFile.help)
            Button { browse(1) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut(.previewNextFile)
                .help(ReaderCommand.previewNextFile.help)
            // ←/→ cycle the page pairs of this document, then across a multi-file selection opened together.
            Button { model.previous() } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.previewPreviousPage)
                .disabled(!model.canGoPrevious)
                .help(ReaderCommand.previewPreviousPage.help)
            Button { model.next() } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.previewNextPage)
                .disabled(!model.canGoNext)
                .help(ReaderCommand.previewNextPage.help)
            // View ▸ Thumbnails and Contact Sheet (⌥⌘2 / ⌥⌘6) reach this sheet's published model too.
            PageViewButtons(model: model, idPrefix: "ar.preview").labelStyle(.iconOnly)
            // Rotate Left / Right are Document menu items (⌃⌘L / ⌃⌘R), which reach this sheet's published model.
            Button { model.rotateLeft() } label: { Image(systemName: "rotate.left") }
                .disabled(!model.canRotate)
                .help(ReaderCommand.rotateLeft.help)
                .accessibilityIdentifier("ar.preview.rotateLeft")
            Button { model.rotateRight() } label: { Image(systemName: "rotate.right") }
                .disabled(!model.canRotate)
                .help(ReaderCommand.rotateRight.help)
                .accessibilityIdentifier("ar.preview.rotateRight")
            // Neither copy button binds its key: ⌘C is Edit ▸ Copy, which reaches the sheet's panes through the
            // responder chain and leaves selectable embedded text its own copy (W48.reader-copy-shortcut), and
            // ⇧⌘C is Edit ▸ Copy Cleaned for Prose, which reaches this sheet's published model. This button bound
            // ⌥⌘C after that key had gone to Selection ▸ Copy Link(s) (W40.reader-commands-table).
            Button { model.copyPlainSelection() } label: { Image(systemName: "doc.on.doc") }
                .help(ReaderCommand.copyExact.help)
            Button { model.copySelection() } label: { Image(systemName: "doc.on.doc.fill") }
                .help(ReaderCommand.copyCleaned.help)
            Button("Open") { onOpenFull() }
                .keyboardShortcut(.open)
                .help("Open in the full document window (\(ReaderCommand.open.glyph))")
                .accessibilityIdentifier("ar.preview.open")
            Button(ReaderCommand.previewDone.title) { dismiss() }
                .keyboardShortcut(.previewDone)
                .help(ReaderCommand.previewDone.help)
                .accessibilityIdentifier("ar.preview.done")
        }
        .padding(10)
    }

    /// One row up or down the list; with ⇧ held, the selection grows or shrinks from its anchor instead.
    private func browse(_ delta: Int) {
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            nav.extendSelectionInList(delta)
        } else {
            nav.moveSelectionInList(delta)
        }
    }

    /// The prerendered bitmap of the image page shown, or a request still waiting for one.
    private var imagePlaceholder: PlaceholderRequest? {
        guard let path = model.currentFilePath else { return nil }
        let pageIndex = DocumentPagePairs.imagePageIndex(pair: model.pair)
        _ = prefetcher.generation   // re-read when a bitmap lands
        return PlaceholderRequest(key: PlaceholderRequest.key(path: path, pageIndex: pageIndex),
                                  image: prefetcher.image(path: path, pageIndex: pageIndex)?.image)
    }

    @ViewBuilder private var content: some View {
        if model.current == nil {
            ContentUnavailableView(model.loadError ?? "No document", systemImage: "doc.questionmark")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                if model.showingThumbnails, !model.showingAllPages {
                    PageThumbnailSidebar(model: model, pages: model.pageCounts, idPrefix: "ar.preview")
                    Divider()
                }
                if model.showingAllPages {
                    DocumentPageOverview(model: model, pages: model.pageCounts, idPrefix: "ar.preview") {
                        DispatchQueue.main.async { model.focusPane(model.focusedPane) }
                    }
                } else {
                    readingPanes
                }
            }
        }
    }

    private var readingPanes: some View {
        HStack(spacing: 0) {
            // `.id(pageIdentity)` — a fresh PDFView per displayed pair/document (DV-3). Needed for the
            // image pane in particular: `updateNSView`'s reuse check compares page text, which is nil
            // on every image page, so without this the pane keeps showing the previous scan.
            // The file's path is in the identity too: browsing with ↑/↓ reloads the model on pair 0 of
            // document 0 each time, so `pageIdentity` alone repeats, and a placeholder for the new file
            // must never land on a view still showing the old one.
            PDFPaneView(page: model.imagePage, controller: model.leftController, id: "ar.preview.imagePane",
                        placeholder: imagePlaceholder, turns: model.imageTurns)
                .id("\(model.currentFilePath ?? "")#\(model.pageIdentity)#\(model.imageTurns)")
                .frame(maxWidth: .infinity)
            Divider()
            if model.hasTextPage {
                PDFPaneView(page: model.textPage, controller: model.rightController, id: "ar.preview.textPane")
                    .id(model.pageIdentity)
                    .frame(maxWidth: .infinity)
            } else if let text = model.embeddedText {
                ExtractedTextPane(text: text, scale: model.textScale, controller: model.textController,
                                  id: "ar.preview.textPane")
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

/// Both viewer scenes report a refused copy without changing the clipboard.
extension View {
    func archiveLinkCopyError(model: DocumentViewerModel) -> some View {
        alert("Could Not Copy Archive Link", isPresented: Binding(
            get: { model.archiveLinkError != nil },
            set: { if !$0 { model.archiveLinkError = nil } }
        )) {
            Button("OK") { model.archiveLinkError = nil }
        } message: {
            Text(model.archiveLinkError ?? "")
        }
    }
}
