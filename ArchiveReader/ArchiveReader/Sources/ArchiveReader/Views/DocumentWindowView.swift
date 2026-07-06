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
    @State private var findText = ""
    @FocusState private var findFocused: Bool
    @State private var didConfigureWindow = false

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
                    PDFPaneView(page: model.imagePage, controller: model.leftController)
                        .frame(width: leftW)
                        .overlay(focusBorder(.left))
                    splitterHandle(total: total)          // drag gesture lives ONLY here
                    if model.hasTextPage {
                        PDFPaneView(page: model.textPage, controller: model.rightController)
                            .frame(maxWidth: .infinity)
                            .overlay(focusBorder(.right))
                    } else {
                        ContentUnavailableView("No OCR text page", systemImage: "text.slash",
                                               description: Text("This document has a single page."))
                            .frame(maxWidth: .infinity)
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
    }

    private var findBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in document…", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .focused($findFocused)
                .onSubmit { model.find(findText) }
            Button("Find") { model.find(findText) }
            Button("Done") { model.showingFind = false; findText = "" }
            Spacer()
        }
        .padding(8)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.previous() } label: { Label("Previous", systemImage: "chevron.up") }
                .disabled(model.index <= 0)
                .help("Previous page in this segment (⌘⇧↑)")
            Button { model.next() } label: { Label("Next", systemImage: "chevron.down") }
                .disabled(model.index >= model.urls.count - 1)
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
        let name = NSWindow.FrameAutosaveName("ArchiveReaderDocumentWindow")
        let restored = window.setFrameUsingName(name)
        window.setFrameAutosaveName(name)
        if !restored, let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)   // first open → full screen
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
