import SwiftUI
import AppKit

/// A thin divider that can be dragged to resize an adjacent panel.
struct PanelDivider: View {
    @Binding var width: Double
    /// `true` when the resizable panel is to the left of this divider (sidebar).
    let panelOnLeft: Bool
    let range: ClosedRange<CGFloat>
    let label: String
    var id: String = ""

    @State private var startWidth: CGFloat?

    var body: some View {
        PanelDividerHandle(width: $width, range: range, label: label, id: id)
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if startWidth == nil { startWidth = CGFloat(width) }
                        let delta = panelOnLeft
                            ? value.translation.width
                            : -value.translation.width
                        let clamped = min(range.upperBound, max(range.lowerBound,
                                          (startWidth ?? CGFloat(width)) + delta))
                        width = Double(clamped)
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// A native splitter exposes the same bounded width to VoiceOver as the drag gesture above.
private struct PanelDividerHandle: NSViewRepresentable {
    @Binding var width: Double
    let range: ClosedRange<CGFloat>
    let label: String
    let id: String

    func makeNSView(context: Context) -> PanelDividerView { PanelDividerView() }

    func updateNSView(_ view: PanelDividerView, context: Context) {
        view.width = $width
        view.range = range
        view.setAccessibilityLabel(label)
        view.setAccessibilityIdentifier(id)
    }
}

final class PanelDividerView: NSView {
    var width: Binding<Double> = .constant(0)
    var range: ClosedRange<CGFloat> = 0...0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height).fill()
    }

    override func accessibilityValue() -> Any? { width.wrappedValue }
    override func accessibilityMinValue() -> Any? { Double(range.lowerBound) }
    override func accessibilityMaxValue() -> Any? { Double(range.upperBound) }

    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return }
        width.wrappedValue = min(Double(range.upperBound), max(Double(range.lowerBound), number.doubleValue))
    }

    override func accessibilityPerformIncrement() -> Bool {
        setAccessibilityValue(width.wrappedValue + 10)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        setAccessibilityValue(width.wrappedValue - 10)
        return true
    }
}
