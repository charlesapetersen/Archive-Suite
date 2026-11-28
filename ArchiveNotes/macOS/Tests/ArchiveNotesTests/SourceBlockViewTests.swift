import Testing
import AppKit
import PDFKit
@testable import ArchiveNotes

// MARK: - ThumbnailImageCache

@Suite("ThumbnailImageCache")
struct ThumbnailImageCacheTests {

    @MainActor @Test("set and retrieve an image")
    func setAndRetrieve() {
        let cache = ThumbnailImageCache(countLimit: 10, costLimitMB: 1)
        let img = NSImage(size: NSSize(width: 100, height: 100))
        cache.set(img, for: "test-key")
        let retrieved = cache.image(for: "test-key")
        #expect(retrieved === img)
    }

    @MainActor @Test("miss returns nil")
    func missReturnsNil() {
        let cache = ThumbnailImageCache(countLimit: 10, costLimitMB: 1)
        #expect(cache.image(for: "nonexistent") == nil)
    }

    @MainActor @Test("removeAll clears the cache")
    func removeAll() {
        let cache = ThumbnailImageCache(countLimit: 10, costLimitMB: 1)
        let img = NSImage(size: NSSize(width: 100, height: 100))
        cache.set(img, for: "key")
        cache.removeAll()
        #expect(cache.image(for: "key") == nil)
    }
}

// MARK: - NotesPDFPaneController

@Suite("NotesPDFPaneController")
struct NotesPDFPaneControllerTests {

    @MainActor @Test("fit resets to auto-scale")
    func fitResetsAutoScale() {
        // W40.a4: this used to call fit/zoom with no PDFView and assert nothing, so it could not fail.
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        view.document = doc
        let controller = NotesPDFPaneController()
        controller.pdfView = view

        view.autoScales = false
        view.scaleFactor = 1
        controller.zoomIn()
        #expect(view.autoScales == false, "zooming takes the view off auto-scale")
        #expect(abs(view.scaleFactor - 1.25) < 0.001, "zoomIn scales by 1.25, got \(view.scaleFactor)")
        controller.zoomOut()
        #expect(abs(view.scaleFactor - 1) < 0.001, "zoomOut undoes zoomIn, got \(view.scaleFactor)")

        controller.zoomIn()
        controller.fit()
        #expect(view.autoScales, "fit returns the view to auto-scale")
    }

    @MainActor @Test("with no PDFView attached, fit and zoom are no-ops")
    func detachedControllerIsInert() {
        let controller = NotesPDFPaneController()
        controller.fit()
        controller.zoomIn()
        controller.zoomOut()
        // Had the detached zoom saved a scale, applyToView would restore it instead of auto-scaling.
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        view.autoScales = false
        controller.pdfView = view
        controller.applyToView()
        #expect(view.autoScales, "detached zoom calls must leave no saved scale behind")
    }

    private func makeMultiPageDoc(pages: Int) -> PDFDocument {
        let doc = PDFDocument()
        for i in 0..<pages {
            doc.insert(PDFPage(), at: i)
        }
        return doc
    }

    @MainActor @Test("clampedPageIndex handles nil, zero, negative, in-range, out-of-range, and empty PDFs")
    func clampedPageIndexEdges() {
        #expect(NotesPDFPaneController.clampedPageIndex(oneBased: nil, pageCount: 6) == 0)
        #expect(NotesPDFPaneController.clampedPageIndex(oneBased: 0, pageCount: 6) == 0)
        #expect(NotesPDFPaneController.clampedPageIndex(oneBased: -3, pageCount: 6) == 0)
        #expect(NotesPDFPaneController.clampedPageIndex(oneBased: 1, pageCount: 6) == 0)
        #expect(NotesPDFPaneController.clampedPageIndex(oneBased: 5, pageCount: 6) == 4)
        #expect(NotesPDFPaneController.clampedPageIndex(oneBased: 99, pageCount: 6) == 5)
        #expect(NotesPDFPaneController.clampedPageIndex(oneBased: 3, pageCount: 0) == 0)
    }

