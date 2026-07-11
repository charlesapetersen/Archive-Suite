import SwiftUI

struct PanelDivider: View {
    @Binding var width: Double
    /// `true` when the resizable panel is to the left of this divider (sidebar).
    let panelOnLeft: Bool
    let range: ClosedRange<CGFloat>
    var id: String = ""

    @State private var startWidth: CGFloat?

    var body: some View {
        Color(nsColor: .separatorColor)
            .frame(width: 1)
            .padding(.horizontal, 3)
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
            .accessibilityIdentifier(id)
    }
}
