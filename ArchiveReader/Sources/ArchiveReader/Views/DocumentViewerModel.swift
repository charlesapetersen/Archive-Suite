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

    func load(_ selection: DocumentSelection) {
        urls = selection.filePaths.map { URL(fileURLWithPath: $0) }
        index = 0
        loadCurrent()
    }

    func next()     { if index < urls.count - 1 { index += 1 } }
    func previous() { if index > 0 { index -= 1 } }

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

    /// Intelligent copy from whichever pane holds the selection.
    func copySelection() {
        let opts = AppSettings.copyOptions
        let text = rightController.cleanedSelection(opts) ?? leftController.cleanedSelection(opts)
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
