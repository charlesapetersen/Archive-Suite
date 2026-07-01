import SwiftUI
import AppKit

/// Full-size image viewer with fit-to-window default plus zoom (magnify gesture, and the
/// parent's `+`/`-`/`0` keys via the `zoom` binding) and drag-to-pan. Renders in the given
/// corrected rotation. Loads a high-resolution bitmap via `ArchiveThumbnail.load`.
struct ZoomableImageView: View {
    let url: URL
    var rotationDegrees: Int = 0
    @Binding var zoom: CGFloat

    @State private var image: NSImage?
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .textBackgroundColor).opacity(0.4)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .rotationEffect(.degrees(Double(rotationDegrees)))
                        .scaleEffect(zoom * pinch)
                        .offset(offset)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    offset = CGSize(width: lastOffset.width + v.translation.width,
                                                    height: lastOffset.height + v.translation.height)
                                }
                                .onEnded { _ in lastOffset = offset }
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
        }
        .onAppear(perform: load)
        .onChange(of: url) { _, _ in
            load()
            offset = .zero
            lastOffset = .zero
        }
        .onChange(of: zoom) { _, newValue in
            if newValue == 1 { offset = .zero; lastOffset = .zero }
        }
    }

    private func load() {
        image = ArchiveThumbnail.load(url: url, maxSize: 2400)
    }

    private func clampZoom(_ z: CGFloat) -> CGFloat { min(8, max(0.5, z)) }
}
