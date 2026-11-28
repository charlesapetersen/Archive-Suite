import SwiftUI
import AppKit

/// A thin divider that can be dragged to resize an adjacent panel, backed by a native splitter so VoiceOver gets
/// a named, adjustable control (W40.fix-reader-a11y-labels, W48.notes-stacked-layout, W49.core-ui-dedup).
///
/// `axis` is the direction it resizes along: `.horizontal` is the vertical line between side-by-side panes
/// (it sets a width), `.vertical` the horizontal line of a stacked layout (it sets a height).
public struct PanelDivider: View {
    /// The divider's own thickness (width when horizontal, height when vertical).
    public static let width: CGFloat = 7

    @Binding public var size: Double
    /// `true` when the resizable panel comes before this divider: to its left (sidebar) or above it (stacked list).
    public let panelBefore: Bool
    public var axis: Axis = .horizontal
    public let range: ClosedRange<CGFloat>
    public let label: String
    public var id: String = ""

    @State private var startSize: CGFloat?

    public init(size: Binding<Double>, panelBefore: Bool, axis: Axis = .horizontal,
                range: ClosedRange<CGFloat>, label: String, id: String = "") {
        self._size = size
        self.panelBefore = panelBefore
        self.axis = axis
        self.range = range
        self.label = label
        self.id = id
    }

    /// Side-by-side width divider convenience (`axis == .horizontal`).
    public init(width: Binding<Double>, panelOnLeft: Bool, range: ClosedRange<CGFloat>,
                label: String, id: String = "") {
        self.init(size: width, panelBefore: panelOnLeft, axis: .horizontal, range: range, label: label, id: id)
    }

    public var body: some View {
        PanelDividerHandle(size: $size, axis: axis, range: range, label: label, id: id)
            .frame(width: axis == .horizontal ? Self.width : nil,
                   height: axis == .vertical ? Self.width : nil)
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

public final class PanelDividerView: NSView {
    public var size: Binding<Double> = .constant(0)
    public var range: ClosedRange<CGFloat> = 0...0
    /// The direction the divider resizes along; its line runs across it. The accessibility orientation is the
    /// line's, as NSSplitView reports it: a vertical line between side-by-side panes is `.vertical`.
    public var axis: Axis = .horizontal {
        didSet {
            guard axis != oldValue else { return }
            setAccessibilityOrientation(axis == .horizontal ? .vertical : .horizontal)
            needsDisplay = true
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        if axis == .horizontal {
            NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
        } else {
            NSRect(x: 0, y: (bounds.height - 1) / 2, width: bounds.width, height: 1).fill()
        }
    }

    /// The size as drawn: a remembered one can sit beyond a range a short window has cut.
    private var shown: Double { min(Double(range.upperBound), max(Double(range.lowerBound), size.wrappedValue)) }

    public override func accessibilityValue() -> Any? { shown }
    public override func accessibilityMinValue() -> Any? { Double(range.lowerBound) }
    public override func accessibilityMaxValue() -> Any? { Double(range.upperBound) }

    public override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return }
        size.wrappedValue = min(Double(range.upperBound), max(Double(range.lowerBound), number.doubleValue))
    }

    public override func accessibilityPerformIncrement() -> Bool {
        setAccessibilityValue(shown + 10)
        return true
    }

    public override func accessibilityPerformDecrement() -> Bool {
        setAccessibilityValue(shown - 10)
        return true
    }
}
