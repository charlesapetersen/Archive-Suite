import AppKit

/// NSTextView subclass enforcing TextKit 2. Never access `layoutManager` — it silently
/// downgrades to TextKit 1 and disables NSTextAttachmentViewProvider (future chips).
final class EditorTextView: NSTextView {

    /// Font size for formatting actions triggered from keyboard overrides (Tab/Return/Backspace).
    var configuredFontSize: CGFloat = 14

    init() {
        // Build the TextKit 2 stack explicitly so we guarantee TK2 in all contexts
        // (including unit tests where the default init may fall back to TK1).
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer()
        layoutManager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        assert(textLayoutManager != nil, "EditorTextView must use TextKit 2")
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    private func commonInit() {
        isRichText = true           // W3-S2: rich text for styled mode
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 12, height: 12)
        if let tc = textContainer {
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // MARK: - List keyboard behavior (Tab / Return / Backspace)

    override func insertTab(_ sender: Any?) {
        guard let storage = textStorage,
              storage.length > 0,
              let kind = storage.attribute(.noteBlockKind,
                                           at: selectedRange().location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem = kind else {
            super.insertTab(sender)
            return
        }
        EditorFormatting.indentList(self, fontSize: configuredFontSize)
    }

    override func insertBacktab(_ sender: Any?) {
        guard let storage = textStorage,
              storage.length > 0,
              let kind = storage.attribute(.noteBlockKind,
                                           at: selectedRange().location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem = kind else {
            super.insertBacktab(sender)
            return
        }
        EditorFormatting.outdentList(self, fontSize: configuredFontSize)
    }

    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage, storage.length > 0 else {
            super.insertNewline(sender)
            return
        }
        let sel = selectedRange()
        guard sel.location <= storage.length else {
            super.insertNewline(sender)
            return
        }
        let paraRange = (string as NSString).paragraphRange(for: sel)
        guard let kind = storage.attribute(.noteBlockKind, at: paraRange.location,
                                           effectiveRange: nil) as? BlockKind,
              case .listItem(let ordered, let depth, let ordinal) = kind else {
            super.insertNewline(sender)
            return
        }

        // If the current list item is empty, outdent / remove list
        let paraText = (string as NSString).substring(with: paraRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if paraText.isEmpty {
            EditorFormatting.outdentList(self, fontSize: configuredFontSize)
            return
        }

        // Insert newline and apply list item kind to the new paragraph
        super.insertNewline(sender)
        let newSel = selectedRange()
        guard newSel.location <= (string as NSString).length else { return }
        let newParaRange = (string as NSString).paragraphRange(for: newSel)
        let newOrdinal = ordered ? ordinal + 1 : 1
        let newKind = BlockKind.listItem(ordered: ordered, depth: depth, ordinal: newOrdinal)

        undoManager?.beginUndoGrouping()
        storage.beginEditing()
        storage.addAttribute(.noteBlockKind, value: newKind, range: newParaRange)
        let ps = NSMutableParagraphStyle()
        let indent = CGFloat(depth + 1) * 20
        ps.headIndent = indent
        ps.firstLineHeadIndent = max(indent - 16, 0)
        storage.addAttribute(.paragraphStyle, value: ps, range: newParaRange)
        storage.endEditing()
        undoManager?.endUndoGrouping()
    }

    override func deleteBackward(_ sender: Any?) {
        guard let storage = textStorage, storage.length > 0 else {
            super.deleteBackward(sender)
            return
        }
        let sel = selectedRange()
        // Only intercept at paragraph start with no selection
        guard sel.length == 0, sel.location > 0 else {
            super.deleteBackward(sender)
            return
        }
        let paraRange = (string as NSString).paragraphRange(for: sel)
        guard sel.location == paraRange.location else {
            super.deleteBackward(sender)
            return
        }
        guard let kind = storage.attribute(.noteBlockKind, at: paraRange.location,
                                           effectiveRange: nil) as? BlockKind else {
            super.deleteBackward(sender)
            return
        }
        switch kind {
        case .listItem:
            EditorFormatting.outdentList(self, fontSize: configuredFontSize)
        case .blockquote, .heading:
            EditorFormatting.setPlain(self, fontSize: configuredFontSize)
        default:
            super.deleteBackward(sender)
        }
    }

    // MARK: - Paste / Drag (inline images + text)

    /// The asset store used for persisting pasted/dragged images.
    /// Set by the coordinator when wiring the editor.
    weak var assetStore: EditorAssetStore?

    /// Handler for pasting archive-link payloads as source blocks.
    /// Set by the coordinator; returns true if handled.
    var sourceBlockPasteHandler: (([SourceBlockPaster.PasteEntry]) -> Bool)?

    /// W7-S2: copy the selection as a `com.archivenotes.passage` payload (note editor only). Set by the
    /// coordinator; returns true when it wrote a passage (so the default RTF/plain copy is skipped).
    var passageCopyHandler: (() -> Bool)?

    /// W7-S2: paste a `com.archivenotes.passage` payload as note-passage block(s) (extract editor only).
    /// Set by the coordinator; returns true when it inserted the passage.
    var passagePasteHandler: (() -> Bool)?

    /// Image UTIs we accept on the pasteboard.
    private static let imageTypes: Set<NSPasteboard.PasteboardType> = [
        .png, .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic")
    ]

    override func copy(_ sender: Any?) {
        // W7-S2: a note selection copies as a com.archivenotes.passage payload (+ RTF + plain); an
        // extract paste then restores full provenance. Anything else uses the default RTF/plain copy.
        if passageCopyHandler?() == true { return }
        super.copy(sender)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if tryPasteImage(from: pb) { return }
        // W7-S2: in an extract editor, a passage payload pastes as note-passage block(s) (provenance
        // preserved). The handler declines outside an extract editor / without a passage payload.
        if tryPastePassage(from: pb) { return }
        if tryPasteSourceBlocks(from: pb) { return }
        // For text: prefer plain string to avoid importing unmodeled rich styling
        if let str = pb.string(forType: .string), !str.isEmpty {
            insertPlainText(str)
            return
        }
        super.paste(sender)
    }

    /// Delegate a passage-payload paste to the coordinator (extract editor only). No-op when the
    /// pasteboard carries no `com.archivenotes.passage` representation.
    @discardableResult
    private func tryPastePassage(from pb: NSPasteboard) -> Bool {
        guard PassagePasteboard.hasPassage(pb), let handler = passagePasteHandler else { return false }
        return handler()
    }

    /// Check the pasteboard for archive-link payloads and delegate to the source-block handler.
    @discardableResult
    private func tryPasteSourceBlocks(from pb: NSPasteboard) -> Bool {
        guard let handler = sourceBlockPasteHandler else { return false }
        let entries = SourceBlockPaster.readPasteboard(from: pb)
        guard !entries.isEmpty else { return false }
        return handler(entries)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if tryPasteImage(from: pb) { return true }
        return super.performDragOperation(sender)
    }

    /// Attempt to read an image from the pasteboard, persist via assetStore, and insert
    /// an inline image attachment. Returns true if an image was handled.
    @discardableResult
    private func tryPasteImage(from pb: NSPasteboard) -> Bool {
        guard let store = assetStore else { return false }

        // Try reading image data from the pasteboard
        let imageData: Data?
        if let data = pb.data(forType: .png) {
            imageData = data
        } else if let data = pb.data(forType: .tiff) {
            // Convert TIFF to PNG for storage
            imageData = Self.tiffToPNG(data)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
                  let url = urls.first,
                  Self.isImageURL(url),
                  let data = try? Data(contentsOf: url) {
            imageData = Self.ensurePNG(data)
        } else {
            imageData = nil
        }

        guard let data = imageData else { return false }

        let dateSuffix = Self.pastedImageDateSuffix()
        let preferredName = "pasted-\(dateSuffix).png"

        do {
            let relPath = try store.addAsset(data, preferredName: preferredName)
            let thumbnail = InlineImageAttachment.downsampledThumbnail(from: data)
            let attachment = InlineImageAttachment(
                relativePath: relPath, altText: "", thumbnail: thumbnail
            )
            let attachStr = NSMutableAttributedString(attachment: attachment)
            attachStr.addAttribute(.noteImageRelPath, value: relPath,
                                   range: NSRange(location: 0, length: attachStr.length))
            // Stamp block kind from the current paragraph
            if let storage = textStorage, storage.length > 0 {
                let loc = min(selectedRange().location, storage.length - 1)
                if let kind = storage.attribute(.noteBlockKind, at: loc,
                                                effectiveRange: nil) {
                    attachStr.addAttribute(.noteBlockKind, value: kind,
                                           range: NSRange(location: 0, length: attachStr.length))
                }
            }

            undoManager?.beginUndoGrouping()
            insertText(attachStr, replacementRange: selectedRange())
            undoManager?.endUndoGrouping()
            return true
        } catch {
            return false
        }
    }

    /// Threshold (in characters) above which pasted text is parsed off-main.
    static let largePasteThreshold = 10_000

    /// Insert plain text at the caret, stripping any rich formatting.
    /// For large pastes in styled mode, parses off-main to avoid blocking the UI.
    private func insertPlainText(_ text: String) {
        if isRichText, text.count > Self.largePasteThreshold {
            insertLargeTextAsync(text)
            return
        }
        let font: NSFont = isRichText
            ? .systemFont(ofSize: configuredFontSize)
            : .monospacedSystemFont(ofSize: configuredFontSize, weight: .regular)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor
        ]
        if isRichText {
            attrs[.noteBlockKind] = BlockKind.plain
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        undoManager?.beginUndoGrouping()
        insertText(str, replacementRange: selectedRange())
        undoManager?.endUndoGrouping()
    }

    /// Parse a large text paste off-main, then apply the result on @MainActor.
    private func insertLargeTextAsync(_ text: String) {
        let fontSize = configuredFontSize
        let range = selectedRange()
        Task.detached(priority: .userInitiated) {
            // Pure parse on background — produces Sendable String→String mapping
            let markdown = text
            // Build attributed string on main (NSAttributedString is not Sendable)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let parsed = MarkdownBridge.parse(markdown: markdown, fontSize: fontSize)
                self.undoManager?.beginUndoGrouping()
                self.insertText(parsed, replacementRange: range)
                self.undoManager?.endUndoGrouping()
            }
        }
    }

    // MARK: - Image helpers

    private static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif"].contains(ext)
    }

    private static func tiffToPNG(_ tiffData: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func ensurePNG(_ data: Data) -> Data? {
        // If already PNG (header bytes), return as-is
        if data.count >= 8, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) {
            return data
        }
        // Otherwise try to convert via NSBitmapImageRep
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func pastedImageDateSuffix() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }

    // MARK: - Raw mode

    /// Toggle between styled mode and raw monospaced mode.
    func applyRawMode(_ isRaw: Bool, fontSize: CGFloat) {
        if isRaw {
            isRichText = false
            let font: NSFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            self.font = font
            typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        } else {
            isRichText = true
            let font: NSFont = .systemFont(ofSize: fontSize)
            typingAttributes = [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .noteBlockKind: BlockKind.plain
            ]
        }
    }

    // MARK: - DEBUG test seam (W8-S7 §3.3)

#if DEBUG
    // Driving this TextKit-2 styled NSTextView through XCUITest is a documented weak spot — focusing the
    // field editor and typing styled text is flaky. These DEBUG-only hooks let a UITest commit text and
    // set a selection deterministically WITHOUT relying on field-editor focus. They go through the
    // sanctioned `shouldChangeText`/`didChangeText` editing path so the delegate's `textDidChange` (→
    // debounced write-back to the bound `.md`) fires exactly as for a keystroke, and work regardless of
    // first-responder state. Compiled out of Release; the coordinator parses Markdown into the attributed
    // string it hands here (so styling + serialize-back match the real load path).

    /// Replace the entire document with `attributed` via the standard editing path (registers undo,
    /// notifies the delegate).
    func uiTestReplace(with attributed: NSAttributedString) {
        let full = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: full, replacementString: attributed.string) else { return }
        textStorage?.replaceCharacters(in: full, with: attributed)
        didChangeText()
    }

    /// Insert `attributed` over the current selection (grouped for undo) and leave the caret after it.
    func uiTestInsert(_ attributed: NSAttributedString) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return }
        undoManager?.beginUndoGrouping()
        textStorage?.replaceCharacters(in: range, with: attributed)
        didChangeText()
        undoManager?.endUndoGrouping()
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
    }