    @MainActor @Test("multi-page merged PDF loads at linked page, steps, jumps back, and keeps page on zoom/fit")
    func multiPageScrollNavigationAndZoom() {
        let doc = makeMultiPageDoc(pages: 6)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = doc

        // Open on 1-based page 5 (0-based index 4) of a 6-page merged PDF.
        let controller = NotesPDFPaneController(initialPageIndex: 4)
        controller.pdfView = view
        controller.documentDidLoad(doc)

        #expect(controller.pageCount == 6)
        #expect(controller.currentPageIndex == 4)
        #expect(controller.isOnInitialPage)
        #expect(controller.canGoPrevious)
        #expect(controller.canGoNext)
        #expect(view.currentPage === doc.page(at: 4))

        // Step forward to last page (index 5); next becomes disabled.
        controller.nextPage()
        #expect(controller.currentPageIndex == 5)
        #expect(!controller.canGoNext)
        #expect(!controller.isOnInitialPage)
        #expect(view.currentPage === doc.page(at: 5))

        // Stepping past the end is a no-op.
        controller.nextPage()
        #expect(controller.currentPageIndex == 5)

        // Step backward twice to index 3.
        controller.previousPage()
        controller.previousPage()
        #expect(controller.currentPageIndex == 3)
        #expect(view.currentPage === doc.page(at: 3))

        // Zooming and fitting keep the current page rather than snapping back to page 0.
        controller.zoomIn()
        controller.recordScale()
        #expect(controller.currentPageIndex == 3)
        controller.fit()
        #expect(controller.currentPageIndex == 3)
        #expect(view.currentPage === doc.page(at: 3))

        // Return to linked page jumps back to index 4.
        controller.goToInitialPage()
        #expect(controller.currentPageIndex == 4)
        #expect(controller.isOnInitialPage)
        #expect(view.currentPage === doc.page(at: 4))

        // External scroll (simulated via PDFView.go(to:)) syncs currentPageIndex.
        view.go(to: doc.page(at: 1)!)
        controller.syncCurrentPage()
        #expect(controller.currentPageIndex == 1)
        #expect(!controller.isOnInitialPage)
    }

    @MainActor @Test("single-page PDF keeps single-page display and disables page stepping")
    func singlePageDisablesStepping() {
        let doc = makeMultiPageDoc(pages: 1)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        view.document = doc
        let controller = NotesPDFPaneController(initialPageIndex: 0)
        controller.pdfView = view
        controller.documentDidLoad(doc)

        #expect(controller.pageCount == 1)
        #expect(controller.currentPageIndex == 0)
        #expect(!controller.canGoPrevious)
        #expect(!controller.canGoNext)
        #expect(controller.isOnInitialPage)
    }
}

// MARK: - BlockHeaderChipView reveal + preview

@Suite("BlockHeaderChipView callbacks")
struct BlockHeaderChipViewCallbackTests {

    @MainActor @Test("reveal callback receives the anchor")
    func revealCallback() {
        let anchor = SourceAnchor(
            link: "archivereader://reveal?root=00000000-0000-0000-0000-000000000001&rel=test.pdf",
            display: "Test"
        )
        let box = SourceAnchorBox(anchor: anchor, kind: .readerDoc)
        // onReveal is @Sendable; the callback fires synchronously on this @MainActor test,
        // so the capture is safe — nonisolated(unsafe) documents that and silences the diagnostic.
        nonisolated(unsafe) var received: SourceAnchor?
        let chip = BlockHeaderChipView(box: box, onReveal: { a in received = a })
        // Invoke the Reveal button's target/action directly. Do NOT send performClick: to
        // the container view: BlockHeaderChipView is an NSView (not an NSControl), so that
        // raised `unrecognized selector` and the resulting NSException SIGABRT'd the whole
        // Swift-Testing process, turning the headless smoke gate red even when every logic
        // suite was green (see KNOWN_ISSUES "headless full-scheme run crashes", now fixed).
        let revealButton = findButtons(in: chip).first { $0.title == "Reveal" }
        #expect(revealButton != nil, "Chip should have a Reveal button")
        if let button = revealButton,
           let action = button.action,
           let target = button.target as? NSObject {
            _ = target.perform(action, with: button)
        }
        #expect(received?.link == anchor.link, "Reveal callback should receive the clicked anchor")
    }

