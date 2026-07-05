import SwiftUI
import PDFKit

/// The document-view window: a two-up viewer — image page (left) / OCR text page (right) — with an
/// independent zoom per pane, a draggable splitter defaulting to ⅔ : ⅓ (reset per document), page
/// cycling with ↑/↓, intelligent copy (⌘C), and in-document find (⌘F).
struct DocumentWindowView: View {
    let selection: DocumentSelection?
    @StateObject private var model = DocumentViewerModel()

    @State private var fraction: CGFloat = 0.667   // left pane share; default ⅔
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    private var defaultFraction: CGFloat { CGFloat(AppSettings.viewerSplitFraction) }
    private let handleWidth: CGFloat = 10
    private let minPane: CGFloat = 140

    var body: some View {
        VStack(spacing: 0) {
            if model.showingFind { findBar; Divider() }
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .focusedSceneObject(model)   // so the Document menu commands act on this window
        .onAppear { fraction = defaultFraction; if let selection { model.load(selection) } }
        .onChange(of: model.index) { fraction = defaultFraction }   // reset layout per document
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
                    splitterHandle(total: total)          // drag gesture lives ONLY here
                    if model.hasTextPage {
                        PDFPaneView(page: model.textPage, controller: model.rightController)
                            .frame(maxWidth: .infinity)
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
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(model.index <= 0)
                .help("Go to the previous document (↑)")
            Button { model.next() } label: { Label("Next", systemImage: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(model.index >= model.urls.count - 1)
                .help("Go to the next document (↓)")

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

            Button { model.copySelection() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the selected text, cleaned for prose (⌘C)")
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
}
