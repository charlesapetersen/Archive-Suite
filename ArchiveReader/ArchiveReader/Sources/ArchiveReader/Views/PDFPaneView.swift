import SwiftUI
import PDFKit

/// Imperative handle to one pane's PDFView — for independent zoom and reading its text selection.
/// Read-only: the view never edits or writes the document.
///
/// The controller (not the PDFView) is the source of truth for zoom, so the level survives both
/// SwiftUI re-renders and the per-page PDFView rebuild used to keep text selectable (DV-3). The last
/// zoom is persisted per pane and becomes the default for the next viewer (DV-2).
@MainActor
final class PDFPaneController {
    weak var pdfView: PDFView?
    let key: String                    // "left" / "right" — persistence + default carry-over
    private var desiredScale: CGFloat?  // nil = fit-to-pane; else an explicit scale factor

    init(key: String) {
        self.key = key
        let saved = AppSettings.viewerZoom(key)
        desiredScale = saved > 0 ? CGFloat(saved) : nil
    }

    func zoomIn()  { setScale(baseScale * 1.25) }
    func zoomOut() { setScale(baseScale / 1.25) }
    func fit() {
        desiredScale = nil
        AppSettings.setViewerZoom(key, 0)
        applyToView()
    }

    private var baseScale: CGFloat { desiredScale ?? (pdfView?.scaleFactor ?? 1) }

    private func setScale(_ s: CGFloat) {
        guard let v = pdfView else { return }
        let clamped = max(v.minScaleFactor, min(v.maxScaleFactor, s))
        desiredScale = clamped
        AppSettings.setViewerZoom(key, Double(clamped))
        applyToView()
    }

    /// Apply the current zoom to the (possibly freshly-built) PDFView and pin the page's top edge to
    /// the top of the pane — reading starts at the top, so a zoom must not drift to the page center.
    func applyToView() {
        guard let v = pdfView else { return }
        if let s = desiredScale {
            v.autoScales = false
            v.scaleFactor = s
        } else {
            v.autoScales = true
        }
        scrollToTop()
    }

    /// Give this pane keyboard focus (so ↑/↓ scroll it and text selection lands here).
    func focus() {
        guard let v = pdfView else { return }
        v.window?.makeFirstResponder(v)
    }

    /// Scroll so the TOP-left of the (single) page sits at the top-left of the viewer. Lay the
    /// document view out first so the scroll uses the post-zoom geometry (else it anchors stale).
    private func scrollToTop() {
        guard let v = pdfView, let page = v.currentPage ?? v.document?.page(at: 0) else { return }
        v.layoutDocumentView()
        let top = page.bounds(for: v.displayBox).height   // PDF origin is bottom-left → y = height is the top
        v.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: top)))
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

/// Displays a single PDF page (read-only, selectable) in its own PDFView. The parent gives each page
/// a fresh view (via `.id`), because reusing one PDFView and swapping its document leaves text
/// selection wedged after cycling (DV-3) — a fresh view is exactly the known-good first-show state.
/// Zoom is restored from the controller so it still persists across pages (DV-2).
struct PDFPaneView: NSViewRepresentable {
    let page: PDFPage?
    let controller: PDFPaneController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        controller.pdfView = view
        loadPage(into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        // Keep the controller pointed at the live view, and (re)load if the page changed under a reused
        // view. With the parent's `.id(page)` this view is normally fresh per page, so this is a no-op
        // on the common path; it's a safety net for any reuse.
        controller.pdfView = view
        if view.document?.page(at: 0)?.string != page?.string { loadPage(into: view) }
    }

    /// Show a COPY of the page in a throwaway one-page document (a PDFPage can belong to only one
    /// document — copying avoids detaching it from the source), then restore the controller's zoom.
    private func loadPage(into view: PDFView) {
        view.clearSelection()
        if let page, let copy = page.copy() as? PDFPage {
            let doc = PDFDocument()
            doc.insert(copy, at: 0)
            view.document = doc
        } else {
            view.document = nil
        }
        view.layoutDocumentView()
        controller.applyToView()   // restore the persisted/current zoom + pin the page top
    }
}
