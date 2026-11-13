import AppKit

/// A list cell's tags as chips that wrap at the cell's width (`TagChips`), read-only: Notes' Tags column, drawn as the
/// Reader's File tags column draws its chips (W40.suite-reader-notes-consistency; owner, Notes session 2 row 12: "tags
/// do not wrap in the list as they do in the Reader"). Filled on an ordinary row, outlined in the selected-row text
/// colour on an emphasized one, with the same geometry in both, so a selection never changes the row's height.
/// The table works out the row's height with `height(for:font:width:)` from the column's width.
@MainActor
public final class TagChipsView: NSView {
    public var titles: [String] = [] { didSet { if titles != oldValue { needsDisplay = true } } }
    public var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize) { didSet { needsDisplay = true } }
    public var placeholder: String = "" { didSet { needsDisplay = true } }
    /// Whether the row behind is selected and emphasized; set by the enclosing cell's `backgroundStyle`.
    public var emphasized = false { didSet { if emphasized != oldValue { needsDisplay = true } } }

    public override var isFlipped: Bool { true }

    /// The height `titles` need at `width`: one line of chips when they fit, more when they wrap.
    /// `titleWidth` is `TagChips.layout`'s: a cached measure, for a table asking for many rows.
    public static func height(for titles: [String], font: NSFont, width: CGFloat,
                              titleWidth: ((String) -> CGFloat)? = nil) -> CGFloat {
        TagChips.layout(titles, font: font, width: width, titleWidth: titleWidth).height
    }

    public override func draw(_ dirtyRect: NSRect) {
        if titles.isEmpty {
            guard !placeholder.isEmpty else { return }
            TagChips.drawPlaceholder(placeholder, in: bounds, flipped: true, font: font, emphasized: emphasized)
            return
        }
        TagChips.draw(TagChips.layout(titles, font: font, width: bounds.width), in: bounds, flipped: true, font: font,
                      emphasized: emphasized)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let rewraps = newSize.width != frame.width
        super.setFrameSize(newSize)
        if rewraps { needsDisplay = true }
    }
}
