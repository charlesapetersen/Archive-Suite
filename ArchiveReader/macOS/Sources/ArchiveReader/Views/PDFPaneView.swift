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
    private var savedScale: CGFloat?   // nil = fit-to-pane; else an explicit scale factor, in reference-page units
    /// The shown page's scale factor per unit of `savedScale`: 1 for a PDF page, and the PDF image page's width
    /// over the JPEG's for a JPEG original, whose page is sized in pixels rather than the PDF's points. Keeping
    /// the zoom in the PDF page's units is what makes the PDF / JPEG switch keep the on-screen size
    /// (W40.fix-reader-jpeg-keep-view), and leaves the persisted zoom meaning the same for either image.
    private var scaleUnit: CGFloat = 1
    /// The region on screen when the PDF / JPEG switch was used, reapplied to the other image's fresh view.
    private(set) var pendingViewport: Viewport?
    private var isApplying = false     // true while WE set the scale, so we don't re-record it
    private var findQuery = ""         // active find query to highlight on this pane ("" = none)
    private var findCurrentIndex: Int? // which match on THIS pane is the current selection; nil = highlight-only
    /// Edit ▸ Copy (⌘C) as this pane's `copy:` answers it — the viewer's verbatim copy from whichever pane
    /// holds the selection, and whether there is one to copy. Set by `DocumentViewerModel`; nil leaves
    /// PDFKit's own `copy:` in place. See `ReaderPDFView.copy(_:)`.
    var copySelection: (() -> Void)?
    var canCopySelection: (() -> Bool)?
    /// A zoom key reaching this pane (`true` = in), forwarded to the viewer so it zooms the FOCUSED pane —
    /// which may be the extracted-text pane, not a PDFView at all. Set by `DocumentViewerModel`.
    var zoomFocused: ((Bool) -> Void)?

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
        pendingViewport = nil
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
        savedScale = v.scaleFactor / scaleUnit
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
        // The zoom limits move with the unit too, so a JPEG measured in pixels can reach the same sizes.
        v.minScaleFactor = Self.defaultScaleRange.lowerBound * scaleUnit
        v.maxScaleFactor = Self.defaultScaleRange.upperBound * scaleUnit
        if let s = savedScale { v.autoScales = false; v.scaleFactor = s * scaleUnit } else { v.autoScales = true }
        isApplying = false
        #if DEBUG
        v.setAccessibilityValue(String(format: "%.4f", v.scaleFactor))
        #endif
        if let viewport = pendingViewport, savedScale != nil { restore(viewport) } else { scrollToTop() }
        pendingViewport = nil
        applyFind()   // re-highlight matches (+ re-select the current one) on the freshly-built view
    }

    /// Show a COPY of `page` in a throwaway one-page document (a PDFPage can belong to only one document —
    /// copying avoids detaching it from the source), then restore the zoom. `reference` is the page the
    /// saved zoom is measured against (the PDF's image page for the left pane); nil means `page` itself.
    func show(_ page: PDFPage?, reference: PDFPage?, in view: PDFView) {
        view.clearSelection()
        if let page, let copy = page.copy() as? PDFPage {
            let doc = PDFDocument()
            doc.insert(copy, at: 0)
            view.document = doc
        } else {
            view.document = nil
        }
        scaleUnit = Self.scaleUnit(showing: page, reference: reference, box: view.displayBox)
        view.layoutDocumentView()
        applyToView()   // restore the persisted/current zoom + pin the page top (or the switched-from region)
    }

    /// Note the region on screen, as fractions of the shown page, so the next page shown in this pane opens
    /// on the same place: called just before the PDF / JPEG switch swaps the image. Fit-to-pane shows the
    /// whole page, so there is nothing to carry and the new image simply opens fitted.
    func captureViewport() {
        pendingViewport = nil
        guard let v = pdfView, savedScale != nil, !v.autoScales, let page = v.document?.page(at: 0),
              v.bounds.width > 0, v.bounds.height > 0 else { return }
        let centre = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: page)
        pendingViewport = Viewport(centre: Self.displayedFraction(of: centre, on: page, box: v.displayBox),
                                   size: v.bounds.size)
    }

    /// Put the noted centre back in the middle of the pane at the new page's zoom. `go(to:)` places its point
    /// at the top-left, so step back half a pane; repeated on the next runloop like `scrollToTop`.
    private func restore(_ viewport: Viewport) {
        guard let v = pdfView, let page = v.document?.page(at: 0) else { return }
        let shown = Self.displayedSize(page, box: v.displayBox)
        let scale = v.scaleFactor
        guard shown.width > 0, shown.height > 0, scale > 0 else { scrollToTop(); return }
        let topLeft = CGPoint(x: min(max(viewport.centre.x - viewport.size.width / 2 / (shown.width * scale), 0), 1),
                              y: min(max(viewport.centre.y - viewport.size.height / 2 / (shown.height * scale), 0), 1))
        let point = Self.pagePoint(fromDisplayed: topLeft, on: page, box: v.displayBox)
        v.layoutDocumentView()
        v.go(to: PDFDestination(page: page, at: point))
        DispatchQueue.main.async { [weak self, weak v] in
            guard let v, v.document?.page(at: 0) === page else { return }
            self?.reassertScale(on: v)
            v.go(to: PDFDestination(page: page, at: point))
        }
    }

    /// A view given its zoom before it had its real size is rescaled by PDFKit, silently (no
    /// `PDFViewScaleChanged`), when its scrollers settle: about 2% with always-shown scrollers, as on a Mac
    /// with a mouse. Put the saved zoom back once the layout has landed, so the page keeps its exact size.
    private func reassertScale(on v: PDFView) {
        guard let s = savedScale, !v.autoScales else { return }
        let want = max(v.minScaleFactor, min(v.maxScaleFactor, s * scaleUnit))
        guard abs(v.scaleFactor - want) > want * 1e-6 else { return }
        isApplying = true
        v.scaleFactor = want
        isApplying = false
        v.layoutDocumentView()
    }

    /// A pane's visible region: its centre as fractions of the page as displayed (x from the left, y from the
    /// top, rotation applied), and the pane's size in view points.
    struct Viewport: Equatable {
        var centre: CGPoint
        var size: CGSize
    }

    /// PDFKit's own zoom limits, read once from a fresh view.
    static let defaultScaleRange: ClosedRange<CGFloat> = {
        let v = PDFView()
        return v.minScaleFactor...max(v.minScaleFactor, v.maxScaleFactor)
    }()

    static func scaleUnit(showing page: PDFPage?, reference: PDFPage?, box: PDFDisplayBox) -> CGFloat {
        guard let page, let reference, page !== reference else { return 1 }
        let shown = displayedSize(page, box: box).width, ref = displayedSize(reference, box: box).width
        return shown > 0 && ref > 0 ? ref / shown : 1
    }

    static func displayedSize(_ page: PDFPage, box: PDFDisplayBox) -> CGSize {
        let size = page.bounds(for: box).size
        return quarterTurns(page) % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// A page-space point (origin bottom-left, y up, unrotated) as fractions of the page as displayed.
    /// `/Rotate` turns the page clockwise for display.
    static func displayedFraction(of point: CGPoint, on page: PDFPage, box: PDFDisplayBox) -> CGPoint {
        let b = page.bounds(for: box)
        guard b.width > 0, b.height > 0 else { return .zero }
        let x = min(max((point.x - b.minX) / b.width, 0), 1), y = min(max((point.y - b.minY) / b.height, 0), 1)
        switch quarterTurns(page) {
        case 1: return CGPoint(x: y, y: x)
        case 2: return CGPoint(x: 1 - x, y: y)
        case 3: return CGPoint(x: 1 - y, y: 1 - x)
        default: return CGPoint(x: x, y: 1 - y)
        }
    }

    /// The inverse of `displayedFraction`.
    static func pagePoint(fromDisplayed f: CGPoint, on page: PDFPage, box: PDFDisplayBox) -> CGPoint {
        let b = page.bounds(for: box)
        let x: CGFloat, y: CGFloat
        switch quarterTurns(page) {
        case 1: (x, y) = (f.y, f.x)
        case 2: (x, y) = (1 - f.x, f.y)
        case 3: (x, y) = (1 - f.y, 1 - f.x)
        default: (x, y) = (f.x, 1 - f.y)
        }
        return CGPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
    }

    private static func quarterTurns(_ page: PDFPage) -> Int { ((page.rotation / 90) % 4 + 4) % 4 }

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
        DispatchQueue.main.async { [weak self, weak v] in
            guard let v, v.document?.page(at: 0) === page else { return }
            self?.reassertScale(on: v)
            v.go(to: PDFDestination(page: page, at: top))
        }
    }

    /// The current text selection, cleaned for prose copy (nil if nothing is selected here).
    func cleanedSelection(_ options: CopyTextOptions) -> String? {
        guard let sel = pdfView?.currentSelection, let s = sel.string, !s.isEmpty else { return nil }
        guard options.paragraphFromLayout else { return CopyTextCleaner.clean(s, options: options) }
        return CopyTextCleaner.clean(s, lines: Self.layoutLines(sel), options: options)
    }

    /// The selection's lines with their boxes on the page, for finding the paragraph breaks the OCR left
    /// unmarked. Reads geometry only; the document is not touched.
    static func layoutLines(_ selection: PDFSelection) -> [CopyTextLine] {
        selection.selectionsByLine().compactMap { line in
            guard let page = line.pages.first, let text = line.string else { return nil }
            return CopyTextLine(text: text, box: line.bounds(for: page),
                                page: page.document?.index(for: page) ?? 0)
        }
    }

    /// The current text selection, raw/verbatim (nil if nothing is selected here) — for plain copy.
    func plainSelection() -> String? {
        guard let s = pdfView?.currentSelection?.string, !s.isEmpty else { return nil }
        return s
    }

    /// Set this pane's find target: the query to highlight, and which of this pane's matches (if any) is
    /// the current selection to scroll to. Stored (not applied) so a rebuilt PDFView re-applies it via
    /// `applyToView` — highlights then survive page cycling, exactly like the persisted zoom.
    func setFindTarget(query: String, currentIndex: Int?) {
        findQuery = query
        findCurrentIndex = currentIndex
    }

    /// Highlight every match of the stored query on this pane's page and, when this pane owns the current
    /// match, select + scroll to it (otherwise just clear the transient selection). An empty query clears
    /// all find highlighting. Read-only — never mutates the document.
    func applyFind() {
        guard let v = pdfView else { return }
        guard !findQuery.isEmpty, let doc = v.document else {
            v.highlightedSelections = nil
            v.clearSelection()
            return
        }
        let matches = doc.findString(findQuery, withOptions: [.caseInsensitive])
        for m in matches { m.color = .systemYellow.withAlphaComponent(0.5) }
        v.highlightedSelections = matches.isEmpty ? nil : matches
        if let i = findCurrentIndex, matches.indices.contains(i) {
            v.setCurrentSelection(matches[i], animate: true)
            v.scrollSelectionToVisible(nil)
        } else {
            v.clearSelection()
        }
    }

    /// Clear any find highlight + selection on this pane (query reset to none).
    func clearFind() {
        findQuery = ""
        findCurrentIndex = nil
        pdfView?.highlightedSelections = nil
        pdfView?.clearSelection()
    }
}