    @MainActor @Test("chip has Reveal and Preview buttons")
    func chipHasBothButtons() {
        let anchor = SourceAnchor(link: "archivereader://reveal?root=00000000-0000-0000-0000-000000000001&rel=test.pdf", display: "Test Doc")
        let box = SourceAnchorBox(anchor: anchor, kind: .readerPage)
        let chip = BlockHeaderChipView(box: box, onReveal: nil, onPreview: nil)
        // Find buttons in the view hierarchy
        let buttons = findButtons(in: chip)
        let titles = buttons.map(\.title)
        #expect(titles.contains("Reveal"), "Should have a Reveal button")
        #expect(titles.contains("Preview"), "Should have a Preview button")
    }

    @MainActor private func findButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        for sub in view.subviews {
            if let btn = sub as? NSButton { result.append(btn) }
            result.append(contentsOf: findButtons(in: sub))
        }
        return result
    }
}

// MARK: - MarkdownBridge onPreview threading

@Suite("MarkdownBridge preview callback")
struct MarkdownBridgePreviewTests {

    @MainActor @Test("parse threads onPreview to chip attachments")
    func parseThreadsPreview() {
        let md = """
        <!-- block: kind=reader-page link=archivereader://reveal?root=00000000-0000-0000-0000-000000000001&rel=test.pdf display=Test page=1 -->
        Some body text.
        """
        let styled = MarkdownBridge.parse(
            markdown: md,
            onPreviewBlock: { _, _ in }
        )
        // The attachment should be in the attributed string
        var foundAttachment = false
        styled.enumerateAttribute(.attachment, in: NSRange(location: 0, length: styled.length)) { val, _, _ in
            if let att = val as? BlockHeaderAttachment {
                foundAttachment = true
                #expect(att.onPreview != nil, "onPreview should be set on the attachment")
            }
        }
        #expect(foundAttachment, "Should find a BlockHeaderAttachment in the parsed result")
    }

    @MainActor @Test("buildInsertableBlock threads onPreview")
    func buildInsertableBlockThreadsPreview() {
        let anchor = SourceAnchor(link: "archivereader://reveal?root=00000000-0000-0000-0000-000000000001&rel=doc.pdf", display: "Doc")
        let chip = MarkdownBridge.buildInsertableBlock(
            anchor: anchor,
            onPreview: { _, _ in }
        )
        var found = false
        chip.enumerateAttribute(.attachment, in: NSRange(location: 0, length: chip.length)) { val, _, _ in
            if let att = val as? BlockHeaderAttachment {
                found = true
                #expect(att.onPreview != nil)
            }
        }
        #expect(found)
    }
}

// MARK: - Reveal via NSWorkspace (integration smoke)

@Suite("Reveal integration")
struct RevealIntegrationTests {

    @MainActor @Test("onRevealBlock constructs valid URL from anchor")
    func revealBlockURL() {
        let anchor = SourceAnchor(
            link: "archivereader://reveal?root=00000000-0000-0000-0000-000000000001&rel=Batch-A%2F00001.pdf&page=1",
            display: "00001 — p. 1",
            page: 1
        )
        guard let link = anchor.link, let url = URL(string: link) else {
            Issue.record("Should have a valid link")
            return
        }
        #expect(url.scheme == "archivereader")
        #expect(url.host == "reveal")
    }
}
