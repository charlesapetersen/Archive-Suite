import AppKit
import SwiftUI

/// Reader-owned small text and warnings must clear AA in both appearances. System secondary-label and
/// orange colours do not clear 4.5:1 on the Reader's light surfaces. Keep informational text primary;
/// use a deeper amber in light mode and a pale orange in dark mode for warnings.
enum ReaderColors {
    static let warningInk = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(srgbRed: 1, green: 0.72, blue: 0.36, alpha: 1)
        }
        return NSColor(srgbRed: 0.55, green: 0.25, blue: 0, alpha: 1)
    }
    static let warning = Color(nsColor: warningInk)

    // Explicit selected colours avoid AppKit dimming secondary labels under emphasis. The same tint follows
    // active/inactive selections in TintedTextCellView; warning hue yields to the readable selection text.
    static let informationalCellTint: (normal: NSColor, emphasized: NSColor, inactiveSelected: NSColor) =
        (.labelColor, .alternateSelectedControlTextColor, .unemphasizedSelectedTextColor)
    static let warningCellTint: (normal: NSColor, emphasized: NSColor, inactiveSelected: NSColor) =
        (warningInk, .alternateSelectedControlTextColor, .unemphasizedSelectedTextColor)
}
