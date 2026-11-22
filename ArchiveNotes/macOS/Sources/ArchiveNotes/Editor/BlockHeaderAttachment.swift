import AppKit
import ArchiveCore

/// Reference wrapper so a `SourceAnchor` (value type) can ride on an `NSAttributedString.Key`.
/// Immutable + `@unchecked Sendable` — all fields are `let`.
///
/// W3.notes-thumb-line-duplicates — there is deliberately no `thumbRef` here. It duplicated
/// `anchor.thumbRef` (its only initializer read exactly that), and the duplicate is what made it easy
/// for `MarkdownBridge.serializeBlockHeader` to re-emit the thumbnail line the block BODY already
/// carried, once per save, forever. The anchor is the single source for it; the body is the single home
/// for the rendered `![display](thumb)` line.
final class SourceAnchorBox: @unchecked Sendable {
    let anchor: SourceAnchor
    let kind: Block.Kind
    let unknownHeaderFields: [(String, String)]
    /// `Block.headerless`: the chip of a block whose incomplete or malformed header is visible in its body.
    let headerless: Bool

    init(anchor: SourceAnchor, kind: Block.Kind = .freeform,
         unknownHeaderFields: [(String, String)] = [], headerless: Bool = false) {
        self.anchor = anchor
        self.kind = kind
        self.unknownHeaderFields = unknownHeaderFields
        self.headerless = headerless
    }

    /// The page an attachment block opens its PDF at in Zotero: a `zotero-attachment` block with a positive
    /// `page:`. An item block keeps `zotero://select`, whatever page it names (W49.notes-zotero-page-links).
    var zoteroPage: Int? {
        guard kind == .zoteroAttachment, anchor.zoteroSelect != nil, let page = anchor.page, page > 0 else { return nil }
        return page
    }

    /// What Open in Zotero opens: the PDF at `zoteroPage` (`zotero://open-pdf`) when there is one, else the
    /// block's `zotero://select` link.
    var zoteroOpenURL: URL? {
        guard let select = anchor.zoteroSelect else { return nil }
        return zoteroPage.flatMap { ZoteroSelectLink.openPDFLink(selectLink: select, page: $0) } ?? URL(string: select)
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
    /// `nonisolated(unsafe)` — set once after init, copied when the provider initializes.
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
        // Keep AppKit's image/view-provider lifecycle, but never paint its generic
        // file icon over the live chip while TextKit installs the view.
        image = NSImage(size: NSSize(width: 1, height: chipHeight), flipped: false) { _ in true }
        allowsTextAttachmentView = true
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

/// Frozen display configuration. Only the preview callback is non-Sendable; it crosses the synchronous
/// main-thread `loadView` bridge and is invoked by the chip's main-thread UI action, never a worker.
private final class BlockHeaderViewConfiguration: @unchecked Sendable {
    let box: SourceAnchorBox
    let reveal: (@Sendable (SourceAnchor) -> Void)?
    let preview: ((SourceAnchor, NSView) -> Void)?
    let jump: (@Sendable (SourceAnchor) -> Void)?
    let label: String?
    let missing: Bool

    init(_ attachment: BlockHeaderAttachment) {
        box = attachment.sourceBox
        reveal = attachment.onReveal
        preview = attachment.onPreview
        jump = attachment.onJump
        label = attachment.passageLiveLabel
        missing = attachment.passageSourceMissing
    }
}

final class BlockHeaderViewProvider: NSTextAttachmentViewProvider {
    private let configuration: BlockHeaderViewConfiguration?

    override init(textAttachment: NSTextAttachment, parentView: NSView?,
                  textLayoutManager: NSTextLayoutManager?, location: any NSTextLocation) {
        // Own immutable fields are ready before AppKit's initializer can request the view.
        // Retain display values rather than depending on the base provider's weak attachment getter.
        configuration = (textAttachment as? BlockHeaderAttachment).map(BlockHeaderViewConfiguration.init)
        super.init(textAttachment: textAttachment, parentView: parentView,
                   textLayoutManager: textLayoutManager, location: location)
    }


    override nonisolated func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any]?, location: any NSTextLocation,
        textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        CGRect(origin: .zero, size: CGSize(width: max(proposedLineFragment.width - position.x, 200), height: 28))
    }