/// Displays a single PDF page (read-only, selectable) in its own PDFView. The parent gives each page a
/// fresh view (via `.id`), because reusing one PDFView and swapping its document leaves text selection
/// wedged after cycling (DV-3). Zoom is restored from the controller so it still persists (DV-2).
struct PDFPaneView: NSViewRepresentable {
    let page: PDFPage?
    let controller: PDFPaneController
    var id: String = ""
    /// The page the pane's zoom is measured against, when `page` may be a differently sized stand-in for it
    /// (the left pane's JPEG original stands in for the PDF's image page). nil = `page` itself.
    var reference: PDFPage? = nil

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor final class Coordinator: NSObject {
        let controller: PDFPaneController
        init(controller: PDFPaneController) { self.controller = controller }
        @objc func scaleChanged(_ note: Notification) { controller.recordScale() }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = ReaderPDFView()
        view.paneController = controller
        view.pageAccessibilityTitle = controller.key == "left" ? "Original image page" : "OCR text page"
        view.setAccessibilityLabel(view.pageAccessibilityTitle)
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

    private func loadPage(into view: PDFView) {
        controller.show(page, reference: reference, in: view)
    }
}

/// PDFKit supplies an AXPage node below the PDFView, with its selectable text underneath. Naming the
/// outer view does not name that page, and PDFKit ignores the node's label setter. Its public title
/// setter works: name only AXPage nodes and leave PDFKit's content, actions and parentage intact.
final class ReaderPDFView: PDFView {
    var pageAccessibilityTitle = "PDF page"
    weak var paneController: PDFPaneController?

    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren()
        namePages(in: children ?? [])
        return children
    }

