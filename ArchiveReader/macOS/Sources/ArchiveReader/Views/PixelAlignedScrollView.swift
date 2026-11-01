import AppKit

/// The file list's scroll view, kept on whole backing pixels (W40.fix-reader-sidebar-slide-1pt).
///
/// While the sidebar slides, SwiftUI places this view at fractional x positions (measured in the VM: 82.44, 113.37,
/// 0.72). The clip view then backing-aligns its own bounds, which put its origin and the table's frame half a point
/// off on alternate passes, so the rows and the header wobbled by up to a point either side of the slide and a cell
/// could turn back by 1 pt. Every frame SwiftUI asks for is rounded here to the nearest pixel edges in the window, so
/// the content only ever moves in whole steps with the slide. A settled layout is already on whole pixels, so the
/// rounding changes nothing there.
final class PixelAlignedScrollView: NSScrollView {
    /// The frame SwiftUI last asked for, before rounding. Kept so that an origin and a size set separately are each
    /// rounded from the requested edges rather than from an already rounded frame.
    private var requested: NSRect?

    override var frame: NSRect {
        get { super.frame }
        set { apply(newValue) }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        var rect = requested ?? frame
        rect.origin = newOrigin
        apply(rect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        var rect = requested ?? frame
        rect.size = newSize
        apply(rect)
    }

    private func apply(_ rect: NSRect) {
        requested = rect
        let aligned = superview.map { $0.backingAlignedRect(rect, options: .alignAllEdgesNearest) } ?? rect
        if frame.origin != aligned.origin { super.setFrameOrigin(aligned.origin) }
        if frame.size != aligned.size { super.setFrameSize(aligned.size) }
    }

    /// A move to another superview (or window) can change where its pixels fall.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let requested { apply(requested) }
    }
}
