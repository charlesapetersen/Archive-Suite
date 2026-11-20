import XCTest
import AppKit
@testable import ArchiveNotes

/// W49.notes-chip-access — a source chip's buttons (Jump, Reveal, Preview, the Zotero actions) must work without
/// the pointer: through VoiceOver (the chip in the editor's accessibility tree, its actions as custom actions), a
/// right-click or context menu, and the Note menu's keyboard commands for the chip under the caret.
@MainActor
final class ChipAccessTests: XCTestCase {

    private static let twoReaderBlocks = """
        Leading prose with no chip.

        <!-- block: reader-page
             link: archivereader://reveal?root=TEST&rel=first.pdf&page=1
             display: "first.pdf — p. 1"
             page: 1 -->
        Body of the first block.

        <!-- block: zotero-item
             zotero: zotero://select/items/ABC123
             display: "Smith 2020" -->
        Body of the second block.

        """

    private func chips(in text: NSAttributedString) -> [(BlockHeaderAttachment, Int)] {
        var found: [(BlockHeaderAttachment, Int)] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let chip = value as? BlockHeaderAttachment { found.append((chip, range.location)) }
        }
        return found
    }

    func testEachRouteOffersOnlyWhatTheBlockSupports() {
        let reader = SourceAnchorBox(anchor: SourceAnchor(link: "archivereader://x", display: "Doc", page: 1),
                                     kind: .readerPage)
        let zotero = SourceAnchorBox(anchor: SourceAnchor(display: "Smith", zoteroSelect: "zotero://select/items/A"),
                                     kind: .zoteroItem)
        let passage = SourceAnchorBox(anchor: .notePassage(sourceNoteId: UUID(), sourceBlockIndex: 0,
                                                           sourceTitle: "Source", sourceDateDisplay: ""),
                                      kind: .notePassage)
        XCTAssertEqual(BlockHeaderChipAction.available(for: reader),
                       [.reveal, .preview, .copyForZotero, .addToZotero])
        XCTAssertEqual(BlockHeaderChipAction.available(for: zotero), [.openInZotero])
        XCTAssertEqual(BlockHeaderChipAction.available(for: passage), [.jump])
        XCTAssertEqual(BlockHeaderChipAction.available(for: SourceAnchorBox(anchor: SourceAnchor())), [])

        for box in [reader, zotero, passage] {
            let chip = BlockHeaderChipView(box: box, onReveal: nil)
            let actions = BlockHeaderChipAction.available(for: box)
            XCTAssertEqual(buttons(in: chip).map { $0.accessibilityIdentifier() }, actions.map(\.identifier),
                           "the buttons, the menu and VoiceOver come from one list")
            XCTAssertEqual(chip.menu?.items.map(\.title), actions.map(\.menuTitle))
            XCTAssertEqual(chip.accessibilityCustomActions()?.map(\.name), actions.map(\.menuTitle))
            XCTAssertTrue(chip.isAccessibilityElement())
            XCTAssertEqual(chip.accessibilityRole(), .group)
            XCTAssertEqual(chip.accessibilityIdentifier(), "an.chip")
        }
        XCTAssertNil(BlockHeaderChipView(box: SourceAnchorBox(anchor: SourceAnchor()), onReveal: nil).menu,
                     "a chip with no actions has no empty menu")
    }

    func testVoiceOverActionAndMenuItemRunTheChipsCallback() throws {
        let id = UUID()
        let anchor = SourceAnchor.notePassage(sourceNoteId: id, sourceBlockIndex: 0,
                                              sourceTitle: "Source", sourceDateDisplay: "")
        var jumped: [UUID] = []
        let chip = BlockHeaderChipView(box: SourceAnchorBox(anchor: anchor, kind: .notePassage), onReveal: nil,
                                       onJump: { anchor in
                                           MainActor.assumeIsolated { jumped.append(anchor.notePassageTarget!.id) }
                                       })
        XCTAssertEqual(chip.accessibilityLabel(), "Source: Source")
        let action = try XCTUnwrap(chip.accessibilityCustomActions()?.first)
        XCTAssertTrue(action.handler?() ?? false)
        let item = try XCTUnwrap(chip.menu?.items.first)
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        XCTAssertEqual(jumped, [id, id])
    }

    func testTheChipUnderTheCaretIsTheOneWhoseBlockHoldsIt() throws {
        let text = MarkdownBridge.parse(markdown: Self.twoReaderBlocks)
        let found = chips(in: text)
        XCTAssertEqual(found.count, 2)
        let string = text.string as NSString
        func chip(at phrase: String, offset: Int = 0) -> BlockHeaderAttachment? {
            let range = string.range(of: phrase)
            XCTAssertNotEqual(range.location, NSNotFound, phrase)
            return EditorTextView.chipAttachment(at: range.location + offset, in: text)?.attachment
        }
        XCTAssertNil(chip(at: "Leading prose"), "text above every chip has none")
        XCTAssertTrue(chip(at: "Body of the first") === found[0].0)
        XCTAssertTrue(chip(at: "Body of the first", offset: 10) === found[0].0)
        XCTAssertTrue(chip(at: "Body of the second") === found[1].0)
        XCTAssertTrue(EditorTextView.chipAttachment(at: found[1].1, in: text)?.attachment === found[1].0,
                      "the caret just before a chip is on that chip")
        XCTAssertTrue(EditorTextView.chipAttachment(at: text.length, in: text)?.attachment === found[1].0,
                      "the caret at the end of the last block")
        XCTAssertNil(EditorTextView.chipAttachment(at: 0, in: NSAttributedString()))
    }

    /// An editor in a window (never ordered in; this host draws nothing), its chips installed by the first layout.
    private func makeEditor(_ markdown: String, configure: (BlockHeaderAttachment) -> Void = { _ in })
        -> (NSWindow, EditorTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let textView = EditorTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        let parsed = MarkdownBridge.parse(markdown: markdown)
        chips(in: parsed).forEach { configure($0.0) }
        textView.replaceStyledDocument(with: parsed)
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, textView)
    }

    func testTheEditorsAccessibilityTreeReachesEachChipsButtons() throws {
        let (window, editor) = makeEditor(Self.twoReaderBlocks)
        defer { window.close() }
        let chipElements = (editor.accessibilityChildren() ?? []).compactMap { $0 as? BlockHeaderChipView }
        XCTAssertEqual(chipElements.map { $0.accessibilityLabel() },
                       ["Source: first.pdf — p. 1", "Source: Smith 2020"])
        for chip in chipElements {
            XCTAssertTrue(chip.accessibilityParent() as? EditorTextView === editor)
        }
        let ids = chipElements.flatMap { buttons(in: $0).map { $0.accessibilityIdentifier() } }
        XCTAssertEqual(ids, ["an.chip.reveal", "an.chip.preview", "an.chip.copyForZotero", "an.chip.addToZotero",
                             "an.chip.zoteroOpen"])
        // What VoiceOver walks: the chip element's own accessibility children, not its view tree.
        func axButtons(_ element: Any) -> [String] {
            let children = (element as? NSView)?.accessibilityChildren()
                ?? (element as? NSAccessibilityElement)?.accessibilityChildren() ?? []
            return children.flatMap { child -> [String] in
                // AppKit's element for a button is its cell; a bare button view here has no role (the audit's
                // "Unknown role" in the VM).
                XCTAssertFalse(child is NSButton, "a chip's child must be the button's accessibility element")
                if let cell = child as? NSButtonCell, let button = cell.controlView as? NSButton {
                    XCTAssertEqual(cell.accessibilityRole(), .button)
                    return [button.accessibilityIdentifier()]
                }
                return axButtons(child)
            }
        }
        XCTAssertEqual(chipElements.flatMap(axButtons), ids)
    }

    func testKeyboardCommandRunsTheActionOfTheChipUnderTheCaret() throws {
        var revealed: [String] = []
        let (window, editor) = makeEditor(Self.twoReaderBlocks) { attachment in
            attachment.onReveal = { anchor in MainActor.assumeIsolated { revealed.append(anchor.link ?? "") } }
        }
        defer { window.close() }
        let string = editor.string as NSString
        editor.setSelectedRange(NSRange(location: string.range(of: "Body of the first").location + 4, length: 0))
        XCTAssertTrue(editor.performChipActionAtCursor(.reveal))
        XCTAssertEqual(revealed, ["archivereader://reveal?root=TEST&rel=first.pdf&page=1"])
        XCTAssertFalse(editor.performChipActionAtCursor(.openInZotero), "the first chip has no Zotero item")
        XCTAssertFalse(editor.performChipActionAtCursor(.jump))

        editor.setSelectedRange(NSRange(location: string.range(of: "Leading prose").location, length: 0))
        XCTAssertFalse(editor.performChipActionAtCursor(.reveal), "no chip above the caret")
        XCTAssertEqual(revealed.count, 1)
    }

    func testContextMenuLeadsWithTheActionsOfTheChipUnderTheCaret() throws {
        let (window, editor) = makeEditor(Self.twoReaderBlocks)
        defer { window.close() }
        let string = editor.string as NSString
        let keyEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0))

        editor.setSelectedRange(NSRange(location: string.range(of: "Body of the second").location, length: 0))
        let menu = try XCTUnwrap(editor.menu(for: keyEvent))
        XCTAssertEqual(menu.items.first?.title, "Open in Zotero")
        XCTAssertTrue(menu.items.count == 1 || menu.items[1].isSeparatorItem)

        editor.setSelectedRange(NSRange(location: string.range(of: "Leading prose").location, length: 0))
        let plain = editor.menu(for: keyEvent)
        XCTAssertFalse(plain?.items.contains { $0.title == "Open in Zotero" || $0.title == "Preview Source" } ?? false)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }
}
