import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

/// W23.m11 — the app-wide inline-image thumbnail cache must be keyed by **the file whose bytes were
/// read**, not by the markdown reference that named it. Scratch stores only (temp dirs; never the real
/// Notes store or the archival corpus).
///
/// The defect these cover: `thumbnailCache` is `static`, so it spans every note in the app, and it was
/// keyed on the caller-supplied relative path — normally `assets/<name>`. Two notes each owning their
/// own `assets/x.png` is ordinary and explicitly supported by the store, so rendering note A cached A's
/// thumbnail under `assets/x.png` and rendering note B **displayed A's image without ever opening B's
/// file**. No malformed data required.
///
/// Every test here is written to be non-vacuous: each one first establishes that the *old* rule really
/// would have collided (the two files exist, differ, and share a relative path; a sentinel planted under
/// the old key is a live hit), so a passing assertion documents the hole it closes rather than merely
/// agreeing with the current code.
/// **W23.m11-fu** adds the second half of that identity: the *version* of the bytes at that file.
/// The cache never expired, which is right for every in-app writer (an asset path is write-once
/// here) and wrong for a store root in a synced folder, where an outside rewrite left the previous
/// thumbnail on screen until eviction or relaunch.
@Suite("Inline-image thumbnail cache identity (W23.m11 · m11-fu)")
@MainActor
struct InlineImageCacheKeyTests {

    // MARK: - Fixture

    /// A `NoteStore`-shaped scratch root with two items, each able to hold its own `assets/<name>`.
    /// Item directories are UUID-named, so no two runs (or two tests) can share a canonical path — which
    /// matters here because the cache under test is process-wide.
    @MainActor
    private struct TwoItemStore {
        let root: URL
        let store: NoteStore
        let itemA: UUID
        let itemB: UUID

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("InlineImageCacheKey-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            store = NoteStore(root: root)
            itemA = UUID()
            itemB = UUID()
            for id in [itemA, itemB] {
                try fm.createDirectory(at: NoteStore.assetsDir(root: root, id: id),
                                       withIntermediateDirectories: true)
            }
        }

        func assetURL(_ name: String, in id: UUID) -> URL {
            NoteStore.assetsDir(root: root, id: id).appendingPathComponent(name)
        }

        func write(_ bytes: Data, named name: String, into id: UUID) throws {
            try bytes.write(to: assetURL(name, in: id))
        }

        func assetStore(for id: UUID) -> ItemAssetStore {
            ItemAssetStore(store: store, root: root, itemID: id)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// A solid-colour PNG of a given size, so a decoded thumbnail can be identified by its own pixels.
    private func solidPNG(_ color: NSColor, side: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Dominant channel of a decoded thumbnail: `"R"`, `"G"`, `"B"`, or nil. Compared by dominance
    /// rather than exact RGB so colour management can't make the assertion flaky.
    private func dominantChannel(of image: NSImage?) -> String? {
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0,
              let raw = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2),
              let c = raw.usingColorSpace(.deviceRGB)
        else { return nil }
        let channels = [("R", c.redComponent), ("G", c.greenComponent), ("B", c.blueComponent)]
        guard let top = channels.max(by: { $0.1 < $1.1 }) else { return nil }
        let others = channels.filter { $0.0 != top.0 }.map(\.1)
        // Require a real separation, so a grey/blank image reads as "no dominant channel" instead of
        // silently satisfying whichever colour a test happened to expect.
        guard top.1 > 0.6, others.allSatisfy({ $0 < top.1 - 0.3 }) else { return nil }
        return top.0
    }

    private func attachments(in styled: NSAttributedString) -> [InlineImageAttachment] {
        var found: [InlineImageAttachment] = []
        styled.enumerateAttribute(.attachment,
                                  in: NSRange(location: 0, length: styled.length)) { value, _, _ in
            if let attachment = value as? InlineImageAttachment { found.append(attachment) }
        }
        return found
    }

    private func renderedImage(_ markdown: String, _ store: EditorAssetStore) -> NSImage? {
        let styled = MarkdownBridge.parse(markdown: markdown, assetStore: store)
        return attachments(in: styled).first?.image
    }

    // MARK: - The headline defect

    @Test("Two notes owning different same-named assets each render their own image")
    func sameNamedAssetsInTwoItemsDoNotCollide() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        // A unique-per-test asset name: the cache is process-wide, so a fixed name could be seeded by
        // a sibling test and make this pass (or fail) for the wrong reason.
        let name = "shared-\(UUID().uuidString).png"
        let reference = "assets/\(name)"
        let redBytes = try solidPNG(.red, side: 24)
        let blueBytes = try solidPNG(.blue, side: 40)
        try fx.write(redBytes, named: name, into: fx.itemA)
        try fx.write(blueBytes, named: name, into: fx.itemB)

        // Non-vacuity: the collision the old key produced is genuinely available here — one relative
        // path, two different files, both present, with different bytes.
        #expect(redBytes != blueBytes)
        #expect(FileManager.default.fileExists(atPath: fx.assetURL(name, in: fx.itemA).path))
        #expect(FileManager.default.fileExists(atPath: fx.assetURL(name, in: fx.itemB).path))
        #expect(fx.assetURL(name, in: fx.itemA) != fx.assetURL(name, in: fx.itemB))

        // Render A first, so the cache is warm under whatever key the code chooses …
        let aImage = renderedImage("![](\(reference))", fx.assetStore(for: fx.itemA))
        #expect(dominantChannel(of: aImage) == "R", "note A must show its own red asset")

        // … then B. Under the old relative-path key this returned A's cached red thumbnail.
        let bImage = renderedImage("![](\(reference))", fx.assetStore(for: fx.itemB))
        #expect(dominantChannel(of: bImage) == "B",
                "note B must show ITS OWN blue asset, not note A's cached red one")
        #expect(aImage !== bImage, "the two notes must not be served one shared cache entry")

