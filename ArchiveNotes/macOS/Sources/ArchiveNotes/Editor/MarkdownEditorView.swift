import SwiftUI
import AppKit

/// A handle the host view can call to push the editor's pending (debounced) serialize into its
/// `markdown` binding **synchronously** — used before a selection switch so a flush-on-switch captures
/// the last keystrokes even if the 400 ms debounce hasn't fired (W7-S1a). The coordinator populates
/// `flush` in `makeNSView`.
@MainActor
final class EditorFlushBox {
    var flush: (() -> Void)?
    init() {}
}

#if DEBUG
/// W8-S7 §3.3 — a DEBUG-only test seam mirroring `EditorFlushBox`. Driving the styled TextKit-2
/// `NSTextView` through XCUITest is unreliable, so the host exposes hidden controls that call these
/// closures to commit body text / insert at the caret / set a selection without field-editor focus.
/// The coordinator populates them in `makeNSView`. Compiled out of Release.
@MainActor
final class EditorTestBox {
    var replaceMarkdown: ((String) -> Void)?
    var insertMarkdown: ((String) -> Void)?
    var setSelection: ((Int, Int) -> Void)?
    var pasteImage: (() -> Void)?
    var jumpFirstPassage: (() -> Void)?
    var revealFirstSource: (() -> Void)?
    var openFirstZotero: (() -> Void)?
    init() {}
}
#endif

/// A request to scroll the editor to a note-passage block ordinal (W7-S3 jump-to-source consume side).
/// `token` makes a repeat jump to the SAME block re-fire (the coalescing-counter idiom); `block == nil`
/// means "just reveal the item" (scroll to the top). Equatable so `updateNSView` fires only on a new token.
struct EditorScrollRequest: Equatable {
    let token: Int
    let block: Int?
}

/// NSViewRepresentable wrapping an EditorTextView in an NSScrollView.
/// Two-way binding to a Markdown string, with debounced write-back, freeze-during-edit,
/// undo/find, and a raw-Markdown toggle (⌘/).
struct MarkdownEditorView: NSViewRepresentable {
    @Binding var markdown: String
    @Binding var isRaw: Bool
    var fontSize: CGFloat = 14
    var formatting: FormattingContext?
    var assetStore: EditorAssetStore?
    /// Optional flush handle: populated by the coordinator so the host can force a synchronous
    /// write-back of pending edits (W7-S1a autosave flush-on-switch).
    var flushBox: EditorFlushBox?
    /// Called when "Reveal in Reader" is clicked on a block chip.
    var onRevealBlock: (@Sendable (SourceAnchor) -> Void)?
    /// Called when "Preview" is clicked on a block chip. Receives anchor + anchor view for popover.
    var onPreviewBlock: ((SourceAnchor, NSView) -> Void)?
    /// W7-S3 — called when "Jump to Source" is clicked on a note-passage (extract) chip.
    var onJumpBlock: (@Sendable (SourceAnchor) -> Void)?
    /// W7-S3 — live item summaries used to resolve a note-passage chip's current title + missing state.
    var passageSummaries: [ItemSummary] = []
    /// W7-S3 — a pending jump-to-source scroll (nil = none). When its token changes, the editor scrolls
    /// the current content to the block's range (or the top when the ordinal is stale / absent).
    var scrollRequest: EditorScrollRequest?
    /// W7-S3 — reports the scroll outcome: `true` if the exact block was found, `false` if the ordinal
    /// was stale (source edited since snapshot) and the editor fell back to the top.
    var onScrollOutcome: ((Bool) -> Void)?
#if DEBUG
    /// DEBUG-only UITest seam (W8-S7 §3.3): populated by the coordinator so the host's hidden UITest
    /// controls can drive the editor (commit / insert / select) without field-editor focus.
    var testBox: EditorTestBox?
#endif

