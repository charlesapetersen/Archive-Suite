import Testing
import AppKit
import Foundation
import SwiftUI
@testable import ArchiveNotes

/// W40.fix-notes-zotero-paste (owner's Notes session 2, rows 27 and 28): ⌘V of a `zotero://select/…` link attaches
/// it as Attach Zotero Link… does, and a greyed Auto-fill from Zotero… says why.
@Suite("ZoteroPasteTests — W40.fix-notes-zotero-paste")
@MainActor
struct ZoteroPasteTests {

    private let linkA = "zotero://select/library/items/ABCD1234"
    private let linkB = "zotero://select/groups/42/items/EFGH5678"

    // MARK: - Which pastes are Zotero links

    @Test func aPasteOfOnlyZoteroLinksIsRecognised() {
        #expect(ZoteroClipboardDetect.pastedLinks(in: linkA).map(\.selectLink) == [linkA])
        #expect(ZoteroClipboardDetect.pastedLinks(in: "  \(linkA)\n").map(\.selectLink) == [linkA])
        #expect(ZoteroClipboardDetect.pastedLinks(in: "\(linkA)\r\n\r\n\(linkB)\r").map(\.selectLink)
                == [linkA, linkB], "CRLF and CR split lines, and blank lines are skipped")
        #expect(ZoteroClipboardDetect.pastedLinks(in: "\(linkA)\n\(linkA)").count == 1, "a repeated link is attached once")
    }

    @Test func textAroundALinkKeepsThePasteText() {
        #expect(ZoteroClipboardDetect.pastedLinks(in: "See \(linkA) for the source").isEmpty)
        #expect(ZoteroClipboardDetect.pastedLinks(in: "\(linkA)\nA second line of prose").isEmpty)
        #expect(ZoteroClipboardDetect.pastedLinks(in: "https://www.zotero.org/").isEmpty)
        #expect(ZoteroClipboardDetect.pastedLinks(in: "\n \n").isEmpty)
    }

    // MARK: - ⌘V through the editor

    private final class Holder {
        var markdown: String
        var isRaw = false
        init(_ markdown: String) { self.markdown = markdown }
    }

    private func makeEditor(_ holder: Holder, kind: Item.Kind)
        -> (MarkdownEditorView.Coordinator, EditorTextView, FormattingContext) {
        let formatting = FormattingContext()
        formatting.currentItemID = UUID()
        formatting.currentItemKind = kind
        let view = MarkdownEditorView(
            markdown: Binding(get: { holder.markdown }, set: { holder.markdown = $0 }),
            isRaw: Binding(get: { holder.isRaw }, set: { holder.isRaw = $0 }),
            formatting: formatting)
        let coordinator = view.makeCoordinator()
        let textView = EditorTextView()
        textView.string = holder.markdown
        coordinator.textView = textView
        coordinator.parent = view
        coordinator.formattingContext = formatting
        formatting.coordinator = coordinator
        formatting.textView = textView
        // As `makeNSView` wires it.
        textView.zoteroPasteHandler = { [weak coordinator] refs in coordinator?.handleZoteroPaste(refs) ?? false }
        return (coordinator, textView, formatting)
    }

    private func paste(_ text: String, into textView: EditorTextView) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.paste(nil)
        pasteboard.clearContents()
    }

    @Test func pastingAZoteroLinkInANoteAttachesItAsABlock() {
        let holder = Holder("Existing note text")
        let (coordinator, textView, formatting) = makeEditor(holder, kind: .note)
        formatting.updateZoteroAutoFillReference(from: item(id: formatting.currentItemID!, blocks: []))
        #expect(formatting.zoteroAutoFillMenuState == .noLink)

        paste(linkA, into: textView)
        coordinator.flushWriteBack()

        #expect(holder.markdown.contains("<!-- block: zotero-item"), "the paste should be a Zotero block:\n\(holder.markdown)")
        #expect(holder.markdown.contains(linkA))
        #expect(!holder.markdown.contains("text\(linkA)"), "the link must not also land as plain text")
        #expect(formatting.zoteroAutoFillMenuState == .available, "a note's one pasted link enables auto-fill")
    }

    @Test func pastingAZoteroLinkInAnExtractStaysText() {
        let holder = Holder("")
        let (coordinator, textView, _) = makeEditor(holder, kind: .extract)
        var degraded = 0
        textView.plainPasteFallbackHandler = { degraded += 1 }
        paste(linkA, into: textView)
        coordinator.flushWriteBack()
        #expect(textView.string == linkA, "extracts reference notes only (§D7)")
        #expect(!holder.markdown.contains("<!-- block:"))
        #expect(degraded == 1, "the extract says the link went in as plain text")
    }

    @Test func pastingInRawMarkdownStaysText() {
        let holder = Holder("")
        let (coordinator, textView, _) = makeEditor(holder, kind: .note)
        coordinator.currentIsRaw = true
        paste(linkA, into: textView)
        #expect(textView.string == linkA)
        coordinator.currentIsRaw = false
        textView.string = ""
        paste(linkA, into: textView)
        #expect(textView.string != linkA, "the same paste out of raw mode is a block")
    }

    @Test func aSecondDifferentLinkMakesAutoFillAmbiguousButTheSameLinkDoesNot() {
        let holder = Holder("")
        let (coordinator, textView, formatting) = makeEditor(holder, kind: .note)
        defer { withExtendedLifetime(coordinator) {} }   // the text view and context hold it weakly
        paste(linkA, into: textView)
        #expect(formatting.zoteroAutoFillMenuState == .available)
        paste(linkA, into: textView)
        #expect(formatting.zoteroAutoFillMenuState == .available, "a second block of the same item is still one source")
        paste(linkB, into: textView)
        #expect(formatting.zoteroAutoFillMenuState == .severalLinks)
    }

    // MARK: - Why Auto-fill is greyed

    @Test func theMenuStateNamesEachReason() {
        let one = ZoteroAutoFillReference(
            ref: ZoteroSelectLink.parse(linkA)!,
            target: ZoteroAutoFillReferenceTarget(selectLink: linkA, noteFrontMatter: true, sourceBlocks: false))
        func state(_ resolution: ZoteroAutoFillReferenceResolution?, hasItem: Bool = true,
                   kind: Item.Kind? = .note, fetching: Bool = false) -> ZoteroAutoFillMenuState {
            .make(hasItem: hasItem, kind: kind, isFetching: fetching, resolution: resolution)
        }
        #expect(state(.available(one)) == .available)
        #expect(state(ZoteroAutoFillReferenceResolution.none) == .noLink)
        #expect(state(.ambiguous) == .severalLinks)
        #expect(state(nil) == .checking)
        #expect(state(.available(one), kind: .extract) == .extract)
        #expect(state(nil, hasItem: false, kind: nil) == .noNote)
        #expect(state(.available(one), fetching: true) == .fetching)

        #expect(ZoteroAutoFillMenuState.available.reason == nil)
        #expect(ZoteroAutoFillMenuState.checking.reason == nil, "a brief read shows no reason")
        for greyed: ZoteroAutoFillMenuState in [.noNote, .extract, .fetching, .noLink, .severalLinks] {
            #expect(greyed.reason?.isEmpty == false, "\(greyed) should say why")
            #expect(!greyed.isAvailable)
        }
    }

    private func item(id: UUID, blocks: [Block]) -> Item {
        Item(id: id, kind: .note, title: "Scratch", authors: [], date: nil, datePrecision: nil,
             dateUncertain: false, quality: nil, tags: [], zotero: [], roundup: false,
             created: Date(timeIntervalSince1970: 0), modified: Date(timeIntervalSince1970: 0), schema: 1,
             blocks: blocks, unknownFrontMatter: [], trailingBodyRaw: nil)
    }
}