        // And re-rendering A afterwards is still A — B's render did not evict or overwrite it.
        #expect(dominantChannel(of: renderedImage("![](\(reference))", fx.assetStore(for: fx.itemA)))
                == "R")
    }

    // MARK: - The key itself

    @Test("A thumbnail is cached under the resolved canonical path, not the markdown reference")
    func entryLandsUnderTheCanonicalPathKey() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "keyed-\(UUID().uuidString).png"
        let reference = "assets/\(name)"
        try fx.write(try solidPNG(.red, side: 24), named: name, into: fx.itemA)

        // The key must be the one derived from the URL the *resolver* hands the renderer — which is
        // canonical (symlinks resolved), so it need not equal a raw `assetsDir/<name>` spelling of the
        // same file. Asserting against the resolver's own output is what pins the production contract.
        guard case .resolved(let canonical) = fx.assetStore(for: fx.itemA).resolve(reference) else {
            Issue.record("the item's own asset must resolve")
            return
        }
        let canonicalKey = try #require(InlineImageAttachment.cacheKey(for: canonical, maxPixels: 800))

        // Nothing is cached under either key before the render (guards against a stale sibling entry).
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: canonicalKey as NSString) == nil)
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: reference as NSString) == nil)

        #expect(renderedImage("![](\(reference))", fx.assetStore(for: fx.itemA)) != nil)

        #expect(InlineImageAttachment.thumbnailCache.object(forKey: canonicalKey as NSString) != nil,
                "the entry must be keyed by the file that was actually read")
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: reference as NSString) == nil,
                "the markdown reference must no longer be a cache key at all")
        // The key names the item that owns the bytes — that is what makes a cross-item collision
        // impossible rather than merely unlikely, and it is why the key needs no separate item UUID
        // bolted on. (`NoteStore.itemDir` spells the UUID lowercased.)
        #expect(canonicalKey.contains(fx.itemA.uuidString.lowercased()))
        #expect(!canonicalKey.contains(fx.itemB.uuidString.lowercased()))
        #expect(canonicalKey.hasSuffix("/assets/\(name)"))
    }

    @Test("A thumbnail planted under the OLD relative-path key is never served")
    func theOldReferenceShapedKeyNoLongerHits() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "sentinel-\(UUID().uuidString).png"
        let reference = "assets/\(name)"
        try fx.write(try solidPNG(.blue, side: 40), named: name, into: fx.itemA)

        // Plant a red sentinel under exactly the key the pre-fix code used.
        let sentinel = try #require(InlineImageAttachment.downsampledThumbnail(
            from: try solidPNG(.red, side: 24)))
        InlineImageAttachment.thumbnailCache.setObject(sentinel, forKey: reference as NSString)
        defer { InlineImageAttachment.thumbnailCache.removeObject(forKey: reference as NSString) }
        // Non-vacuity: the sentinel is a live, retrievable, red hit under the old key right now.
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: reference as NSString) === sentinel)
        #expect(dominantChannel(of: sentinel) == "R")

        let rendered = renderedImage("![](\(reference))", fx.assetStore(for: fx.itemA))
        #expect(rendered !== sentinel, "the reference-keyed entry must not be consulted")
        #expect(dominantChannel(of: rendered) == "B", "the item's own blue bytes must be decoded")
        // The foreign entry is left exactly as it was — the new key writes elsewhere.
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: reference as NSString) === sentinel)
    }

    @Test("Different thumbnail sizes of one file do not alias onto each other")
    func maxPixelsIsPartOfTheKey() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "sized-\(UUID().uuidString).png"
        try fx.write(try solidPNG(.red, side: 200), named: name, into: fx.itemA)
        let url = fx.assetURL(name, in: fx.itemA)

        let small = try #require(InlineImageAttachment.loadThumbnail(from: url, maxPixels: 32))
        let large = try #require(InlineImageAttachment.loadThumbnail(from: url, maxPixels: 128))
        #expect(small.size.width <= 32)
        #expect(large.size.width > 32, "the 128px request must not be served the 32px entry")
        let key32 = try #require(InlineImageAttachment.cacheKey(for: url, maxPixels: 32))
        let key128 = try #require(InlineImageAttachment.cacheKey(for: url, maxPixels: 128))
        #expect(key32 != key128)
    }

    // MARK: - Properties the fix must not break

    @Test("A repeat render of the same asset is still a cache hit (no content read)")
    func repeatRenderStillHitsTheCache() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "warm-\(UUID().uuidString).png"
        let reference = "assets/\(name)"
        try fx.write(try solidPNG(.red, side: 24), named: name, into: fx.itemA)
        let assetStore = fx.assetStore(for: fx.itemA)
        let url = fx.assetURL(name, in: fx.itemA)

        // W23.m11-fu: the key now carries the file's size + modification time, so "unchanged file"
        // has to be arranged rather than assumed. A whole-second timestamp is restorable *exactly*
        // (`st_mtimespec` comes back as {sec, 0}), which is what keeps this deterministic.
        let pinned = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: url.path)

        let first = try #require(renderedImage("![](\(reference))", assetStore))
        let second = try #require(renderedImage("![](\(reference))", assetStore))
        #expect(first === second, "the second render must reuse the decoded thumbnail, not re-decode")

        // Prove that really was a cache hit and not a cheap re-read: swap the bytes for garbage of the
        // SAME length and put the timestamp back, so the file's identity is untouched and only its
        // *contents* differ. Anything that reads them now cannot produce `first`.
        let bytes = try Data(contentsOf: url)
        try Data(repeating: 0x00, count: bytes.count).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: pinned], ofItemAtPath: url.path)
        let third = renderedImage("![](\(reference))", assetStore)
        #expect(third === first, "a warm entry must be served without reading the file's bytes again")
        try bytes.write(to: url)
    }

    @Test("Two references to one shared file share a single entry — same bytes, one thumbnail")
    func aliasesOfOneFileShareTheEntry() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let realName = "real-\(UUID().uuidString).png"
        let linkName = "alias-\(UUID().uuidString).png"
        try fx.write(try solidPNG(.red, side: 24), named: realName, into: fx.itemA)
        // A symlink *inside* the item's own assets/ — in bounds, and canonically the same file.
        try FileManager.default.createSymbolicLink(at: fx.assetURL(linkName, in: fx.itemA),
                                                   withDestinationURL: fx.assetURL(realName, in: fx.itemA))
        let assetStore = fx.assetStore(for: fx.itemA)

        let viaReal = try #require(renderedImage("![](assets/\(realName))", assetStore))
        let viaLink = try #require(renderedImage("![](assets/\(linkName))", assetStore))
        // Correct, not a collision: the key is the identity of the *bytes*, and these are one file.
        #expect(viaReal === viaLink)
        #expect(dominantChannel(of: viaLink) == "R")
    }

    @Test("A missing or refused reference caches nothing")
    func unreadableReferencesCacheNothing() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "private-\(UUID().uuidString).png"
        try fx.write(try solidPNG(.blue, side: 40), named: name, into: fx.itemB)
        let escape = "../\(fx.itemB.uuidString)/assets/\(name)"
        let missing = "assets/gone-\(UUID().uuidString).png"
        let assetStore = fx.assetStore(for: fx.itemA)

        // The canonical key item B's own bytes WOULD occupy — via B's store, so this is the exact key
        // a later legitimate render of B would use, not an approximation of it.
        guard case .resolved(let bCanonical) =
                fx.assetStore(for: fx.itemB).resolve("assets/\(name)") else {
            Issue.record("item B's own asset must resolve")
            return
        }
        let bKey = try #require(InlineImageAttachment.cacheKey(for: bCanonical, maxPixels: 800))

        #expect(renderedImage("![](\(escape))", assetStore) != nil)   // the "Blocked" placeholder
        #expect(renderedImage("![](\(missing))", assetStore) != nil)  // the "Missing" placeholder

        // Neither the reference nor the file it pointed at may have left an entry behind: a refusal
        // that warmed the cache would hand item B's bytes to the next reader of that path.
        for key in [escape, missing, bKey] {
            #expect(InlineImageAttachment.thumbnailCache.object(forKey: key as NSString) == nil)
        }
    }

    @Test("An explicit uncached load neither reads nor writes the cache")
    func uncachedLoadBypassesTheCacheEntirely() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "bypass-\(UUID().uuidString).png"
        try fx.write(try solidPNG(.red, side: 24), named: name, into: fx.itemA)
        let url = fx.assetURL(name, in: fx.itemA)
        let key = try #require(InlineImageAttachment.cacheKey(for: url, maxPixels: 800)) as NSString

        #expect(InlineImageAttachment.loadThumbnail(from: url, cached: false) != nil)
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: key) == nil,
                "an uncached load must not populate the shared cache")

        let warm = try #require(InlineImageAttachment.loadThumbnail(from: url))
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: key) === warm)
        let fresh = try #require(InlineImageAttachment.loadThumbnail(from: url, cached: false))
        #expect(fresh !== warm, "an uncached load must decode rather than return the warm entry")
    }

    // MARK: - Freshness: bytes replaced from outside the app (W23.m11-fu)
    //
    // m11 made the key name the right *file*; these pin that it also names the right *bytes*. An asset
    // path is write-once to this app, so nothing in-app can reach these paths — but the store root can
    // live in a synced folder, and a sync client is not bound by that. Each test below first shows the
    // stale entry is still sitting in the cache, so what it proves is that the key walks past it, not
    // that something evicted it.

    /// A whole-second timestamp, so `setAttributes` round-trips it into `st_mtimespec` exactly
    /// (`{sec, 0}`) and a test can make two files' modification times *identical by construction*
    /// rather than by hoping the clock cooperated.
    private func pinModificationTime(_ url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    private var epochA: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    private var epochB: Date { Date(timeIntervalSince1970: 1_700_000_060) }

    @Test("An asset replaced outside the app renders its NEW bytes, not the warm thumbnail")
    func anExternallyReplacedAssetRendersItsNewBytes() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "synced-\(UUID().uuidString).png"
        let reference = "assets/\(name)"
        let url = fx.assetURL(name, in: fx.itemA)
        let assetStore = fx.assetStore(for: fx.itemA)

        try fx.write(try solidPNG(.red, side: 24), named: name, into: fx.itemA)
        try pinModificationTime(url, to: epochA)
        let before = try #require(renderedImage("![](\(reference))", assetStore))
        #expect(dominantChannel(of: before) == "R")
        let staleKey = try #require(InlineImageAttachment.cacheKey(for: url, maxPixels: 800)) as NSString
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: staleKey) === before)

        // The sync client's write: same path, different bytes, and a timestamp it did not consult us
        // about. Nothing in the app is involved, so nothing in the app gets a chance to invalidate.
        try solidPNG(.blue, side: 40).write(to: url)
        try pinModificationTime(url, to: epochB)

        let after = renderedImage("![](\(reference))", assetStore)
        #expect(dominantChannel(of: after) == "B",
                "the editor must show the bytes now on disk, not the thumbnail it decoded earlier")
        #expect(after !== before)

        // Non-vacuity: the old thumbnail is still a live, retrievable entry — the fix is that its key
        // no longer describes this file, not that anything purged it. Pre-fix, the key was the path
        // alone, so this same entry is exactly what the render above would have been handed.
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: staleKey) === before,
                "the stale entry must be keyed past, not evicted")
    }

    @Test("The replacement's thumbnail is filed under the new identity, so it caches too")
    func theReplacementIsFiledUnderItsOwnIdentity() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "refiled-\(UUID().uuidString).png"
        let reference = "assets/\(name)"
        let url = fx.assetURL(name, in: fx.itemA)
        let assetStore = fx.assetStore(for: fx.itemA)

        try fx.write(try solidPNG(.red, side: 24), named: name, into: fx.itemA)
        try pinModificationTime(url, to: epochA)
        #expect(renderedImage("![](\(reference))", assetStore) != nil)

        try solidPNG(.blue, side: 40).write(to: url)
        try pinModificationTime(url, to: epochB)

        // Keying past a stale entry must not mean "stop caching this file": the second render of the
        // replacement is a hit, or every later render of a synced asset pays a full decode forever.
        let first = try #require(renderedImage("![](\(reference))", assetStore))
        let second = try #require(renderedImage("![](\(reference))", assetStore))
        #expect(first === second, "the new bytes must be memoized under their own key")
        let newKey = try #require(InlineImageAttachment.cacheKey(for: url, maxPixels: 800)) as NSString
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: newKey) === first)
    }

    @Test("The key tracks size AND modification time, and nothing else about the bytes")
    func theKeyTracksSizeAndModificationTime() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "versioned-\(UUID().uuidString).bin"
        let url = fx.assetURL(name, in: fx.itemA)
        func key() throws -> String {
            try #require(InlineImageAttachment.cacheKey(for: url, maxPixels: 800))
        }

        try Data(repeating: 0x41, count: 100).write(to: url)
        try pinModificationTime(url, to: epochA)
        let base = try key()

        // (a) same length, different content — only the modification time can tell these apart, which
        // is the case a size-only version would miss and a sync client can easily produce.
        try Data(repeating: 0x42, count: 100).write(to: url)
        try pinModificationTime(url, to: epochB)
        let byTime = try key()
        #expect(byTime != base, "an mtime change alone must change the key")

        // (b) different length at the *same* timestamp — the case an mtime-only version would miss,
        // and whole-second timestamps are common enough (restores, unzips) for it to matter.
        try Data(repeating: 0x42, count: 250).write(to: url)
        try pinModificationTime(url, to: epochB)
        #expect(try key() != byTime, "a size change alone must change the key")

        // (c) restored to the original size and timestamp — the key comes back. Stated as a property
        // rather than discovered later: the identity is exactly size+mtime, so a rewrite that matches
        // on both is deliberately not detected. That is also what makes a plain repeat render a hit.
        try Data(repeating: 0x43, count: 100).write(to: url)
        try pinModificationTime(url, to: epochA)
        #expect(try key() == base)
    }

    @Test("Two different files sharing a size and a timestamp still get different keys")
    func identicalVersionsOnDifferentPathsDoNotCollide() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "twin-\(UUID().uuidString).bin"
        let aURL = fx.assetURL(name, in: fx.itemA)
        let bURL = fx.assetURL(name, in: fx.itemB)
        try Data(repeating: 0x41, count: 100).write(to: aURL)
        try Data(repeating: 0x42, count: 100).write(to: bURL)
        try pinModificationTime(aURL, to: epochA)
        try pinModificationTime(bURL, to: epochA)

        let aKey = try #require(InlineImageAttachment.cacheKey(for: aURL, maxPixels: 800))
        let bKey = try #require(InlineImageAttachment.cacheKey(for: bURL, maxPixels: 800))
        // Non-vacuity: the version halves really are identical, so only the path is separating these.
        // (Key layout: maxPixels, version, path — NUL-separated.)
        let aParts = aKey.components(separatedBy: "\u{0000}")
        let bParts = bKey.components(separatedBy: "\u{0000}")
        #expect(aParts.count == 3 && bParts.count == 3)
        #expect(aParts[1] == bParts[1], "the two files must be indistinguishable by version alone")
        #expect(aKey != bKey, "the path must stay in the key — W23.m11 is not undone by versioning it")
    }

    @Test("A vanished asset has no cache identity and is not served from memory")
    func aVanishedAssetIsNotServedFromMemory() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let name = "vanished-\(UUID().uuidString).png"
        let url = fx.assetURL(name, in: fx.itemA)
        try fx.write(try solidPNG(.red, side: 24), named: name, into: fx.itemA)

        let warm = try #require(InlineImageAttachment.loadThumbnail(from: url))
        let staleKey = try #require(InlineImageAttachment.cacheKey(for: url, maxPixels: 800)) as NSString
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: staleKey) === warm)

        try FileManager.default.removeItem(at: url)

        // The render path never reaches this — `AssetPathResolver` answers `.missing` for a path that
        // is gone, so `MarkdownBridge` shows the placeholder without asking for a thumbnail. This is
        // the accessor's own contract, and it is load-bearing: if a file with no `stat` still produced
        // a key, the entry below is what the loader would hand back for bytes that no longer exist.
        #expect(InlineImageAttachment.cacheKey(for: url, maxPixels: 800) == nil)
        #expect(InlineImageAttachment.loadThumbnail(from: url) == nil)
        #expect(InlineImageAttachment.thumbnailCache.object(forKey: staleKey) === warm,
                "still a live entry — it is the missing identity that keeps it from being served")
    }
}
