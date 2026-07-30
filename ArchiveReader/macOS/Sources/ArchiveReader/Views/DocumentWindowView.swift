import SwiftUI
import PDFKit
import AppKit

/// The document-view window: a two-up viewer — image page (left) / OCR text page (right) — with an
/// independent zoom per pane, a draggable splitter defaulting to ⅔ : ⅓ (reset per document), page
/// cycling with ↑/↓, intelligent copy (⌘C), and in-document find (⌘F).
struct DocumentWindowView: View {
    let selection: DocumentSelection?
    @StateObject private var model = DocumentViewerModel()

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
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .focusedSceneObject(model)   // so the Document menu commands act on this window
        .onAppear { fraction = defaultFraction; if let selection { model.load(selection) } }
        // DV-2: the split width + per-pane zoom now persist across ↑/↓ cycling — no per-document reset.
        .onChange(of: model.showingFind) { if model.showingFind { findFocused = true } }
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
                    PDFPaneView(page: model.imagePage, controller: model.leftController, id: "ar.doc.imagePane")
                        .id(model.pageIdentity)
                        .frame(width: leftW)
                        .overlay(focusBorder(.left))
                    splitterHandle(total: total)          // drag gesture lives ONLY here
                    if model.hasTextPage {
                        PDFPaneView(page: model.textPage, controller: model.rightController, id: "ar.doc.textPane")
                            .id(model.pageIdentity)
                            .frame(maxWidth: .infinity)
                            .overlay(focusBorder(.right))
                    } else if let text = model.embeddedText {
                        ScrollView {
                            Text(text)
                                .textSelection(.enabled)
                                .font(.body)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity)
                        .overlay(focusBorder(.right))
                        .accessibilityIdentifier("ar.doc.textPane")
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

    /// A thin accent outline on the pane that has keyboard focus, so it's clear which page ⌘↑/⌘↓
    /// (zoom) and ↑/↓ (scroll) act on. Switch focus with ⌘⌥← / ⌘⌥→.
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
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.previous() } label: { Label("Previous", systemImage: "chevron.up") }
                .disabled(!model.canGoPrevious)
                .help("Previous page in this segment (⌘⇧↑)")
            Button { model.next() } label: { Label("Next", systemImage: "chevron.down") }
                .disabled(!model.canGoNext)
                .help("Next page in this segment (⌘⇧↓)")

            Divider()

            Button { model.leftController.zoomOut() } label: { Label("Zoom Out Left", systemImage: "minus.magnifyingglass") }
                .help("Zoom out the image page")
            Button { model.leftController.zoomIn() } label: { Label("Zoom In Left", systemImage: "plus.magnifyingglass") }
                .help("Zoom in the image page")
            Button { model.leftController.fit() } label: { Label("Fit Left", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("Fit the image page to its pane")

            Divider()

            Button { model.rightController.zoomOut() } label: { Label("Zoom Out Right", systemImage: "minus.magnifyingglass") }
                .help("Zoom out the OCR text page")
            Button { model.rightController.zoomIn() } label: { Label("Zoom In Right", systemImage: "plus.magnifyingglass") }
                .help("Zoom in the OCR text page")
            Button { model.rightController.fit() } label: { Label("Fit Right", systemImage: "arrow.up.left.and.arrow.down.right") }
                .help("Fit the OCR text page to its pane")

            Divider()

            Button { model.copyPlainSelection() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the selected text exactly (⌘C)")
            Button { model.copySelection() } label: { Label("Copy Cleaned", systemImage: "doc.on.doc.fill") }
                .help("Copy the selected text cleaned for prose — joins lines, de-hyphenates (⌘⇧C)")
            Button { model.showingFind = true; findFocused = true } label: { Label("Find", systemImage: "magnifyingglass") }
                .help("Search for text in this document (⌘F)")
            Button { fraction = defaultFraction; model.leftController.fit(); model.rightController.fit() } label: {
                Label("Reset Layout", systemImage: "rectangle.split.2x1")
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
            .help("Reset the split and zoom to defaults (⌥⌘0)")
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.title).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(model.positionLabel).foregroundStyle(.secondary)
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
