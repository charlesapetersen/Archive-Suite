import AppKit
import PDFKit
import SwiftUI

/// Draws a scan's image page to a pane-sized bitmap in the background, before the preview needs it, so the
/// preview's image arrives with its text (W40.fix-reader-preview-image-speed).
///
/// Why: the text of a corpus PDF is ready in about 5 ms, but PDFKit's first draw of its scanned page costs
/// 75–650 ms (measured on twelve corpus PDFs: the full-resolution image is decoded on first draw), and a
/// PDFView shows nothing on the page until that draw lands. Warming the document is not enough: Core
/// Graphics keeps the decoded image only at the resolution it was drawn at (a warm 920×1300 px draw left a
/// 2× draw just as slow as a cold one), so there is no way to warm the size PDFView's tiles will ask for.
/// Instead the bitmap itself is shown, by `PlaceholderPageOverlay`, until PDFKit's own render replaces it.
///
/// The list's selection is drawn as soon as it changes, while the reader is still looking at the list, and
/// the rows on either side once the preview is up, so ↑/↓ land on a page already drawn. Read-only: each
/// render opens its own `PDFDocument`, so no PDFKit object is shared with the main thread, and nothing is
/// written anywhere.
@MainActor
final class PreviewImagePrefetcher: ObservableObject {
    static let shared = PreviewImagePrefetcher()
    /// The document window's: its image pane is window-sized, so its box follows the pane
    /// (`setPixelBox`), and it keeps the open file and the files either side (W40.fix-reader-viewer-switch).
    static let documentWindow = PreviewImagePrefetcher(pixelBox: CGSize(width: 1536, height: 1536), cacheLimit: 4)

    /// A finished bitmap of one page's crop box, unrotated: PDFKit lays a page overlay out in page space and
    /// turns it with the page, so the overlay draws it as it is.
    final class Rendered: @unchecked Sendable {   // immutable after init; CGImage is thread-safe to read
        let image: CGImage
        let renderMilliseconds: Double
        init(image: CGImage, renderMilliseconds: Double) {
            self.image = image
            self.renderMilliseconds = renderMilliseconds
        }
    }

    /// One page of one file, as it was on disk: a rewritten file has a new stamp, so a stale bitmap is never
    /// shown over a changed scan.
    struct Key: Hashable, Sendable {
        let path: String
        let pageIndex: Int
        let stamp: FileStamp
    }

    struct FileStamp: Hashable, Sendable {
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        /// `stat(2)`, not `URLResourceValues`: a reused `URL` answers from its resource-value cache.
        static func of(_ path: String) -> FileStamp? {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            return FileStamp(size: Int64(st.st_size), modifiedSeconds: st.st_mtimespec.tv_sec,
                             modifiedNanoseconds: st.st_mtimespec.tv_nsec)
        }
    }

    /// The largest bitmap, in pixels: one preview pane (`PreviewSheet.preferredSize` split in two, about
    /// 470×650 pt) at 2× backing. A smaller fitted sheet shows it scaled down; a pane shown larger than this
    /// (zoomed in) falls back to PDFKit's own render — see `PlaceholderPageOverlayView`.
    static let defaultPixelBox = CGSize(width: 940, height: 1300)
    /// Bitmaps kept: the selection, the rows either side and a few just left. About 4 MB each.
    static let cacheLimit = 8
    /// The largest box `setPixelBox` takes: a full-screen pane on a 5K display, about 23 MB a bitmap.
    static let maxPixelSide: CGFloat = 3072

    private(set) var pixelBox: CGSize
    private let cacheLimit: Int
    private let queue: DispatchQueue
    private var cache: [Key: Rendered] = [:]
    private var order: [Key] = []          // least recently used first
    private var wanted: [Key] = []         // highest priority first; replaced by each `prefetch`
    private var inFlight: Key?
    /// Bumped when a bitmap lands, so a view showing `image(path:pageIndex:)` asks again.
    @Published private(set) var generation = 0

