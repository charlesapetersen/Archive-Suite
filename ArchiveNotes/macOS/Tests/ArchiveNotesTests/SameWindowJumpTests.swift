import Testing
import AppKit
import Foundation
import SwiftUI
@testable import ArchiveNotes

/// W49.notes-same-window-jump — a jump into the note whose editor is first responder. Freeze-during-edit
/// skips the content re-apply there, so before scrolling the editor flushes the pending edit and installs
/// what the model then holds (`flushWriteBack` + `installModelMarkdownIfStale`, run one turn after
/// `updateNSView` sees the request). These drive those two steps the way the deferred jump does.
@Suite("SameWindowJumpTests — W49.notes-same-window-jump")
struct SameWindowJumpTests {

    @MainActor
    final class Holder {
        var markdown: String
        var isRaw = false
        init(_ markdown: String) { self.markdown = markdown }
    }

    /// An editor showing `shown`, installed the way `updateNSView` installs it.
    @MainActor
    private func makeEditor(holder: Holder, shown: String) -> MarkdownEditorView.Coordinator {
        let view = MarkdownEditorView(
            markdown: Binding(get: { holder.markdown }, set: { holder.markdown = $0 }),
            isRaw: Binding(get: { holder.isRaw }, set: { holder.isRaw = $0 })
        )
        let coordinator = view.makeCoordinator()
        let textView = EditorTextView()
        textView.replaceStyledDocument(with: MarkdownBridge.parse(markdown: shown))
        coordinator.textView = textView
        coordinator.parent = view
        coordinator.lastAppliedMarkdown = shown
        coordinator.recordAppliedSerialization()
        return coordinator
    }

    /// Markdown for a note with leading prose and two source chips (three blocks), serialized by the editor.
    @MainActor
    private func threeBlockMarkdown() -> String {
        let holder = Holder("Intro paragraph")
        let formatting = FormattingContext()
        formatting.currentItemID = UUID()
        formatting.currentItemKind = .note
        let coordinator = makeEditor(holder: holder, shown: holder.markdown)
        coordinator.formattingContext = formatting
        let textView = coordinator.textView!
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        for page in 1...2 {
            coordinator.insertBlock(anchor: SourceAnchor(
                link: "archivereader://reveal?root=TEST&rel=Scan.pdf&page=\(page)",
                display: "Scan — p. \(page)", page: page))
            textView.insertText("Body \(page)", replacementRange: textView.selectedRange())
        }
        coordinator.flushWriteBack()
        return holder.markdown
    }

    @Test @MainActor
    func aBodyTheModelReloadedIsInstalledBeforeTheScroll() throws {
        let reloaded = threeBlockMarkdown()
        let holder = Holder("Intro paragraph")
        let coordinator = makeEditor(holder: holder, shown: holder.markdown)
        let textView = try #require(coordinator.textView)
        // The model reloads the body while the editor is focused; freeze-during-edit left the view as it was.
        holder.markdown = reloaded
        #expect(NotePassageResolve.scrollRange(forBlock: 2, in: textView.textStorage!) == nil,
                "precondition: the stale view has no third block, so the jump would land at the top")

        coordinator.flushWriteBack()
        coordinator.installModelMarkdownIfStale()

        #expect(holder.markdown == reloaded, "an untouched editor must not write over the reloaded body")
        #expect(coordinator.lastAppliedMarkdown == reloaded)
        #expect(NotePassageResolve.scrollRange(forBlock: 2, in: textView.textStorage!) != nil,
                "the reloaded body's third block should be found")
        #expect(textView.string.contains("Body 2"))
    }

    @Test @MainActor
    func aPendingEditIsSavedAndKeptBeforeTheScroll() throws {
        let markdown = threeBlockMarkdown()
        let holder = Holder(markdown)
        let coordinator = makeEditor(holder: holder, shown: markdown)
        let textView = try #require(coordinator.textView)
        // The user types; the write-back is still waiting for its debounce.
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        textView.insertText(" typed just now", replacementRange: textView.selectedRange())
        #expect(holder.markdown == markdown, "precondition: the edit has not been written back")

        coordinator.flushWriteBack()
        coordinator.installModelMarkdownIfStale()

        #expect(holder.markdown.contains("typed just now"), "the jump must save the pending edit")
        #expect(textView.string.contains("typed just now"), "the edit must stay on screen")
        #expect(NotePassageResolve.scrollRange(forBlock: 2, in: textView.textStorage!) != nil)
    }

    @Test @MainActor
    func installKeepsTheSelectionInsideTheNewBody() throws {
        let holder = Holder(threeBlockMarkdown())
        let coordinator = makeEditor(holder: holder, shown: holder.markdown)
        let textView = try #require(coordinator.textView)
        let end = textView.string.utf16.count
        textView.setSelectedRange(NSRange(location: end, length: 0))
        holder.markdown = "Short"

        coordinator.installModelMarkdownIfStale()

        let length = textView.string.utf16.count
        #expect(textView.selectedRange().location <= length, "the selection must be clamped to the new body")
        #expect(textView.string.hasPrefix("Short"))
    }
}