    private func namePages(in children: [Any]) {
        for case let element as any NSAccessibilityProtocol in children {
            if element.accessibilityRole() == .pageRole {
                element.setAccessibilityTitle(pageAccessibilityTitle)
            } else if let descendants = element.accessibilityChildren() {
                namePages(in: descendants)
            }
        }
    }

    /// W48.reader-copy-shortcut: ⌘C is the standard Edit ▸ Copy, sent down the responder chain, so a
    /// focused text field (the find bar) copies its own text. It used to be a second ⌘C on Document ▸
    /// Copy, which AppKit matched first and which copied the PDF selection even with the caret in the
    /// find field (measured in the VM). Reaching a pane, it copies the viewer's selection from EITHER
    /// pane, plain text only, so focus on the image pane still copies text selected on the text page.
    override func copy(_ sender: Any?) {
        if let copy = paneController?.copySelection { copy() } else { super.copy(sender) }
    }

    /// W40.fix-reader-text-zoom: the Document menu shows ⌘+ / ⌘− for Zoom In / Out, and a menu item holds
    /// one shortcut. The others — ⌘= (⌘+ without Shift), and the ⌘↑ / ⌘↓ that came first — are answered
    /// here. A window offers key equivalents to every view in it, so this catches them wherever the
    /// focus is (the find field included), and both panes forward to the same focused-pane zoom.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let zoomIn = Self.zoomKey(event), let zoom = paneController?.zoomFocused {
            zoom(zoomIn)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// `true` for a zoom-in key, `false` for zoom-out, `nil` for anything else. Command alone, except
    /// that Shift is allowed for "+" (⌘+ is ⌘⇧= on most layouts) — and only there: ⌘⇧↑ / ⌘⇧↓ page
    /// through the segment.
    static func zoomKey(_ event: NSEvent) -> Bool? {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers else { return nil }
        var mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if key == "+" { mods.remove(.shift) }
        guard mods == .command else { return nil }
        switch key {
        case "=", "+", String(UnicodeScalar(NSUpArrowFunctionKey)!): return true
        case "-", String(UnicodeScalar(NSDownArrowFunctionKey)!): return false
        default: return nil
        }
    }
}

extension ReaderPDFView: NSMenuItemValidation {
    /// Copy is enabled only when one of the viewer's panes has selected text. PDFKit's own validation
    /// is not public API, so every other item is forwarded to it by selector.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)), let canCopy = paneController?.canCopySelection {
            return canCopy()
        }
        let selector = #selector(NSMenuItemValidation.validateMenuItem(_:))
        guard PDFView.instancesRespond(to: selector) else { return true }
        typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> Bool
        let validate = unsafeBitCast(PDFView.instanceMethod(for: selector), to: Validate.self)
        return validate(self, selector, menuItem)
    }
}
