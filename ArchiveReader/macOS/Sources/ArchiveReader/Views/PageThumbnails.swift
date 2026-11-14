import SwiftUI
import PDFKit
import ImageIO
import ArchiveCore

/// The page pictures of the thumbnail sidebar and the contact sheet (W40.reader-page-views). Each comes from
/// the app's on-disk thumbnail cache (`PDFThumbnailer`, the one Copy Archive Link uses), so a page drawn once is
/// read back from disk on every later visit, and is decoded down to the size it is shown at. Nothing here
/// holds a `PDFDocument` or a PDFView, so a window with many files open costs only the cells on screen.
enum PageThumbnails {
    /// One size for both views, so a page has one cache entry; each view decodes it down to its own size.
    static let spec = PDFThumbnailer.Spec(pointWidth: 240, scale: 2)

    /// A cache of its own beside Copy Archive Link's, so scrolling the page views never queues a copied link's
    /// picture behind theirs or evicts it. The unit host's is in its temporary folder, so tests never touch the app's.
    static let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDirectory, diskBudgetBytes: 300 * 1024 * 1024)

    private static let cacheDirectory: URL = {
        guard !ArchiveTestHost.isUnitTestHost else {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "ArchiveReaderTests-PageThumbnails-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ArchiveReader", isDirectory: true)
            .appendingPathComponent("PageThumbnails", isDirectory: true)
    }()

    /// The image of PDF page `pageIndex` (0-based) at most `maxPixel` on its longer side, turned `turns`
    /// quarter turns clockwise (the reader's view-only turn, `PageTurnStore`). `nil` when the file or the page
    /// cannot be read. Read-only: the cache writes only its own folder.
    nonisolated static func image(path: String, pageIndex: Int, maxPixel: CGFloat, turns: Int = 0,
                                  thumbnailer: PDFThumbnailer = PageThumbnails.thumbnailer) async -> PageImage? {
        guard pageIndex >= 0, let mtime = modificationDate(path) else { return nil }
        guard let png = await thumbnailer.png(fileURL: URL(fileURLWithPath: path), page: pageIndex + 1, spec: spec,
                                              linkKey: "reader-page-views:" + path, mtime: mtime),
              !Task.isCancelled,
              let decoded = decode(png, maxPixel: maxPixel) else { return nil }
        return PageImage(cgImage: rotated(decoded, turns: turns))
    }

    /// The file's page count, read without opening a `PDFDocument` and without downloading a cloud placeholder.
    nonisolated static func pageCount(path: String) async -> Int? {
        CorpusWalker.withDatalessMaterializationDisabled {
            CGPDFDocument(URL(fileURLWithPath: path) as CFURL).map { $0.numberOfPages }
        }
    }

    /// What each page of the file is (`PDFPageRole`, one per page); nil when it cannot be read.
    nonisolated static func pageRoles(path: String) async -> [PDFPageRole]? {
        CorpusWalker.withDatalessMaterializationDisabled {
            CGPDFDocument(URL(fileURLWithPath: path) as CFURL).map { PDFPageRole.roles(of: $0) }
        }
    }

    /// `stat(2)`, not `URL.resourceValues`, which caches on a reused URL and would miss a re-OCR.
    nonisolated private static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    nonisolated private static func decode(_ png: Data, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel.rounded(.up))),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image turned `turns` quarter turns clockwise, into a new bitmap.
    nonisolated static func rotated(_ image: CGImage, turns: Int) -> CGImage {
        let quarter = ((turns % 4) + 4) % 4
        guard quarter != 0 else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let size = quarter == 2 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        // Quartz's y axis points up, so a positive angle turns anticlockwise.
        switch quarter {
        case 1: context.translateBy(x: 0, y: size.height); context.rotate(by: -.pi / 2)
        case 2: context.translateBy(x: size.width, y: size.height); context.rotate(by: .pi)
        default: context.translateBy(x: size.width, y: 0); context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}

/// A decoded page picture. `CGImage` is immutable, so handing one from the decoding task to the view is safe.
struct PageImage: @unchecked Sendable {
    let cgImage: CGImage
    var aspect: CGFloat { CGFloat(cgImage.width) / max(1, CGFloat(cgImage.height)) }
}

/// The page counts of the files open in one viewer, read lazily as their sections come into view. The current
/// file's count is set when it loads. Kept apart from the viewer model so a count landing redraws only the
/// page views, not the reading panes.
@MainActor
final class OpenFilePageCounts: ObservableObject {
    @Published private(set) var counts: [String: Int] = [:]
    /// Which page of each file is which (`DocumentPagePairs`), read with its count (W42.int-s5-searchable).
    @Published private(set) var layouts: [String: DocumentPagePairs] = [:]
    private var asked: Set<String> = []

    func count(_ path: String) -> Int? { counts[path] }

    /// The file's pairs; until it has been read, what its count (or its first page) says as pairs alone.
    func pairs(_ path: String) -> DocumentPagePairs {
        layouts[path] ?? DocumentPagePairs(pageCount: counts[path] ?? 1)
    }

    func set(_ count: Int, pairs: DocumentPagePairs? = nil, for path: String) {
        if counts[path] != count { counts[path] = count }
        if let pairs, layouts[path] != pairs { layouts[path] = pairs }
    }

    /// Keep only the files now open, so browsing many selections never grows the table.
    func retain(_ paths: [String]) {
        let keep = Set(paths)
        if counts.keys.contains(where: { !keep.contains($0) }) { counts = counts.filter { keep.contains($0.key) } }
        if layouts.keys.contains(where: { !keep.contains($0) }) { layouts = layouts.filter { keep.contains($0.key) } }
        asked.formIntersection(keep)
    }

    /// Reads the count once; a file that cannot be opened counts 0 pages.
    func request(_ path: String) async {
        guard counts[path] == nil, !asked.contains(path) else { return }
        asked.insert(path)
        let roles = await PageThumbnails.pageRoles(path: path)
        // A file the viewer let go of while its count was read stays out.
        if counts[path] == nil, asked.contains(path) {
            counts[path] = roles?.count ?? 0
            if let roles { layouts[path] = DocumentPagePairs(roles: roles) }
        }
    }
}

/// One page picture with its label, a selection outline, and a placeholder until the picture arrives.
/// Kept apart from the cell that fetches it so the headless render guards draw exactly what the views draw.
struct PageThumbnailLabel: View {
    let image: PageImage?
    let label: String
    let selected: Bool
    let finished: Bool
    let height: CGFloat
    /// Drawn dark, as the image pane is under Invert Image Colors (W40.reader-image-invert).
    var inverted = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(decorative: inverted ? DarkPageImages.darkened(image.cgImage) : image.cgImage, scale: 1)
                        .resizable().aspectRatio(image.aspect, contentMode: .fit)
                        .background(inverted ? Color(white: Double(DarkPageImages.darkest)) : Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                } else if finished {
                    Image(systemName: "doc.questionmark").font(.title2).foregroundStyle(.secondary)
                        .accessibilityLabel("Preview unavailable")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text(label).font(.caption).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// A page picture that fetches itself while on screen and lets go of its bitmap when it scrolls away.
struct PageThumbnailCell: View {
    let path: String
    let pageIndex: Int
    let turns: Int
    let label: String
    let selected: Bool
    let height: CGFloat
    let maxPixel: CGFloat
    var inverted = false
    let identifier: String
    let accessibilityLabel: String
    let open: () -> Void
    @State private var image: PageImage?
    @State private var finished = false

    var body: some View {
        Button(action: open) {
            PageThumbnailLabel(image: image, label: label, selected: selected, finished: finished, height: height,
                               inverted: inverted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selected ? "current" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(identifier)
        .task(id: "\(path)#\(pageIndex)#\(turns)") {
            // A cell is reused by position when the files change, so the last file's picture must not linger.
            image = nil
            finished = false
            let fetched = await PageThumbnails.image(path: path, pageIndex: pageIndex, maxPixel: maxPixel, turns: turns)
            guard !Task.isCancelled else { return }
            image = fetched
            finished = true
        }
        .onDisappear { image = nil; finished = false }
    }
}

/// The heading of one open file in the page views, marked while it is the file on view.
struct OpenFileHeader: View {
    let name: String
    let position: String
    let current: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: current ? "eye.fill" : "doc").foregroundStyle(current ? Color.accentColor : .secondary)
                .font(.caption)
            Text(name).font(.caption.weight(current ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Text(position).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(current ? Color.accentColor.opacity(0.15) : Color(nsColor: .windowBackgroundColor).opacity(0.95))
        .accessibilityElement(children: .combine)
        .accessibilityValue(current ? "on view" : "")
    }
}
