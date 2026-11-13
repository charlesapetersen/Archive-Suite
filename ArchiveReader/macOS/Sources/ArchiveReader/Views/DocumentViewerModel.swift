import Combine
import SwiftUI
import PDFKit
import os
import ArchiveCore

/// Drives the document window: the selected files, the current document, and page cycling.
/// Loads one document at a time (never materializes the whole selection).
///
/// Cycling is two-level: within a document the viewer walks its image/OCR-text **page pairs**
/// (`DocumentPagePairs`), and only past the last pair does it move to the next file. An archival PDF may
/// interleave image, text, image, text, … (`SPEC/tag-format.md` §"Interleaved multi-page variant" —
/// merged multi-page documents and Re-OCR output), so pinning the panes to pages 0/1 made every later
/// scan of such a document unreachable; pairs are what make the whole document readable.
@MainActor
final class DocumentViewerModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published var index = 0 { didSet { if index != oldValue { loadCurrent() } } }
    /// Which page pair of the current document the two panes show. Reset to 0 by every document load.
    @Published private(set) var pair = 0
    /// W44.reocr-reader: counts the times the open file's contents were replaced under it (an Improve OCR
    /// receipt); part of the panes' identity, so a reload builds fresh views on the new pages.
    @Published private(set) var contentRevision = 0
    private var replacedObserver: AnyCancellable?
    @Published private(set) var current: PDFDocument?
    @Published private(set) var loadError: String?
    @Published private(set) var jpegPartnerPage: PDFPage?
    @Published private(set) var jpegPartnerRelativePath: String?
    @Published private(set) var imageSource: DocumentImageSource = .pdf
    /// Why the current document has no JPEG original to switch to, in words for the toolbar switch's
    /// tooltip (W40.fix-reader-jpeg-toolbar). `nil` while a partner is available or nothing is loaded.
    @Published private(set) var jpegUnavailableReason: String?
    @Published var showingFind = false   // driven by the toolbar and the Document menu
    /// Bumped by every `beginFind()`, so the view puts the caret in the find field even when the bar is
    /// already showing (⌘F again after clicking a pane), where `showingFind` itself does not change.
    @Published private(set) var findFocusRequest = 0
    @Published var findQuery = ""        // the find-bar text (bound to the field)
    @Published private(set) var findOrdinal: Int?     // 1-based position of the current match ("3 of 12")
    @Published private(set) var findTotal = 0         // total matches across ALL open documents

    private var findNavigator = FindNavigator()
    /// The query the navigator was last built for (avoids rescanning). Published because the extracted-text
    /// pane's highlight reads it (`extractedTextFind`), and a new search can leave the counts unchanged.
    @Published private var lastFoundQuery: String?

    let leftController: PDFPaneController     // the current pair's image page (PDF page 2·pair)
    let rightController: PDFPaneController   // the current pair's OCR text page (PDF page 2·pair + 1)
    /// The right pane when the pair has no OCR text page but its image page has text (a one-page PDF).
    let textController = ExtractedTextController()

    /// Whether the view driven by this model renders a find bar — i.e. whether the user can type a query
    /// at all. The Document menu's `Find…` / `Find Next` / `Find Previous` gate on it, and so do the find
    /// entry points below, so the invariant lives in ONE place rather than in three menu modifiers.
    ///
    /// It exists because of `W26.previewzoom-fu1`: the preview sheet's model is published to the scene (so
    /// zoom / paging / copy / page-link commands reach the sheet — `W26.previewzoom`), which necessarily
    /// enables **every** `.disabled(doc == nil)` item in that menu; but `DocumentWindowView` holds the app's
    /// only `if model.showingFind { findBar }`, so in the preview those three were live-looking and inert.
    ///
    /// Deliberately NOT derived from `persists`. The two co-vary in the one preview we have today, but
    /// "does not write zoom to defaults" and "has no find bar" are different facts about a viewer; a future
    /// non-persisting viewer that DOES render a find bar would silently inherit the wrong answer.
    let supportsFind: Bool
    /// Whether the viewer offers the page views (W40.reader-page-views: the document window and the preview
    /// sheet both do; `false` is kept for tests of a viewer without them).
    let supportsPageOverview: Bool
    /// The contact sheet is showing in place of the reading panes. Every move to a page ends it.
    @Published private(set) var showingAllPages = false
    /// Whether file switches feed the DEBUG switch probe: the document window's, which the probe measures.
    private let reportsSwitches: Bool
    /// The thumbnail sidebar is showing beside the reading panes. Unlike the contact sheet it stays up while
    /// the reader moves around; the window remembers it.
    @Published var showingThumbnails = false
    /// The page counts of the open files, for the page views.
    let pageCounts = OpenFilePageCounts()

    /// Preview's three page views: the page alone, the thumbnail sidebar (⌥⌘2, `ReaderCommand.showThumbnails`,
    /// which toggles) and the contact sheet (⌥⌘6, `.contactSheet`).
    enum PageView: Sendable, Equatable { case single, thumbnails, contactSheet }

    var pageView: PageView { showingAllPages ? .contactSheet : (showingThumbnails ? .thumbnails : .single) }

    /// The contact sheet is worth showing when there is more than one page to lay out: several files, or a
    /// file with more than one page.
    var canShowAllPages: Bool { supportsPageOverview && (urls.count > 1 || (current?.pageCount ?? 0) > 1) }
    var canShowThumbnails: Bool { supportsPageOverview && !urls.isEmpty }

    func setPageView(_ view: PageView) {
        switch view {
        case .single: showingThumbnails = false; setShowingAllPages(false)
        case .thumbnails:
            guard canShowThumbnails else { return }
            showingThumbnails = true; setShowingAllPages(false)
        case .contactSheet: setShowingAllPages(true)
        }
    }

    /// View ▸ Show/Hide Thumbnails (⌥⌘2) and its toolbar button: hides the sidebar when it is showing, otherwise
    /// shows it, leaving the contact sheet as Preview does (W40.reader-thumbnails-toggle).
    func toggleThumbnails() { setPageView(pageView == .thumbnails ? .single : .thumbnails) }

    func setShowingAllPages(_ show: Bool) {
        showingAllPages = show && canShowAllPages
        if showingAllPages {
            leftController.clearSelection()
            rightController.clearSelection()
            textController.clearSelection()
        }
    }

    /// A tile names a physical PDF page of the file on view, including OCR pages and an odd trailing scan.
    func openTiledPage(_ page: Int) { openTiledPage(file: index, page: page) }

    /// A tile names a physical PDF page of one of the open files. A page past the end of its file changes nothing.
    func openTiledPage(file: Int, page: Int) {
        guard urls.indices.contains(file), page >= 1 else { return }
        if file != index {
            // Until its count is read, a file shows its first page alone, which can be opened.
            guard page <= (pageCounts.count(urls[file].path) ?? 1) else { return }
            prepareFindForManualCycle()
            index = file                     // didSet → loadCurrent()
        }
        guard let current, page <= current.pageCount else { return }
        prepareFindForManualCycle()
        // Tiles depict PDF pages. Show exactly the clicked page without changing the saved JPEG preference.
        imageSource = .pdf
        goToPDFPage(page)
    }

    /// A thumbnail names a page pair (its image page) of one of the open files.
    func openThumbnail(file: Int, pair target: Int) {
        guard urls.indices.contains(file), target >= 0 else { return }
        showingAllPages = false
        prepareFindForManualCycle()
        if file != index { index = file }    // didSet → loadCurrent() → pair 0
        setPair(target)
    }
    /// Shared renderer for the page-link payload. `nil` is an explicit degradation seam for tests;
    /// production uses the app-owned cache actor below.
    private let thumbnailer: PDFThumbnailer?
    /// Makes an older thumbnail task unable to replace the clipboard after a newer archive-page copy.
    private var archivePageLinkCopyGeneration = 0
    private var archiveLinkTarget: ArchiveLinkTarget?
    private var jpegPartnerIndex: JPEGPartnerIndex?
    private let imageSourcePreferences: DocumentImageSourcePreferences
    /// Where the image pages' turns are remembered (W40.reader-view-rotate): the Reader's own store, never the file.
    let pageTurns: PageTurnStore
    private let persistsImageSource: Bool
    private var pinsJPEGPartnerFromLink = false
    private let persistsTextScale: Bool
    private var linkedJPEGRelativePath: String?
    /// The files either side of the open one, and their JPEG originals, opened ahead on `prepareQueue`.
    private var neighbours = NeighbourCache()
    private let prepareQueue = DispatchQueue(label: "ArchiveReader.viewerNeighbours", qos: .userInitiated)
    /// What the queue should still open: an item no longer wanted when its turn comes is skipped, so holding
    /// an arrow key never leaves a backlog of opens ahead of the files now either side.
    private let stillWanted = OSAllocatedUnfairLock(initialState: Set<String>())
    /// The document window's image pages drawn ahead, at its image pane's size, for the open file and the
    /// files either side (one per window: two windows of different sizes would wipe each other's).
    let imagePrefetcher = PreviewImagePrefetcher(pixelBox: CGSize(width: 1536, height: 1536), cacheLimit: 4)

    /// `persists: false` → preview mode: fit-to-pane default, zoom changes don't write to UserDefaults.
    /// `supportsFind: false` → the view renders no find bar, so the find commands stay disabled.
    init(persists: Bool = true, supportsFind: Bool = true, supportsPageOverview: Bool = true, reportsSwitches: Bool = true,
         imageSourcePreferences: DocumentImageSourcePreferences = DocumentImageSourcePreferences(),
         pageTurns: PageTurnStore = .shared,
         thumbnailer: PDFThumbnailer? = ArchiveTestHost.isUnitTestHost ? nil : ArchiveLinkThumbnailer.shared) {
        leftController = PDFPaneController(key: "left", persists: persists)
        rightController = PDFPaneController(key: "right", persists: persists)
        self.supportsFind = supportsFind
        self.supportsPageOverview = supportsPageOverview
        self.reportsSwitches = reportsSwitches
        self.imageSourcePreferences = imageSourcePreferences
        self.pageTurns = pageTurns
        self.persistsImageSource = persists
        self.persistsTextScale = persists
        self.thumbnailer = thumbnailer
        if persists, AppSettings.viewerTextScale > 0 {
            textScale = Self.clampedTextScale(CGFloat(AppSettings.viewerTextScale))
        }
        // Edit ▸ Copy (⌘C) reaching any pane copies the viewer's selection (`ReaderPDFView.copy(_:)`,
        // `ExtractedTextView.copy(_:)`), and a selection the user makes in one pane clears the other's.
        textController.copySelection = { [weak self] in self?.copyPlainSelection() }
        replacedObserver = NotificationCenter.default.publisher(for: .readerFileContentsReplaced)
            .sink { [weak self] note in
                guard let paths = note.userInfo?[ReaderFileContentsReplaced.pathsKey] as? [String] else { return }
                Task { @MainActor in self?.reloadReplaced(paths: Set(paths)) }
            }
        textController.canCopySelection = { [weak self] in self?.hasTextSelection ?? false }
        textController.userSelected = { [weak self] in self?.userSelected(in: .right) }
        textController.tookFocus = { [weak self] in self?.paneTookFocus(.right) }
        textController.holdsFocus = { [weak self] in self?.focusedPane == .right }
        for controller in [leftController, rightController] {
            controller.copySelection = { [weak self] in self?.copyPlainSelection() }
            controller.canCopySelection = { [weak self] in self?.hasTextSelection ?? false }
            let pane: Pane = controller === leftController ? .left : .right
            controller.userSelected = { [weak self] in self?.userSelected(in: pane) }
            controller.tookFocus = { [weak self] in self?.paneTookFocus(pane) }
            controller.holdsFocus = { [weak self] in self?.focusedPane == pane }
            // ⌘= / ⌘↑ / ⌘↓ reaching either pane zoom the FOCUSED pane (`ReaderPDFView.performKeyEquivalent`).
            controller.zoomFocused = { [weak self] zoomIn in
                if zoomIn { self?.zoomFocusedIn() } else { self?.zoomFocusedOut() }
            }
            controller.zoomChanged = { [weak self] in self?.objectWillChange.send() }
        }
        // Right-click on the image page (W40.reader-image-context-menu); the text page keeps PDFKit's menu.
        leftController.copyImage = { [weak self] in self?.copyImage() }
        leftController.revealImageFile = { [weak self] in self?.revealShownImageFile() }
        leftController.hasImage = { [weak self] in
            guard let self else { return false }
            return !self.showingAllPages && self.shownImageFileURL != nil
        }
    }

    /// Which pane keyboard focus / zoom acts on. ⌘↑/⌘↓ zoom this pane; ⌘⌥←/→ switch it.
    enum Pane: Sendable, Equatable { case left, right }
    @Published var focusedPane: Pane = .left

    /// `showing` opens on that file of the selection, if it is one (W40.reader-selection-current); else the first.
    func load(_ selection: DocumentSelection, showing path: String? = nil) {
        urls = selection.filePaths.map { URL(fileURLWithPath: $0) }
        pageCounts.retain(selection.filePaths)
        pinsJPEGPartnerFromLink = selection.pinsJPEGPartner
        linkedJPEGRelativePath = selection.jpegRelativePath
        index = path.flatMap { selection.filePaths.firstIndex(of: $0) } ?? 0
        focusedPane = .left
        loadCurrent()
    }

    /// Step forward one page pair; past the current document's last pair, move to the next file.
    func next() {
        showingAllPages = false
        if pair + 1 < pairCount { prepareFindForManualCycle(); setPair(pair + 1); return }
        guard index < urls.count - 1 else { return }
        prepareFindForManualCycle()
        index += 1                          // didSet → loadCurrent() → pair 0 of the new document
    }

    /// Step back one page pair; before the current document's first pair, move to the previous file and
    /// land on its LAST pair, so walking backwards visits every pair rather than skipping to page 1.
    func previous() {
        showingAllPages = false
        if pair > 0 { prepareFindForManualCycle(); setPair(pair - 1); return }
        guard index > 0 else { return }
        prepareFindForManualCycle()
        index -= 1                          // didSet → loadCurrent() → pair 0 of the previous document…
        setPair(pairCount - 1)              // …then to its last pair (clamped; a load failure gives 0)
    }

    /// Whether `next()` / `previous()` would move at all — either within this document's pairs or across
    /// files. The toolbar/header buttons disable on these, so a multi-pair document stays navigable.
    var canGoNext: Bool { pair + 1 < pairCount || index < urls.count - 1 }
    var canGoPrevious: Bool { pair > 0 || index > 0 }

    /// Move to a pair of the CURRENT document, clamped into range. Keyboard focus follows: a pair with no
    /// OCR text page has no right pane, so leaving focus there would point zoom/scroll at nothing.
    private func setPair(_ p: Int) {
        pair = min(max(0, p), max(0, pairCount - 1))
        if focusedPane == .right, textPage == nil, embeddedText == nil { focusedPane = .left }
    }

    /// When the user manually cycles documents while find is active, keep the query's highlights on the
    /// newly-shown pages but drop the "current match" selection (its ordinal belonged to the old document),
    /// so cycling never selects a spurious match. Find Next/Previous re-establish the current match.
    private func prepareFindForManualCycle() {
        guard !findQuery.isEmpty else { return }
        leftController.setFindTarget(query: findQuery, currentIndex: nil)
        rightController.setFindTarget(query: findQuery, currentIndex: nil)
    }

    // MARK: Pane focus + focused-pane zoom (keyboard-driven)

    private func controller(_ p: Pane) -> PDFPaneController { p == .left ? leftController : rightController }

    /// Move keyboard focus to a pane (so ↑/↓ scroll it and ⌘↑/⌘↓ zoom it).
    func focusPane(_ p: Pane) {
        focusedPane = p
        if p == .right, !hasTextPage { textController.focus() } else { controller(p).focus() }
    }
    /// A pane's view became first responder — a click in it, Tab, or `focusPane` — so the focus border and
    /// the zoom keys follow it (owner's Reader session 2, row 7: a click in the text pane left the border on
    /// the image). W40.fix-reader-doc-keys-focus.
    func paneTookFocus(_ p: Pane) {
        if focusedPane != p { focusedPane = p }
    }
    func zoomFocusedIn()  { focusedPane == .left ? leftController.zoomIn() : zoomTextIn() }
    func zoomFocusedOut() { focusedPane == .left ? leftController.zoomOut() : zoomTextOut() }
    func fitFocused()     { focusedPane == .left ? leftController.fit() : fitText() }

    // MARK: Text pane zoom (W40.fix-reader-text-zoom)

    /// The extracted-text pane's text size, as a multiple of the body size. A pair with an OCR text page
    /// shows it in a PDFView, which `rightController` zooms; a single-page PDF (almost all of the corpus)
    /// has none, so the right pane is plain SwiftUI text that a PDF zoom never reached — Zoom In on it
    /// changed nothing visible. The text pane's zoom commands go through here and size that text instead.
    /// Persists like the panes' zoom (not in preview mode).
    @Published private(set) var textScale: CGFloat = 1
    static let textScaleRange: ClosedRange<CGFloat> = 0.5...4

    func zoomTextIn()  { hasTextPage ? rightController.zoomIn()  : setTextScale(textScale * 1.25) }
    func zoomTextOut() { hasTextPage ? rightController.zoomOut() : setTextScale(textScale / 1.25) }
    func fitText()     { hasTextPage ? rightController.fit()     : setTextScale(1) }

    /// Both pages fitted and the text at its normal size: Reset Zoom has nothing to do, so the toolbar shows
    /// it disabled. W40.fix-reader-doc-toolbar: per-pane Fit buttons, live but with no visible effect on a
    /// page already fitted, read to the owner as controls that did nothing.
    var zoomIsDefault: Bool {
        leftController.isFitted && (hasTextPage ? rightController.isFitted : textScale == 1)
    }

    func resetZoom() { leftController.fit(); fitText() }

    private func setTextScale(_ s: CGFloat) {
        textScale = Self.clampedTextScale(s)
        if persistsTextScale { AppSettings.setViewerTextScale(textScale == 1 ? 0 : Double(textScale)) }
    }

    private static func clampedTextScale(_ s: CGFloat) -> CGFloat {
        min(textScaleRange.upperBound, max(textScaleRange.lowerBound, s))
    }

    var title: String { urls.indices.contains(index) ? urls[index].lastPathComponent : "Document View" }

    // MARK: Tags from the document window (W40.fix-reader-menus-follow-window)

    /// The open file's path, which the Tags menu acts on in the document window (`DocumentTagActions`).
    var currentFilePath: String? { currentURL?.path }
    /// The right-hand Inspector follows the open document.
    @Published var showingTagEditor = false
    /// Whether the find field has the caret. Undo Tag Change (⌘Z) stays off then, so ⌘Z in the field
    /// never undoes a tag change instead of the typing (S-001; `TextUndoGuard` does the same app-wide).
    @Published var findFieldFocused = false
    /// The last tag action's result, shown in the status bar until the next document loads.
    @Published var tagStatus: String?

    /// "3 of 12" across the open selection, plus " · page 2 of 4" when the current document holds more
    /// than one page pair — so a merged multi-page document says where you are inside it. Single-pair
    /// documents (the overwhelming majority) keep the original label exactly.
    var positionLabel: String {
        guard !urls.isEmpty else { return "" }
        let file = "\(index + 1) of \(urls.count)"
        if showingAllPages { return "\(file) · all \(current?.pageCount ?? 0) PDF pages" }
        guard pairCount > 1 else { return file }
        return "\(file) · page \(pair + 1) of \(pairCount)"
    }

    /// How many image/OCR-text page pairs the loaded document has (1 for a standard 2-page archival PDF).
    var pairCount: Int { DocumentPagePairs.pairCount(pageCount: current?.pageCount ?? 0) }

    /// Left pane = the current pair's image page. Present for any non-empty PDF.
    var imagePage: PDFPage? { page(at: DocumentPagePairs.imagePageIndex(pair: pair)) }
    /// The left pane switches to the linked full-resolution image while the PDF remains loaded for its
    /// OCR text pages, navigation, and page-level citations.
    var displayedImagePage: PDFPage? { imageSource == .jpeg ? jpegPartnerPage : imagePage }
    var hasJPEGPartner: Bool { jpegPartnerPage != nil }
    var isShowingJPEG: Bool { imageSource == .jpeg }
    /// Right pane = the current pair's OCR text page, when the pair has one (a trailing odd image page
    /// has none).
    var textPage: PDFPage? { page(at: DocumentPagePairs.textPageIndex(pair: pair)) }
    var hasTextPage: Bool { textPage != nil }

    /// W44.reocr-reader: who read this pair's text page and its Kind, from the page's own header
    /// ("Gemini · gemini-3.7-flash · Typewritten"); nil when the header names neither. Display only.
    var textPageReading: String? {
        let key = pageIdentity
        if let cached = readingCache, cached.key == key { return cached.value }
        let header = textPage.map { PDFHeaderParser.parse($0).header } ?? nil
        var parts: [String] = []
        if let p = header?.provenance { parts += [p.provider, p.model] }
        if let k = header?.kind { parts.append(k.displayName) }
        let value = parts.isEmpty ? nil : parts.joined(separator: " · ")
        readingCache = (key, value)
        return value
    }
    private var readingCache: (key: String, value: String?)?

    /// The file's contents were replaced (an Improve OCR receipt): load it again from the disk, on the same
    /// pair where it still exists. Any other window's file is left alone.
    func reloadReplaced(paths: Set<String>) {
        guard let path = currentFilePath, paths.contains(path) else { return }
        let keep = pair
        neighbours = NeighbourCache()
        contentRevision += 1
        loadCurrent()
        setPair(keep)
        tagStatus = "The text of this file was improved in Archive Processor; it is shown now."
    }

    func updateArchiveContext(target: ArchiveLinkTarget?, index: JPEGPartnerIndex?) {
        archiveLinkTarget = target
        jpegPartnerIndex = index
        refreshJPEGPartner()
        prepareNeighbours()
    }

    /// Whether a document or JPEG original has been opened ahead and is waiting (tests and the switch probe).
    func holdsPrepared(document path: String) -> Bool { neighbours.holds(document: path) }
    var preparedCounts: (documents: Int, jpegs: Int) { (neighbours.documentCount, neighbours.jpegCount) }

    /// The open file and the files either side: the image pages the document window draws ahead.
    var neighbourhoodPaths: [String] {
        [index, index + 1, index - 1].filter { urls.indices.contains($0) }.map { urls[$0].path }
    }

    func toggleImageSource() {
        guard hasJPEGPartner else { return }
        leftController.captureViewport()   // the other image opens on the same region (W40.fix-reader-jpeg-keep-view)
        imageSource = imageSource == .pdf ? .jpeg : .pdf
        guard persistsImageSource,
              let target = archiveLinkTarget,
              let relativePath = relativePDFPath(for: currentURL, rootPath: target.rootPath) else { return }
        imageSourcePreferences.set(imageSource, rootGUID: target.preferenceGUID, relativePath: relativePath)
    }

    /// Bounds-checked page lookup — `pair` can outrun a freshly-loaded shorter document for one
    /// publish cycle, and PDFKit is happier not being asked for a page it doesn't have.
    private func page(at pageIndex: Int) -> PDFPage? {
        guard let doc = current, pageIndex >= 0, pageIndex < doc.pageCount else { return nil }
        return doc.page(at: pageIndex)
    }

    /// Identity of the displayed page pair. The panes use it for `.id(…)` so stepping between pairs gives
    /// each a FRESH PDFView (DV-3), exactly as cycling documents does. Required, not cosmetic:
    /// `PDFPaneView.updateNSView`'s reuse fallback compares `page.string`, which is `nil` for both an old
    /// and a new *image* page — so without the pair in the identity the left pane would keep showing the
    /// previous scan.
    var pageIdentity: String { contentRevision == 0 ? "\(index)#\(pair)" : "\(index)#\(pair)#r\(contentRevision)" }
    /// The image pane's identity also covers the PDF / JPEG switch, so the swap always builds a fresh view
    /// that takes the carried zoom and region, rather than leaning on `updateNSView`'s text comparison
    /// (an image page and a JPEG both have no text, so it cannot tell them apart).
    var imagePaneIdentity: String { "\(pageIdentity)#\(imageSource.rawValue)#\(imageTurns)" }

    // MARK: Rotation — a view of the page, the file untouched (W40.reader-view-rotate)

    /// Quarter turns clockwise the reader gave the current image page, 0…3, from `pageTurns`. The PDF's image
    /// page and its JPEG original are the same photograph, so one turn serves both; the OCR text page is not
    /// turned. The image pane's identity includes it, so a turn builds a fresh view.
    var imageTurns: Int {
        guard let path = currentFilePath, imagePage != nil else { return 0 }
        return pageTurns.turns(path: path, page: DocumentPagePairs.imagePageIndex(pair: pair))
    }
    /// An image page is on screen, so there is something to turn.
    var canRotate: Bool { imagePage != nil && !showingAllPages }
    var isRotated: Bool { imageTurns != 0 }

    func rotateLeft() { setImageTurns(imageTurns - 1) }
    func rotateRight() { setImageTurns(imageTurns + 1) }
    func resetRotation() { setImageTurns(0) }

    private func setImageTurns(_ turns: Int) {
        guard canRotate, let path = currentFilePath else { return }
        objectWillChange.send()
        leftController.clearSelection()   // a selection's place on screen moves with the page; start clean
        pageTurns.set(turns, path: path, page: DocumentPagePairs.imagePageIndex(pair: pair))
    }

    /// The text extracted from the current pair's image page, when that pair has no OCR text page (a
    /// single-page PDF with selectable text, or an odd trailing scan). `nil` when a text page exists or
    /// the image page has no text layer.
    var embeddedText: String? {
        guard textPage == nil, let text = imagePage?.string, !text.isEmpty else { return nil }
        return text
    }

    /// A one-line warning when the current document is non-standard — image-only with no selectable
    /// OCR text anywhere. `nil` for a standard document. (Open failures / empty PDFs are already
    /// surfaced via `loadError`, so this focuses on the no-text-layer case.) Derived from the loaded
    /// `PDFDocument` — no re-read; mirrors `PDFFormatStatus.noTextLayer`.
    var formatNote: String? {
        guard let doc = current, doc.pageCount > 0 else { return nil }
        let hasText = (0..<doc.pageCount).contains { doc.page(at: $0)?.string?.isEmpty == false }
        return hasText ? nil : "No OCR text layer — this document is image-only, so text search and copy won’t work here."
    }

    // MARK: Copy — one live selection (W40.fix-reader-copy-text-pane)

    /// Intelligent copy (prose-cleaned) from the pane that holds the selection — ⇧⌘C.
    func copySelection() { copyToPasteboard(cleanedCopyText(AppSettings.copyOptions)) }

    /// Plain/direct copy — the raw selected text, exactly as the pane reports it (no cleaning) — ⌘C, which
    /// is Edit ▸ Copy reaching a pane's `copy:` (W48.reader-copy-shortcut).
    func copyPlainSelection() { copyToPasteboard(plainCopyText) }

    /// What ⌘C puts on the pasteboard (tests read it here rather than from the owner's clipboard).
    var plainCopyText: String? { selectedText(plainSelection(in:)) }

    /// What ⇧⌘C puts on the pasteboard.
    func cleanedCopyText(_ opts: CopyTextOptions) -> String? {
        selectedText { pane in
            pane == .left ? leftController.cleanedSelection(opts)
                : hasTextPage ? rightController.cleanedSelection(opts) : textController.cleanedSelection(opts)
        }
    }

    /// Any pane has selected text — what enables Edit ▸ Copy over the viewer.
    var hasTextSelection: Bool { !showingAllPages && (plainSelection(in: .left) != nil || plainSelection(in: .right) != nil) }

    /// The right pane is a PDFView over the OCR text page when the pair has one, else the extracted text.
    private func plainSelection(in pane: Pane) -> String? {
        pane == .left ? leftController.plainSelection()
            : hasTextPage ? rightController.plainSelection() : textController.plainSelection()
    }

    /// The focused pane's selection, else the other's. A selection the user makes moves the focus to its
    /// pane and clears the other (`userSelected`), so this is the pane the user selected in; only find,
    /// which selects its hit in both panes of the pair, leaves two, and then the focused pane is the one
    /// that shows the hit.
    private func selectedText(_ read: (Pane) -> String?) -> String? {
        guard !showingAllPages else { return nil }
        let other: Pane = focusedPane == .left ? .right : .left
        return read(focusedPane) ?? read(other)
    }

    /// The user selected text in `pane`: it takes the focus border, and the other pane's selection goes, so
    /// it is never ambiguous what a copy or a service takes (owner's Reader session 2, row 12).
    func userSelected(in pane: Pane) {
        focusedPane = pane
        if pane == .left {
            rightController.clearSelection()
            textController.clearSelection()
        } else {
            leftController.clearSelection()
        }
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: The image pane's own menu — Copy Image, Reveal in Finder (W40.reader-image-context-menu)

    /// The image page as the pane shows it: the PDF's image page or its JPEG original, turned as `pageTurns`
    /// says. Drawn from a private copy of the page, so neither the file nor the model's page is turned. A JPEG
    /// original's page is sized in pixels and is drawn one to one; a PDF page, in points, at 300 dpi.
    var shownImage: CGImage? {
        guard !showingAllPages, let page = displayedImagePage else { return nil }
        return PDFPaneController.render(page, turns: imageTurns, scale: isShowingJPEG ? 1 : 300 / 72)
    }

    /// The file the shown image comes from: the JPEG original while it is shown, else the PDF.
    var shownImageFileURL: URL? {
        guard displayedImagePage != nil else { return nil }
        if isShowingJPEG { return loadedPartner.map { URL(fileURLWithPath: $0.path) } }
        return currentURL
    }

    /// Copy Image: the shown image on the pasteboard, as an image other apps paste.
    func copyImage(to pasteboard: NSPasteboard = .general) {
        guard let image = shownImage else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    /// Reveal in Finder: the shown image's file, selected in a Finder window. Read-only.
    func revealShownImageFile() {
        guard let url = shownImageFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: In-document find (⌘F) — highlight all matches, next/prev across every open PDF

    /// Rebuild the match list for `findQuery` across ALL open documents — every page pair of each, which
    /// is everything the viewer can now navigate to — start on the first match, and reveal it. Scanning
    /// opens each not-currently-loaded PDF once, so this runs on submit / next / prev — not per keystroke.
    /// (A very large multi-document selection therefore pauses briefly on the first search; acceptable
    /// because the viewer opens one document at a time and selections are bounded in practice.)
    func performFind() {
        guard supportsFind else { return }
        showingAllPages = false
        let query = findQuery
        lastFoundQuery = query
        guard !query.isEmpty else {
            findNavigator = FindNavigator()
            refreshFindPublished()
            applyCurrentMatch()
            return
        }
        var perPair: [(doc: Int, pair: Int, left: Int, right: Int)] = []
        for i in urls.indices {
            // Reuse the already-loaded document for the current index; open the rest read-only.
            let doc = (i == index) ? current : PDFDocument(url: urls[i])
            guard let doc else { continue }
            for (p, counts) in DocumentFindScanner.pairMatchCounts(in: doc, query: query).enumerated() {
                perPair.append((doc: i, pair: p, left: counts.left, right: counts.right))
            }
        }
        findNavigator = FindNavigator(perPair: perPair)
        refreshFindPublished()
        applyCurrentMatch()
    }

    /// Show the find bar and ask the view to focus its field. ⌘F and the toolbar's Find button.
    func beginFind() {
        guard supportsFind else { return }
        showingAllPages = false
        showingFind = true
        findFocusRequest += 1
    }

    /// Move to the next match (wrapping past the last), rebuilding first if the query changed. ⌘G.
    func findNext() {
        guard supportsFind else { return }
        showingAllPages = false
        if findQuery != lastFoundQuery { performFind(); return }
        findNavigator.next()
        refreshFindPublished()
        applyCurrentMatch()
    }

    /// Step to the previous match (wrapping before the first), rebuilding first if the query changed. ⌘⇧G.
    func findPrevious() {
        guard supportsFind else { return }
        showingAllPages = false
        if findQuery != lastFoundQuery { performFind(); return }
        findNavigator.previous()
        refreshFindPublished()
        applyCurrentMatch()
    }

    /// Close the find bar: clear the query, the navigator, and every pane's highlight.
    func endFind() {
        showingFind = false
        findQuery = ""
        lastFoundQuery = nil
        findNavigator = FindNavigator()
        refreshFindPublished()
        leftController.clearFind()
        rightController.clearFind()
    }

    /// Find-bar status: "3 of 12" / "No matches", shown only once the *current* query has been searched
    /// (blank while the user is still typing a new query, before submitting it).
    var findStatusText: String {
        guard !findQuery.isEmpty, findQuery == lastFoundQuery else { return "" }
        return findTotal == 0 ? "No matches" : "\(findOrdinal ?? 1) of \(findTotal)"
    }

    private func refreshFindPublished() {
        findOrdinal = findNavigator.ordinal
        findTotal = findNavigator.total
    }

    /// Push the navigator's current match down to the panes. A move within the displayed pair applies
    /// immediately; a move to another pair or another document sets each pane's target FIRST, then changes
    /// `pair`/`index` so the pane rebuild re-applies it (via `applyToView` → `applyFind`) with no timing
    /// race — the pane's `.id(pageIdentity)` covers a pair change exactly as it covers a document change.
    private func applyCurrentMatch() {
        guard let loc = findNavigator.current else {
            // No current match (empty query or zero matches): clear the current selection but still push
            // the query so any incidental matches on the shown pages stay highlighted.
            leftController.setFindTarget(query: findQuery, currentIndex: nil)
            rightController.setFindTarget(query: findQuery, currentIndex: nil)
            leftController.applyFind()
            rightController.applyFind()
            return
        }
        // The current hit is selected in BOTH panes of its pair, each pane at its own match for it
        // (W40.fix-reader-find-both-panes); a pane without one just highlights its matches.
        leftController.setFindTarget(query: findQuery, currentIndex: loc.left)
        rightController.setFindTarget(query: findQuery, currentIndex: loc.right)
        if loc.doc != index {
            index = loc.doc     // → loadCurrent() (pair 0) + pane rebuild → applyToView() re-applies it
            setPair(loc.pair)
        } else if loc.pair != pair {
            setPair(loc.pair)   // same document, different pair → pane `.id` changes → rebuild re-applies
        } else {
            leftController.applyFind()
            rightController.applyFind()
        }
        // Move the focus border (not keyboard focus — the find field keeps that) only when the focused
        // pane does not show the hit, preferring the text page. Set last: `setPair` pulls focus off a
        // text pane that doesn't exist, and a pane holding the hit always does.
        if !loc.holds(focusedPane) { focusedPane = loc.right != nil ? .right : .left }
    }

    /// What the extracted-text pane highlights: the searched query, and which of its matches is the
    /// current hit — whatever the image pane beside it selects, since that pane shows the same text layer
    /// (so paging away and back drops the current hit in both, as `prepareFindForManualCycle` does).
    /// `nil` while no query has been searched.
    var extractedTextFind: (query: String, current: Int?)? {
        guard let query = lastFoundQuery, !query.isEmpty else { return nil }
        return (query, leftController.findCurrentIndex)
    }

    // MARK: Page-level durable links (W23.m4)

    /// The **1-based PDF page number** a page link should cite: the page shown in the pane that has
    /// focus. Citing the OCR text page while reading it, and the scan while looking at the scan, is what
    /// makes a link round-trip — `goToPDFPage` puts the reader back on exactly that pane.
    ///
    /// Falls back to the pair's image page when the focused pane holds no page at all (a trailing scan
    /// with no OCR text page, or a document that failed to load), so the number always names a page the
    /// document plausibly has rather than one past its end.
    var focusedPageNumber: Int {
        guard focusedPane == .right, textPage != nil else {
            return DocumentPagePairs.imagePageIndex(pair: pair) + 1
        }
        return DocumentPagePairs.textPageIndex(pair: pair) + 1
    }

    /// Move the panes to a **1-based PDF page number** (what a durable page link carries) and put the
    /// focus border on the pane that page occupies — the inverse of `focusedPageNumber`. Clamped by
    /// `setPair`, so a link whose page is past the end of a since-shortened document lands on the last
    /// pair instead of showing nothing. A cited OCR text page that no longer exists degrades to its
    /// pair's image page rather than focusing an empty pane.
    func goToPDFPage(_ page: Int) {
        showingAllPages = false
        let pageIndex = max(0, page - 1)
        setPair(DocumentPagePairs.pair(ofPageIndex: pageIndex))
        // Set after `setPair` — which pulls focus off a text pane that doesn't exist — and re-check
        // `textPage`, which is a function of the pair we just moved to.
        focusedPane = (!DocumentPagePairs.isImagePage(pageIndex) && textPage != nil) ? .right : .left
    }

    /// Build the pasteboard item for a page link to the page on screen, without touching the pasteboard
    /// — so the *contents* of the link (in particular which page it names) are testable.
    /// `nil` when no document is loaded.
    func archivePageLink(target: ArchiveLinkTarget) async -> NSPasteboardItem? {
        guard urls.indices.contains(index), let marker = target.marker else { return nil }
        return await ArchiveLinkWriter.pageLink(
            fileURL: urls[index], page: focusedPageNumber,
            rootPath: target.rootPath, marker: marker, thumbnailer: thumbnailer,
            mainRootPath: target.mainRootPath, jpegPartnerIndex: jpegPartnerIndex
        )
    }

    /// Copy through the shared focused context, preparing a durable identity only on this deliberate
    /// action. The document window and preview need no focused NavigationModel (W23.m4).
    @Published var archiveLinkError: String?

    func copyArchivePageLink(context: ArchiveLinkContext) {
        guard urls.indices.contains(index) else { return }
        guard let target = context.prepareForCopy?(urls[index]) else {
            archiveLinkError = context.copyFailureMessage?() ?? "Choose an archive folder first."
            return
        }
        archiveLinkError = nil
        copyArchivePageLink(target: target)
    }

    func copyArchivePageLink(target: ArchiveLinkTarget) {
        guard urls.indices.contains(index), let marker = target.marker else { return }
        // Snapshot the page at command time. Rendering is asynchronous, but a later document/page change
        // must not silently turn the user's copied citation into whatever happens to be visible later.
        let fileURL = urls[index]
        let page = focusedPageNumber
        let immediateItem = ArchiveLinkWriter.pageLinkWithoutThumbnail(
            fileURL: fileURL, page: page, rootPath: target.rootPath, marker: marker,
            mainRootPath: target.mainRootPath, jpegPartnerIndex: jpegPartnerIndex
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([immediateItem])
        let expectedChangeCount = NSPasteboard.general.changeCount
        archivePageLinkCopyGeneration &+= 1
        let generation = archivePageLinkCopyGeneration
        Task {
            let item = await ArchiveLinkWriter.pageLink(
                fileURL: fileURL, page: page, rootPath: target.rootPath, marker: marker,
                thumbnailer: thumbnailer, mainRootPath: target.mainRootPath,
                jpegPartnerIndex: jpegPartnerIndex
            )
            guard archivePageLinkCopyGeneration == generation,
                  NSPasteboard.general.changeCount == expectedChangeCount else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
        }
    }

    nonisolated private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "bmp", "gif"
    ]

    private func loadCurrent() {
        showingAllPages = false
        pair = 0   // a newly loaded document always opens on its first page pair
        tagStatus = nil
        let outgoing = current.map { (document: $0, loaded: loaded, page: jpegPartnerPage, partner: loadedPartner) }
        jpegPartnerPage = nil
        jpegPartnerRelativePath = nil
        imageSource = .pdf
        guard urls.indices.contains(index) else { current = nil; loadError = nil; loaded = nil; return }
        let url = urls[index]
        #if DEBUG
        if reportsSwitches {   // the document window, not the preview
            ViewerSwitchProbe.shared?.switchStarted(bitmapReady: imagePrefetcher.image(path: url.path, pageIndex: 0) != nil)
        }
        #endif
        // The file just left is often the next one wanted (Previous after Next), so it is kept, already
        // drawn, beside the neighbours being opened.
        if let outgoing, let file = outgoing.loaded, !Self.prefetchDisabled {
            neighbours.keep(document: outgoing.document, file)
            if let page = outgoing.page, let partner = outgoing.partner { neighbours.keep(jpeg: page, partner) }
        }
        ReaderStages.measure("viewer.loadDocument") { loadDocument(url) }
        if let current { pageCounts.set(current.pageCount, for: url.path) }
        ReaderStages.measure("viewer.jpegPartner") { refreshJPEGPartner() }
        prepareNeighbours()
    }

    /// The file in `current`, and the JPEG original in `jpegPartnerPage`, as they were when opened.
    private var loaded: NeighbourCache.File?
    private var loadedPartner: NeighbourCache.File?

    private func loadDocument(_ url: URL) {
        loaded = NeighbourCache.File(url.path)
        if let prepared = neighbours.document(at: url.path) {
            current = prepared
            loadError = prepared.pageCount == 0 ? "“\(url.lastPathComponent)” has no pages." : nil
        } else if let doc = PDFDocument(url: url) {
            current = doc
            loadError = doc.pageCount == 0 ? "“\(url.lastPathComponent)” has no pages." : nil
        } else if Self.imageExtensions.contains(url.pathExtension.lowercased()),
                  let image = NSImage(contentsOf: url),
                  let page = PDFPage(image: image) {
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            current = doc
            loadError = nil
        } else {
            current = nil
            loadError = "Could not open “\(url.lastPathComponent)” (missing, corrupt, or unsupported format)."
        }
    }

    private var currentURL: URL? { urls.indices.contains(index) ? urls[index] : nil }

    // MARK: Opening the files either side ahead (W40.fix-reader-viewer-switch)

    /// Open the next and previous files, and their JPEG originals, on `prepareQueue`, so a file switch
    /// takes a document already open (its text read) instead of opening one on the main actor. Each is
    /// built and read on that queue and handed over only when finished; from then on only the main actor
    /// touches it, and nothing is ever written. The cache holds the open file's neighbours and nothing else.
    private func prepareNeighbours() {
        guard !Self.prefetchDisabled else { return }
        let wanted = [index + 1, index - 1].filter { urls.indices.contains($0) }.map { urls[$0] }
        var partners: [String: URL] = [:]
        // A link that pins its JPEG names one file for every PDF, so nothing is opened ahead for it.
        if !pinsJPEGPartnerFromLink {
            for url in wanted { if let partner = jpegPartnerURL(for: url) { partners[url.path] = partner } }
        }
        neighbours.retain(documents: Set(wanted.map(\.path)), jpegs: Set(partners.values.map(\.path)))
        let keys = Set(wanted.map { "d:" + $0.path } + partners.values.map { "j:" + $0.path })
        stillWanted.withLock { $0 = keys }
        let stillWanted = stillWanted
        for url in wanted {
            if let file = neighbours.start(document: url.path) {
                prepareQueue.async { [weak self] in
                    let opened = Handover(stillWanted.withLock { $0.contains("d:" + url.path) } ? Self.openDocument(url) : nil)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.neighbours.finish(document: opened.value, file) }
                    }
                }
            }
            if let partner = partners[url.path], let file = neighbours.start(jpeg: partner.path) {
                prepareQueue.async { [weak self] in
                    let opened = Handover(stillWanted.withLock { $0.contains("j:" + partner.path) } ? Self.openJPEGPage(partner) : nil)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.neighbours.finish(jpeg: opened.value, file) }
                    }
                }
            }
        }
    }

    /// Open a file the way `loadDocument` does, off the main actor, and read its pages' text there (the
    /// text pane and the format banner read it on the main actor as the file is shown). Read-only.
    nonisolated private static func openDocument(_ url: URL) -> PDFDocument? {
        let doc: PDFDocument
        if let pdf = PDFDocument(url: url) {
            doc = pdf
        } else if imageExtensions.contains(url.pathExtension.lowercased()),
                  let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
            doc = PDFDocument()
            doc.insert(page, at: 0)
        } else {
            return nil
        }
        for i in 0..<min(doc.pageCount, 8) { _ = doc.page(at: i)?.string }
        return doc
    }

    #if DEBUG
    static var prefetchDisabled: Bool { ViewerSwitchProbe.prefetchDisabled }
    #else
    static let prefetchDisabled = false
    #endif

    nonisolated private static func openJPEGPage(_ url: URL) -> PDFPage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return PDFPage(image: image)
    }

    /// A file's JPEG original, by the same checks `refreshJPEGPartner` makes, or nil. Cheap: the index
    /// answers from dictionaries.
    private func jpegPartnerURL(for pdfURL: URL) -> URL? {
        guard let target = archiveLinkTarget, let index = jpegPartnerIndex, index.isClean,
              case .match(let url) = resolvedJPEGPartner(pdfURL: pdfURL, target: target, index: index),
              ReaderArchiveLayout.isContained(url, inRootPath: target.rootPath),
              ReaderArchiveLayout.isSupportedImage(url.pathExtension),
              index.candidate(atPath: filesystemPath(url))?.fingerprint.isDataless != true else { return nil }
        return url
    }

    private func refreshJPEGPartner() {
        jpegPartnerPage = nil
        loadedPartner = nil
        jpegPartnerRelativePath = nil
        imageSource = .pdf
        jpegUnavailableReason = nil
        guard let pdfURL = currentURL, current != nil else { return }
        guard let target = archiveLinkTarget else {
            jpegUnavailableReason = "No JPEG original: this file is not inside an open archive."
            return
        }
        guard let index = jpegPartnerIndex else {
            jpegUnavailableReason = "No JPEG originals yet: the “\(ReaderArchiveLayout.jpegDirectoryName)” folder "
                + "beside “\(ReaderArchiveLayout.mainDirectoryName)” was not found, or is still being checked."
            return
        }
        guard index.isClean else {
            jpegUnavailableReason = "JPEG originals are unknown until the JPEG folder is checked again; rescan to retry."
            return
        }
        let partnerURL: URL
        switch resolvedJPEGPartner(pdfURL: pdfURL, target: target, index: index) {
        case .match(let url): partnerURL = url
        case .ambiguous:
            jpegUnavailableReason = "More than one JPEG has this file's name, so the Reader cannot tell which is its original."
            return
        case .unknown:
            jpegUnavailableReason = "No JPEG original: this file is not inside “\(ReaderArchiveLayout.mainDirectoryName)”."
            return
        case .none:
            jpegUnavailableReason = pinsJPEGPartnerFromLink
                ? "No JPEG original: the JPEG this link names is no longer in the JPEG folder."
                : "No JPEG original: the JPEG folder has no file with this file's name."
            return
        }
        guard ReaderArchiveLayout.isContained(partnerURL, inRootPath: target.rootPath),
              ReaderArchiveLayout.isSupportedImage(partnerURL.pathExtension) else {
            jpegUnavailableReason = "No JPEG original: the JPEG folder has no file with this file's name."
            return
        }
        guard index.candidate(atPath: filesystemPath(partnerURL))?.fingerprint.isDataless != true else {
            jpegUnavailableReason = "The JPEG original is not downloaded to this Mac."
            return
        }
        let partnerFile = NeighbourCache.File(partnerURL.path)
        guard let page = neighbours.jpeg(at: partnerURL.path) ?? Self.openJPEGPage(partnerURL) else {
            jpegUnavailableReason = "The JPEG original “\(partnerURL.lastPathComponent)” could not be opened."
            return
        }
        let partnerRelativePath = relativePDFPath(for: partnerURL, rootPath: target.rootPath)
        if pinsJPEGPartnerFromLink, linkedJPEGRelativePath != partnerRelativePath {
            jpegUnavailableReason = "No JPEG original: the JPEG this link names is no longer in the JPEG folder."
            return
        }
        jpegPartnerPage = page
        loadedPartner = partnerFile
        jpegPartnerRelativePath = partnerRelativePath
        guard let relativePath = relativePDFPath(for: pdfURL, rootPath: target.rootPath) else { return }
        if persistsImageSource {
            imageSource = imageSourcePreferences.source(rootGUID: target.preferenceGUID,
                                                        relativePath: relativePath)
            if imageSource == .jpeg, jpegPartnerPage == nil { imageSource = .pdf }
        }
    }

    private func relativePDFPath(for url: URL?, rootPath: String) -> String? {
        guard let url else { return nil }
        let path = url.withUnsafeFileSystemRepresentation { raw in raw.map(String.init(cString:)) ?? url.path }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func resolvedJPEGPartner(pdfURL: URL, target: ArchiveLinkTarget,
                                     index: JPEGPartnerIndex) -> JPEGPartnerResolution {
        if pinsJPEGPartnerFromLink {
            guard let relative = linkedJPEGRelativePath, !relative.isEmpty,
                  !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
                return .none
            }
            let prefix = target.rootPath.hasSuffix("/") ? target.rootPath : target.rootPath + "/"
            guard let candidate = index.candidate(atPath: prefix + relative) else {
                return .none
            }
            return .match(candidate.path.withCString {
                URL(fileURLWithFileSystemRepresentation: $0, isDirectory: false, relativeTo: nil)
            })
        }
        return index.resolve(pdfURL: pdfURL,
                             mainRoot: URL(fileURLWithPath: target.mainRootPath, isDirectory: true))
    }

    private func filesystemPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { raw in raw.map(String.init(cString:)) ?? url.path }
    }
}

