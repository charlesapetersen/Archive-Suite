import SwiftUI
import PDFKit
import ArchiveCore

/// Drives the document window: the selected files, the current document, and page cycling.
/// Loads one document at a time (never materializes the whole selection).
@MainActor
final class DocumentViewerModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published var index = 0 { didSet { if index != oldValue { loadCurrent() } } }
    @Published private(set) var current: PDFDocument?
    @Published private(set) var loadError: String?
    @Published var showingFind = false   // driven by the toolbar and the Document menu
    @Published var findQuery = ""        // the find-bar text (bound to the field)
    @Published private(set) var findOrdinal: Int?     // 1-based position of the current match ("3 of 12")
    @Published private(set) var findTotal = 0         // total matches across ALL open documents

    private var findNavigator = FindNavigator()
    private var lastFoundQuery: String?  // the query the navigator was last built for (avoids rescanning)

    let leftController: PDFPaneController     // image page (page 0)
    let rightController: PDFPaneController   // OCR text page (page 1)

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

    /// Move to the previous / next document within the current segment (the opened run/selection).
    func next()     { if index < urls.count - 1 { prepareFindForManualCycle(); index += 1 } }
    func previous() { if index > 0 { prepareFindForManualCycle(); index -= 1 } }

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
    var positionLabel: String { urls.isEmpty ? "" : "\(index + 1) of \(urls.count)" }

    /// Left pane = the image page (page 0). Present for any non-empty PDF.
    var imagePage: PDFPage? { current?.page(at: 0) }
    /// Right pane = the OCR text page (page 1) when the document has one.
    var textPage: PDFPage? {
        guard let doc = current, doc.pageCount > 1 else { return nil }
        return doc.page(at: 1)
    }
    var hasTextPage: Bool { textPage != nil }

    /// The text extracted from the first page's embedded text layer, when the document is a
    /// single-page PDF with selectable text but no OCR page-2. `nil` for multi-page (processed)
    /// PDFs or image-only documents.
    var embeddedText: String? {
        guard textPage == nil,
              let page = current?.page(at: 0),
              let text = page.string, !text.isEmpty else { return nil }
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

    /// Rebuild the match list for `findQuery` across ALL open documents (each document's page 0 + page 1,
    /// which is what the two-pane viewer can display), start on the first match, and reveal it. Scanning
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
        var perPane: [(doc: Int, pane: Pane, count: Int)] = []
        for i in urls.indices {
            // Reuse the already-loaded document for the current index; open the rest read-only.
            let doc = (i == index) ? current : PDFDocument(url: urls[i])
            guard let doc else { continue }
            let counts = DocumentFindScanner.paneMatchCounts(in: doc, query: query)
            perPane.append((doc: i, pane: .left, count: counts.left))
            perPane.append((doc: i, pane: .right, count: counts.right))
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

    /// Push the navigator's current match down to the panes. A same-document move applies immediately; a
    /// cross-document move sets each pane's target FIRST, then changes `index` so the pane rebuild
    /// re-applies it (via `applyToView` → `applyFind`) with no timing race.
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
        focusedPane = loc.pane   // move the focus border (not keyboard focus — the find field keeps that)
        if loc.doc == index {
            leftController.applyFind()
            rightController.applyFind()
        } else {
            index = loc.doc   // → loadCurrent() + pane rebuild → applyToView() re-applies the stored target
        }
    }

    /// Copy an archive link for the current page (1-based) to the pasteboard.
    /// Needs the root + marker from the navigation model to build a durable link.
    func copyArchivePageLink(root: URL, marker: RootMarker) {
        guard urls.indices.contains(index) else { return }
        let fileURL = urls[index]
        // Page is 1-based in the link format; `index` here is the doc index (not the PDF page).
        // For the document viewer, "this page" means the current document at page 1 (image page).
        let page = 1
        Task {
            let item = await ArchiveLinkWriter.pageLink(
                fileURL: fileURL, page: page,
                root: root, marker: marker, thumbnailer: nil
            )
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([item])
        }
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "heic", "heif", "bmp", "gif"
    ]

    private func loadCurrent() {
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