    @preconcurrency override func loadView() {
        let captured = configuration
        let chipView: NSView = MainActor.assumeIsolated {
            guard let captured else { return NSView() }
            return BlockHeaderChipView(box: captured.box,
                                       onReveal: captured.reveal,
                                       onPreview: captured.preview,
                                       onJump: captured.jump,
                                       liveLabel: captured.label,
                                       sourceMissing: captured.missing)
        }
        self.view = chipView
    }
}

// MARK: - Chip actions

/// W49.notes-chip-access — what a chip offers, in its buttons' order. One list feeds the buttons, the chip's
/// right-click menu, VoiceOver's actions and the editor's keyboard commands, so no route can offer an action the
/// block does not support.
enum BlockHeaderChipAction: Int, CaseIterable {
    case jump, reveal, preview, copyForZotero, addToZotero, openInZotero

    /// By what the block supports: a note-passage (extract) anchor jumps to its source note (W7-S3); a source
    /// anchor (`link`) reveals and previews; a Reader page or document also goes to Zotero (W47.ct-zotero); a
    /// Zotero ref (`zoteroSelect`) opens in Zotero.
    static func available(for box: SourceAnchorBox) -> [Self] {
        var actions: [Self] = []
        if box.anchor.notePassageTarget != nil { actions.append(.jump) }
        if box.anchor.link != nil { actions += [.reveal, .preview] }
        if box.anchor.link != nil && (box.kind == .readerPage || box.kind == .readerDoc) {
            actions += [.copyForZotero, .addToZotero]
        }
        if box.anchor.zoteroSelect != nil { actions.append(.openInZotero) }
        return actions
    }

    var buttonTitle: String {
        switch self {
        case .jump: "Jump to Source"
        case .reveal: "Reveal"
        case .preview: "Preview"
        case .copyForZotero: "Copy for Zotero"
        case .addToZotero: "Add to Zotero"
        case .openInZotero: "Open in Zotero"
        }
    }

    /// The menus' and VoiceOver's name, which has no chip beside it to say what is revealed or previewed.
    var menuTitle: String {
        switch self {
        case .reveal: "Reveal Source in Reader"
        case .preview: "Preview Source"
        default: buttonTitle
        }
    }

    var identifier: String {
        switch self {
        case .jump: "an.chip.jump"
        case .reveal: "an.chip.reveal"
        case .preview: "an.chip.preview"
        case .copyForZotero: "an.chip.copyForZotero"
        case .addToZotero: "an.chip.addToZotero"
        case .openInZotero: "an.chip.zoteroOpen"
        }
    }

    /// The tooltip for this action on `box`'s chip: Open in Zotero says when it opens the PDF at a page.
    func toolTip(for box: SourceAnchorBox) -> String? {
        if self == .openInZotero, let page = box.zoteroPage { return "Open the PDF in Zotero at page \(page)" }
        return toolTip
    }

