import AppKit

/// The tag chips as the suite draws them in a list: the Reader's File tags column (W40.fix-reader-selected-row-contrast)
/// and Notes' Tags column, whose chips are these (W40.suite-reader-notes-consistency). `TagChip` is the SwiftUI chip
/// drawn to the same metrics, for a tag bar or a filter field.
///
/// `NSTokenField` fills its tokens with a tint of the accent colour. On a selected, emphasized row that is the
/// colour of the row itself, so the chips all but vanished (worst in dark), and none of the field's four token
/// styles is an outline. So while a row's field is not being edited the Reader lays its chips out and draws them
/// itself: filled on an ordinary row, outlined and lettered in the selected-row text colour on an emphasized one.
/// The geometry is the same in both states, so selecting a row never moves a chip or changes the row's height.
/// The native field editor still draws the tokens while one is being edited (`WrappingTokenField`).
public enum TagChips {
    public struct Chip: Equatable {
        public let title: String
        /// In a top-down coordinate space whose origin is the field's top-left corner.
        public let frame: CGRect
    }

    public struct Layout: Equatable {
        public let chips: [Chip]
        /// The height the chips need, insets included; one line when there are none (the placeholder's).
        public let height: CGFloat
    }

    // The metrics follow the font, so the list text size setting scales the chips with the text, and they are
    // those of a native rounded token (about a point size of padding each side, half of one between tokens), so
    // a one-line row keeps the height it had and the chips wrap where the tokens wrap
    // (`SelectedRowContrastTests` holds the heights within a point).
    public static let lineGap: CGFloat = 2
    public static let verticalInset: CGFloat = 0
    public static let leadingInset: CGFloat = 1
    public static let cornerRadius: CGFloat = 4

    public static func chipHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender) + 1
    }

    public static func horizontalPadding(for font: NSFont) -> CGFloat { ceil(font.pointSize) }

    public static func chipGap(for font: NSFont) -> CGFloat { ceil(font.pointSize / 2) }

    /// Flows the chips left to right, wrapping at `width`. A chip wider than the field is clamped to it and its
    /// title truncated when drawn. `lineHeight` is the chips' height; the field passes one line of native tokens.
    /// `titleWidth` measures a title in `font` (`titleWidth(_:font:)`); a list working out many rows' heights passes
    /// a cached copy, since a title's width does not depend on the field's.
    public static func layout(_ titles: [String], font: NSFont, width: CGFloat, lineHeight: CGFloat? = nil,
                              titleWidth: ((String) -> CGFloat)? = nil) -> Layout {
        let height = lineHeight ?? chipHeight(for: font)
        let padding = horizontalPadding(for: font)
        let gap = chipGap(for: font)
        let maxWidth = max(width - leadingInset, 1)
        var chips: [Chip] = []
        var x = leadingInset
        var y = verticalInset
        for title in titles {
            let textWidth = titleWidth?(title) ?? Self.titleWidth(title, font: font)
            let chipWidth = min(textWidth + 2 * padding, maxWidth)
            if x > leadingInset, x + chipWidth > leadingInset + maxWidth {
                x = leadingInset
                y += height + lineGap
            }
            chips.append(Chip(title: title, frame: CGRect(x: x, y: y, width: chipWidth, height: height)))
            x += chipWidth + gap
        }
        return Layout(chips: chips, height: y + height + verticalInset)
    }

    /// A title's drawn width in `font`, rounded up.
    public static func titleWidth(_ title: String, font: NSFont) -> CGFloat {
        ceil(attributedTitle(title, font: font, color: .labelColor).size().width)
    }

    /// The fill of a chip on an ordinary row: the accent, tinted like the native token.
    public static var fill: NSColor { NSColor.controlAccentColor.withAlphaComponent(0.3) }

    /// Draws `layout` into the current graphics context of a view with `bounds`, flipped or not.
    public static func draw(_ layout: Layout, in bounds: CGRect, flipped: Bool, font: NSFont, emphasized: Bool) {
        let ink: NSColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        let padding = horizontalPadding(for: font)
        for chip in layout.chips {
            let frame = viewRect(chip.frame, in: bounds, flipped: flipped)
            if emphasized {
                // Inset by half the line, so the whole 1-pt stroke lies inside the chip's frame.
                let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: cornerRadius, yRadius: cornerRadius)
                ink.setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                fill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            }
            let title = attributedTitle(chip.title, font: font, color: ink)
            let textHeight = ceil(title.size().height)
            let textRect = CGRect(x: frame.minX + padding,
                                  y: (frame.midY - textHeight / 2).rounded(),
                                  width: max(frame.width - 2 * padding, 1),
                                  height: textHeight)
            title.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// The field's placeholder, on the first chip line, in the placeholder colour of the row's state.
    public static func drawPlaceholder(_ text: String, in bounds: CGRect, flipped: Bool, font: NSFont, emphasized: Bool,
                                lineHeight: CGFloat? = nil) {
        let color: NSColor = emphasized
            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.7)
            : .placeholderTextColor
        let title = attributedTitle(text, font: font, color: color)
        let textHeight = ceil(title.size().height)
        let line = viewRect(CGRect(x: leadingInset + 2, y: verticalInset,
                                   width: max(bounds.width - leadingInset - 2, 1),
                                   height: lineHeight ?? chipHeight(for: font)),
                            in: bounds, flipped: flipped)
        title.draw(with: CGRect(x: line.minX, y: (line.midY - textHeight / 2).rounded(),
                                width: line.width, height: textHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    public static func attributedTitle(_ title: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    private static func viewRect(_ topDown: CGRect, in bounds: CGRect, flipped: Bool) -> CGRect {
        guard !flipped else { return topDown }
        return CGRect(x: topDown.minX, y: bounds.height - topDown.maxY, width: topDown.width, height: topDown.height)
    }
}
