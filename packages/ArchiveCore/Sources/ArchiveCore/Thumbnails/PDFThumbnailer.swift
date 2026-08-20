// PDFThumbnailer.swift — actor: render PDF page -> PNG Data + disk LRU cache
import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Renders PDF pages to PNG thumbnails with a two-tier cache (disk + caller-side in-memory).
///
/// Returns `Data` (PNG), never `NSImage`, so the boundary is Sendable-safe for Swift 6.
/// The caller (typically `@MainActor`) decodes to `NSImage` on its side.
public actor PDFThumbnailer {

    /// Render specification for a thumbnail.
    public struct Spec: Sendable, Hashable {
        public var pointWidth: CGFloat
        public var scale: CGFloat

        public init(pointWidth: CGFloat = 220, scale: CGFloat = 2) {
            self.pointWidth = pointWidth
            self.scale = scale
        }
    }

    private let cacheDirectory: URL
    private let diskBudgetBytes: Int
    private var index: [String: CacheEntry] = [:]  // filename -> entry
    private var totalBytes: Int = 0
    private var indexLoaded = false

    public init(cacheDirectory: URL, diskBudgetBytes: Int = 500 * 1024 * 1024) {
        self.cacheDirectory = cacheDirectory
        self.diskBudgetBytes = diskBudgetBytes
    }

    /// Render (or fetch cached) a PNG for `page` (1-based) of the PDF at `fileURL`.
    ///
    /// - Parameters:
    ///   - fileURL: Path to the source PDF.
    ///   - page: 1-based page number.
    ///   - spec: Render dimensions.
    ///   - linkKey: Canonical `archivereader://` URL string (part of the cache key).
    ///   - mtime: Source file's content-modification date.
    /// - Returns: PNG data, or `nil` if the page can't be rendered (degrade).
    public func png(
        fileURL: URL,
        page: Int,
        spec: Spec = Spec(),
        linkKey: String,
        mtime: Date
    ) async -> Data? {
        ensureIndexLoaded()

        let cacheFilename = ThumbnailCacheKey.filename(
            linkKey: linkKey, page: page, mtime: mtime,
            pointWidth: spec.pointWidth, scale: spec.scale
        )
        let cacheFileURL = cacheDirectory.appendingPathComponent(cacheFilename)

        // Disk cache hit
        if let entry = index[cacheFilename],
           FileManager.default.fileExists(atPath: cacheFileURL.path),
           let data = try? Data(contentsOf: cacheFileURL) {
            // Touch last-access for LRU
            var updated = entry
            updated.lastAccess = Date()
            index[cacheFilename] = updated
            return data
        }

        // Render
        guard let data = renderPage(fileURL: fileURL, page: page, spec: spec) else {
            return nil
        }

        // Write to disk cache
        writeToDisk(data: data, filename: cacheFilename, fileURL: cacheFileURL)

        return data
    }

    // MARK: - Rendering

    /// Renders a single page to PNG data. Pure computation, no disk I/O.
    private func renderPage(fileURL: URL, page: Int, spec: Spec) -> Data? {
        guard page >= 1,
              let doc = PDFDocument(url: fileURL),
              let sourcePage = doc.page(at: page - 1) else {
            return nil
        }

        let mediaBox = sourcePage.bounds(for: .cropBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }

        let aspect = mediaBox.height / mediaBox.width
        let pxWidth = spec.pointWidth * spec.scale
        let pxHeight = pxWidth * aspect
        let width = Int(pxWidth.rounded(.up))
        let height = Int(pxHeight.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }

        // Both the raw bitmap context and PDF page use Quartz's bottom-left coordinate system. Draw
        // directly into a private bitmap: neither the source PDF nor its PDFPage is modified.
        let scale = CGFloat(width) / mediaBox.width
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -mediaBox.minX, y: -mediaBox.minY)
        sourcePage.draw(with: .cropBox, to: context)

        guard let image = context.makeImage() else { return nil }
        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            pngData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return pngData as Data
    }

    // MARK: - Disk cache management

    private func writeToDisk(data: Data, filename: String, fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            let entry = CacheEntry(
                filename: filename,
                bytes: data.count,
                lastAccess: Date()
            )
            index[filename] = entry
            totalBytes += data.count
            evictIfNeeded()
        } catch {
            // Cache write failure is non-fatal; the thumbnail was still returned.
        }
    }

    private func evictIfNeeded() {
        guard totalBytes > diskBudgetBytes else { return }

        // Sort by lastAccess ascending (oldest first)
        let sorted = index.values.sorted { $0.lastAccess < $1.lastAccess }
        for entry in sorted {
            guard totalBytes > diskBudgetBytes else { break }
            let url = cacheDirectory.appendingPathComponent(entry.filename)
            try? FileManager.default.removeItem(at: url)
            totalBytes -= entry.bytes
            index.removeValue(forKey: entry.filename)
        }
    }

    private func ensureIndexLoaded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        loadIndexFromDisk()
    }

    private func loadIndexFromDisk() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return }

        totalBytes = 0
        index.removeAll()

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "png" else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
            let bytes = values?.fileSize ?? 0
            let access = values?.contentAccessDate ?? Date.distantPast
            let filename = url.lastPathComponent
            index[filename] = CacheEntry(
                filename: filename,
                bytes: bytes,
                lastAccess: access
            )
            totalBytes += bytes
        }
    }
}

// MARK: - Cache index entry

extension PDFThumbnailer {
    struct CacheEntry: Sendable {
        var filename: String
        var bytes: Int
        var lastAccess: Date
    }
}
