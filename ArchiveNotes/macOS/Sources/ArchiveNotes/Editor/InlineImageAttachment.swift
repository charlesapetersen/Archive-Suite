import AppKit

/// Protocol abstracting asset storage for the editor. The editor calls `addAsset` to persist
/// pasted/dragged images and `resolve` to load thumbnails from relative paths.
/// In production, backed by `NoteStore`; in tests, by a scratch-temp implementation.
@MainActor
protocol EditorAssetStore: AnyObject {
    /// Write `data` into the item's assets folder; returns the `assets/…` relative path.
    func addAsset(_ data: Data, preferredName: String) throws -> String
    /// Resolve a Markdown asset reference (e.g. `assets/photo.png`) **contained** to the item's own
    /// `assets/` directory — see `AssetPathResolver`. The reference is untrusted (a note body is a
    /// hand-editable file), so an escape must come back as `.outOfBounds`, never as a URL (W23.m3).
    func resolve(_ relativePath: String) -> AssetResolution
}

extension EditorAssetStore {
    /// Convenience for callers that only want a readable URL: a `missing` **or** refused reference is
    /// nil. On the passage/extract path that means no bytes are embedded — the Markdown reference still
    /// survives, so nothing is silently rewritten.
    func resolveAsset(_ relativePath: String) -> URL? {
        if case .resolved(let url) = resolve(relativePath) { return url }
        return nil
    }
}

// MARK: - Inline image attachment

/// `NSTextAttachment` subclass carrying a downsampled thumbnail and the `assets/…` relative path.
/// The rel-path is preserved even if the thumbnail can't load (missing-asset placeholder), so
/// re-serializing never loses the reference.
final class InlineImageAttachment: NSTextAttachment {

    /// Why no thumbnail is shown. The two cases look different on screen so the operator can tell a
    /// dangling reference from one the read seam **refused** (W23.m3) — a refusal is a data-provenance
    /// signal, not a missing file.
    enum Placeholder: Equatable {
        /// Nothing readable at an in-bounds `assets/…` path (dangling ref, or a write still in flight).
        case missing
        /// The reference points outside this item's `assets/` — never opened, never read.
        case outOfBounds
    }

    /// The `assets/…` relative path stored on disk.
    let relativePath: String

    /// Alt text for the Markdown `![alt](path)` syntax.
    let altText: String

    /// Which placeholder is being shown, or nil when a real thumbnail loaded.
    let placeholder: Placeholder?

    init(relativePath: String, altText: String = "", thumbnail: NSImage? = nil,
         placeholder: Placeholder = .missing) {
        self.relativePath = relativePath
        self.altText = altText
        self.placeholder = thumbnail == nil ? placeholder : nil
        super.init(data: nil, ofType: nil)
        if let thumbnail {
            self.image = thumbnail
            let size = constrainedSize(thumbnail.size)
            self.bounds = CGRect(origin: .zero, size: size)
        } else {
            self.image = Self.placeholderImage(placeholder)
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

    private static func placeholderImage(_ kind: Placeholder) -> NSImage {
        switch kind {
        case .missing: return missingImage
        case .outOfBounds: return outOfBoundsImage
        }
    }

    private static let missingImage = makePlaceholderImage(labelled: "Missing")
    private static let outOfBoundsImage = makePlaceholderImage(labelled: "Blocked")

    private static func makePlaceholderImage(labelled label: String) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = label as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (size.width - textSize.width) / 2,
                              y: (size.height - textSize.height) / 2),
                  withAttributes: attrs)
        img.unlockFocus()
        return img
    }
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

    /// Contained to `<root>/assets/` — the scratch store stands in for one item's directory, so it
    /// enforces the same read-seam boundary the production store does (W23.m3).
    func resolve(_ relativePath: String) -> AssetResolution {
        AssetPathResolver.resolve(relativePath, inItemDirectory: root)
    }
}

// MARK: - Item-scoped asset store (W7-S5)

/// Error surfaced when the editor tries to persist an asset with no item selected.
enum ItemAssetStoreError: Error, Sendable { case noTargetItem }

