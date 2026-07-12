import SwiftUI
import PDFKit

/// Imperative handle to a preview PDF pane — zoom + scroll, no persistence.
/// Stripped-down version of Reader's PDFPaneController for Notes preview use.
@MainActor
final class NotesPDFPaneController {
    weak var pdfView: PDFView?
    private var savedScale: CGFloat?
    private var isApplying = false

    func zoomIn()  { setScale(currentScale * 1.25) }
    func zoomOut() { setScale(currentScale / 1.25) }

    func fit() {
        guard let v = pdfView else { return }
        savedScale = nil
        isApplying = true; v.autoScales = true; isApplying = false
        scrollToTop()
    }

    private var currentScale: CGFloat { pdfView?.scaleFactor ?? savedScale ?? 1 }

    private func setScale(_ s: CGFloat) {
        guard let v = pdfView else { return }
        v.autoScales = false
        v.scaleFactor = max(v.minScaleFactor, min(v.maxScaleFactor, s))
    }

    func recordScale() {
        guard let v = pdfView, !isApplying, v.autoScales == false else { return }
        savedScale = v.scaleFactor
        scrollToTop()
    }

    func applyToView() {
        guard let v = pdfView else { return }
        isApplying = true
        if let s = savedScale { v.autoScales = false; v.scaleFactor = s } else { v.autoScales = true }
        isApplying = false
        scrollToTop()
    }

    private func scrollToTop() {
        guard let v = pdfView, let page = v.document?.page(at: 0) else { return }
        let top = CGPoint(x: 0, y: page.bounds(for: v.displayBox).height)
        v.layoutDocumentView()
        v.go(to: PDFDestination(page: page, at: top))
        DispatchQueue.main.async { [weak v] in
            guard let v, v.document?.page(at: 0) === page else { return }
            v.go(to: PDFDestination(page: page, at: top))
        }
    }
}

/// Displays a single PDF page (read-only) in a PDFView.
/// Adapted from Reader's PDFPaneView for Notes preview use.
struct NotesPDFPaneView: NSViewRepresentable {
    let page: PDFPage?
    let controller: NotesPDFPaneController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor final class Coordinator: NSObject {
        let controller: NotesPDFPaneController
        init(controller: NotesPDFPaneController) { self.controller = controller }
        @objc func scaleChanged(_ note: Notification) { controller.recordScale() }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        controller.pdfView = view
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: view)
        loadPage(into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.pdfView = view
        if view.document?.page(at: 0)?.string != page?.string { loadPage(into: view) }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: nsView)
    }

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
        controller.applyToView()
    }
}
