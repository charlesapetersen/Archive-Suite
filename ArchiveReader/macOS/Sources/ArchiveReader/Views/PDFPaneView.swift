import SwiftUI
import PDFKit

/// Imperative handle to one pane's PDFView — for independent zoom and reading its text selection.
/// Read-only: the view never edits or writes the document.
///
/// Zoom lives on the controller (not the transient PDFView) so it survives both SwiftUI re-renders and
/// the per-page PDFView rebuild that keeps text selectable (DV-3). The controller learns of EVERY zoom
/// — toolbar, keyboard, AND trackpad pinch — by observing `PDFViewScaleChanged`, persists it per pane,
/// and reapplies it to each fresh page, so the level carries across cycling and becomes the next
/// viewer's default (DV-2). Each zoom also pins the page's top edge to the top of the pane (DV-2b).
@MainActor
final class PDFPaneController {
    weak var pdfView: PDFView?
    let key: String                    // "left" / "right" — persistence + default carry-over
    private let persists: Bool         // false → fit-to-pane default, no UserDefaults writes (preview mode)
    private var savedScale: CGFloat?   // nil = fit-to-pane; else an explicit scale factor
    private var isApplying = false     // true while WE set the scale, so we don't re-record it

    init(key: String, persists: Bool = true) {
        self.key = key
        self.persists = persists
        if persists {
            let saved = AppSettings.viewerZoom(key)
            savedScale = saved > 0 ? CGFloat(saved) : nil
        }
    }

    func zoomIn()  { setScale(currentScale * 1.25) }
    func zoomOut() { setScale(currentScale / 1.25) }
    func fit() {
        guard let v = pdfView else { return }
        savedScale = nil
        if persists { AppSettings.setViewerZoom(key, 0) }
        isApplying = true; v.autoScales = true; isApplying = false
        scrollToTop()
    }

    private var currentScale: CGFloat { pdfView?.scaleFactor ?? savedScale ?? 1 }

    private func setScale(_ s: CGFloat) {
        guard let v = pdfView else { return }
        v.autoScales = false
        v.scaleFactor = max(v.minScaleFactor, min(v.maxScaleFactor, s))   // fires PDFViewScaleChanged → recorded
    }

    /// Fired on every `PDFViewScaleChanged` (pinch, toolbar, keyboard). Persists the user's zoom so it
    /// survives cycling and becomes the default, and re-pins the page top. Ignores our own programmatic
    /// changes (`isApplying`) and the auto-fit recomputes (`autoScales`).
    func recordScale() {
        guard let v = pdfView, !isApplying, v.autoScales == false else { return }
        savedScale = v.scaleFactor
        if persists { AppSettings.setViewerZoom(key, Double(v.scaleFactor)) }
        #if DEBUG
        v.setAccessibilityValue(String(format: "%.4f", v.scaleFactor))
        #endif
        scrollToTop()
    }

    /// Apply the saved zoom to a freshly-built view + pin the top. Bracketed by `isApplying` so the
    /// resulting scale-change notification isn't mistaken for a user zoom.
    func applyToView() {
        guard let v = pdfView else { return }
        isApplying = true
        if let s = savedScale { v.autoScales = false; v.scaleFactor = s } else { v.autoScales = true }
        isApplying = false
        #if DEBUG
        v.setAccessibilityValue(String(format: "%.4f", v.scaleFactor))
        #endif
        scrollToTop()
    }

    /// Give this pane keyboard focus (so ↑/↓ scroll it and text selection lands here).
    func focus() { pdfView?.window?.makeFirstResponder(pdfView) }

    /// Pin the TOP-left of the (single) page to the top-left of the viewer. Lay out first (so the scroll
    /// uses post-zoom geometry) and repeat on the next runloop (the zoom's relayout lands after this
    /// call, so a single synchronous scroll anchors stale — the deferred one corrects it).
    private func scrollToTop() {
        guard let v = pdfView, let page = v.document?.page(at: 0) else { return }
        let top = CGPoint(x: 0, y: page.bounds(for: v.displayBox).height)   // PDF origin bottom-left → y=height is the top
        v.layoutDocumentView()
        v.go(to: PDFDestination(page: page, at: top))
        DispatchQueue.main.async { [weak v] in
            guard let v, v.document?.page(at: 0) === page else { return }
            v.go(to: PDFDestination(page: page, at: top))
        }
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

/// Displays a single PDF page (read-only, selectable) in its own PDFView. The parent gives each page a
/// fresh view (via `.id`), because reusing one PDFView and swapping its document leaves text selection
/// wedged after cycling (DV-3). Zoom is restored from the controller so it still persists (DV-2).
struct PDFPaneView: NSViewRepresentable {
    let page: PDFPage?
    let controller: PDFPaneController
    var id: String = ""

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor final class Coordinator: NSObject {
        let controller: PDFPaneController
        init(controller: PDFPaneController) { self.controller = controller }
        @objc func scaleChanged(_ note: Notification) { controller.recordScale() }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        controller.pdfView = view
        if !id.isEmpty { view.setAccessibilityIdentifier(id) }
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: view)
        loadPage(into: view)
        #if DEBUG
        view.setAccessibilityValue(String(format: "%.4f", view.scaleFactor))
        #endif
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.pdfView = view
        if view.document?.page(at: 0)?.string != page?.string { loadPage(into: view) }   // safety net for any reuse
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: nsView)
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
