import SwiftUI
import AppKit

/// Full-image viewer: the entire (correctly-oriented) image fits the window at zoom 1 — never
/// zoomed-in on first view. `+`/`−`/`0` (via the `zoom` binding) and pinch zoom in; drag,
/// scroll-wheel, or trackpad then pan the zoomed image in every direction (clamped to its edges).
/// Rotation is baked into the bitmap so the fit is always correct even for 90°/270° corrections.
struct ZoomableImageView: View {
    let url: URL
    var rotationDegrees: Int = 0
    @Binding var zoom: CGFloat
    /// When true, a newly-loaded image anchors to its top; when false, the current scroll offset is
    /// preserved (re-clamped to the new image) so the user's scrolled/zoomed state carries across photos.
    var anchorTopOnLoad: Bool = true
    /// Bumping this value forces a re-anchor to the top (used by a "reset to default" key).
    var resetToken: Int = 0
    /// Called when the user manually zooms/pans/scrolls, so the caller can mark the view "customized".
    var onUserAdjust: (() -> Void)? = nil

    /// Pan lives in a reference type so the scroll-wheel monitor (an escaping closure) reads and
    /// writes the live offset/bounds rather than a stale @State snapshot.
    @StateObject private var pan = PanState()
    @State private var image: NSImage?
    @State private var scrollMonitor: Any?
    @GestureState private var pinch: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            let fit = Self.fitSize(image?.size ?? geo.size, in: geo.size)
            let z = clampZoom(zoom * pinch)
            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.4)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: max(1, fit.width * z), height: max(1, fit.height * z))
                        .offset(pan.offset)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    onUserAdjust?()
                                    pan.setOffset(width: pan.last.width + v.translation.width,
                                                  height: pan.last.height + v.translation.height)
                                }
                                .onEnded { _ in pan.commit() }
                        )
                        .gesture(
                            MagnificationGesture()
                                .updating($pinch) { value, state, _ in state = value }
                                .onEnded { value in zoom = clampZoom(zoom * value); onUserAdjust?() }
                        )
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // Hit-test-transparent AppKit probe: supplies this canvas's backing NSView so the
            // scroll monitor can confine pan-scroll to THIS view's frame (see startMonitor).
            .background(ViewProbe(pan: pan))
            .clipped()
            .contentShape(Rectangle())
            .onAppear { pan.update(zoom: z, fit: fit, viewport: geo.size) }
            .onChange(of: z) { _, nz in pan.update(zoom: nz, fit: fit, viewport: geo.size) }
            .onChange(of: geo.size) { _, v in pan.update(zoom: z, fit: fit, viewport: v) }
            // New image (e.g. navigating photos): anchor to the top by default, or PRESERVE the user's
            // scroll (re-clamped to the new image) if they've adjusted the view.
            .onChange(of: image?.size) { _, _ in
                if anchorTopOnLoad { pan.update(zoom: z, fit: fit, viewport: geo.size) }
                else { pan.reclamp(zoom: z, fit: fit, viewport: geo.size) }
            }
            // "0"/reset bumps resetToken to force a top re-anchor even when the zoom is unchanged.
            .onChange(of: resetToken) { _, _ in pan.update(zoom: z, fit: fit, viewport: geo.size) }
        }
        .onAppear { load(); startMonitor() }
        .onDisappear { stopMonitor() }
        .onChange(of: url) { _, _ in load() }   // pan is handled by the image?.size / anchorTopOnLoad logic
    }

    // MARK: Scroll-wheel / trackpad pan (only when zoomed in, and only over this view)

    private func startMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // SCOPED, not app-wide: only pan+consume when the image is zoomed in AND the scroll
            // event is over THIS view's backing frame. Otherwise return the event untouched so the
            // filmstrip / tag-card thumbnail strip / any other view keeps receiving scroll.
            // `pan.hostView` is the hit-test-transparent probe installed by `ViewProbe` — a SwiftUI
            // struct owns no backing NSView, so we borrow the probe's frame to hit-test the pointer.
            guard pan.zoom > 1, let host = pan.hostView, event.window === host.window,
                  host.bounds.contains(host.convert(event.locationInWindow, from: nil))
            else { return event }
            onUserAdjust?()
            pan.setOffset(width: pan.offset.width + event.scrollingDeltaX,
                          height: pan.offset.height + event.scrollingDeltaY)
            pan.commit()
            return nil   // consume only while panning the zoomed image the pointer is over
        }
    }
    private func stopMonitor() { if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil } }

    // MARK: Loading (bakes the rotation correction into the bitmap)

    private func load() {
        guard let base = ArchiveThumbnail.load(url: url, maxSize: 2400) else { image = nil; return }
        if rotationDegrees % 360 != 0,
           let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let rotated = ImageEncoding.rotate(cg, byDegreesClockwise: rotationDegrees) {
            image = NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
        } else {
            image = base
        }
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(8, max(1, z)) }

    /// The size that fits `s` entirely within `v` (aspect-preserving, never cropping).
    private static func fitSize(_ s: CGSize, in v: CGSize) -> CGSize {
        guard s.width > 0, s.height > 0, v.width > 0, v.height > 0 else { return v }
        let scale = min(v.width / s.width, v.height / s.height)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
}

