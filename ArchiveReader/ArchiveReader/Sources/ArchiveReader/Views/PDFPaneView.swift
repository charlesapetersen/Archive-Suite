import SwiftUI
import PDFKit

/// Imperative handle to one pane's PDFView — for independent zoom and reading its text selection.
/// Read-only: the view never edits or writes the document.
@MainActor
final class PDFPaneController {
    weak var pdfView: PDFView?

    func zoomIn()  { adjust(1.25) }
    func zoomOut() { adjust(1 / 1.25) }
    func fit()     { pdfView?.autoScales = true }

    /// Give this pane keyboard focus (so ↑/↓ scroll it and text selection lands here).
    func focus() {
        guard let v = pdfView else { return }
        v.window?.makeFirstResponder(v)
    }

    private func adjust(_ factor: CGFloat) {
        guard let v = pdfView else { return }
        v.autoScales = false
        v.scaleFactor = max(v.minScaleFactor, min(v.maxScaleFactor, v.scaleFactor * factor))
        scrollToTop()   // anchor zoom to the TOP of the page (reading starts at the top third), not center
    }

    /// Scroll so the top-left of the (single) page sits at the top-left of the viewer.
    private func scrollToTop() {
        guard let v = pdfView, let page = v.document?.page(at: 0) else { return }
        let topLeft = CGPoint(x: 0, y: page.bounds(for: v.displayBox).height)
        v.go(to: PDFDestination(page: page, at: topLeft))
    }

    /// The current text selection, cleaned for prose copy (nil if nothing is selected here).
    func cleanedSelection(_ options: CopyTextOptions) -> String? {
        guard let s = pdfView?.currentSelection?.string, !s.isEmpty else { return nil }
        return CopyTextCleaner.clean(s, options: options)
    }

    /// The current text selection, raw/verbatim (nil if nothing is selected here) — for plain copy.
    func plainSelection() -> String? {
        guard let s = pdfView?.currentSelection?.string, !s.isEmpty else { return nil }
        return s
    }

    func findAndSelect(_ query: String) {
        guard let v = pdfView, let doc = v.document, !query.isEmpty else { return }
        if let match = doc.findString(query, withOptions: [.caseInsensitive]).first {
            v.setCurrentSelection(match, animate: true)
            v.scrollSelectionToVisible(nil)
        }
    }
}

/// Displays a single PDF page (read-only, selectable) in its own PDFView. Rebuilds only when the
/// page actually changes, so imperative zoom persists across SwiftUI re-renders; a new page resets
/// to fit (the per-document default).
struct PDFPaneView: NSViewRepresentable {
    let page: PDFPage?
    let controller: PDFPaneController

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var shownPage: PDFPage? }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        controller.pdfView = view
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.shownPage !== page else { return }   // only rebuild on page change
        context.coordinator.shownPage = page
        if let page, let copy = page.copy() as? PDFPage {
            let doc = PDFDocument()
            doc.insert(copy, at: 0)
            view.document = doc
        } else {
            view.document = nil
        }
        view.autoScales = true   // reset to fit for the new document (the per-document default)
    }
}