/// A PDFKit object built on the viewer's prepare queue, carried to the main actor once finished. Nothing
/// touches it on the queue after the hand-over, so it is never used from two threads at once.
private final class Handover<Value>: @unchecked Sendable {
    let value: Value?
    init(_ value: Value?) { self.value = value }
}

/// The documents and JPEG pages opened ahead for the files either side of the open one
/// (W40.fix-reader-viewer-switch). Bounded by what `retain` names: at most two documents and two JPEG
/// pages, plus the file just left until the next `retain`. Each entry carries its file's `stat(2)` stamp
/// from before it was opened, and is served only while the file still has it, so a rewritten file is
/// opened afresh rather than shown as it was.
@MainActor
struct NeighbourCache {
    struct File: Equatable {
        let path: String
        let stamp: PreviewImagePrefetcher.FileStamp?
        init(_ path: String) {
            self.path = path
            stamp = PreviewImagePrefetcher.FileStamp.of(path)
        }
    }

    private var documents: [String: (value: PDFDocument, file: File)] = [:]
    private var jpegs: [String: (value: PDFPage, file: File)] = [:]
    private var pending: Set<String> = []          // "d:" + path or "j:" + path
    private var wantedDocuments: Set<String> = []
    private var wantedJPEGs: Set<String> = []

