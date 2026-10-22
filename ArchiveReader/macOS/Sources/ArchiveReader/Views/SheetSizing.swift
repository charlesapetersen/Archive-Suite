import CoreGraphics

/// A sheet's size inside the window it hangs from. Sheets have a preferred size, but the navigation window's
/// minimum content area is 900×560, so a fixed-size sheet taller or wider than that overhangs the window
/// (W40.fix-reader-preview-sheet-oversize, W40.fix-reader-tag-editor-chips).
enum SheetSizing {
    static let windowMargin: CGFloat = 40

    /// `preferred`, shrunk to leave `windowMargin` inside `window`. A zero size means the window has not been
    /// measured yet; the preferred size stands until it is.
    static func fitted(_ preferred: CGSize, in window: CGSize) -> CGSize {
        guard window.width > 0, window.height > 0 else { return preferred }
        return CGSize(width: max(1, min(preferred.width, window.width - windowMargin)),
                      height: max(1, min(preferred.height, window.height - windowMargin)))
    }
}
