import SwiftUI

/// `.borderedProminent` that steps down to `.bordered` while the button is disabled.
///
/// In dark appearance macOS draws a disabled `.borderedProminent` button as a solid, slightly
/// darker blue with a white label, which reads as enabled (W40.fix-processor-dark-disabled-buttons:
/// an empty queue's Start, the key wizard's Validate key, Compare Models' Select Image…). In light it
/// is a pale blue. A disabled `.bordered` button is grey with a dimmed label in both appearances, so
/// the prominent fill is kept only for an action the user can take now.
///
/// It reads `isEnabled` from the environment, so a `.disabled(_:)` placed after it (the usual
/// order) or on any ancestor applies.
private struct ProminentWhenEnabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if isEnabled {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// Use instead of `.buttonStyle(.borderedProminent)`: see `ProminentWhenEnabled`.
    func prominentButtonStyle() -> some View {
        modifier(ProminentWhenEnabled())
    }
}