    init(pixelBox: CGSize = PreviewImagePrefetcher.defaultPixelBox, cacheLimit: Int = PreviewImagePrefetcher.cacheLimit,
         queue: DispatchQueue = DispatchQueue(label: "ArchiveReader.previewPrefetch", qos: .userInitiated)) {
        self.pixelBox = pixelBox
        self.cacheLimit = max(1, cacheLimit)
        self.queue = queue
    }

    /// Draw at a new size: a square of the longer side, rounded up to 256 px so a window resize does not
    /// redraw on every point, and at most `maxPixelSide`. A changed size drops the bitmaps drawn at the old
    /// one (a render already running lands at its own size, which the overlay's resolution check covers).
    func setPixelBox(longSide: CGFloat) {
        let side = min(Self.maxPixelSide, max(256, (longSide / 256).rounded(.up) * 256))
        guard side != pixelBox.width || side != pixelBox.height else { return }
        pixelBox = CGSize(width: side, height: side)
        cache = [:]
        order = []
    }

    /// Draw these files' first image pages, in order, dropping whatever an earlier call asked for and has
    /// not started. Files already drawn are skipped; a render already running finishes.
    func prefetch(paths: [String]) {
        var seen = Set<Key>()
        wanted = paths.compactMap { path in
            guard let stamp = FileStamp.of(path) else { return nil }
            let key = Key(path: path, pageIndex: DocumentPagePairs.imagePageIndex(pair: 0), stamp: stamp)
            return seen.insert(key).inserted ? key : nil
        }
        startNext()
    }

    /// The bitmap of `path`'s page, if it has been drawn and the file is unchanged since.
    func image(path: String, pageIndex: Int) -> Rendered? {
        guard let stamp = FileStamp.of(path) else { return nil }
        let key = Key(path: path, pageIndex: pageIndex, stamp: stamp)
        guard let hit = cache[key] else { return nil }
        touch(key)
        return hit
    }

