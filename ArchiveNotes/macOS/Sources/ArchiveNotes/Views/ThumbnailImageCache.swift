import AppKit

/// In-memory NSCache for decoded thumbnail NSImages, keyed by asset-relative path.
/// NSCache auto-evicts under memory pressure; countLimit/totalCostLimit bound the hot set.
@MainActor
final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()

    private let cache = NSCache<NSString, NSImage>()

    init(countLimit: Int = 300, costLimitMB: Int = 64) {
        cache.countLimit = countLimit
        cache.totalCostLimit = costLimitMB * 1024 * 1024
    }

    func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: NSImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * 4) // approx RGBA bytes
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
