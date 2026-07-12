import AppKit

/// Sendable wrapper for a non-Sendable preview callback so it can cross the
/// MainActor.assumeIsolated boundary in `loadView()`. Safe: loadView always runs on main.
final class PreviewCallbackBox: @unchecked Sendable {
    let callback: ((SourceAnchor, NSView) -> Void)?
    init(_ callback: ((SourceAnchor, NSView) -> Void)?) { self.callback = callback }
}

/// Reference wrapper so a `SourceAnchor` (value type) can ride on an `NSAttributedString.Key`.
/// Immutable + `@unchecked Sendable` — all fields are `let`.
final class SourceAnchorBox: @unchecked Sendable {
    let anchor: SourceAnchor
    let kind: Block.Kind
    let unknownHeaderFields: [(String, String)]
    let thumbRef: String?

    init(anchor: SourceAnchor, kind: Block.Kind = .freeform,
         unknownHeaderFields: [(String, String)] = [], thumbRef: String? = nil) {
        self.anchor = anchor
        self.kind = kind
        self.unknownHeaderFields = unknownHeaderFields
        self.thumbRef = thumbRef
    }
}

/// NSTextAttachment for source-block header chips. Each chip is a single atomic character
/// in the text storage — non-editable inside, deletes as a unit. Stores the `SourceAnchor`
/// + block kind + unknown header fields for lossless round-trip.
///
/// In styled mode the chip renders as a colored pill with display text + a Reveal button.
/// In raw mode the chip is absent — the `<!-- block: … -->` header shows verbatim.
@MainActor
final class BlockHeaderAttachment: NSTextAttachment {

    let sourceBox: SourceAnchorBox

    /// Callback invoked when the user clicks "Reveal in Reader" on the chip.
    /// `nonisolated(unsafe)` — set once after init, read from nonisolated viewProvider.
    nonisolated(unsafe) var onReveal: (@Sendable (SourceAnchor) -> Void)?

    /// Callback invoked when the user clicks "Preview" on the chip.
    /// Receives the anchor and the view to anchor the popover to.
    nonisolated(unsafe) var onPreview: ((SourceAnchor, NSView) -> Void)?

    init(sourceBox: SourceAnchorBox) {
        self.sourceBox = sourceBox
        super.init(data: nil, ofType: nil)
        self.bounds = CGRect(origin: .zero, size: CGSize(width: 1, height: chipHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    private let chipHeight: CGFloat = 28

    // MARK: - TextKit 2 view provider

    override nonisolated func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = BlockHeaderViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.chipBox = sourceBox
        provider.chipReveal = onReveal
        provider.chipPreview = onPreview
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    override nonisolated func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any]?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        let height: CGFloat = 28
        let width = max(proposedLineFragment.width - position.x, 200)
        return CGRect(origin: .zero, size: CGSize(width: width, height: height))
    }
}

// MARK: - View provider

final class BlockHeaderViewProvider: NSTextAttachmentViewProvider {
    /// Set before `loadView`; `nonisolated(unsafe)` because NSTextAttachmentViewProvider's
    /// inherited interfaces are nonisolated but `loadView` runs on main thread.
    nonisolated(unsafe) var chipBox: SourceAnchorBox?
    nonisolated(unsafe) var chipReveal: (@Sendable (SourceAnchor) -> Void)?
    nonisolated(unsafe) var chipPreview: ((SourceAnchor, NSView) -> Void)?

    // loadView is always called on the main thread by TextKit 2.
    @preconcurrency override func loadView() {
        let box = chipBox
        let reveal = chipReveal
        let previewBox = PreviewCallbackBox(chipPreview)
        // NSView.init is @MainActor — assumeIsolated is correct here (always main thread).
        let chipView: NSView = MainActor.assumeIsolated {
            if let box {
                return BlockHeaderChipView(box: box, onReveal: reveal, onPreview: previewBox.callback)
            }
            return NSView()
        }
        self.view = chipView
    }
}

// MARK: - Chip view (AppKit)

/// The visible chip: a rounded-rect pill with display label + Reveal button.
final class BlockHeaderChipView: NSView {

    private let box: SourceAnchorBox
    private var onReveal: (@Sendable (SourceAnchor) -> Void)?
    private var onPreview: ((SourceAnchor, NSView) -> Void)?

    @preconcurrency
    init(box: SourceAnchorBox, onReveal: (@Sendable (SourceAnchor) -> Void)?,
         onPreview: ((SourceAnchor, NSView) -> Void)? = nil) {
        self.box = box
        self.onReveal = onReveal
        self.onPreview = onPreview
        super.init(frame: .zero)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    private func setupSubviews() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor

        let displayText: String
        if let d = box.anchor.display, !d.isEmpty {
            displayText = d
        } else {
            displayText = box.kind.rawValue
        }

        let label = NSTextField(labelWithString: displayText)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .controlAccentColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let revealButton = NSButton(title: "Reveal", target: self, action: #selector(revealClicked))
        revealButton.bezelStyle = .inline
        revealButton.controlSize = .small
        revealButton.font = .systemFont(ofSize: 10)

        let previewButton = NSButton(title: "Preview", target: self, action: #selector(previewClicked))
        previewButton.bezelStyle = .inline
        previewButton.controlSize = .small
        previewButton.font = .systemFont(ofSize: 10)

        let stack = NSStackView(views: [label, revealButton, previewButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func revealClicked() {
        onReveal?(box.anchor)
    }

    @objc private func previewClicked() {
        onPreview?(box.anchor, self)
    }
}