    var documentCount: Int { documents.count }
    func holds(document path: String) -> Bool { documents[path] != nil }
    var jpegCount: Int { jpegs.count }

    /// Keep only these; anything else is dropped, and a late arrival for anything else is discarded.
    mutating func retain(documents keep: Set<String>, jpegs keepJPEGs: Set<String>) {
        wantedDocuments = keep
        wantedJPEGs = keepJPEGs
        documents = documents.filter { keep.contains($0.key) }
        jpegs = jpegs.filter { keepJPEGs.contains($0.key) }
    }

    /// The file's stamp now if it needs opening (nothing held for it, nothing on the way), else nil. A file
    /// whose bytes are not on this Mac is not opened ahead: that would download it unasked.
    mutating func start(document path: String) -> File? {
        guard documents[path] == nil, !pending.contains("d:" + path) else { return nil }
        let file = File(path)
        guard file.stamp?.isDataless != true else { return nil }
        pending.insert("d:" + path)
        return file
    }

    mutating func start(jpeg path: String) -> File? {
        guard jpegs[path] == nil, !pending.contains("j:" + path) else { return nil }
        let file = File(path)
        guard file.stamp?.isDataless != true else { return nil }
        pending.insert("j:" + path)
        return file
    }

    mutating func finish(document: PDFDocument?, _ file: File) {
        pending.remove("d:" + file.path)
        if let document, wantedDocuments.contains(file.path) { documents[file.path] = (document, file) }
    }

    mutating func finish(jpeg: PDFPage?, _ file: File) {
        pending.remove("j:" + file.path)
        if let jpeg, wantedJPEGs.contains(file.path) { jpegs[file.path] = (jpeg, file) }
    }

    /// Hold a document already open (the file just left), until the next `retain`.
    mutating func keep(document: PDFDocument, _ file: File) { documents[file.path] = (document, file) }
    mutating func keep(jpeg: PDFPage, _ file: File) { jpegs[file.path] = (jpeg, file) }

    /// Take the document opened for `path`, if the file is unchanged since; it leaves the cache.
    mutating func document(at path: String) -> PDFDocument? {
        guard let entry = documents.removeValue(forKey: path), entry.file == File(path) else { return nil }
        return entry.value
    }

    mutating func jpeg(at path: String) -> PDFPage? {
        guard let entry = jpegs.removeValue(forKey: path), entry.file == File(path) else { return nil }
        return entry.value
    }
}