    var toolTip: String? {
        switch self {
        case .copyForZotero:
            "Copy this source's archival location, dates, people and item fields as CSL-JSON; "
                + "in Zotero, choose File ▸ Import from Clipboard"
        case .addToZotero:
            "Add this source to Zotero on this Mac, with its subjects as tags, into the library "
                + "or collection selected there"
        default: nil
        }
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
    /// W47.ct-zotero — the source's archival location, shown once read.
    private let containerLabel = NSTextField(labelWithString: "")
    /// What this chip offers, in button order (W49.notes-chip-access).
    private var actions: [BlockHeaderChipAction] { BlockHeaderChipAction.available(for: box) }
    /// Retitled "Added to Zotero" once the add succeeds, by whichever route asked.
    private weak var addButton: NSButton?
#if DEBUG
    var uiTestSourceNoteID: String? { box.anchor.notePassageTarget?.id.uuidString.lowercased() }
#endif

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

    /// A chip view for `attachment` with the callbacks its own view was given (the editor's keyboard route, for a
    /// chip whose view is not installed).
    convenience init(attachment: BlockHeaderAttachment) {
        self.init(box: attachment.sourceBox, onReveal: attachment.onReveal, onPreview: attachment.onPreview,
                  onJump: attachment.onJump, liveLabel: attachment.passageLiveLabel,
                  sourceMissing: attachment.passageSourceMissing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    private var tint: NSColor {
        box.anchor.notePassageTarget != nil && sourceMissing ? .secondaryLabelColor : .controlAccentColor
    }

    // The pill's fill is a CGColor, which does not follow the appearance by itself. `updateLayer` runs with the
    // view's effective appearance current, at first display and again whenever it changes, so a switch in
    // Settings ▸ Appearance repaints the chip (W48.appearance-notes).
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        }
    }

    private func setupSubviews() {
        // A note-passage chip (extract provenance, W7-S3) offers "Jump to Source" and prefers the
        // source note's live title; a missing source renders greyed.
        let isPassage = box.anchor.notePassageTarget != nil
        let tint = self.tint

        wantsLayer = true
        layer?.cornerRadius = 6
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
        // Middle, as Finder does: a file name's end ("….pdf — p. 3") says which page it is, and
        // cutting the tail left fragments such as "Dean Papers (moved)…." (W40.fix-notes-visual-polish).
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Assemble action buttons by what the block actually supports (`BlockHeaderChipAction.available`).
        // A block with none (plain freeform) shows just its label rather than dead buttons.
        var views: [NSView] = [label]

        // W47.ct-zotero: a Reader source shows where its document sits in the archive, filled in once the file's
        // container is read, and offers its gathered metadata to Zotero.
        if box.anchor.link != nil && (box.kind == .readerPage || box.kind == .readerDoc) {
            containerLabel.font = .systemFont(ofSize: 10)
            containerLabel.textColor = .secondaryLabelColor
            containerLabel.lineBreakMode = .byTruncatingTail
            containerLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            containerLabel.isHidden = true
            containerLabel.setAccessibilityIdentifier("an.chip.container")
            views.append(containerLabel)
            loadContainerLine()
        }

        for action in actions {
            let button = NSButton(title: action.buttonTitle, target: self, action: #selector(buttonClicked(_:)))
            button.tag = action.rawValue
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 10)
            button.toolTip = action.toolTip(for: box)
            button.setAccessibilityIdentifier(action.identifier)
            if action == .jump {
                button.image = NSImage(systemSymbolName: "arrow.up.forward.square",
                                       accessibilityDescription: "Jump to source")
                button.imagePosition = .imageLeading
            }
            if action == .addToZotero { addButton = button }
            views.append(button)
        }

        // W49.notes-chip-access — the same actions without the pointer on a button: a right-click on the chip,
        // and VoiceOver's actions on the chip as one element (its buttons stay reachable as its children).
        menu = actions.isEmpty ? nil : actionMenu()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Source: \(displayText)")
        setAccessibilityIdentifier("an.chip")
        setAccessibilityCustomActions(actions.map { action in
            NSAccessibilityCustomAction(name: action.menuTitle) { [weak self] in
                self?.perform(action)
                return self != nil
            }
        })

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

    /// The chip is one accessibility element, so AppKit no longer offers its subviews as children; its buttons
    /// are, for VoiceOver to step through. Each as AppKit exposes it (its cell): the button view itself has no
    /// role, and the audit reported it as an element of unknown role beside the real button.
    override func accessibilityChildren() -> [Any]? {
        var buttons: [NSButton] = []
        func visit(_ view: NSView) {
            for child in view.subviews {
                if let button = child as? NSButton { buttons.append(button) } else { visit(child) }
            }
        }
        visit(self)
        return buttons.filter { !$0.isHidden }.compactMap { NSAccessibility.unignoredDescendant(of: $0) }
    }

    /// The chip's actions as menu items, for its right-click menu.
    func actionMenu() -> NSMenu {
        let menu = NSMenu(title: "Source")
        for action in actions {
            let item = NSMenuItem(title: action.menuTitle, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        BlockHeaderChipAction(rawValue: sender.tag).map { perform($0) }
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        BlockHeaderChipAction(rawValue: sender.tag).map { perform($0) }
    }

    /// Runs one of the chip's actions, whichever route asked: a button, the menu, VoiceOver or the editor's
    /// keyboard command. `presenter` is the view a preview popover or an alert attaches to when this chip view
    /// is not on screen itself (the editor makes a detached one for a chip scrolled out of its viewport).
    func perform(_ action: BlockHeaderChipAction, presenter: NSView? = nil) {
        guard actions.contains(action) else { return }
        self.presenter = presenter
        switch action {
        case .jump: onJump?(box.anchor)
        case .reveal: onReveal?(box.anchor)
        case .preview: onPreview?(box.anchor, presenter ?? self)
        case .copyForZotero: copyForZotero()
        case .addToZotero: addToZotero()
        case .openInZotero: openInZotero()
        }
    }

    /// Where alerts go: this chip's window, else the presenter's.
    private weak var presenter: NSView?
    private var alertWindow: NSWindow? { window ?? presenter?.window }

    private func loadContainerLine() {
        let anchor = box.anchor
        Task { @MainActor [weak self] in
            guard let line = await SourceArchiveInfo.shared?.containerLine(for: anchor), let self else { return }
            self.containerLabel.stringValue = line
            self.containerLabel.toolTip = line
            self.containerLabel.isHidden = false
        }
    }

    private func copyForZotero() {
        let anchor = box.anchor
        Task { @MainActor [weak self] in
            guard let json = await SourceArchiveInfo.shared?.zoteroJSON(for: anchor),
                  let text = String(data: json, encoding: .utf8) else {
                self?.reportCopyFailure()
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// W47.ct-zotero-tags: the source straight into the Zotero on this Mac, through its connector, with the
    /// subjects as tags (the clipboard's CSL-JSON cannot carry them).
    private func addToZotero() {
        let anchor = box.anchor
        Task { @MainActor [weak self] in
            guard let source = await SourceArchiveInfo.shared?.zoteroSource(for: anchor) else {
                self?.reportCopyFailure(action: "Add to Zotero")
                return
            }
            do {
                try await ZoteroConnector().save([source])
                self?.addButton?.title = "Added to Zotero"
            } catch {
                self?.reportZoteroFailure(error as? ZoteroConnector.Failure ?? .notRunning)
            }
        }
    }

    private func reportZoteroFailure(_ failure: ZoteroConnector.Failure) {
        let alert = NSAlert()
        switch failure {
        case .notRunning:
            alert.messageText = "Zotero is not running on this Mac."
            alert.informativeText = "Start Zotero and try again, or use Copy for Zotero and File ▸ Import from Clipboard."
        case .refused(let status):
            alert.messageText = "Zotero did not add this source."
            alert.informativeText = "It answered \(status). Select a library or collection you can edit in Zotero and "
                + "try again."
        }
        if let window = alertWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    private func reportCopyFailure(action: String = "Copy for Zotero") {
        let alert = NSAlert()
        alert.messageText = "This source's file could not be read."
        alert.informativeText = "\(action) reads the document at its recorded path in an archive folder Notes "
            + "can open. Use Preview to find it, or choose its archive folder from the File menu (Choose Archive Folder…)."
        if let window = alertWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    /// An attachment block that names a page opens the PDF there (`zotero://open-pdf`); any other Zotero block
    /// selects its item or attachment in the library (W49.notes-zotero-page-links).
    private func openInZotero() {
        guard let url = box.zoteroOpenURL else { return }
        // Shared choke-point: records under a UITest launch (G11), opens for real otherwise.
        openExternalURL(url)
    }
}
