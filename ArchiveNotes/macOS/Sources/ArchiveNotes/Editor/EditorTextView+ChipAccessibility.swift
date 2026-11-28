import AppKit

// MARK: - Source chips without the pointer (W49.notes-chip-access; split in W49.notes-model-split)

extension EditorTextView {
    /// The text view's own accessibility children leave out the views TextKit hosts for attachments, so VoiceOver
    /// and XCUITest never reached a chip's buttons. The chips in the viewport are added here, each a group whose
    /// children are its buttons.
    override func accessibilityChildren() -> [Any]? {
        // A chip view this editor rehosted as its own subview (`installStrandedChipViews`) may already be among
        // AppKit's children; VoiceOver would then read it twice, so the chips are listed once, here.
        var children = (super.accessibilityChildren() ?? []).filter { child in
            var view = child as? NSView
            while let current = view, current !== self {
                if current is BlockHeaderChipView { return false }
                view = current.superview
            }
            return true
        }
        var seen = Set<ObjectIdentifier>()
        for chip in installedChipViews() where seen.insert(ObjectIdentifier(chip)).inserted {
            chip.setAccessibilityParent(self)
            children.append(chip)
        }
#if DEBUG
        appendDebugProbes(to: &children)
#endif
        return children
    }

    /// The chip views currently on screen in this editor, in text order.
    private func installedChipViews() -> [BlockHeaderChipView] {
        guard let layout = textLayoutManager,
              let viewport = layout.textViewportLayoutController.viewportRange else { return [] }
        var chips: [BlockHeaderChipView] = []
        layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            for provider in fragment.textAttachmentViewProviders where provider.textAttachment is BlockHeaderAttachment {
                if let chip = provider.view as? BlockHeaderChipView, chip.window === window, chip.superview != nil {
                    chips.append(chip)
                }
            }
            return true
        }
        return chips
    }

    /// The chip whose block holds `location`: the chip at it (the caret just before the chip), else the nearest
    /// one before it, unless a block boundary — the separator the Styler puts between blocks, or the newline that
    /// ends a block's text before the next chip — lies between them. Text with no chip above it has none.
    static func chipAttachment(at location: Int, in text: NSAttributedString) -> (attachment: BlockHeaderAttachment, location: Int)? {
        guard text.length > 0 else { return nil }
        let start = min(max(location, 0), text.length - 1)
        if let chip = text.attribute(.attachment, at: start, effectiveRange: nil) as? BlockHeaderAttachment {
            return (chip, start)
        }
        var found: (BlockHeaderAttachment, Int)?
        text.enumerateAttributes(in: NSRange(location: 0, length: start), options: .reverse) { attributes, range, stop in
            if let chip = attributes[.attachment] as? BlockHeaderAttachment {
                found = (chip, range.location)
                stop.pointee = true
            } else if attributes[.noteBlockSeparator] as? Bool == true || attributes[.noteChipLineEnd] as? Bool == true {
                stop.pointee = true
            }
        }
        return found.map { (attachment: $0.0, location: $0.1) }
    }

    /// The chip whose block holds the caret (the start of the selection).
    func chipAtCursor() -> (attachment: BlockHeaderAttachment, location: Int)? {
        guard let storage = textStorage else { return nil }
        return Self.chipAttachment(at: selectedRange().location, in: storage)
    }

    /// Runs `action` on the chip under the caret; false (and a beep from the caller) when there is none, or it
    /// does not offer that action.
    @discardableResult
    func performChipActionAtCursor(_ action: BlockHeaderChipAction) -> Bool {
        guard let (attachment, location) = chipAtCursor() else { return false }
        return performChipAction(action, on: attachment, at: location)
    }

    @discardableResult
    private func performChipAction(_ action: BlockHeaderChipAction, on attachment: BlockHeaderAttachment,
                                   at location: Int) -> Bool {
        guard BlockHeaderChipAction.available(for: attachment.sourceBox).contains(action) else { return false }
        if let chip = installedChipView(for: attachment, at: location) {
            chip.perform(action)
            return true
        }
        // Scrolled out of the viewport: a detached chip view with the same callbacks does the work, and is kept
        // until the next one so an action that finishes later (Add to Zotero) can still report.
        let detached = BlockHeaderChipView(attachment: attachment)
        detachedChipView = detached
        detached.perform(action, presenter: enclosingScrollView ?? self)
        return true
    }

    private func installedChipView(for attachment: BlockHeaderAttachment, at location: Int) -> BlockHeaderChipView? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let textLocation = content.location(content.documentRange.location, offsetBy: location),
              let fragment = layout.textLayoutFragment(for: textLocation) else { return nil }
        return fragment.textAttachmentViewProviders
            .first { $0.textAttachment === attachment }
            .flatMap { $0.view as? BlockHeaderChipView }
            .flatMap { $0.window === window && $0.superview != nil ? $0 : nil }
    }

    /// The editor's context menu leads with the actions of the chip clicked on, or for a menu opened without the
    /// pointer (VoiceOver), of the chip under the caret.
    override func menu(for event: NSEvent) -> NSMenu? {
        // Read before super, which moves the selection to the event's location — for a menu opened without the
        // pointer, wherever that happens to be.
        let isMouse = [.rightMouseDown, .leftMouseDown, .otherMouseDown].contains(event.type)
        let location = isMouse
            ? characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            : selectedRange().location
        let base = super.menu(for: event)
        guard let storage = textStorage,
              let (attachment, chipLocation) = Self.chipAttachment(at: location, in: storage) else { return base }
        let actions = BlockHeaderChipAction.available(for: attachment.sourceBox)
        guard !actions.isEmpty else { return base }
        // A copy: NSTextView hands out one shared default menu, and chip items left in it would show on every
        // later menu, chip or not.
        let menu = (base?.copy() as? NSMenu) ?? NSMenu()
        if menu.numberOfItems > 0 { menu.insertItem(.separator(), at: 0) }
        for action in actions.reversed() {
            let item = NSMenuItem(title: action.menuTitle, action: #selector(chipMenuItemChosen(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            item.representedObject = ChipMenuTarget(attachment: attachment, location: chipLocation)
            menu.insertItem(item, at: 0)
        }
        return menu
    }

    private final class ChipMenuTarget: NSObject {
        weak var attachment: BlockHeaderAttachment?
        let location: Int
        init(attachment: BlockHeaderAttachment, location: Int) {
            self.attachment = attachment
            self.location = location
        }
    }

    @objc private func chipMenuItemChosen(_ sender: NSMenuItem) {
        guard let action = BlockHeaderChipAction(rawValue: sender.tag),
              let target = sender.representedObject as? ChipMenuTarget,
              let attachment = target.attachment else { return }
        performChipAction(action, on: attachment, at: target.location)
    }
}
