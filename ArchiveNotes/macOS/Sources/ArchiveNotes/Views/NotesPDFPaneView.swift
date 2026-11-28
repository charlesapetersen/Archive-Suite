import SwiftUI
import PDFKit
import Combine

/// Imperative handle to a preview PDF pane — zoom + multi-page scroll navigation, no persistence.
/// Stripped-down version of Reader's PDFPaneController for Notes preview use (W49.notes-preview-scroll).
@MainActor
final class NotesPDFPaneController: ObservableObject {
    weak var pdfView: PDFView?
    let initialPageIndex: Int
    @Published private(set) var currentPageIndex: Int = 0
    @Published private(set) var pageCount: Int = 0

    private var savedScale: CGFloat?
    private var isApplying = false

    init(initialPageIndex: Int = 0) {
        self.initialPageIndex = max(0, initialPageIndex)
    }

    /// Maps a 1-based durable-link page number onto a safe 0-based page index for `pageCount`.
    static func clampedPageIndex(oneBased page: Int?, pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return max(0, min(pageCount - 1, (page ?? 1) - 1))
    }

    var clampedInitialPageIndex: Int {
        guard pageCount > 0 else { return 0 }
        return max(0, min(pageCount - 1, initialPageIndex))
    }

    var canGoPrevious: Bool { currentPageIndex > 0 }
    var canGoNext: Bool { currentPageIndex + 1 < pageCount }
    var isOnInitialPage: Bool { currentPageIndex == clampedInitialPageIndex }

    func zoomIn()  { setScale(currentScale * 1.25) }
    func zoomOut() { setScale(currentScale / 1.25) }

    func fit() {
        guard let v = pdfView else { return }
        savedScale = nil
        isApplying = true; v.autoScales = true; isApplying = false
        scrollToPage(currentPageIndex, deferRetry: true)
    }

    func previousPage() {
        guard canGoPrevious else { return }
        goToPage(currentPageIndex - 1)
    }

    func nextPage() {
        guard canGoNext else { return }
        goToPage(currentPageIndex + 1)
    }

    func goToInitialPage() {
        goToPage(clampedInitialPageIndex)
    }

    func goToPage(_ index: Int) {
        guard let v = pdfView, let doc = v.document, doc.pageCount > 0 else { return }
        let clamped = max(0, min(doc.pageCount - 1, index))
        currentPageIndex = clamped
        scrollToPage(clamped, deferRetry: false)
    }

    func syncCurrentPage() {
        guard let v = pdfView, let doc = v.document, let page = v.currentPage else { return }
        let index = doc.index(for: page)
        if index != NSNotFound, index != currentPageIndex {
            currentPageIndex = index
        }
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
    }

    func documentDidLoad(_ doc: PDFDocument?) {
        pageCount = doc?.pageCount ?? 0
        let target = clampedInitialPageIndex
        currentPageIndex = target
        applyToView(targetPageIndex: target)
    }

    func applyToView(targetPageIndex: Int? = nil) {
        guard let v = pdfView else { return }
        isApplying = true
        if let s = savedScale { v.autoScales = false; v.scaleFactor = s } else { v.autoScales = true }
        isApplying = false
        scrollToPage(targetPageIndex ?? currentPageIndex, deferRetry: true)
    }

    private func scrollToPage(_ index: Int, deferRetry: Bool) {
        guard let v = pdfView, let doc = v.document, doc.pageCount > 0 else { return }
        let clamped = max(0, min(doc.pageCount - 1, index))
        guard let page = doc.page(at: clamped) else { return }
        let top = CGPoint(x: 0, y: page.bounds(for: v.displayBox).height)
        v.layoutDocumentView()
        v.go(to: PDFDestination(page: page, at: top))
        if deferRetry {
            DispatchQueue.main.async { [weak v] in
                guard let v, v.document?.page(at: clamped) === page else { return }
                v.go(to: PDFDestination(page: page, at: top))
            }
        }
    }
}

/// Displays a read-only PDF document in a PDFView, scrolled to the linked source page
/// with continuous scrolling for multi-page / merged PDFs (W49.notes-preview-scroll).
struct NotesPDFPaneView: NSViewRepresentable {
    let document: PDFDocument?
    let controller: NotesPDFPaneController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor final class Coordinator: NSObject {
        let controller: NotesPDFPaneController
        init(controller: NotesPDFPaneController) { self.controller = controller }
        @objc func scaleChanged(_ note: Notification) { controller.recordScale() }
        @objc func pageChanged(_ note: Notification) { controller.syncCurrentPage() }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .windowBackgroundColor
        controller.pdfView = view
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: view)
        loadDocument(into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.pdfView = view
        if view.document !== document { loadDocument(into: view) }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: nsView)
    }

    private func loadDocument(into view: PDFView) {
        view.clearSelection()
        let multiPage = (document?.pageCount ?? 0) > 1
        view.displayMode = multiPage ? .singlePageContinuous : .singlePage
        view.displaysPageBreaks = multiPage
        view.document = document
        view.layoutDocumentView()
        controller.documentDidLoad(document)
    }
}
