import SwiftUI
import AppKit

/// NSViewRepresentable wrapping an EditorTextView in an NSScrollView.
/// Two-way binding to a Markdown string, with debounced write-back, freeze-during-edit,
/// undo/find, and a raw-Markdown toggle (⌘/).
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var markdown: String
    @Binding var isRaw: Bool
    var fontSize: CGFloat = 14

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView()
        textView.delegate = context.coordinator
        textView.applyRawMode(isRaw, fontSize: fontSize)
        textView.string = markdown

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        // Let the text view fill the scroll view width.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)

        context.coordinator.textView = textView
        return scrollView
    }

    @MainActor
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }
        coordinator.parent = self

        // Font / raw-mode change
        let wantRaw = isRaw
        if coordinator.currentIsRaw != wantRaw {
            coordinator.switchMode(to: wantRaw)
        }
        if coordinator.currentFontSize != fontSize {
            coordinator.currentFontSize = fontSize
            textView.applyRawMode(wantRaw, fontSize: fontSize)
        }

        // Freeze-during-edit: don't clobber the text storage while the user is typing.
        let isEditing = textView.window?.firstResponder === textView
        if !isEditing {
            let current = textView.string
            if current != markdown {
                coordinator.isApplyingProgrammaticChange = true
                textView.string = markdown
                coordinator.isApplyingProgrammaticChange = false
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: EditorTextView?
        var isApplyingProgrammaticChange = false
        var currentIsRaw = false
        var currentFontSize: CGFloat = 14
        private var serializeDebounce: Task<Void, Never>?

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
            self.currentFontSize = parent.fontSize
            self.currentIsRaw = parent.isRaw
        }

        // MARK: NSTextViewDelegate

        nonisolated func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard !isApplyingProgrammaticChange else { return }
                scheduleWriteBack()
            }
        }

        nonisolated func textDidEndEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                flushWriteBack()
            }
        }

        // MARK: Debounced write-back

        private func scheduleWriteBack() {
            serializeDebounce?.cancel()
            serializeDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.writeBack()
            }
        }

        func flushWriteBack() {
            serializeDebounce?.cancel()
            serializeDebounce = nil
            writeBack()
        }

        private func writeBack() {
            guard let textView else { return }
            let current = textView.string
            if parent.markdown != current {
                parent.markdown = current
            }
        }

        // MARK: Raw-mode toggle

        func switchMode(to raw: Bool) {
            guard let textView else { return }
            // Flush any pending write-back so we don't lose edits.
            flushWriteBack()

            currentIsRaw = raw
            // Swap visual presentation. In S1 both modes show plain text;
            // S2 will add rich rendering in styled mode.
            textView.applyRawMode(raw, fontSize: currentFontSize)

            // Clear undo across the toggle — intentional design decision (plan §6).
            textView.undoManager?.removeAllActions()

            // Sync binding
            if parent.isRaw != raw {
                parent.isRaw = raw
            }
        }
    }
}
