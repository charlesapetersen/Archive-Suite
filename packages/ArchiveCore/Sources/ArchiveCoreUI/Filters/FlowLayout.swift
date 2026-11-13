import SwiftUI

/// A wrapping flow layout: left-aligned, a subview that does not fit starts the next line. The suite's one copy
/// (W40.suite-reader-notes-consistency): the Reader's tag cloud, tag editor and In effect row, and Notes' tag bar, tag
/// filter and In effect row.
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    /// `lineSpacing` defaults to `spacing`.
    public init(spacing: CGFloat = 8, lineSpacing: CGFloat? = nil) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing ?? spacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = Self.size(of: v, within: maxW)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : widest, height: y + rowH)
    }

    /// A subview's own width, or the row's width when that is less. Measured at its ideal size alone, a tag wider
    /// than the tag cloud ran past the panel's edge and was cut without an ellipsis (W40.fix-reader-tagcloud-width);
    /// offered the row's width instead, its text wraps or truncates as the subview says.
    static func size(of v: LayoutSubview, within maxW: CGFloat) -> CGSize {
        let ideal = v.sizeThatFits(.unspecified)
        guard maxW.isFinite, ideal.width > maxW else { return ideal }
        let fitted = v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
        return CGSize(width: min(fitted.width, maxW), height: fitted.height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = Self.size(of: v, within: maxW)
            if x > 0, x + s.width > maxW { x = 0; y += rowH + lineSpacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
