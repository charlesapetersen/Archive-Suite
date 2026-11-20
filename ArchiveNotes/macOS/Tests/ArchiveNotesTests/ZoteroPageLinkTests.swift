import Testing
import AppKit
import Foundation
import SwiftUI
@testable import ArchiveNotes

/// W49.notes-zotero-page-links: a `zotero://open-pdf/…?page=N` link attaches as an attachment block that names the
/// page, and its chip's Open in Zotero opens the PDF there; an item block keeps `zotero://select`.
@Suite("ZoteroPageLinkTests — W49.notes-zotero-page-links")
@MainActor
struct ZoteroPageLinkTests {

    // MARK: - Parsing

    @Test func anOpenPDFLinkIsAnAttachmentWithItsPage() throws {
        let ref = try #require(ZoteroSelectLink.parse("zotero://open-pdf/library/items/ATCH5678?page=12"))
        #expect(ref.kind == .attachment)
        #expect(ref.itemKey == "ATCH5678")
        #expect(ref.library == .user)
        #expect(ref.page == 12)
        #expect(ref.selectLink == "zotero://select/library/items/ATCH5678", "the canonical link stays a select link")

        let group = try #require(ZoteroSelectLink.parse("zotero://open-pdf/groups/7/items/ATCH5678?page=3&annotation=ANNO1234"))
        #expect(group.library == .group(7))
        #expect(group.page == 3, "other query items are ignored")
        #expect(group.selectLink == "zotero://select/groups/7/items/ATCH5678")

        #expect(ZoteroSelectLink.parse("zotero://open/library/items/ATCH5678?page=4")?.page == 4, "Zotero 7's open")

        let zotfile = try #require(ZoteroSelectLink.parse("zotero://open-pdf/0_ATCH5678/21"))
        #expect(zotfile.page == 21, "ZotFile's open-pdf/<libID>_<KEY>/<page>")
        #expect(zotfile.selectLink == "zotero://select/library/items/ATCH5678")
        #expect(ZoteroSelectLink.parse("zotero://open-pdf/7_ATCH5678/2")?.library == .group(7))
        #expect(ZoteroSelectLink.parse("zotero://select/0_ATCH5678/2") == nil, "only open-pdf has that form")
    }

    @Test func anOpenPDFLinkWithoutAUsablePageHasNone() {
        for link in ["zotero://open-pdf/library/items/ATCH5678",
                     "zotero://open-pdf/library/items/ATCH5678?page=0",
                     "zotero://open-pdf/library/items/ATCH5678?page=-2",
                     "zotero://open-pdf/library/items/ATCH5678?page=iv"] {
            let ref = ZoteroSelectLink.parse(link)
            #expect(ref?.kind == .attachment, "\(link)")
            #expect(ref?.page == nil, "\(link)")
        }
        #expect(ZoteroSelectLink.parse("zotero://open-pdf/library/items/bad")  == nil)
        #expect(ZoteroSelectLink.parse("zotero://select/library/items/ABCD1234")?.page == nil)
        #expect(ZoteroSelectLink.parse("zotero://select/library/items/ABCD1234")?.kind == .item)
    }

    @Test func theOpenPDFLinkIsBuiltFromTheSelectLink() {
        #expect(ZoteroSelectLink.openPDFLink(selectLink: "zotero://select/library/items/ATCH5678", page: 9)?
            .absoluteString == "zotero://open-pdf/library/items/ATCH5678?page=9")
        #expect(ZoteroSelectLink.openPDFLink(selectLink: "zotero://select/groups/7/items/ATCH5678", page: 2)?
            .absoluteString == "zotero://open-pdf/groups/7/items/ATCH5678?page=2")
        #expect(ZoteroSelectLink.openPDFLink(selectLink: "zotero://select/library/items/ATCH5678", page: 0) == nil)
        #expect(ZoteroSelectLink.openPDFLink(selectLink: "https://example.com", page: 1) == nil)
    }

    @Test func twoPagesOfOneAttachmentAreTwoPastedLinks() {
        let p3 = "zotero://open-pdf/library/items/ATCH5678?page=3"
        let p9 = "zotero://open-pdf/library/items/ATCH5678?page=9"
        #expect(ZoteroClipboardDetect.pastedLinks(in: "\(p3)\n\(p9)\n\(p3)").map(\.page) == [3, 9])
    }

    // MARK: - What the chip opens

    @Test func anAttachmentBlockWithAPageOpensThePDFThere() {
        let select = "zotero://select/library/items/ATCH5678"
        let attachment = SourceAnchorBox(anchor: SourceAnchor(display: "Moore", page: 14, zoteroSelect: select),
                                         kind: .zoteroAttachment)
        #expect(attachment.zoteroOpenURL?.absoluteString == "zotero://open-pdf/library/items/ATCH5678?page=14")
        #expect(BlockHeaderChipAction.openInZotero.toolTip(for: attachment) == "Open the PDF in Zotero at page 14")

        let item = SourceAnchorBox(anchor: SourceAnchor(display: "Moore", page: 14, zoteroSelect: select),
                                   kind: .zoteroItem)
        #expect(item.zoteroOpenURL?.absoluteString == select, "an item block keeps zotero://select")
        #expect(BlockHeaderChipAction.openInZotero.toolTip(for: item) == nil)

        let noPage = SourceAnchorBox(anchor: SourceAnchor(display: "Moore", zoteroSelect: select),
                                     kind: .zoteroAttachment)
        #expect(noPage.zoteroOpenURL?.absoluteString == select)
        #expect(SourceAnchorBox(anchor: SourceAnchor(display: "x", page: 2), kind: .zoteroAttachment)
            .zoteroOpenURL == nil)
    }

    // MARK: - ⌘V through the editor

    @Test func pastingAPageLinkWritesAnAttachmentBlockThatNamesThePage() {
        var markdown = "Existing note text"
        var isRaw = false
        let formatting = FormattingContext()
        formatting.currentItemID = UUID()
        formatting.currentItemKind = .note
        let view = MarkdownEditorView(markdown: Binding(get: { markdown }, set: { markdown = $0 }),
                                      isRaw: Binding(get: { isRaw }, set: { isRaw = $0 }),
                                      formatting: formatting)
        let coordinator = view.makeCoordinator()
        let textView = EditorTextView()
        textView.string = markdown
        coordinator.textView = textView
        coordinator.parent = view
        coordinator.formattingContext = formatting
        formatting.coordinator = coordinator
        formatting.textView = textView
        textView.zoteroPasteHandler = { [weak coordinator] refs in coordinator?.handleZoteroPaste(refs) ?? false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("zotero://open-pdf/library/items/ATCH5678?page=12", forType: .string)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.paste(nil)
        pasteboard.clearContents()
        coordinator.flushWriteBack()

        let block = BlockParser.parse(markdown).blocks.first { $0.kind == .zoteroAttachment }
        #expect(block != nil, "the paste should be an attachment block:\n\(markdown)")
        #expect(block?.source?.page == 12)
        #expect(block?.source?.zoteroSelect == "zotero://select/library/items/ATCH5678")
        #expect(!markdown.contains("open-pdf"), "the block keeps the canonical select link and the page")
    }
}
