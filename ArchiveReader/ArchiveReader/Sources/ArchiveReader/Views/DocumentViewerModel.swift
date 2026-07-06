import SwiftUI
import PDFKit

/// Drives the document window: the selected files, the current document, and page cycling.
/// Loads one document at a time (never materializes the whole selection).
@MainActor
final class DocumentViewerModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published var index = 0 { didSet { if index != oldValue { loadCurrent() } } }
    @Published private(set) var current: PDFDocument?
    @Published private(set) var loadError: String?
    @Published var showingFind = false   // driven by the toolbar and the Document menu

    let leftController = PDFPaneController()   // image page (page 0)
    let rightController = PDFPaneController()  // OCR text page (page 1)

    /// Which pane keyboard focus / zoom acts on. ⌘↑/⌘↓ zoom this pane; ⌘⌥←/→ switch it.
    enum Pane: Sendable { case left, right }
    @Published var focusedPane: Pane = .left

    func load(_ selection: DocumentSelection) {
        urls = selection.filePaths.map { URL(fileURLWithPath: $0) }
        index = 0
        focusedPane = .left
        loadCurrent()
    }

    /// Move to the previous / next document within the current segment (the opened run/selection).
    func next()     { if index < urls.count - 1 { index += 1 } }
    func previous() { if index > 0 { index -= 1 } }

    // MARK: Pane focus + focused-pane zoom (keyboard-driven)

    private func controller(_ p: Pane) -> PDFPaneController { p == .left ? leftController : rightController }

    /// Move keyboard focus to a pane (so ↑/↓ scroll it and ⌘↑/⌘↓ zoom it).
    func focusPane(_ p: Pane) { focusedPane = p; controller(p).focus() }
    func zoomFocusedIn()  { controller(focusedPane).zoomIn() }
    func zoomFocusedOut() { controller(focusedPane).zoomOut() }
    func fitFocused()     { controller(focusedPane).fit() }

    var title: String { urls.indices.contains(index) ? urls[index].lastPathComponent : "Document View" }
    var positionLabel: String { urls.isEmpty ? "" : "\(index + 1) of \(urls.count)" }

    /// Left pane = the image page (page 0). Present for any non-empty PDF.
    var imagePage: PDFPage? { current?.page(at: 0) }
    /// Right pane = the OCR text page (page 1) when the document has one.
    var textPage: PDFPage? {
        guard let doc = current, doc.pageCount > 1 else { return nil }
        return doc.page(at: 1)
    }
    var hasTextPage: Bool { textPage != nil }

    /// Intelligent copy (prose-cleaned) from whichever pane holds the selection — ⌘⇧C.
    func copySelection() {
        let opts = AppSettings.copyOptions
        let text = rightController.cleanedSelection(opts) ?? leftController.cleanedSelection(opts)
        copyToPasteboard(text)
    }

    /// Plain/direct copy — the raw selected text, exactly as PDFKit reports it (no cleaning) — ⌘C.
    func copyPlainSelection() {
        let text = rightController.plainSelection() ?? leftController.plainSelection()
        copyToPasteboard(text)
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func find(_ query: String) {
        // Search the text pane first (that is where OCR text lives), then the image pane.
        rightController.findAndSelect(query)
        leftController.findAndSelect(query)
    }

    private func loadCurrent() {
        guard urls.indices.contains(index) else { current = nil; loadError = nil; return }
        let url = urls[index]
        if let doc = PDFDocument(url: url) {
            current = doc
            loadError = doc.pageCount == 0 ? "“\(url.lastPathComponent)” has no pages." : nil
        } else {
            current = nil
            loadError = "Could not open “\(url.lastPathComponent)” (missing, corrupt, or not a PDF)."
        }
    }
}
