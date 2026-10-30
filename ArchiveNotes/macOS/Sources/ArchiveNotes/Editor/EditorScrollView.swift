import AppKit

/// The editor's scroll view. A resize keeps the reader's place: the caret stays in view if it was in view, or else
/// the first visible character stays at the top (W48.notes-stacked-layout). Without this a switch to the stacked
/// layout, which makes the note wider and shorter, left the clip origin where it was while TextKit 2 re-laid the
/// reflowed document, and the end the user was typing at fell out of view (VM: the scroll bar from 1.0 to 0.45).
final class EditorScrollView: NSScrollView {
    private struct Place {
        let selection: NSRange
        let length: Int
        /// The caret was in view: keep it there. Otherwise the character at the top of the view.
        let caretVisible: Bool
        let topCharacter: Int?
        let width: CGFloat
    }
    /// Taken at the first resize of a burst (a divider drag, a window resize), restored once on the next turn.
    private var pending: Place?

    override func setFrameSize(_ newSize: NSSize) {
        let old = frame.size
        if pending == nil, old != newSize, old.width > 0, old.height > 0, newSize.width > 0, newSize.height > 0,
           let place = currentPlace() {
            pending = place
            DispatchQueue.main.async { [weak self] in self?.restorePlace() }
        }
        super.setFrameSize(newSize)
    }

    private var textView: EditorTextView? { documentView as? EditorTextView }

    private func currentPlace() -> Place? {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return nil }
        let visible = contentView.bounds
        let selection = textView.selectedRange()
        var caretVisible = false
        if selection.length == 0, let window = textView.window {
            // `firstRect` is in screen coordinates; bring it back into the text view's.
            let screenRect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
            let inWindow = window.convertFromScreen(screenRect)
            let inText = textView.convert(inWindow, from: nil)
            caretVisible = inText.height > 0 && visible.intersects(inText.insetBy(dx: -1, dy: 0))
        }
        return Place(selection: selection, length: storage.length, caretVisible: caretVisible,
                     topCharacter: caretVisible ? nil : characterIndex(atY: visible.minY, in: textView),
                     width: frame.width)
    }

    private func restorePlace() {
        defer { pending = nil }
        guard let place = pending, let textView, let storage = textView.textStorage,
              storage.length == place.length, textView.selectedRange() == place.selection else { return }
        if place.caretVisible {
            textView.scrollRangeToVisible(place.selection)
        } else if let top = place.topCharacter, abs(frame.width - place.width) >= 1,
                  let y = lineTop(ofCharacter: top, in: textView) {
            // Only a width change reflows; a height change alone keeps the origin, and so the top line.
            let maxY = max(0, textView.frame.height - contentView.bounds.height)
            contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: min(max(0, y), maxY)))
            reflectScrolledClipView(contentView)
        }
    }

    /// The first character of the LINE at `y`, not of the paragraph: a TextKit 2 layout fragment is a whole
    /// paragraph, so anchoring to its start would jump a reader in the middle of a long paragraph back to its first line
    /// on every resize (Tier-2 review of checkpoint 10).
    private func characterIndex(atY y: CGFloat, in textView: EditorTextView) -> Int? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y - textView.textContainerOrigin.y))
        else { return nil }
        let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let yInFragment = y - textView.textContainerOrigin.y - fragment.layoutFragmentFrame.minY
        let line = fragment.textLineFragments.last { $0.typographicBounds.minY <= yInFragment }
            ?? fragment.textLineFragments.first
        return paragraphStart + (line?.characterRange.location ?? 0)
    }

    private func lineTop(ofCharacter index: Int, in textView: EditorTextView) -> CGFloat? {
        guard let layout = textView.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: index) else { return nil }
        layout.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layout.textLayoutFragment(for: location) else { return nil }
        let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let offsetInParagraph = index - paragraphStart
        // After a reflow the character may sit on a different line of the same paragraph; find the line that holds it.
        let line = fragment.textLineFragments.last { $0.characterRange.location <= offsetInParagraph }
        return fragment.layoutFragmentFrame.minY + (line?.typographicBounds.minY ?? 0) + textView.textContainerOrigin.y
    }
}
