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
}
