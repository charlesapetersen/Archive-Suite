import AppKit

/// NSTextView subclass enforcing TextKit 2. Never access `layoutManager` — it silently
/// downgrades to TextKit 1 and disables NSTextAttachmentViewProvider (future chips).
final class EditorTextView: NSTextView {

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
        isRichText = false          // W3-S1: plain Markdown only; S2 enables rich
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

    /// Toggle between styled mode (future S2) and raw monospaced mode.
    func applyRawMode(_ isRaw: Bool, fontSize: CGFloat) {
        let font: NSFont = isRaw
            ? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            : .systemFont(ofSize: fontSize)
        self.font = font
        typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
    }
}
