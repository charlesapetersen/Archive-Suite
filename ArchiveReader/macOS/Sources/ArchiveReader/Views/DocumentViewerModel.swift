import SwiftUI
import PDFKit
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
    @Published private(set) var current: PDFDocument?
    @Published private(set) var loadError: String?
    @Published var showingFind = false   // driven by the toolbar and the Document menu
    @Published var findQuery = ""        // the find-bar text (bound to the field)
    @Published private(set) var findOrdinal: Int?     // 1-based position of the current match ("3 of 12")
    @Published private(set) var findTotal = 0         // total matches across ALL open documents

    private var findNavigator = FindNavigator()
    private var lastFoundQuery: String?  // the query the navigator was last built for (avoids rescanning)

    let leftController: PDFPaneController     // the current pair's image page (PDF page 2·pair)
    let rightController: PDFPaneController   // the current pair's OCR text page (PDF page 2·pair + 1)

    /// `persists: false` → preview mode: fit-to-pane default, zoom changes don't write to UserDefaults.
    init(persists: Bool = true) {
        leftController = PDFPaneController(key: "left", persists: persists)
        rightController = PDFPaneController(key: "right", persists: persists)
    }

    /// Which pane keyboard focus / zoom acts on. ⌘↑/⌘↓ zoom this pane; ⌘⌥←/→ switch it.
    enum Pane: Sendable, Equatable { case left, right }
    @Published var focusedPane: Pane = .left

    func load(_ selection: DocumentSelection) {
        urls = selection.filePaths.map { URL(fileURLWithPath: $0) }
        index = 0
        focusedPane = .left
        loadCurrent()
    }

    /// Step forward one page pair; past the current document's last pair, move to the next file.
    func next() {
        if pair + 1 < pairCount { prepareFindForManualCycle(); setPair(pair + 1); return }
        guard index < urls.count - 1 else { return }
        prepareFindForManualCycle()
        index += 1                          // didSet → loadCurrent() → pair 0 of the new document
    }

    /// Step back one page pair; before the current document's first pair, move to the previous file and
    /// land on its LAST pair, so walking backwards visits every pair rather than skipping to page 1.
    func previous() {
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
        if focusedPane == .right, textPage == nil { focusedPane = .left }
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
    func focusPane(_ p: Pane) { focusedPane = p; controller(p).focus() }
    func zoomFocusedIn()  { controller(focusedPane).zoomIn() }
    func zoomFocusedOut() { controller(focusedPane).zoomOut() }
    func fitFocused()     { controller(focusedPane).fit() }

    var title: String { urls.indices.contains(index) ? urls[index].lastPathComponent : "Document View" }

    /// "3 of 12" across the open selection, plus " · page 2 of 4" when the current document holds more
    /// than one page pair — so a merged multi-page document says where you are inside it. Single-pair
    /// documents (the overwhelming majority) keep the original label exactly.
    var positionLabel: String {
        guard !urls.isEmpty else { return "" }
        let file = "\(index + 1) of \(urls.count)"
        guard pairCount > 1 else { return file }
        return "\(file) · page \(pair + 1) of \(pairCount)"
    }

    /// How many image/OCR-text page pairs the loaded document has (1 for a standard 2-page archival PDF).
    var pairCount: Int { DocumentPagePairs.pairCount(pageCount: current?.pageCount ?? 0) }

    /// Left pane = the current pair's image page. Present for any non-empty PDF.
    var imagePage: PDFPage? { page(at: DocumentPagePairs.imagePageIndex(pair: pair)) }
    /// Right pane = the current pair's OCR text page, when the pair has one (a trailing odd image page
    /// has none).
    var textPage: PDFPage? { page(at: DocumentPagePairs.textPageIndex(pair: pair)) }
    var hasTextPage: Bool { textPage != nil }

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
    var pageIdentity: String { "\(index)#\(pair)" }

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

    /// Intelligent copy (prose-cleaned) from whichever pane holds the selection — ⌘⇧C.
    func copySelection() {
        let opts = AppSettings.copyOptions
        let text = rightController.cleanedSelection(opts) ?? leftController.cleanedSelection(opts)
        copyToPasteboard(text)
    }

    /// Plain/direct copy — the raw selected text, exactly as PDFKit reports it (no cleaning) — ⌘C.
    func copyPlainSelection() {
        let text = rightController.plainSelection() ?? leftController.plainSelection()
        copyToPasteboard(text)
    }

    private func copyToPasteboard(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: In-document find (⌘F) — highlight all matches, next/prev across every open PDF

    /// Rebuild the match list for `findQuery` across ALL open documents — every page pair of each, which
    /// is everything the viewer can now navigate to — start on the first match, and reveal it. Scanning
    /// opens each not-currently-loaded PDF once, so this runs on submit / next / prev — not per keystroke.
    /// (A very large multi-document selection therefore pauses briefly on the first search; acceptable
    /// because the viewer opens one document at a time and selections are bounded in practice.)
    func performFind() {
        let query = findQuery
        lastFoundQuery = query
        guard !query.isEmpty else {
            findNavigator = FindNavigator()
            refreshFindPublished()
            applyCurrentMatch()
            return
        }
        var perPane: [(doc: Int, pair: Int, pane: Pane, count: Int)] = []
        for i in urls.indices {
            // Reuse the already-loaded document for the current index; open the rest read-only.
            let doc = (i == index) ? current : PDFDocument(url: urls[i])
            guard let doc else { continue }
            for (p, counts) in DocumentFindScanner.pairMatchCounts(in: doc, query: query).enumerated() {
                perPane.append((doc: i, pair: p, pane: .left, count: counts.left))
                perPane.append((doc: i, pair: p, pane: .right, count: counts.right))
            }
        }
        findNavigator = FindNavigator(perPane: perPane)
        refreshFindPublished()
        applyCurrentMatch()
    }

    /// Move to the next match (wrapping past the last), rebuilding first if the query changed. ⌘G.
    func findNext() {
        if findQuery != lastFoundQuery { performFind(); return }
        findNavigator.next()
        refreshFindPublished()
        applyCurrentMatch()
    }

    /// Step to the previous match (wrapping before the first), rebuilding first if the query changed. ⌘⇧G.
    func findPrevious() {
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
        // The current match owns exactly one pane; the other highlights its matches but holds no selection.
        leftController.setFindTarget(query: findQuery, currentIndex: loc.pane == .left ? loc.index : nil)
        rightController.setFindTarget(query: findQuery, currentIndex: loc.pane == .right ? loc.index : nil)
        if loc.doc != index {
            index = loc.doc     // → loadCurrent() (pair 0) + pane rebuild → applyToView() re-applies it
            setPair(loc.pair)
        } else if loc.pair != pair {
            setPair(loc.pair)   // same document, different pair → pane `.id` changes → rebuild re-applies
        } else {
            leftController.applyFind()
            rightController.applyFind()
        }
        // Move the focus border (not keyboard focus — the find field keeps that). Set last: `setPair`
        // pulls focus off a text pane that doesn't exist, and the match's own pane always does.
        focusedPane = loc.pane
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
        guard urls.indices.contains(index) else { return nil }
        return await ArchiveLinkWriter.pageLink(
            fileURL: urls[index], page: focusedPageNumber,
            root: target.root, marker: target.marker, thumbnailer: nil
        )
    }

    /// Copy an archive link for the page on screen to the pasteboard. Takes the root + marker as an
    /// `ArchiveLinkTarget` focused value rather than a `NavigationModel`, so the command is available in
    /// the document window too (W23.m4 defect 1).
    func copyArchivePageLink(target: ArchiveLinkTarget) {
        Task {
            guard let item = await archivePageLink(target: target) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
        }
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "bmp", "gif"
    ]

    private func loadCurrent() {
        pair = 0   // a newly loaded document always opens on its first page pair
        guard urls.indices.contains(index) else { current = nil; loadError = nil; return }
        let url = urls[index]
        if let doc = PDFDocument(url: url) {
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
}
