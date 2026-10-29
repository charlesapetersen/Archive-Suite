import SwiftUI
import AppKit

/// A thin divider that can be dragged to resize an adjacent panel. The same shape as the Reader's
/// (W40.fix-reader-a11y-labels): a native splitter underneath, so VoiceOver gets a named, adjustable control.
///
/// `axis` is the direction it resizes along: `.horizontal` is the vertical line between side-by-side panes
/// (it sets a width), `.vertical` the horizontal line of the stacked layout (it sets the list's height,
/// W48.notes-stacked-layout). One view for both, so switching layouts keeps the panes' identities.
struct PanelDivider: View {
    @Binding var size: Double
    /// `true` when the resizable panel comes before this divider: to its left (sidebar) or above it (stacked list).
    let panelBefore: Bool
    var axis: Axis = .horizontal
    let range: ClosedRange<CGFloat>
    let label: String
    var id: String = ""

    @State private var startSize: CGFloat?

    var body: some View {
        PanelDividerHandle(size: $size, axis: axis, range: range, label: label, id: id)
            .frame(width: axis == .horizontal ? 7 : nil, height: axis == .vertical ? 7 : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                else { NSCursor.pop() }
            }
            .gesture(
                // Global coordinates, so moving the divider does not feed back into its own translation.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // From where it is drawn: a remembered size can sit beyond a range a short window has cut.
                        if startSize == nil { startSize = min(range.upperBound, max(range.lowerBound, CGFloat(size))) }
                        let moved = axis == .horizontal ? value.translation.width : value.translation.height
                        let delta = panelBefore ? moved : -moved
                        let clamped = min(range.upperBound, max(range.lowerBound,
                                          (startSize ?? CGFloat(size)) + delta))
                        size = Double(clamped)
                    }
                    .onEnded { _ in startSize = nil }
            )
    }
}

/// A native splitter exposes the same bounded size to VoiceOver as the drag gesture above.
private struct PanelDividerHandle: NSViewRepresentable {
    @Binding var size: Double
    let axis: Axis
    let range: ClosedRange<CGFloat>
    let label: String
    let id: String

    func makeNSView(context: Context) -> PanelDividerView { PanelDividerView() }

    func updateNSView(_ view: PanelDividerView, context: Context) {
        view.size = $size
        view.range = range
        view.axis = axis
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(id)
    }
}

final class PanelDividerView: NSView {
    var size: Binding<Double> = .constant(0)
    var range: ClosedRange<CGFloat> = 0...0
    /// The direction the divider resizes along; its line runs across it. The accessibility orientation is the
    /// line's, as NSSplitView reports it: a vertical line between side-by-side panes is `.vertical`.
    var axis: Axis = .horizontal {
        didSet {
            guard axis != oldValue else { return }
            setAccessibilityOrientation(axis == .horizontal ? .vertical : .horizontal)
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        if axis == .horizontal {
            NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1).fill()
        }
    }

    /// The size as drawn: a remembered one can sit beyond a range a short window has cut.
    private var shown: Double { min(Double(range.upperBound), max(Double(range.lowerBound), size.wrappedValue)) }

    override func accessibilityValue() -> Any? { shown }
    override func accessibilityMinValue() -> Any? { Double(range.lowerBound) }
    override func accessibilityMaxValue() -> Any? { Double(range.upperBound) }

    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return }
        size.wrappedValue = min(Double(range.upperBound), max(Double(range.lowerBound), number.doubleValue))
    }

    override func accessibilityPerformIncrement() -> Bool {
        setAccessibilityValue(shown + 10)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        setAccessibilityValue(shown - 10)
        return true
    }
}
