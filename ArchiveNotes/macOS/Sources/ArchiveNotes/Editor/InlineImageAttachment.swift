import AppKit

/// Protocol abstracting asset storage for the editor. The editor calls `addAsset` to persist
/// pasted/dragged images and `resolveAsset` to load thumbnails from relative paths.
/// In production, backed by `NoteStore`; in tests, by a scratch-temp implementation.
@MainActor
protocol EditorAssetStore: AnyObject {
    /// Write `data` into the item's assets folder; returns the `assets/…` relative path.
    func addAsset(_ data: Data, preferredName: String) throws -> String
    /// Resolve a relative asset path (e.g. `assets/photo.png`) to an absolute file URL, or nil.
    func resolveAsset(_ relativePath: String) -> URL?
}

// MARK: - Inline image attachment

/// `NSTextAttachment` subclass carrying a downsampled thumbnail and the `assets/…` relative path.
/// The rel-path is preserved even if the thumbnail can't load (missing-asset placeholder), so
/// re-serializing never loses the reference.
final class InlineImageAttachment: NSTextAttachment {

    /// The `assets/…` relative path stored on disk.
    let relativePath: String

    /// Alt text for the Markdown `![alt](path)` syntax.
    let altText: String

    init(relativePath: String, altText: String = "", thumbnail: NSImage? = nil) {
        self.relativePath = relativePath
        self.altText = altText
        super.init(data: nil, ofType: nil)
        if let thumbnail {
            self.image = thumbnail
            let size = constrainedSize(thumbnail.size)
            self.bounds = CGRect(origin: .zero, size: size)
        } else {
            // Missing-asset placeholder
            self.image = Self.placeholderImage
            self.bounds = CGRect(origin: .zero, size: CGSize(width: 64, height: 64))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not supported") }

    /// Constrain thumbnail to a max display size while preserving aspect ratio.
    private func constrainedSize(_ original: NSSize) -> NSSize {
        let maxWidth: CGFloat = 400
        let maxHeight: CGFloat = 300
        guard original.width > 0, original.height > 0 else {
            return CGSize(width: 64, height: 64)
        }
        let wRatio = min(maxWidth / original.width, 1.0)
        let hRatio = min(maxHeight / original.height, 1.0)
        let ratio = min(wRatio, hRatio)
        return CGSize(width: original.width * ratio, height: original.height * ratio)
    }

    private static let placeholderImage: NSImage = {
        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = "Missing" as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                              y: (size.height - textSize.height) / 2),
                  withAttributes: attrs)
        img.unlockFocus()
        return img
    }()
}

// MARK: - Thumbnail generation + cache

extension InlineImageAttachment {

    /// Bounded cache of decoded thumbnails keyed by asset relative path.
    /// Evictable by the system; re-decoded on demand. Full-resolution PNGs are never
    /// loaded into the editor — only downsampled thumbnails.
    /// `nonisolated(unsafe)` — NSCache is thread-safe by design; the static let is
    /// initialized once and the cache handles its own synchronization.
    nonisolated(unsafe) static let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024  // ~50 MB
        return cache
    }()

    /// Create a downsampled thumbnail from raw image data.
    /// Returns nil if the data isn't a recognized image format.
    static func downsampledThumbnail(from data: Data, maxPixels: Int = 800) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Load a thumbnail from a file URL, using the cache keyed by `cacheKey`.
    /// If `cacheKey` is provided and a cached thumbnail exists, returns it without disk I/O.
    static func loadThumbnail(from url: URL, maxPixels: Int = 800,
                              cacheKey: String? = nil) -> NSImage? {
        if let key = cacheKey {
            let nsKey = key as NSString
            if let cached = thumbnailCache.object(forKey: nsKey) {
                return cached
            }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let thumb = downsampledThumbnail(from: data, maxPixels: maxPixels) else { return nil }
        if let key = cacheKey {
            let cost = Int(thumb.size.width * thumb.size.height * 4)
            thumbnailCache.setObject(thumb, forKey: key as NSString, cost: cost)
        }
        return thumb
    }
}

// MARK: - Scratch asset store for tests

/// A temporary-directory-backed asset store for unit tests and GUI testing.
/// Writes land under `mktemp`, never the real store or corpus.
@MainActor
final class ScratchAssetStore: EditorAssetStore {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("an-scratch-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            self.root = tmp
        }
    }

    func addAsset(_ data: Data, preferredName: String) throws -> String {
        let assetsDir = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        var target = assetsDir.appendingPathComponent(preferredName)
        if FileManager.default.fileExists(atPath: target.path) {
            let stem = (preferredName as NSString).deletingPathExtension
            let ext = (preferredName as NSString).pathExtension
            var n = 1
            repeat {
                let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                target = assetsDir.appendingPathComponent(name)
                n += 1
            } while FileManager.default.fileExists(atPath: target.path)
        }

        try data.write(to: target, options: [.atomic])
        return "assets/\(target.lastPathComponent)"
    }

    func resolveAsset(_ relativePath: String) -> URL? {
        let url = root.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
