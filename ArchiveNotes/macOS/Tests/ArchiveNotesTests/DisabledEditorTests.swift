import Testing
import AppKit
import SwiftUI
@testable import ArchiveNotes

@Suite("Disabled editor — loading cannot mutate text or assets")
@MainActor
struct DisabledEditorTests {
    @Test
    func disabledUndoPreservesHistoryAndRefusesDirectManagerActions() throws {
        let tv = EditorTextView()
        tv.applyRawMode(true, fontSize: 14)
        let manager = try #require(tv.undoManager)
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        tv.insertPlainText("accepted")
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        tv.isEditable = false
        #expect(tv.undoManager === manager, "selection loading must keep the same history")
        #expect(!manager.canUndo)
        manager.undo()
        manager.undoNestedGroup()
        #expect(tv.string == "accepted")
        tv.isEditable = true
        #expect(manager.canUndo)
        manager.undo()
        #expect(tv.string.isEmpty)
        #expect(manager.canRedo)
        tv.isEditable = false
        #expect(!manager.canRedo)
        manager.redo()
        #expect(tv.string.isEmpty)
        tv.isEditable = true
        manager.redo()
        #expect(tv.string == "accepted")
    }

    @Test(arguments: [false, true])
    func disabledInputIsRefused(raw: Bool) {
        let tv = EditorTextView()
        tv.applyRawMode(raw, fontSize: 14)
        tv.string = "Original body"
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.isEditable = false
        tv.insertText("typed", replacementRange: tv.selectedRange())
        tv.insertPlainText("plain paste")
        tv.insertStyled(NSAttributedString(string: "styled paste"), replacementRange: tv.selectedRange())
        tv.uiTestInsert(NSAttributedString(string: "seam insert"))
        tv.uiTestReplace(with: NSAttributedString(string: "seam replace"))
        tv.insertNewline(nil)
        tv.deleteBackward(nil)
        #expect(tv.string == "Original body")
        #expect(!tv.shouldChangeText(in: tv.selectedRange(), replacementString: "x"))
        for action in ["undo:", "redo:", "cut:", "paste:"] {
            let item = NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "")
            #expect(!tv.validateMenuItem(item))
            #expect(!tv.validateUserInterfaceItem(item))
        }
        tv.isEditable = true
        tv.insertPlainText("accepted ")
        #expect(tv.string == "accepted Original body", "editing must resume after the load")
    }

    @Test
    func disabledImagePasteWritesNoAsset() throws {
        let store = ScratchAssetStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let tv = EditorTextView()
        tv.assetStore = store
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(image.representation(using: .png, properties: [:]))
        let pb = NSPasteboard.general
        defer { pb.clearContents() }
        pb.clearContents()
        pb.setData(png, forType: .png)
        tv.isEditable = false
        tv.paste(nil)
        #expect(!tv.uiTestPasteImage())
        #expect(tv.string.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("assets").path))
        tv.isEditable = true
        #expect(tv.uiTestPasteImage(), "the same payload must succeed once enabled")
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("assets").path).count == 1)
    }

    @Test
    func disabledFormattingAndSourcePasteAreRefused() {
        let tv = EditorTextView()
        tv.replaceStyledDocument(with: MarkdownBridge.parse(markdown: "Original body"))
        let before = NSAttributedString(attributedString: tv.textStorage!)
        tv.setSelectedRange(NSRange(location: 0, length: tv.textStorage!.length))
        let context = FormattingContext()
        context.textView = tv
        let view = MarkdownEditorView(markdown: .constant("Original body"), isRaw: .constant(false))
        let coordinator = view.makeCoordinator()
        coordinator.textView = tv
        let anchor = SourceAnchor(link: "archivereader://reveal?root=TEST&rel=test.pdf", display: "Test")
        tv.isEditable = false
        context.toggleBold()
        context.setHeading(1)
        context.toggleInlineCode()
        coordinator.insertBlock(anchor: anchor)
        #expect(!coordinator.handleSourceBlockPaste([.init(kind: .readerDoc, anchor: anchor, thumbnailData: nil)]))
        #expect(tv.textStorage!.isEqual(to: before))
    }
}