    @MainActor
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    func makeNSView(context: Context) -> NSScrollView {
        let textView = EditorTextView()
        textView.setAccessibilityIdentifier("an.editor.text")
        textView.delegate = context.coordinator
        textView.configuredFontSize = fontSize
        textView.applyRawMode(isRaw, fontSize: fontSize)

        // Wire formatting context + asset store
        if let fmt = formatting {
            fmt.textView = textView
            fmt.fontSize = fontSize
            fmt.coordinator = context.coordinator
            context.coordinator.formattingContext = fmt
        }
        textView.assetStore = assetStore
        context.coordinator.assetStore = assetStore
        context.coordinator.onRevealBlock = onRevealBlock
        context.coordinator.onPreviewBlock = onPreviewBlock
        context.coordinator.onJumpBlock = onJumpBlock
        context.coordinator.passageSummaries = passageSummaries
        flushBox?.flush = { [weak coordinator = context.coordinator] in coordinator?.flushWriteBack() }
#if DEBUG
        testBox?.replaceMarkdown = { [weak coordinator = context.coordinator] in
            coordinator?.uiTestReplaceMarkdown($0)
        }
        testBox?.insertMarkdown = { [weak coordinator = context.coordinator] in
            coordinator?.uiTestInsertMarkdown($0)
        }
        testBox?.setSelection = { [weak coordinator = context.coordinator] loc, len in
            coordinator?.uiTestSetSelection(loc, len)
        }
        testBox?.pasteImage = { [weak coordinator = context.coordinator] in
            _ = coordinator?.uiTestPasteImage()
        }
        testBox?.jumpFirstPassage = { [weak coordinator = context.coordinator] in
            _ = coordinator?.uiTestJumpFirstPassage()
        }
        testBox?.revealFirstSource = { [weak coordinator = context.coordinator] in
            _ = coordinator?.uiTestRevealFirstSource()
        }
        testBox?.openFirstZotero = { [weak coordinator = context.coordinator] in
            _ = coordinator?.uiTestOpenFirstZotero()
        }
#endif
        textView.sourceBlockPasteHandler = { [weak coordinator = context.coordinator] entries in
            coordinator?.handleSourceBlockPaste(entries) ?? false
        }
        textView.passageCopyHandler = { [weak coordinator = context.coordinator] in
            coordinator?.copyPassageIfNote() ?? false
        }
        textView.passagePasteHandler = { [weak coordinator = context.coordinator] in
            coordinator?.handlePassagePaste() ?? false
        }
        if isRaw {
            textView.string = markdown
        } else {
            let styled = MarkdownBridge.parse(markdown: markdown, fontSize: fontSize,
                                               assetStore: assetStore,
                                               onRevealBlock: onRevealBlock,
                                               onPreviewBlock: onPreviewBlock,
                                               onJumpBlock: onJumpBlock,
                                               passageSummaries: passageSummaries)
            textView.textStorage?.setAttributedString(styled)
        }
        context.coordinator.lastAppliedMarkdown = markdown

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
        // Keep the block-chip callbacks + live summaries current (the struct is recreated each render).
        coordinator.onRevealBlock = onRevealBlock
        coordinator.onPreviewBlock = onPreviewBlock
        coordinator.onJumpBlock = onJumpBlock
        coordinator.passageSummaries = passageSummaries
        // Keep the asset store current — it can appear/refresh after makeNSView (W7-S5: the pane creates
        // the item-scoped store in onAppear, once the NotesModel's NoteStore has bootstrapped).
        if coordinator.assetStore !== assetStore {
            coordinator.assetStore = assetStore
            textView.assetStore = assetStore
        }

        // Font / raw-mode change
        let wantRaw = isRaw
        if coordinator.currentIsRaw != wantRaw {
            coordinator.switchMode(to: wantRaw)
            // switchMode already re-rendered the content in the new representation; record it so the
            // apply guard below doesn't redundantly re-render (which could restart the update loop).
            coordinator.lastAppliedMarkdown = markdown
        }
        if coordinator.currentFontSize != fontSize {
            coordinator.currentFontSize = fontSize
            textView.configuredFontSize = fontSize
            textView.applyRawMode(wantRaw, fontSize: fontSize)
            coordinator.formattingContext?.fontSize = fontSize
        }

        // Freeze-during-edit: don't clobber the text storage while the user is typing. Re-apply only
        // when the SOURCE Markdown actually changed — compare against the last-applied source, NOT the
        // rendered `textView.string` (which in styled mode never equals the raw Markdown, so the old
        // guard re-applied on every pass; the ensuing selection-change → @Published formatting-state
        // mutation re-invalidated the view, pinning the main thread at 100% while an unfocused styled
        // note was shown — W8-S8 spindump). Gating on the source makes updateNSView idempotent.
        let isEditing = textView.window?.firstResponder === textView
        if !isEditing, coordinator.lastAppliedMarkdown != markdown {
            coordinator.isApplyingProgrammaticChange = true
            if wantRaw {
                textView.string = markdown
            } else {
                let styled = MarkdownBridge.parse(markdown: markdown, fontSize: fontSize,
                                                   assetStore: coordinator.assetStore,
                                                   onRevealBlock: coordinator.onRevealBlock,
                                                   onPreviewBlock: coordinator.onPreviewBlock,
                                                   onJumpBlock: coordinator.onJumpBlock,
                                                   passageSummaries: coordinator.passageSummaries)
                textView.textStorage?.setAttributedString(styled)
            }
            coordinator.isApplyingProgrammaticChange = false
            coordinator.lastAppliedMarkdown = markdown
        }

        // W7-S3 jump-to-source: scroll to the requested block once (per token). The content above has
        // just been (re)applied when the loaded item changed, so the block-ordinal map is current; the
        // host only sets `scrollRequest` once the target item's body is loaded (gated on `loadedID`).
        if !wantRaw, let req = scrollRequest, coordinator.lastScrollToken != req.token {
            coordinator.lastScrollToken = req.token
            let rendered = textView.textStorage ?? NSAttributedString()
            let range = NotePassageResolve.scrollRange(forBlock: req.block, in: rendered)
            let hitExact = (req.block == nil) || (range != nil)
            textView.scrollRangeToVisible(range ?? NSRange(location: 0, length: 0))
            onScrollOutcome?(hitExact)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditorView
        weak var textView: EditorTextView?
        var formattingContext: FormattingContext?
        weak var assetStore: EditorAssetStore?
        var onRevealBlock: (@Sendable (SourceAnchor) -> Void)?
        var onPreviewBlock: ((SourceAnchor, NSView) -> Void)?
        var onJumpBlock: (@Sendable (SourceAnchor) -> Void)?
        var passageSummaries: [ItemSummary] = []
        /// The last scroll token handled by `updateNSView`, so a jump fires once per request (W7-S3).
        var lastScrollToken: Int?
        var isApplyingProgrammaticChange = false
        var currentIsRaw = false
        var currentFontSize: CGFloat = 14
        /// The source Markdown last pushed into the text view by makeNSView/updateNSView/switchMode.
        /// The re-apply guard compares against THIS (the source), not the rendered `textView.string`,
        /// so updateNSView is idempotent for an unchanged note (see the guard in updateNSView).
        var lastAppliedMarkdown: String?
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

        nonisolated func textViewDidChangeSelection(_ notification: Notification) {
            MainActor.assumeIsolated {
                formattingContext?.updateState()
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
            let current: String
            if currentIsRaw {
                current = textView.string
            } else if let storage = textView.textStorage {
                current = MarkdownBridge.serialize(storage)
            } else {
                current = textView.string
            }
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
            textView.applyRawMode(raw, fontSize: currentFontSize)

            // Swap the storage contents between raw Markdown and styled
            if raw {
                // Entering raw: show the plain Markdown string
                textView.string = parent.markdown
            } else {
                // Leaving raw: parse and style the Markdown
                let styled = MarkdownBridge.parse(markdown: parent.markdown,
                                                   fontSize: currentFontSize,
                                                   assetStore: assetStore,
                                                   onRevealBlock: onRevealBlock,
                                                   onPreviewBlock: onPreviewBlock,
                                                   onJumpBlock: onJumpBlock,
                                                   passageSummaries: passageSummaries)
                textView.textStorage?.setAttributedString(styled)
            }

            // Clear undo across the toggle — intentional design decision (plan §6).
            textView.undoManager?.removeAllActions()

            // Sync binding
            if parent.isRaw != raw {
                parent.isRaw = raw
            }
        }

        // MARK: Insert block (W4 seam)

        /// Insert a source-block chip at the current caret position.
        func insertBlock(kind: Block.Kind = .readerPage, anchor: SourceAnchor) {
            guard let textView, !currentIsRaw else { return }
            let chipStr = MarkdownBridge.buildInsertableBlock(
                kind: kind, anchor: anchor, fontSize: currentFontSize,
                onReveal: onRevealBlock, onPreview: onPreviewBlock
            )
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(chipStr, replacementRange: textView.selectedRange())
            textView.undoManager?.endUndoGrouping()
            scheduleWriteBack()
        }

        // MARK: Source-block paste (W4-S6)

        /// Handle a paste of archive-link entries as source blocks.
        /// Imports thumbnails via assetStore and inserts each block at the caret.
        func handleSourceBlockPaste(_ entries: [SourceBlockPaster.PasteEntry]) -> Bool {
            guard let textView, !currentIsRaw, !entries.isEmpty else { return false }
            // Extracts reference NOTES only (§D7): a Reader/zotero link paste must not attach an
            // outside-document source block to an extract — decline so it degrades to plain text.
            if formattingContext?.currentItemKind == .extract { return false }
            textView.undoManager?.beginUndoGrouping()
            for var entry in entries.prefix(100) {
                if let thumbData = entry.thumbnailData, let store = assetStore {
                    if let ref = SourceBlockPaster.importThumbnail(
                        thumbData, page: entry.anchor.page, assetStore: store
                    ) {
                        entry.anchor.thumbRef = ref
                    }
                }
                let chipStr = MarkdownBridge.buildInsertableBlock(
                    kind: entry.kind, anchor: entry.anchor, fontSize: currentFontSize,
                    onReveal: onRevealBlock, onPreview: onPreviewBlock
                )
                textView.insertText(chipStr, replacementRange: textView.selectedRange())
            }
            textView.undoManager?.endUndoGrouping()
            scheduleWriteBack()
            return true
        }

        // MARK: Passage copy / paste (W7-S2)

        /// Copy the current selection as a `com.archivenotes.passage` payload when a NOTE is loaded
        /// (07-extracts §5). Writes plain + system RTF + the passage UTI, so external apps and note
        /// pastes get text/RTF while an extract paste restores full provenance. Returns false (→ the
        /// default RTF/plain copy) when no note is loaded or nothing is selected.
        func copyPassageIfNote() -> Bool {
            guard let textView, !currentIsRaw, let fmt = formattingContext,
                  fmt.currentItemKind == .note, let noteId = fmt.currentItemID else { return false }
            let source = EditorPassageSource(textView: textView, sourceNoteId: noteId,
                                             sourceTitle: fmt.currentItemTitle,
                                             sourceDateDisplay: fmt.currentItemDateDisplay,
                                             assetStore: assetStore)
            guard let payload = ExtractBuilder.passagePayload(fromSelectionIn: source) else { return false }
            return PassagePasteboard.write(payload, rtf: rtfForSelection(textView))
        }

        /// Paste a `com.archivenotes.passage` payload as note-passage block(s) into an EXTRACT editor
        /// (07-extracts §5). Declines (→ falls through to plain paste) unless an extract is loaded and a
        /// passage payload is present; the markdown is coerced to notes-only + rendered exactly as a
        /// saved-then-reloaded extract would render (chip + body).
        func handlePassagePaste() -> Bool {
            guard let textView, !currentIsRaw, formattingContext?.currentItemKind == .extract,
                  let payload = PassagePasteboard.read() else { return false }
            // Copy the payload's inline-image BYTES into THIS extract's own assets/ (reserve→write,
            // no-overwrite guard) and rewrite refs on collision, so pasted images persist instead of
            // dangling as missing-asset placeholders. Writes go only through the audited ItemAssetStore.
            let markdown = ExtractBuilder.pastedExtractMarkdown(from: payload) { data, bare in
                try? assetStore?.addAsset(data, preferredName: bare)
            }
            guard !markdown.isEmpty else { return false }
            let attributed = MarkdownBridge.parse(markdown: markdown, fontSize: currentFontSize,
                                                  assetStore: assetStore,
                                                  onRevealBlock: onRevealBlock,
                                                  onPreviewBlock: onPreviewBlock,
                                                  onJumpBlock: onJumpBlock,
                                                  passageSummaries: passageSummaries)
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(attributed, replacementRange: textView.selectedRange())
            textView.undoManager?.endUndoGrouping()
            scheduleWriteBack()
            return true
        }

        /// System RTF for the primary selected range (the copy path's rich-text fallback), or nil when
        /// nothing is selected / RTF generation fails.
        private func rtfForSelection(_ textView: NSTextView) -> Data? {
            let sel = textView.selectedRange()
            guard sel.length > 0, let storage = textView.textStorage,
                  sel.location + sel.length <= storage.length else { return nil }
            let sub = storage.attributedSubstring(from: sel)
            return try? sub.data(from: NSRange(location: 0, length: sub.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }

        // MARK: - DEBUG test seam (W8-S7 §3.3)

#if DEBUG
        /// Replace the whole body from a Markdown string (parsed styled, or raw when in raw mode), then
        /// synchronously write back to the binding so a UITest can assert the saved `.md` immediately.
        func uiTestReplaceMarkdown(_ markdown: String) {
            guard let textView else { return }
            textView.uiTestReplace(with: attributedForTest(markdown))
            flushWriteBack()
        }

        /// Insert a Markdown fragment at the caret (styled, or raw when in raw mode); schedules write-back.
        func uiTestInsertMarkdown(_ markdown: String) {
            guard let textView else { return }
            textView.uiTestInsert(attributedForTest(markdown))
            scheduleWriteBack()
        }

        /// Set the editor selection to a clamped range (supports the extract-from-selection check, G9).
        func uiTestSetSelection(_ location: Int, _ length: Int) {
            textView?.uiTestSetSelection(location: location, length: length)
        }

        /// Drive the real image-paste path from the general pasteboard (G4) without ⌘V focus routing, then
        /// flush so the `![](…)` inline reference is on disk immediately (the asset bytes persist on a
        /// background task, so the file lands shortly after). Returns whether an image was handled.
        @discardableResult
        func uiTestPasteImage() -> Bool {
            guard let textView else { return false }
            let handled = textView.uiTestPasteImage()
            if handled { flushWriteBack() }
            return handled
        }

        /// Fire the first note-passage chip's Jump-to-Source callback (G10) — read-only navigation, so no
        /// write-back. Bypasses only the un-hit-testable chip-button gesture; the anchor's real `onJump`
        /// (→ `NotesModel.openItem`) runs verbatim. Returns whether a note-passage chip was found.
        @discardableResult
        func uiTestJumpFirstPassage() -> Bool {
            return textView?.uiTestJumpFirstPassage() ?? false
        }

        /// Fire the first reader-page chip's Reveal-in-Reader callback (G6) — read-only dispatch, so no
        /// write-back. Bypasses only the un-hit-testable chip-button gesture; the anchor's real `onReveal`
        /// (→ `openExternalURL`) runs verbatim. Returns whether a reveal-able source chip was found.
        @discardableResult
        func uiTestRevealFirstSource() -> Bool {
            return textView?.uiTestRevealFirstSource() ?? false
        }

        /// Fire the first Zotero chip's Open-in-Zotero path (G11) — read-only dispatch, so no write-back.
        /// Bypasses only the un-hit-testable chip-button gesture; the same `openExternalURL` dispatch runs.
        /// Returns whether a Zotero chip was found.
        @discardableResult
        func uiTestOpenFirstZotero() -> Bool {
            return textView?.uiTestOpenFirstZotero() ?? false
        }

        /// The attributed string a test commit inserts: raw mode → monospaced plain; styled → the same
        /// `MarkdownBridge.parse` the real load path uses (so styling + serialize-back match).
        private func attributedForTest(_ markdown: String) -> NSAttributedString {
            if currentIsRaw {
                return NSAttributedString(string: markdown, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular),
                    .foregroundColor: NSColor.textColor
                ])
            }
            return MarkdownBridge.parse(markdown: markdown, fontSize: currentFontSize,
                                        assetStore: assetStore, onRevealBlock: onRevealBlock,
                                        onPreviewBlock: onPreviewBlock, onJumpBlock: onJumpBlock,
                                        passageSummaries: passageSummaries)
        }
#endif
    }
}
