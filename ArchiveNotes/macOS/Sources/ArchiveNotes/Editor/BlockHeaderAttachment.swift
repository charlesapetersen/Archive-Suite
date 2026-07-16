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

    /// W7-S3 — invoked when the user clicks "Jump to Source" on a note-passage (extract) chip.
    /// Set once after init, read from the nonisolated viewProvider.
    nonisolated(unsafe) var onJump: (@Sendable (SourceAnchor) -> Void)?

    /// W7-S3 — the source note's CURRENT title + date (resolved against the live item set at style
    /// time), preferred over the snapshot `display`; nil ⟹ use the snapshot label. Only set for
    /// note-passage chips (in the extract editor).
    nonisolated(unsafe) var passageLiveLabel: String?

    /// W7-S3 — true when a note-passage source no longer resolves (deleted / trashed). The chip renders
    /// greyed with a "source removed" tooltip; the jump still fires (it surfaces the preserved-text
    /// status). Only meaningful for note-passage chips.
    nonisolated(unsafe) var passageSourceMissing = false

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
        provider.chipJump = onJump
        provider.chipLiveLabel = passageLiveLabel
        provider.chipSourceMissing = passageSourceMissing
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
    nonisolated(unsafe) var chipJump: (@Sendable (SourceAnchor) -> Void)?
    nonisolated(unsafe) var chipLiveLabel: String?
    nonisolated(unsafe) var chipSourceMissing = false

    // loadView is always called on the main thread by TextKit 2.
    @preconcurrency override func loadView() {
        let box = chipBox
        let reveal = chipReveal
        let jump = chipJump
        let liveLabel = chipLiveLabel
        let sourceMissing = chipSourceMissing
        let previewBox = PreviewCallbackBox(chipPreview)
        // NSView.init is @MainActor — assumeIsolated is correct here (always main thread).
        let chipView: NSView = MainActor.assumeIsolated {
            if let box {
                return BlockHeaderChipView(box: box, onReveal: reveal, onPreview: previewBox.callback,
                                           onJump: jump, liveLabel: liveLabel, sourceMissing: sourceMissing)
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
    private var onJump: (@Sendable (SourceAnchor) -> Void)?
    /// W7-S3 — resolved live label (source note's current title + date); nil ⟹ use the snapshot.
    private let liveLabel: String?
    /// W7-S3 — the note-passage source no longer resolves; render greyed with a "source removed" hint.
    private let sourceMissing: Bool

    @preconcurrency
    init(box: SourceAnchorBox, onReveal: (@Sendable (SourceAnchor) -> Void)?,
         onPreview: ((SourceAnchor, NSView) -> Void)? = nil,
         onJump: (@Sendable (SourceAnchor) -> Void)? = nil,
         liveLabel: String? = nil, sourceMissing: Bool = false) {
        self.box = box
        self.onReveal = onReveal
        self.onPreview = onPreview
        self.onJump = onJump
        self.liveLabel = liveLabel
        self.sourceMissing = sourceMissing
        super.init(frame: .zero)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    private func setupSubviews() {
        // A note-passage chip (extract provenance, W7-S3) offers "Jump to Source" and prefers the
        // source note's live title; a missing source renders greyed.
        let isPassage = box.anchor.notePassageTarget != nil
        let tint: NSColor = (isPassage && sourceMissing) ? .secondaryLabelColor : .controlAccentColor

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        if isPassage && sourceMissing {
            toolTip = "The source note for this passage no longer exists — the extract text is preserved."
        }

        let displayText: String
        if isPassage, let live = liveLabel, !live.isEmpty {
            displayText = live
        } else if let d = box.anchor.display, !d.isEmpty {
            displayText = d
        } else {
            displayText = box.kind.rawValue
        }

        let label = NSTextField(labelWithString: displayText)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Assemble action buttons by what the block actually supports:
        //  - a source anchor (`link`) gets Reveal + Preview (reader-page / reader-doc);
        //  - a Zotero ref (`zoteroSelect`) gets "Open in Zotero";
        //  - a note-passage (extract) anchor gets "Jump to Source" (W7-S3).
        // A block with none of these (plain freeform) shows just its label rather than dead buttons.
        var views: [NSView] = [label]

        if isPassage {
            let jumpButton = NSButton(title: "Jump to Source", target: self,
                                      action: #selector(jumpClicked))
            jumpButton.bezelStyle = .inline
            jumpButton.controlSize = .small
            jumpButton.font = .systemFont(ofSize: 10)
            jumpButton.image = NSImage(systemSymbolName: "arrow.up.forward.square",
                                       accessibilityDescription: "Jump to source")
            jumpButton.imagePosition = .imageLeading
            jumpButton.setAccessibilityIdentifier("an.chip.jump")
            views.append(jumpButton)
        }

        if box.anchor.link != nil {
            let revealButton = NSButton(title: "Reveal", target: self, action: #selector(revealClicked))
            revealButton.bezelStyle = .inline
            revealButton.controlSize = .small
            revealButton.font = .systemFont(ofSize: 10)
            revealButton.setAccessibilityIdentifier("an.chip.reveal")

            let previewButton = NSButton(title: "Preview", target: self, action: #selector(previewClicked))
            previewButton.bezelStyle = .inline
            previewButton.controlSize = .small
            previewButton.font = .systemFont(ofSize: 10)
            previewButton.setAccessibilityIdentifier("an.chip.preview")

            views.append(revealButton)
            views.append(previewButton)
        }

        if box.anchor.zoteroSelect != nil {
            let zoteroButton = NSButton(title: "Open in Zotero", target: self,
                                        action: #selector(openZoteroClicked))
            zoteroButton.bezelStyle = .inline
            zoteroButton.controlSize = .small
            zoteroButton.font = .systemFont(ofSize: 10)
            zoteroButton.setAccessibilityIdentifier("an.chip.zoteroOpen")
            views.append(zoteroButton)
        }

        let stack = NSStackView(views: views)
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

    @objc private func jumpClicked() {
        onJump?(box.anchor)
    }

    @objc private func openZoteroClicked() {
        guard let select = box.anchor.zoteroSelect,
              let url = URL(string: select) else { return }
        // Shared choke-point: records under a UITest launch (G11), opens for real otherwise.
        openExternalURL(url)
    }
}