/// The production `EditorAssetStore`: persists pasted / dropped images into the *currently-selected*
/// item's `assets/` folder through the audited async `NoteStore`, keyed to `itemID` (retargeted by
/// `NoteEditorPane` on selection change).
///
/// **The sync↔async bridge (the crux of W7-S5).** `EditorAssetStore.addAsset` is *synchronous*
/// (`throws -> String`) because the editor needs the `assets/<name>` reference *immediately* to build the
/// inline-image attachment + markdown, but `NoteStore` is an `actor` (async) and the image bytes may be
/// large. So `addAsset`:
///   1. computes a **unique** filename synchronously (matching `NoteStore.disambiguateAsset`'s
///      `stem-1`, `stem-2`… scheme, against both on-disk files *and* an in-flight `reserved` set),
///      returning `assets/<name>` at once;
///   2. persists the bytes on a background `Task` via `NoteStore.writeReservedAsset` (off the main
///      thread — no UI stall on a big paste).
/// Because this @MainActor store is the *single arbiter* of names (every paste for the item flows through
/// it, serialized on the main actor) and the actor writes to the *exact* reserved name (never
/// re-disambiguating), the reference handed to the editor always matches the file that lands on disk —
/// even for rapid same-named pastes. A failed write leaves a dangling reference (a missing-asset
/// placeholder), never corrupt or clobbered bytes.
@MainActor
final class ItemAssetStore: EditorAssetStore {
    private let store: NoteStore
    private let root: URL

    /// The item whose `assets/` receives pastes. `NoteEditorPane` retargets it on selection change.
    var itemID: UUID?

    /// Names handed to the editor this session whose bytes may not be on disk yet (write in flight), per
    /// item. Closes the window in which a second same-name paste could pick the same name before the
    /// first `Task`'s write lands. Bounded by pastes-per-session (trivially small).
    private var reserved: [UUID: Set<String>] = [:]

    /// In-flight byte-write tasks, so `awaitPendingWrites()` can flush them (tests; future quit-flush).
    private var pendingWrites: [Task<Void, Never>] = []

    init(store: NoteStore, root: URL, itemID: UUID? = nil) {
        self.store = store
        self.root = root
        self.itemID = itemID
    }

    func addAsset(_ data: Data, preferredName: String) throws -> String {
        guard let id = itemID else { throw ItemAssetStoreError.noTargetItem }
        let dir = NoteStore.assetsDir(root: root, id: id)
        let name = uniqueName(preferredName, in: dir, itemID: id)
        reserved[id, default: []].insert(name)

        // Persist the bytes off-main through the audited actor, at exactly the reserved name. A failed
        // write leaves a dangling reference (missing-asset placeholder) — never corrupt/clobbered bytes.
        let task = Task.detached(priority: .utility) { [store] in
            do { try await store.writeReservedAsset(data, name: name, into: id) }
            catch { NSLog("ItemAssetStore: asset write failed for %@: %@", name, "\(error)") }
        }
        pendingWrites.append(task)
        return "assets/\(name)"
    }

    /// Contained to the *targeted* item's own `assets/` (W23.m3): a note body is a hand-editable file,
    /// so `![](../OTHER_UUID/assets/x.png)` must not resolve — it would render, and let copy/extract
    /// snapshot, another item's bytes. With no target item there is no boundary to check against, so
    /// nothing resolves.
    func resolve(_ relativePath: String) -> AssetResolution {
        guard let id = itemID else { return .missing }
        return AssetPathResolver.resolve(relativePath,
                                         inItemDirectory: NoteStore.itemDir(root: root, id: id))
    }

    /// Await all in-flight asset byte-writes (used by tests; a natural flush seam for a future
    /// window-close / quit save, W7-S6).
    func awaitPendingWrites() async {
        let tasks = pendingWrites
        pendingWrites.removeAll()
        for t in tasks { await t.value }
    }

    /// Pick a filename not taken on disk or by an in-flight write, matching `NoteStore.disambiguateAsset`
    /// (`stem-1`, `stem-2`, …) so the actor write and this pre-commit never diverge.
    private func uniqueName(_ preferred: String, in dir: URL, itemID id: UUID) -> String {
        let fm = FileManager.default
        let inFlight = reserved[id] ?? []
        func taken(_ n: String) -> Bool {
            inFlight.contains(n) || fm.fileExists(atPath: dir.appendingPathComponent(n).path)
        }
        if !taken(preferred) { return preferred }
        let ns = preferred as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}