/// Pan offset + the bounds needed to clamp it, held by reference so the scroll monitor stays live.
private final class PanState: ObservableObject {
    @Published private(set) var offset: CGSize = .zero
    private(set) var last: CGSize = .zero
    private(set) var zoom: CGFloat = 1
    private var maxOffset: CGSize = .zero
    /// Backing NSView of the image canvas (from `ViewProbe`), used by the scroll monitor to confine
    /// pan-scroll to this view's frame. Weak: owned by SwiftUI, may outlive/predecease this state.
    weak var hostView: NSView?

    /// Refresh the zoom + max pan distance, and anchor the TOP of the image to the top of the viewport
    /// (don't zoom toward the center) so the first line of a document stays put as you zoom in. The
    /// current horizontal pan is preserved; the user can still scroll down to reach lower content.
    func update(zoom: CGFloat, fit: CGSize, viewport: CGSize) {
        self.zoom = zoom
        maxOffset = CGSize(width: max(0, (fit.width * zoom - viewport.width) / 2),
                           height: max(0, (fit.height * zoom - viewport.height) / 2))
        // +maxOffset.height shifts the image down so its top edge sits at the viewport top.
        offset = clamp(CGSize(width: offset.width, height: maxOffset.height))
        last = offset
    }
    /// Recompute bounds for a new image/zoom and clamp the CURRENT offset to them WITHOUT re-anchoring
    /// to the top — preserves the user's scrolled position across image swaps.
    func reclamp(zoom: CGFloat, fit: CGSize, viewport: CGSize) {
        self.zoom = zoom
        maxOffset = CGSize(width: max(0, (fit.width * zoom - viewport.width) / 2),
                           height: max(0, (fit.height * zoom - viewport.height) / 2))
        offset = clamp(offset)
        last = offset
    }
    func setOffset(width: CGFloat, height: CGFloat) { offset = clamp(CGSize(width: width, height: height)) }
    func commit() { last = offset }

    private func clamp(_ o: CGSize) -> CGSize {
        CGSize(width: min(maxOffset.width, max(-maxOffset.width, o.width)),
               height: min(maxOffset.height, max(-maxOffset.height, o.height)))
    }
}

/// Hands its backing NSView to `PanState` so the scroll monitor can hit-test the pointer against the
/// image canvas's frame — scoping pan-scroll to this view instead of swallowing scroll app-wide.
/// `hitTest` returns nil so the probe is invisible to mouse events, leaving the SwiftUI drag / pinch /
/// tap gestures on the image completely intact.
private struct ViewProbe: NSViewRepresentable {
    let pan: PanState
    func makeNSView(context: Context) -> HitTransparentView {
        let v = HitTransparentView()
        pan.hostView = v
        return v
    }
    func updateNSView(_ nsView: HitTransparentView, context: Context) { pan.hostView = nsView }
}

/// A layout-only NSView that never intercepts events (so it can't disturb SwiftUI gesture handling);
/// it exists purely to expose a backing view's `window`/`bounds` for the scroll hit-test.
private final class HitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
