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
                                    pan.setOffset(width: pan.last.width + v.translation.width,
                                                  height: pan.last.height + v.translation.height)
                                }
                                .onEnded { _ in pan.commit() }
                        )
                        .gesture(
                            MagnificationGesture()
                                .updating($pinch) { value, state, _ in state = value }
                                .onEnded { value in zoom = clampZoom(zoom * value) }
                        )
                } else {
                    ProgressView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onAppear { pan.update(zoom: z, fit: fit, viewport: geo.size) }
            .onChange(of: z) { _, nz in pan.update(zoom: nz, fit: fit, viewport: geo.size) }
            .onChange(of: geo.size) { _, v in pan.update(zoom: z, fit: fit, viewport: v) }
        }
        .onAppear { load(); startMonitor() }
        .onDisappear { stopMonitor() }
        .onChange(of: url) { _, _ in load(); pan.reset() }
    }

    // MARK: Scroll-wheel / trackpad pan (only when zoomed in)

    private func startMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard pan.zoom > 1 else { return event }
            pan.setOffset(width: pan.offset.width + event.scrollingDeltaX,
                          height: pan.offset.height + event.scrollingDeltaY)
            pan.commit()
            return nil   // consume while panning the zoomed image
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
        pan.reset()
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
    func setOffset(width: CGFloat, height: CGFloat) { offset = clamp(CGSize(width: width, height: height)) }
    func commit() { last = offset }
    func reset() { offset = .zero; last = .zero }

    private func clamp(_ o: CGSize) -> CGSize {
        CGSize(width: min(maxOffset.width, max(-maxOffset.width, o.width)),
               height: min(maxOffset.height, max(-maxOffset.height, o.height)))
    }
}
