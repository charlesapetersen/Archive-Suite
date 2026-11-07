import SwiftUI
import PDFKit
import AppKit
import Combine

/// The document-view window: a two-up viewer — image page (left) / OCR text page (right) — with an
/// independent zoom per pane, a draggable splitter defaulting to ⅔ : ⅓ (reset per document), page
/// cycling with ⌘⇧↑/⌘⇧↓, arrow-key panning, verbatim copy (⌘C, Edit ▸ Copy) and intelligent copy (⌥⌘C), and in-document find (⌘F).
struct DocumentWindowView: View {
    let selection: DocumentSelection?
    @StateObject private var model = DocumentViewerModel()
    @EnvironmentObject private var linkContext: ArchiveLinkContext
    @EnvironmentObject private var router: DeepLinkRouter

    @State private var fraction: CGFloat = 0.667   // left pane share; default ⅔
    @FocusState private var findFocused: Bool
    @State private var didConfigureWindow = false
    @State private var docWindow: NSWindow?

    private var defaultFraction: CGFloat { CGFloat(AppSettings.viewerSplitFraction) }
    private let handleWidth: CGFloat = 10
    private let minPane: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            if model.showingFind { findBar; Divider() }
            if let note = model.formatNote { formatBanner(note); Divider() }
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(WindowAccessor { configureWindow($0) })   // DV-1: open maximized, then remember size
        .archiveLinkCopyError(model: model)
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .focusedSceneObject(model)   // so the Document menu commands act on this window
        // W23.m4: publish the link target here too, so "Copy Archive Link to This Page" is ENABLED in
        // the document window — it used to require a focused NavigationModel this scene never has.
        .focusedSceneValue(\.archiveLinkContext, linkContext)
        // W40.fix-reader-menus-follow-window: the Tags menu acts on this window's open file.
        .focusedSceneValue(\.documentTagActions, DocumentTagActions(router: router, viewer: model))
        .sheet(isPresented: $model.showingTagEditor) { tagEditorSheet }
        .onChange(of: findFocused) { model.findFieldFocused = findFocused }
        .onReceive(linkContext.$target.combineLatest(linkContext.$jpegPartnerIndex)) { target, index in
            model.updateArchiveContext(target: target, index: index)
        }
        .onAppear {
            fraction = defaultFraction
            if let selection { model.load(selection) }
            // A deep link that cited a page opens straight on it (W23.m4 defect 3). Deferred first
            // responder: the pane's PDFView isn't in a window yet on the first `onAppear`.
            if let page = selection?.initialPage {
                model.goToPDFPage(page)
                DispatchQueue.main.async { model.focusPane(model.focusedPane) }
            }
        }
        // DV-2: the split width + per-pane zoom now persist across ↑/↓ cycling — no per-document reset.
        // W40.fix-reader-doc-find-focus: ⌘F left the caret in the pane. Setting focus in the same update
        // that inserts the find bar targets a field that isn't in the window yet, so it is deferred a turn;
        // and a pane's PDFView is an AppKit first responder SwiftUI's focus doesn't always take from, so it
        // is resigned first. The counter makes ⌘F refocus a bar that is already open; `showingFind` still
        // covers ⌘G / ⇧⌘G opening the bar.
        .onChange(of: model.findFocusRequest) { focusFindField() }
        .onChange(of: model.showingFind) { if model.showingFind { focusFindField() } }
        // DV-1: on close, the current window size becomes the default for the next viewer.
        .onDisappear { if let w = docWindow { AppSettings.setViewerWindowSize(w.frame.size) } }
    }

    @ViewBuilder private var content: some View {
        if model.current == nil {
            ContentUnavailableView(model.loadError ?? "No document",
                                   systemImage: "doc.questionmark",
                                   description: Text(model.loadError == nil ? "Select files in the navigation window." : ""))
        } else {
            GeometryReader { geo in
                let total = geo.size.width
                let leftW = max(minPane, min(total - minPane - handleWidth, fraction * total))
                HStack(spacing: 0) {
                    // `.id(pageIdentity)` gives each page a fresh PDFView (DV-3: a reused view loses text
                    // selection after the document is swapped). Zoom persists via the controller. The
                    // identity covers the page PAIR, not just the file, so stepping within an interleaved
                    // multi-page document rebuilds the panes too.
                    PDFPaneView(page: model.displayedImagePage, controller: model.leftController,
                                id: "ar.doc.imagePane", reference: model.imagePage)
                        .id(model.imagePaneIdentity)
                        .frame(width: leftW)
                        .overlay(focusBorder(.left))
                    splitterHandle(total: total)          // drag gesture lives ONLY here
                    if model.hasTextPage {
                        PDFPaneView(page: model.textPage, controller: model.rightController, id: "ar.doc.textPane")
                            .id(model.pageIdentity)
                            .frame(maxWidth: .infinity)
                            .overlay(focusBorder(.right))
                    } else if let text = model.embeddedText {
                        ExtractedTextPane(text: text, scale: model.textScale, controller: model.textController,
                                          find: model.extractedTextFind, id: "ar.doc.textPane")
                            .overlay(focusBorder(.right))
                    } else {
                        ContentUnavailableView("No OCR text page", systemImage: "text.slash",
                                               description: Text(model.pairCount > 1
                                                                 ? "This scan has no OCR text page."
                                                                 : "This document has a single page."))
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("ar.doc.noText")
                    }
                }
                .coordinateSpace(name: "split")
            }
        }
    }

    /// A thin accent outline on the pane that has keyboard focus, so it's clear which page ⌘+/⌘−
    /// (zoom; also ⌘↑/⌘↓) and ↑/↓ (scroll) act on. Switch focus with ⌘⌥← / ⌘⌥→.
    private func focusBorder(_ pane: DocumentViewerModel.Pane) -> some View {
        Rectangle()
            .strokeBorder(model.focusedPane == pane ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2)
            .allowsHitTesting(false)
    }

    private func splitterHandle(total: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .separatorColor))
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: .tertiaryLabelColor))
                .frame(width: 3, height: 34)
        }
        .frame(width: handleWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("split"))
                .onChanged { g in fraction = min(0.85, max(0.15, g.location.x / max(total, 1))) }
                .onEnded { _ in AppSettings.setViewerSplitFraction(Double(fraction)) }   // DV-2: last drag = next default
        )
    }

    /// Slim warning strip shown above the panes when the document is image-only (no OCR text layer).
    private func formatBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ReaderColors.warning)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .accessibilityIdentifier("ar.doc.formatBanner")
    }

    /// ⌘F find bar: searches the open PDF(s) — every document currently open in the viewer, across both
    /// panes — highlights all matches, and steps through them with ⌃/⌄ (⌘G / ⇧⌘G). "N of M" is the global
    /// position across all open documents.
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in open document(s)…", text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($findFocused)
                .onSubmit { model.findNext() }
                .accessibilityIdentifier("ar.doc.findField")
            Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G)")
                .disabled(model.findQuery.isEmpty)
                .accessibilityIdentifier("ar.doc.findPrev")
            Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G)")
                .disabled(model.findQuery.isEmpty)
                .accessibilityIdentifier("ar.doc.findNext")
            Text(model.findStatusText)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(minWidth: 72, alignment: .leading)
                .accessibilityIdentifier("ar.doc.findCount")
            Spacer()
            Button("Done") { model.endFind() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(8)
    }

    private func focusFindField() {
        DispatchQueue.main.async {
            docWindow?.makeFirstResponder(nil)
            findFocused = true
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.previous() } label: { Label("Previous", systemImage: "chevron.up") }
                .disabled(!model.canGoPrevious)
                .help("Previous page in this segment (⌘⇧↑)")
            Button { model.next() } label: { Label("Next", systemImage: "chevron.down") }
                .disabled(!model.canGoNext)
                .help("Next page in this segment (⌘⇧↓)")

            Divider()

            imageSourceSwitch

            Divider()

            // W40.fix-reader-doc-toolbar: the owner could not tell the two zoom pairs apart (both were
            // magnifying glasses) and saw the text pair and the per-pane Fit arrows do nothing — the text pair
            // never reached a one-page PDF's text before W40.fix-reader-text-zoom, and Fit has no visible effect
            // on a page already fitted. The text pair now shows text-size glyphs, and the two Fit buttons are
            // gone: Reset Zoom did what both did, and ⌘0 still fits the focused pane alone.
            Button { model.leftController.zoomOut() } label: { Label("Zoom Out Image", systemImage: "minus.magnifyingglass") }
                .help("Zoom out the image page, on the left")
                .accessibilityIdentifier("ar.doc.imageZoomOut")
            Button { model.leftController.zoomIn() } label: { Label("Zoom In Image", systemImage: "plus.magnifyingglass") }
                .help("Zoom in the image page, on the left")
                .accessibilityIdentifier("ar.doc.imageZoomIn")

            Divider()

            Button { model.zoomTextOut() } label: { Label("Smaller Text", systemImage: "textformat.size.smaller") }
                .help("Make the OCR text on the right smaller")
                .accessibilityIdentifier("ar.doc.textZoomOut")
            Button { model.zoomTextIn() } label: { Label("Larger Text", systemImage: "textformat.size.larger") }
                .help("Make the OCR text on the right larger")
                .accessibilityIdentifier("ar.doc.textZoomIn")

            Divider()

            Button { model.copyPlainSelection() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the selected text exactly (⌘C)")
            Button { model.copySelection() } label: { Label("Copy Cleaned", systemImage: "doc.on.doc.fill") }
                .help("Copy the selected text cleaned for prose — joins lines, de-hyphenates (⌥⌘C)")
            Button { model.beginFind() } label: { Label("Find", systemImage: "magnifyingglass") }
                .help("Search for text in this document (⌘F)")
            // The tooltip sits on a wrapper, like the image switch's: a disabled button's own is not shown.
            HStack(spacing: 0) {
                Button { fraction = defaultFraction; model.resetZoom() } label: {
                    Label("Reset Zoom", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(model.zoomIsDefault)
                .accessibilityIdentifier("ar.doc.resetZoom")
            }
            .contentShape(Rectangle())
            .help(model.zoomIsDefault
                  ? "Both pages already fit their panes, with the text at its normal size"
                  : "Fit both pages to their panes and the text to its normal size (⌥⌘0; ⌘0 fits the focused page alone)")
        }
    }

    /// W40.fix-reader-jpeg-toolbar: the PDF / JPEG switch for the image pane, which the owner could not
    /// find in the Document menu alone. It always shows which image is on screen; with no JPEG original it
    /// stays on PDF, disabled, and its tooltip says why.
    ///
    /// W40.fix-reader-jpeg-switch-missing: on macOS 27 a disabled segmented control in the toolbar does not
    /// look disabled, so the owner saw JPEG offered on a file with no JPEG original (the pairing was right).
    /// Without a partner the switch is now a greyed "PDF only" that offers no JPEG side at all.
    private var imageSourceSwitch: some View {
        // The tooltip sits on a wrapper: a disabled control's own tooltip is not shown, and the reason
        // matters most exactly when the switch is disabled.
        HStack(spacing: 0) {
            if model.hasJPEGPartner {
                Picker("Image", selection: Binding(
                    get: { model.imageSource },
                    set: { if $0 != model.imageSource { model.toggleImageSource() } }
                )) {
                    Text("PDF").tag(DocumentImageSource.pdf)
                    Text("JPEG").tag(DocumentImageSource.jpeg)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Image source")
                .accessibilityIdentifier("ar.doc.imageSource")
            } else {
                // Greyed by its own colour, not only by `.disabled`, which is what failed to show.
                Button {} label: { Text("PDF only").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(true)
                    .accessibilityLabel("Image source")
                    .accessibilityValue("PDF only")
                    .accessibilityHint(model.jpegUnavailableReason ?? "")
                    .accessibilityIdentifier("ar.doc.imageSource")
            }
        }
        .contentShape(Rectangle())
        .help(model.hasJPEGPartner
              ? (model.isShowingJPEG
                 ? "Showing the JPEG original. Switch to the PDF's image (⌥⌘J)"
                 : "Showing the PDF's image. Switch to the JPEG original (⌥⌘J)")
              : (model.jpegUnavailableReason ?? "No JPEG original for this file."))
    }

    /// The tag editor over this window, editing the open file through the navigation window's model.
    @ViewBuilder private var tagEditorSheet: some View {
        if let nav = router.nav, let path = model.tagEditorPath {
            TagEditorView(model: nav,
                          size: SheetSizing.fitted(TagEditorView.preferredSize, in: docWindow?.frame.size ?? .zero),
                          targetPaths: [path])
        } else {
            VStack(spacing: 12) {
                Text("Tags can be edited while the Archive Reader window is open.")
                Button("Done") { model.showingTagEditor = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.title).lineLimit(1).truncationMode(.middle)
            if let status = model.tagStatus {
                Text(status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("ar.doc.tagStatus")
            }
            Spacer()
            Text(model.positionLabel).foregroundStyle(.primary)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    /// DV-1: on first appearance, restore the saved window frame if one exists; otherwise open
    /// maximized to the screen. `setFrameAutosaveName` then remembers the user's size/position, so
    /// later opens reuse it. Runs once per window (guarded).
    private func configureWindow(_ window: NSWindow) {
        guard !didConfigureWindow else { return }
        didConfigureWindow = true
        docWindow = window   // kept so onDisappear can persist the final size (DV-1)
        // Target: the user's remembered size, else maximize (first ever open). The `> 2` guards skip a
        // redundant setFrame when the scene's `.defaultSize` already opened at the target — avoids the
        // "small window that jumps to full" flash.
        let vis = (window.screen ?? NSScreen.main)?.visibleFrame
        if let size = AppSettings.viewerWindowSize {
            if abs(window.frame.width - size.width) > 2 || abs(window.frame.height - size.height) > 2 {
                var frame = window.frame
                frame.size = size
                if let vis { frame.origin = CGPoint(x: vis.midX - size.width / 2, y: vis.midY - size.height / 2) }
                window.setFrame(frame, display: true)
            }
        } else if let vis, abs(window.frame.width - vis.width) > 2 || abs(window.frame.height - vis.height) > 2 {
            window.setFrame(vis, display: true)
        }
    }
}

/// Reaches the hosting `NSWindow` once the view is in the hierarchy, to apply AppKit-only window
/// configuration (frame autosave + first-run maximize) that SwiftUI's scene API doesn't expose.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window { onWindow(w) }   // in case the window attaches after makeNSView
    }
}
