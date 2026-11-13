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
    private var isApplyingFind = false // true while find selects its hit, which is not the user's selection
    private var findQuery = ""         // active find query to highlight on this pane ("" = none)
    private(set) var findCurrentIndex: Int? // which match on THIS pane is the current selection; nil = highlight-only
    /// The page whose text layer find reads when the shown page is a stand-in for it — the PDF's image page
    /// behind its JPEG original, which has no text of its own. nil = find reads the shown page.
    private var findSource: PDFPage?
    /// Quarter turns clockwise the reader added to the shown page (W40.reader-view-rotate), applied to the pane's
    /// private copy of it, so the file and the model's page are never turned. Find boxes on a stand-in are worked
    /// out on a copy of the source turned the same way.
    private(set) var turns = 0
    /// Draws the stand-in's find boxes over its page. An overlay rather than annotations: a `PDFPage` copy
    /// shares its annotations with the original, and removing one from the copy leaves it on the original
    /// (measured), so boxes would pile up on the model's JPEG page.
    let standInOverlay = StandInFindOverlay()
    /// Shows the preview's prerendered bitmap over the image page until PDFKit's own render lands
    /// (W40.fix-reader-preview-image-speed). Installed only on a pane shown with `showsPlaceholder`.
    let placeholderOverlay = PlaceholderPageOverlay()
    /// Edit ▸ Copy (⌘C) as this pane's `copy:` answers it — the viewer's verbatim copy from whichever pane
    /// holds the selection, and whether there is one to copy. Set by `DocumentViewerModel`; nil leaves
    /// PDFKit's own `copy:` in place. See `ReaderPDFView.copy(_:)`.
    var copySelection: (() -> Void)?
    var canCopySelection: (() -> Bool)?
    /// A zoom key reaching this pane (`true` = in), forwarded to the viewer so it zooms the FOCUSED pane —
    /// which may be the extracted-text pane, not a PDFView at all. Set by `DocumentViewerModel`.
    var zoomFocused: ((Bool) -> Void)?
    /// The user made a selection in this pane — set by `DocumentViewerModel`, which clears the other
    /// pane's so only one holds one (W40.fix-reader-copy-text-pane).
    var userSelected: (() -> Void)?
    /// This pane's view became first responder (a click, Tab, Focus Image / Text Page), so the focus border
    /// moves to it; and whether the viewer's focused pane is this one, so a freshly built view takes the
    /// focus back when the old one left the window holding it. Set by `DocumentViewerModel`.
    /// W40.fix-reader-doc-keys-focus.
    var tookFocus: (() -> Void)?
    var holdsFocus: (() -> Bool)?
    /// Called after the zoom is recorded or reset, so the viewer can republish what depends on it (whether
    /// Reset Zoom has anything to do). Set by `DocumentViewerModel`.
    var zoomChanged: (() -> Void)?
    /// The image pane's right-click items, Copy Image and Reveal in Finder, and whether there is an image for
    /// them to act on. Set by `DocumentViewerModel` on the image pane only; nil leaves PDFKit's menu as it is.
    /// W40.reader-image-context-menu.
    var copyImage: (() -> Void)?
    var revealImageFile: (() -> Void)?
    var hasImage: (() -> Bool)?

    /// True while the pane fits its page, i.e. no explicit zoom is held.
    var isFitted: Bool { savedScale == nil }

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
        zoomChanged?()
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
        zoomChanged?()
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
        let restoring = pendingViewport != nil && savedScale != nil
        if let viewport = pendingViewport, restoring { restore(viewport) } else { scrollToTop() }
        pendingViewport = nil
        // Re-highlight matches (+ re-select the current one) on the freshly-built view. The PDF / JPEG
        // switch keeps the region the reader was looking at, so it does not scroll to the hit.
        applyFind(scroll: !restoring)
    }

    /// Show a COPY of `page` in a throwaway one-page document (a PDFPage can belong to only one document —
    /// copying avoids detaching it from the source), then restore the zoom. `reference` is the page the
    /// saved zoom is measured against (the PDF's image page for the left pane); nil means `page` itself.
    ///
    /// `turns` quarter-turns the copy clockwise on top of the page's own `/Rotate` (W40.reader-view-rotate). PDFKit
    /// turns everything drawn in page space with it: the text layer and its selection, find highlights, and the
    /// overlays below. The zoom unit is measured on the unturned pages, so a turn keeps the zoom's meaning.
    func show(_ page: PDFPage?, reference: PDFPage?, placeholder: PlaceholderRequest? = nil, turns: Int = 0,
              in view: PDFView) {
        view.clearSelection()
        self.turns = Self.quarter(turns)
        findSource = (page != nil && reference != nil && page !== reference) ? reference : nil
        standInOverlay.update(rects: [], current: nil)
        placeholderOverlay.reset(key: findSource == nil ? placeholder?.key : nil,
                                 image: findSource == nil ? placeholder?.image : nil)
        // Before the document, so PDFKit asks it for the page's overlay as it lays the page out. The
        // placeholder's provider goes in even before its bitmap is ready, so a late one can still be shown.
        view.pageOverlayViewProvider = findSource != nil ? standInOverlay
            : placeholder != nil ? placeholderOverlay : nil
        if let page, let copy = page.copy() as? PDFPage {
            copy.rotation = Self.quarter(page.rotation / 90 + self.turns) * 90
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

    private static func quarterTurns(_ page: PDFPage) -> Int { quarter(page.rotation / 90) }
    static func quarter(_ turns: Int) -> Int { (turns % 4 + 4) % 4 }

    /// The page as a pane shows it, `turns` quarter turns clockwise on top of its own `/Rotate`, drawn on white
    /// at `scale` pixels per page unit (W40.reader-image-context-menu's Copy Image). Drawn from a copy, as `show`
    /// does, so the page itself is never turned. The longer side is held to `maxPixels`.
    static func render(_ page: PDFPage, turns: Int, scale: CGFloat, maxPixels: CGFloat = 8000) -> CGImage? {
        guard let copy = page.copy() as? PDFPage else { return nil }
        copy.rotation = quarter(page.rotation / 90 + turns) * 90
        let box = PDFDisplayBox.cropBox
        let shown = displayedSize(copy, box: box)
        guard shown.width > 0, shown.height > 0, scale > 0 else { return nil }
        let s = min(scale, maxPixels / max(shown.width, shown.height))
        let width = max(1, Int((shown.width * s).rounded())), height = max(1, Int((shown.height * s).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(width) / shown.width, y: CGFloat(height) / shown.height)
        copy.draw(with: box, to: ctx)   // applies the copy's turn and moves the box to the bitmap's origin
        return ctx.makeImage()
    }

    /// A text selection is drawn under page overlays, so the placeholder steps aside for good once one
    /// appears (a drag-select, Select All). Clearing the selection does not bring it back.
    ///
    /// A non-empty selection while this pane is first responder is the user's (find selects its hit with
    /// the caret in the find field), so the viewer is told, to clear the other pane's.
    func selectionChanged() {
        guard let v = pdfView, let s = v.currentSelection?.string, !s.isEmpty else { return }
        if placeholderOverlay.isShowing { placeholderOverlay.retire() }
        if !isApplyingFind, v.window?.firstResponder === v { userSelected?() }
    }

    /// Drop this pane's text selection (another pane took the live one).
    func clearSelection() {
        guard let v = pdfView, v.currentSelection != nil else { return }
        v.clearSelection()
    }

    /// Give this pane keyboard focus (so ↑/↓ scroll it and text selection lands here).
    func focus() { pdfView?.window?.makeFirstResponder(pdfView) }

    /// Pin the TOP-left of the (single) page to the top-left of the viewer. Lay out first (so the scroll
    /// uses post-zoom geometry) and repeat on the next runloop (the zoom's relayout lands after this
    /// call, so a single synchronous scroll anchors stale — the deferred one corrects it).
    private func scrollToTop() {
        guard let v = pdfView, let page = v.document?.page(at: 0) else { return }
        // The page's displayed top-left: page space has its origin bottom-left, and a turned page's top is
        // another of its edges (W40.reader-view-rotate).
        let top = Self.pagePoint(fromDisplayed: .zero, on: page, box: v.displayBox)
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
    func applyFind(scroll: Bool = true) {
        guard let v = pdfView else { return }
        standInOverlay.update(rects: [], current: nil)
        if !findQuery.isEmpty { placeholderOverlay.retire() }   // PDFKit draws find highlights under overlays
        guard !findQuery.isEmpty, let doc = v.document else {
            v.highlightedSelections = nil
            v.clearSelection()
            return
        }
        if let source = findSource, let shown = doc.page(at: 0) {
            v.highlightedSelections = nil
            v.clearSelection()
            highlightStandIn(shown, from: source, in: v, scroll: scroll)
            return
        }
        let matches = doc.findString(findQuery, withOptions: [.caseInsensitive])
        for m in matches { m.color = .systemYellow.withAlphaComponent(0.5) }
        v.highlightedSelections = matches.isEmpty ? nil : matches
        if let i = findCurrentIndex, matches.indices.contains(i) {
            isApplyingFind = true
            v.setCurrentSelection(matches[i], animate: true)
            isApplyingFind = false
            if scroll {
                v.scrollSelectionToVisible(nil)
                if let page = doc.page(at: 0) { scrollAgain(to: matches[i].bounds(for: page), on: page, in: v) }
            }
        } else {
            v.clearSelection()
        }
    }

    /// Clear any find highlight + selection on this pane (query reset to none).
    func clearFind() {
        findQuery = ""
        findCurrentIndex = nil
        standInOverlay.update(rects: [], current: nil)
        pdfView?.highlightedSelections = nil
        pdfView?.clearSelection()
    }

    /// The JPEG original has no text layer, so its hits are found on the PDF image page it stands in for
    /// and drawn at the same place on the JPEG: each match's box as fractions of the displayed image page,
    /// then back onto the JPEG page (both are the same photograph, so the fractions agree). The boxes are
    /// drawn by the pane's overlay, so no page is marked; the current hit is scrolled to.
    /// W40.fix-reader-find-both-panes.
    private func highlightStandIn(_ shown: PDFPage, from source: PDFPage, in v: PDFView, scroll: Bool) {
        let rects = Self.standInMatchRects(query: findQuery, source: source, shown: shown, box: v.displayBox,
                                           turns: turns)
        let current = findCurrentIndex.flatMap { rects.indices.contains($0) ? $0 : nil }
        standInOverlay.update(rects: rects, current: current)
        if scroll, let current, !rects[current].isEmpty {
            v.go(to: rects[current], on: shown)
            scrollAgain(to: rects[current], on: shown, in: v)
        }
    }

    /// Scroll to the current hit once more on the next runloop. A freshly built pane (a hit on another
    /// pair or document) pins its top in `scrollToTop`, whose deferred half lands after this call and
    /// would otherwise scroll the hit back out of sight; this is queued after it, so it wins.
    private func scrollAgain(to rect: CGRect, on page: PDFPage, in v: PDFView) {
        DispatchQueue.main.async { [weak v] in
            guard let v, v.document?.page(at: 0) === page else { return }
            v.go(to: rect, on: page)
        }
    }

    /// The boxes, in `shown`'s page space, of `query`'s matches on `source`, in match order — one per match,
    /// an empty box for a match with no bounds, so the k-th box stays the k-th match. Read-only: `source` is
    /// searched through a copy, so neither page's document is touched. `turns` is the reader's turn, already on
    /// `shown`: the copy of `source` is turned the same way, so the two still show the photograph alike.
    static func standInMatchRects(query: String, source: PDFPage, shown: PDFPage, box: PDFDisplayBox,
                                  turns: Int = 0) -> [CGRect] {
        guard !query.isEmpty, let copy = source.copy() as? PDFPage else { return [] }
        copy.rotation = quarter(source.rotation / 90 + turns) * 90
        let doc = PDFDocument()
        doc.insert(copy, at: 0)
        return doc.findString(query, withOptions: [.caseInsensitive]).map { match in
            let r = match.bounds(for: copy)
            guard !r.isEmpty else { return .zero }
            let a = pagePoint(fromDisplayed: displayedFraction(of: CGPoint(x: r.minX, y: r.minY), on: copy, box: box),
                              on: shown, box: box)
            let b = pagePoint(fromDisplayed: displayedFraction(of: CGPoint(x: r.maxX, y: r.maxY), on: copy, box: box),
                              on: shown, box: box)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }
    }
}

/// The find boxes over a stand-in page (the JPEG original), in that page's space: every hit in the match
/// yellow, the current one in the find colour. PDFKit lays the overlay view over the page and keeps it there
/// through zoom and scroll; it takes no clicks. Nothing here touches a page. W40.fix-reader-find-both-panes.
@MainActor
final class StandInFindOverlay: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private(set) var rects: [CGRect] = []
    private(set) var current: Int?
    /// Every overlay handed to PDFKit, held weakly: PDFKit owns them while the page is shown.
    private let views = NSHashTable<StandInFindOverlayView>.weakObjects()

    func update(rects: [CGRect], current: Int?) {
        guard rects != self.rects || current != self.current else { return }
        self.rects = rects
        self.current = current
        for view in views.allObjects { view.needsDisplay = true }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = StandInFindOverlayView(provider: self, page: page, pdfView: view)
        views.add(overlay)
        return overlay
    }
}

final class StandInFindOverlayView: NSView {
    private weak var provider: StandInFindOverlay?
    private weak var page: PDFPage?
    private weak var pdfView: PDFView?

    init(provider: StandInFindOverlay, page: PDFPage, pdfView: PDFView) {
        self.provider = provider
        self.page = page
        self.pdfView = pdfView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let provider, let page, let pdfView else { return }
        for (k, rect) in provider.rects.enumerated() {
            (k == provider.current ? NSColor.findHighlightColor.withAlphaComponent(0.6)
                                   : NSColor.systemYellow.withAlphaComponent(0.5)).setFill()
            convert(pdfView.convert(rect, from: page), from: pdfView).fill(using: .sourceOver)
        }
    }
}

/// The placeholder a pane is asked to show: `key` names the file and page it is a picture of, and `image`
/// is nil until the prerender lands.
struct PlaceholderRequest {
    var key: String
    var image: CGImage?

    static func key(path: String, pageIndex: Int) -> String { "\(path)#\(pageIndex)" }
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
    /// Show a prerendered bitmap over the page until PDFKit's own render lands (the preview's image pane).
    /// nil = no placeholder; a request with no image yet still lets a late bitmap be shown.
    var placeholder: PlaceholderRequest? = nil
    /// Quarter turns clockwise the reader gave this page (W40.reader-view-rotate). The parent puts the turn in the
    /// pane's `.id`, so a turn builds a fresh view, as a page turn does.
    var turns: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    /// The grey behind the page, as in Preview, fixed rather than a system colour: on macOS 27
    /// `windowBackgroundColor` is as white as a scanned page, which then showed only by its faint shadow
    /// (W40.fix-reader-pane-background). Resolved per appearance, so a live Light/Dark switch follows it.
    static let paneBackground = NSColor(name: "ArchiveReader.pdfPaneBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.78, alpha: 1)
    }

    @MainActor final class Coordinator: NSObject {
        let controller: PDFPaneController
        init(controller: PDFPaneController) { self.controller = controller }
        @objc func scaleChanged(_ note: Notification) {
            controller.placeholderOverlay.redraw()   // its resolution check is made per draw
            controller.recordScale()
        }
        @objc func selectionChanged(_ note: Notification) { controller.selectionChanged() }
    }

    func makeNSView(context: Context) -> PDFView {
        let view = ReaderPDFView()
        view.paneController = controller
        view.pageAccessibilityTitle = controller.key == "left" ? "Original image page" : "OCR text page"
        view.setAccessibilityLabel(view.pageAccessibilityTitle)
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.backgroundColor = Self.paneBackground
        controller.pdfView = view
        if !id.isEmpty { view.setAccessibilityIdentifier(id) }
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: view)
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.selectionChanged(_:)),
                                               name: .PDFViewSelectionChanged, object: view)
        loadPage(into: view)
        #if DEBUG
        view.setAccessibilityValue(String(format: "%.4f", view.scaleFactor))
        #endif
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        controller.pdfView = view
        if view.document?.page(at: 0)?.string != page?.string {
            loadPage(into: view)   // safety net for any reuse
        } else if let placeholder, let image = placeholder.image {
            // The bitmap landed after the page was shown; the overlay takes it only for the page it shows.
            controller.placeholderOverlay.supply(image, key: placeholder.key)
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewSelectionChanged, object: nsView)
    }

    private func loadPage(into view: PDFView) {
        controller.show(page, reference: reference, placeholder: placeholder, turns: turns, in: view)
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

    // MARK: Arrow keys pan, and the focus follows the responder (W40.fix-reader-doc-keys-focus)

    /// The owner's Reader session 2 (rows 6, 7): the arrow keys did nothing in the document window, and a
    /// click in the text pane did not move the focus border. PDFKit's single-page mode reads ←/→ as page
    /// turns, which a one-page document never has, so the arrows alone pan the page here instead.
    override func keyDown(with event: NSEvent) {
        if let direction = Self.panKey(event) { pan(direction); return }
        super.keyDown(with: event)
    }

    /// How far one arrow press moves the page: a tenth of the pane, and never less than `minPanStep` points.
    static let panFraction: CGFloat = 0.1
    static let minPanStep: CGFloat = 40

    /// The direction a plain arrow key moves the view over the page (x to the right, y up), nil for anything
    /// else: a modifier means a menu command (⌘⇧↑ / ⌘⇧↓ page through the segment, ⌘⌥← / ⌘⌥→ switch the pane).
    static func panKey(_ event: NSEvent) -> CGVector? {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.unicodeScalars.first,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock]).isEmpty else { return nil }
        switch Int(key.value) {
        case NSUpArrowFunctionKey: return CGVector(dx: 0, dy: 1)
        case NSDownArrowFunctionKey: return CGVector(dx: 0, dy: -1)
        case NSLeftArrowFunctionKey: return CGVector(dx: -1, dy: 0)
        case NSRightArrowFunctionKey: return CGVector(dx: 1, dy: 0)
        default: return nil
        }
    }

    /// Scroll the page one step in `direction`, clamped to its edges. A page that fits the pane has nowhere
    /// to go, so nothing moves.
    func pan(_ direction: CGVector) {
        guard let clip = documentView?.enclosingScrollView?.contentView else { return }
        let visible = clip.bounds
        let dx = direction.dx * max(Self.minPanStep, visible.width * Self.panFraction)
        let dy = direction.dy * max(Self.minPanStep, visible.height * Self.panFraction)
        let moved = NSRect(origin: CGPoint(x: visible.minX + dx, y: visible.minY + (clip.isFlipped ? -dy : dy)),
                           size: visible.size)
        let origin = clip.constrainBoundsRect(moved).origin
        guard origin != visible.origin else { return }
        clip.scroll(to: origin)
        clip.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: Right-click on the image page (W40.reader-image-context-menu)

    /// The owner, 2026-11-13: right-clicking the image offers Copy Image and Reveal in Finder, above PDFKit's
    /// own items. Both only read. The text page has no `copyImage` and keeps PDFKit's menu unchanged.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard paneController?.copyImage != nil else { return menu }
        let full = menu ?? NSMenu()
        let items = [NSMenuItem(title: ReaderCommand.copyImage.title, action: #selector(copyImageFromMenu(_:)),
                                keyEquivalent: ""),
                     NSMenuItem(title: ReaderCommand.revealInFinder.title,
                                action: #selector(revealImageFileFromMenu(_:)), keyEquivalent: "")]
        if !full.items.isEmpty { full.insertItem(.separator(), at: 0) }
        for item in items.reversed() {
            item.target = self
            full.insertItem(item, at: 0)
        }
        return full
    }

    @objc func copyImageFromMenu(_ sender: Any?) { paneController?.copyImage?() }
    @objc func revealImageFileFromMenu(_ sender: Any?) { paneController?.revealImageFile?() }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { paneController?.tookFocus?() }
        return became
    }

    /// Each page gets a fresh view (DV-3), and the old one leaves the window holding the focus, which then
    /// falls to the window itself, so the arrows reached nothing after a page turn or on opening. The new
    /// view takes it back when its pane is the focused one; never from a field or another view.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, paneController?.holdsFocus?() == true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder === window,
                  self.paneController?.holdsFocus?() == true else { return }
            window.makeFirstResponder(self)
        }
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
        if menuItem.action == #selector(copyImageFromMenu(_:)) || menuItem.action == #selector(revealImageFileFromMenu(_:)) {
            return paneController?.hasImage?() ?? false
        }
        let selector = #selector(NSMenuItemValidation.validateMenuItem(_:))
        guard PDFView.instancesRespond(to: selector) else { return true }
        typealias Validate = @convention(c) (AnyObject, Selector, NSMenuItem) -> Bool
        let validate = unsafeBitCast(PDFView.instanceMethod(for: selector), to: Validate.self)
        return validate(self, selector, menuItem)
    }
}
