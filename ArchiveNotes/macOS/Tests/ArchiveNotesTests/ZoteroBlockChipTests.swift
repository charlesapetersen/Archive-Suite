import Testing
import AppKit
@testable import ArchiveNotes

/// The block-header chip's action buttons must match what the block supports:
/// a Zotero block gets "Open in Zotero"; a reader block keeps Reveal + Preview (W5-S4).
/// Kept in its own suite so it runs in isolation via `-only-testing` (the W4
/// `BlockHeaderChipViewCallbackTests` suite still aborts headless on `performClick:`).
@Suite("Zotero block chip buttons")
struct ZoteroBlockChipTests {

    @MainActor
    private func buttonTitles(in view: NSView) -> [String] {
        var titles: [String] = []
        for sub in view.subviews {
            if let button = sub as? NSButton { titles.append(button.title) }
            titles.append(contentsOf: buttonTitles(in: sub))
        }
        return titles
    }

    @MainActor @Test("a zotero block chip shows Open in Zotero, not Reveal/Preview")
    func zoteroChipButtons() {
        let anchor = SourceAnchor(display: "Moore 2001",
                                  zoteroSelect: "zotero://select/library/items/ABCD1234")
        let box = SourceAnchorBox(anchor: anchor, kind: .zoteroItem)
        let chip = BlockHeaderChipView(box: box, onReveal: nil, onPreview: nil)
        let titles = buttonTitles(in: chip)
        #expect(titles.contains("Open in Zotero"))
        #expect(!titles.contains("Reveal"))
        #expect(!titles.contains("Preview"))
    }

    @MainActor @Test("a reader-page block chip still shows Reveal + Preview, not Zotero")
    func readerChipButtons() {
        let anchor = SourceAnchor(
            link: "archivereader://reveal?root=00000000-0000-0000-0000-000000000001&rel=x.pdf",
            display: "Doc")
        let box = SourceAnchorBox(anchor: anchor, kind: .readerPage)
        let chip = BlockHeaderChipView(box: box, onReveal: nil, onPreview: nil)
        let titles = buttonTitles(in: chip)
        #expect(titles.contains("Reveal"))
        #expect(titles.contains("Preview"))
        #expect(!titles.contains("Open in Zotero"))
    }
}