    /// Set the selection to a range clamped into the current text (out-of-range never crashes) — used by
    /// the extract-from-selection GUI check (G9).
    func uiTestSetSelection(location: Int, length: Int) {
        setSelectedRange(uiTestClampedRange(location: location, length: length))
    }

    /// Clamp a requested `(location, length)` into `[0, textLength]`. Pure — unit-tested directly.
    func uiTestClampedRange(location: Int, length: Int) -> NSRange {
        let total = (string as NSString).length
        let loc = min(max(location, 0), total)
        let len = min(max(length, 0), total - loc)
        return NSRange(location: loc, length: len)
    }

    /// Drive the REAL image-paste path (`tryPasteImage`) from the general pasteboard, bypassing ⌘V and
    /// field-editor focus (same rationale as the text seams: XCUITest can't reliably focus this styled
    /// NSTextView and route a paste to it). The UITest seeds `NSPasteboard.general` with PNG bytes
    /// cross-process, then triggers this; the production asset-write → attachment-insert → serialize path
    /// runs verbatim (nothing here is stubbed). Returns whether an image was handled. Used by the
    /// paste-image GUI check (G4). The ⌘V user-gesture routing itself is owner-eye (like G2's typing).
    @discardableResult
    func uiTestPasteImage() -> Bool {
        return tryPasteImage(from: NSPasteboard.general)
    }

    /// Fire the "Jump to Source" action of the FIRST note-passage block chip in the document — via the
    /// SAME `onJump` callback the chip button's `jumpClicked` invokes, with the SAME `SourceAnchor`.
    /// Only the button-CLICK gesture is bypassed: the chip is a TextKit-2 attachment-view-provider
    /// subview XCUITest can't hit-test (the literal click is owner-eye, like G2's typing), so the
    /// jump-to-source GUI check (G10) drives the anchor's callback directly. Returns whether a
    /// note-passage chip was found + fired. Compiled out of Release.
    @discardableResult
    func uiTestJumpFirstPassage() -> Bool {
        guard let storage = textStorage else { return false }
        var fired = false
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let chip = value as? BlockHeaderAttachment,
                  chip.sourceBox.anchor.notePassageTarget != nil else { return }
            chip.onJump?(chip.sourceBox.anchor)
            fired = true
            stop.pointee = true
        }
        return fired
    }
#endif
}
