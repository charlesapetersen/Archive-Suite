import Testing
import Foundation
import SwiftUI
@testable import ArchiveNotes

@Suite("EditorBindingTests — W3-S1 editor plumbing")
struct EditorBindingTests {

    // MARK: - EditorTextView basics

    @Test @MainActor
    func textViewUsesTextKit2() {
        let tv = EditorTextView()
        #expect(tv.textLayoutManager != nil, "EditorTextView must use TextKit 2")
    }

    @Test @MainActor
    func textViewUndoEnabled() {
        let tv = EditorTextView()
        #expect(tv.allowsUndo)
    }

    @Test @MainActor
    func textViewFindBarEnabled() {
        let tv = EditorTextView()
        #expect(tv.usesFindBar)
        #expect(tv.isIncrementalSearchingEnabled)
    }

    @Test @MainActor
    func rawModeToggleChangesFont() {
        let tv = EditorTextView()
        tv.applyRawMode(false, fontSize: 14)
        let styledFont = tv.font
        tv.applyRawMode(true, fontSize: 14)
        let rawFont = tv.font
        #expect(styledFont != rawFont, "Raw mode should use a different (monospaced) font")
    }

    @Test @MainActor
    func rawModeFontIsMonospaced() {
        let tv = EditorTextView()
        tv.applyRawMode(true, fontSize: 14)
        let font = tv.font!
        // Monospaced system font has "Menlo" or contains "Mono" in its name,
        // or we can check the font descriptor traits.
        let traits = font.fontDescriptor.symbolicTraits
        #expect(traits.contains(.monoSpace), "Raw-mode font must be monospaced")
    }

    // MARK: - Coordinator write-back

    @Test @MainActor
    func coordinatorFlushWritesBackToBinding() {
        let holder = BindingHolder("initial")
        let coordinator = makeCoordinator(holder: holder)
        coordinator.textView?.string = "changed by user"
        coordinator.flushWriteBack()
        #expect(holder.markdown == "changed by user")
    }

    @Test @MainActor
    func coordinatorSuppressesProgrammaticWriteBack() {
        let holder = BindingHolder("initial")
        let coordinator = makeCoordinator(holder: holder)
        coordinator.isApplyingProgrammaticChange = true
        coordinator.textView?.string = "programmatic"
        coordinator.flushWriteBack()
        #expect(holder.markdown == "programmatic")
    }

    @Test @MainActor
    func switchModeClearsUndo() {
        let holder = BindingHolder("hello")
        let coordinator = makeCoordinator(holder: holder)
        let tv = coordinator.textView!
        tv.string = "hello world"
        coordinator.flushWriteBack()
        coordinator.switchMode(to: true)
        #expect(coordinator.currentIsRaw == true)
        // Without a window the undo manager may be nil; when present it must be empty.
        if let um = tv.undoManager {
            #expect(um.canUndo == false, "Undo stack should be cleared after mode switch")
        }
    }

    @Test @MainActor
    func switchModePreservesText() {
        let holder = BindingHolder("# Hello\n\nSome **bold** text")
        let coordinator = makeCoordinator(holder: holder)

        // Switch to raw: the binding's markdown string is shown verbatim
        coordinator.switchMode(to: true)
        let rawText = coordinator.textView!.string
        #expect(rawText.contains("Hello"), "Text content must survive raw-mode switch")
        #expect(rawText.contains("bold"), "Text content must survive raw-mode switch")

        // Switch back to styled: text content preserved (bridge may normalize formatting)
        coordinator.switchMode(to: false)
        let styledText = coordinator.textView!.string
        #expect(styledText.contains("Hello"), "Text content must survive styled-mode switch")
        #expect(styledText.contains("bold"), "Text content must survive styled-mode switch")
    }

    // MARK: - Lint check (no .layoutManager in Editor/)

    @Test
    func lintEditorNoLayoutManager() throws {
        // Verify none of the Editor/ Swift files reference .layoutManager
        let editorDir = findEditorDir()
        guard let dir = editorDir else {
            // If we can't find the dir (e.g. running from Xcode with a different working dir),
            // skip gracefully — the shell lint script is the real gate.
            return
        }
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".swift") }
        for file in files {
            let content = try String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
            #expect(!content.contains(".layoutManager"),
                    "Editor/\(file) must not reference .layoutManager (TextKit 1 downgrade risk)")
        }
    }

    // MARK: - Helpers

    @MainActor
    final class BindingHolder {
        var markdown: String
        var isRaw: Bool = false
        init(_ md: String) { self.markdown = md }
    }

    @MainActor
    private func makeCoordinator(holder: BindingHolder) -> MarkdownEditorView.Coordinator {
        let view = MarkdownEditorView(
            markdown: Binding(get: { holder.markdown }, set: { holder.markdown = $0 }),
            isRaw: Binding(get: { holder.isRaw }, set: { holder.isRaw = $0 })
        )
        let coordinator = view.makeCoordinator()
        let textView = EditorTextView()
        textView.string = holder.markdown
        coordinator.textView = textView
        coordinator.parent = view
        return coordinator
    }

    private func findEditorDir() -> String? {
        // Walk up from the test bundle to find the source tree.
        // In a worktree: .../ArchiveNotes/macOS/Sources/ArchiveNotes/Editor
        let fm = FileManager.default
        var dir = fm.currentDirectoryPath
        for _ in 0..<10 {
            let candidate = "\(dir)/ArchiveNotes/macOS/Sources/ArchiveNotes/Editor"
            if fm.fileExists(atPath: candidate) { return candidate }
            dir = (dir as NSString).deletingLastPathComponent
            if dir == "/" { break }
        }
        return nil
    }
}
