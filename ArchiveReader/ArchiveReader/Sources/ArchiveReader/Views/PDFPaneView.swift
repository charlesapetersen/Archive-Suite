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
/// page actually changes, so imperative zoom persists across SwiftUI re-renders. The user's zoom is
/// also carried across ↑/↓ cycling (DV-2): only the very first page fits; later pages keep the
/// current scale (or stay fitting if the user never zoomed).
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
        let isFirstPage = context.coordinator.shownPage == nil
        context.coordinator.shownPage = page

        // DV-2: preserve the user's zoom across cycling — capture it before swapping the document.
        let priorScale = view.scaleFactor
        let wasFitting = view.autoScales

        // DV-3: a selection left on the OUTGOING page wedges mouse selection once the document is
        // swapped in this reused PDFView (selection worked on first show, then died after cycling).
        // Clear it before the swap, and force a fresh layout pass after, so the new page is selectable.
        view.clearSelection()

        if let page, let copy = page.copy() as? PDFPage {
            let doc = PDFDocument()
            doc.insert(copy, at: 0)
            view.document = doc
        } else {
            view.document = nil
        }
        view.layoutDocumentView()   // rebuild the internal page view so text selection re-attaches

        // DV-2: first page fits; afterwards keep the user's zoom (a manual zoom carries over; if they
        // were still fitting, new pages keep fitting — either way the zoom level stays consistent).
        if isFirstPage || wasFitting {
            view.autoScales = true
        } else {
            view.autoScales = false
            view.scaleFactor = priorScale
        }
    }
}