    private func startNext() {
        guard inFlight == nil else { return }
        wanted.removeAll { cache[$0] != nil }
        guard !wanted.isEmpty else { return }
        let key = wanted.removeFirst()
        inFlight = key
        let box = pixelBox
        queue.async { [weak self] in
            let rendered = Self.render(path: key.path, pageIndex: key.pageIndex, pixelBox: box)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(key, rendered) }
            }
        }
    }

    private func finish(_ key: Key, _ rendered: Rendered?) {
        inFlight = nil
        if let rendered {
            cache[key] = rendered
            touch(key)
            while order.count > cacheLimit { cache[order.removeFirst()] = nil }
            generation &+= 1
        }
        startNext()
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Open the file afresh and draw one page's crop box (the box a PDFView shows), unrotated, fitted into
    /// `pixelBox` by its longer side. nil for anything PDFKit cannot open or a page that is not there.
    nonisolated static func render(path: String, pageIndex: Int, pixelBox: CGSize) -> Rendered? {
        let start = CFAbsoluteTimeGetCurrent()
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else { return nil }
        let box = PDFDisplayBox.cropBox
        // This document is private to the render and never written, so its page may be turned upright: the
        // overlay is drawn in page space and PDFKit applies the page's turn to it.
        page.rotation = 0
        let shown = page.bounds(for: box).size
        guard shown.width > 0, shown.height > 0 else { return nil }
        let long = max(pixelBox.width, pixelBox.height), short = min(pixelBox.width, pixelBox.height)
        let fit = shown.width > shown.height ? CGSize(width: long, height: short) : CGSize(width: short, height: long)
        let scale = min(fit.width / shown.width, fit.height / shown.height)
        let width = max(1, Int((shown.width * scale).rounded())), height = max(1, Int((shown.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)          // a page is drawn on white, as PDFView draws it
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(width) / shown.width, y: CGFloat(height) / shown.height)
        page.draw(with: box, to: ctx)     // moves the box's origin to the bitmap's itself
        guard let image = ctx.makeImage() else { return nil }
        return Rendered(image: image, renderMilliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

/// Shows a prerendered bitmap over a pane's page until PDFKit's own render can take over. PDFKit lays the
/// overlay over the page and keeps it there through scroll and zoom; it takes no clicks. The bitmap is the
/// same page drawn the same way, so at the fitted size the two look alike and the swap cannot be seen.
///
/// It stops drawing for good, on that page, once it could hide something: a text selection or find
/// highlights, which PDFKit draws under overlays. Shown larger than its own resolution (zoomed in) it draws
/// nothing, leaving PDFKit's sharper render; that is checked per draw, not retired, because PDFKit lays the
/// page out at a passing scale before its fit lands.
@MainActor
final class PlaceholderPageOverlay: NSObject, @preconcurrency PDFPageOverlayViewProvider {
    private(set) var image: CGImage?
    private(set) var retired = false
    private(set) var key: String?
    private let views = NSHashTable<PlaceholderPageOverlayView>.weakObjects()

    /// A new page, named by `key`, with its bitmap if it is ready; a new page starts un-retired.
    func reset(key: String?, image: CGImage?) {
        self.key = key
        self.image = key == nil ? nil : image
        retired = false
        redraw()
    }

    /// A bitmap that arrived after the page was shown. Taken only for the page shown, and not once retired.
    func supply(_ image: CGImage, key: String) {
        guard !retired, self.image == nil, key == self.key else { return }
        self.image = image
        redraw()
    }

    func retire() {
        guard !retired else { return }
        retired = true
        redraw()
    }

    var isShowing: Bool { image != nil && !retired }

    /// Ask every overlay to draw again: after a change here, and after a zoom, so the resolution check in
    /// `PlaceholderPageOverlayView.draw` is made at the new scale.
    func redraw() { for view in views.allObjects { view.needsDisplay = true } }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PlaceholderPageOverlayView(provider: self, page: page, pdfView: view, key: key)
        views.add(overlay)
        return overlay
    }
}

final class PlaceholderPageOverlayView: NSView {
    private weak var provider: PlaceholderPageOverlay?
    private weak var page: PDFPage?
    private weak var pdfView: PDFView?
    /// The page this overlay was made for. The controller's one provider outlives each pane's PDFView, so an
    /// outgoing view must never draw the bitmap of the page that replaced it.
    private let key: String?

    init(provider: PlaceholderPageOverlay, page: PDFPage, pdfView: PDFView, key: String?) {
        self.provider = provider
        self.page = page
        self.pdfView = pdfView
        self.key = key
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let provider, provider.isShowing, provider.key == key, let image = provider.image, page != nil,
              let pdfView else { return }
        // PDFKit lays the overlay out in the page's own space (its bounds are the page's box, measured) and
        // scales and turns it with the page; the unrotated bitmap fills it.
        let rect = bounds
        // Past the bitmap's resolution PDFKit's render is sharper: leave it showing.
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let onScreen = max(rect.width, rect.height) * pdfView.scaleFactor * backing
        guard onScreen <= CGFloat(max(image.width, image.height)) * 1.1 else { return }
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        NSGraphicsContext.current?.cgContext.draw(image, in: rect)
    }
}

extension View {
    /// Draw the list selection's image pages ahead of the preview: on every selection change, and with the
    /// rows either side while the preview is up.
    func previewImagePrefetch(model: NavigationModel) -> some View {
        modifier(PreviewImagePrefetchModifier(model: model))
    }
}

private struct PreviewImagePrefetchModifier: ViewModifier {
    @ObservedObject var model: NavigationModel

    func body(content: Content) -> some View {
        content
            .onAppear(perform: prefetch)
            .onChange(of: model.selection) { prefetch() }
            .onChange(of: model.showingPreview) { prefetch() }
    }

    private func prefetch() {
        PreviewImagePrefetcher.shared.prefetch(paths: model.previewPrefetchPaths(neighbours: model.showingPreview))
    }
}
