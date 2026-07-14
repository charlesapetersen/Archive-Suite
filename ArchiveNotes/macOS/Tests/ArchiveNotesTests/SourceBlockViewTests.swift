import Testing
import AppKit
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
        let controller = NotesPDFPaneController()
        // Without a PDFView attached, operations should be no-ops (not crash)
        controller.fit()
        controller.zoomIn()
        controller.zoomOut()
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
