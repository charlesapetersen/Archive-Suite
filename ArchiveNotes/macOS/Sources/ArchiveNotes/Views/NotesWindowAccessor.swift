import SwiftUI
import AppKit

/// Reaches the hosting `NSWindow` once the view is in the hierarchy, so the browser shell can
/// restore the remembered window size on first open and persist it on close (W6-S1). This is the
/// pattern Reader uses for its document window (DV-1); Notes keeps its own copy because Reader's
/// `WindowAccessor` is `private` and this is UI-adjacent (AppKit) so it does not belong in ArchiveCore.
struct NotesWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let w = nsView.window { onWindow(w) }   // in case the window attaches after makeNSView
    }
}
