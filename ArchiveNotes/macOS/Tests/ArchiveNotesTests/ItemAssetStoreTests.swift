import Testing
import Foundation
@testable import ArchiveNotes

/// W7-S5 (Tier-2) — the item-scoped inline-image asset store's file-write path, on a **scratch** store
/// (temp dir; never the real Notes store or the archival corpus). Proves the sync↔async bridge keeps the
/// `assets/<name>` reference the editor stored in sync with the bytes that land on disk: writes persist,
/// survive reload, disambiguate on same-name pastes, and never overwrite / corrupt existing bytes.
@Suite("ItemAssetStore — item-scoped asset persistence (W7-S5)")
@MainActor
struct ItemAssetStoreTests {

    private func makeScratchStore() throws -> (NoteStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ItemAssetStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (NoteStore(root: tmp), tmp)
    }

    private func makeItem(title: String = "Asset Host") -> Item {
        Item(
            id: UUID(), kind: .note, title: title, authors: ["Author A"], date: "1980",
            datePrecision: .year, dateUncertain: false, quality: nil, tags: ["test"], zotero: [],
            roundup: false, created: Date(), modified: Date(), schema: 1, blocks: [],
            unknownFrontMatter: [], trailingBodyRaw: nil
        )
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    // MARK: - Happy path: paste persists + reference matches on-disk file

    @Test("addAsset writes bytes to assets/<name>, ref matches the file, survives reload")
    func addPersistsAndSurvivesReload() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }
        let item = makeItem()
        _ = try await store.create(item)

        let asset = ItemAssetStore(store: store, root: store.rootURL, itemID: item.id)
        let bytes = Data("PNG-BYTES-1".utf8)
        let ref = try asset.addAsset(bytes, preferredName: "pasted-1.png")
        await asset.awaitPendingWrites()

        // The synchronous reference the editor baked into the markdown …
        #expect(ref == "assets/pasted-1.png")
        // … names exactly the file that landed on disk, with the pasted bytes.
        let onDisk = await store.itemDir(item.id).appendingPathComponent(ref)
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
        #expect(try Data(contentsOf: onDisk) == bytes)
        // resolveAsset round-trips the same reference (used by the editor to load a thumbnail on reload).
        #expect(asset.resolveAsset(ref)?.standardizedFileURL == onDisk.standardizedFileURL)

        // "Survives reload": a fresh store instance over the same root still finds the asset.
        let reopened = ItemAssetStore(store: NoteStore(root: tmp), root: tmp, itemID: item.id)
        #expect(reopened.resolveAsset(ref) != nil)
    }

    // MARK: - Same-name pastes do not clobber

    @Test("two same-named pastes disambiguate; both files keep their own bytes")
    func sameNameDoesNotClobber() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }
        let item = makeItem()
        _ = try await store.create(item)

        let asset = ItemAssetStore(store: store, root: store.rootURL, itemID: item.id)
        let d1 = Data("FIRST".utf8)
        let d2 = Data("SECOND".utf8)
        let r1 = try asset.addAsset(d1, preferredName: "img.png")
        let r2 = try asset.addAsset(d2, preferredName: "img.png")
        await asset.awaitPendingWrites()

        #expect(r1 == "assets/img.png")
        #expect(r2 == "assets/img-1.png")     // matches NoteStore.disambiguateAsset's scheme
        let dir = await store.assetsDir(item.id)
        #expect(try Data(contentsOf: dir.appendingPathComponent("img.png")) == d1)
        #expect(try Data(contentsOf: dir.appendingPathComponent("img-1.png")) == d2)
    }

    @Test("a name already on disk is skipped (reservation sees existing files)")
    func skipsPreexistingOnDisk() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }
        let item = makeItem()
        _ = try await store.create(item)
        // Pre-existing asset from an earlier session (written via the audited importAsset).
        let existing = Data("OLD".utf8)
        _ = try await store.importAsset(existing, preferredName: "img.png", into: item.id)

        let asset = ItemAssetStore(store: store, root: store.rootURL, itemID: item.id)
        let fresh = Data("NEW".utf8)
        let ref = try asset.addAsset(fresh, preferredName: "img.png")
        await asset.awaitPendingWrites()

        #expect(ref == "assets/img-1.png")    // did not reuse the on-disk name
        let dir = await store.assetsDir(item.id)
        #expect(try Data(contentsOf: dir.appendingPathComponent("img.png")) == existing)  // untouched
        #expect(try Data(contentsOf: dir.appendingPathComponent("img-1.png")) == fresh)
    }

    // MARK: - Retarget per selection

    @Test("retargeting itemID routes each paste to the current item's assets/")
    func retargetRoutesToCurrentItem() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }
        let a = makeItem(title: "Note A")
        let b = makeItem(title: "Note B")
        _ = try await store.create(a)
        _ = try await store.create(b)

        let asset = ItemAssetStore(store: store, root: store.rootURL, itemID: a.id)
        _ = try asset.addAsset(Data("A".utf8), preferredName: "x.png")
        asset.itemID = b.id
        _ = try asset.addAsset(Data("B".utf8), preferredName: "x.png")
        await asset.awaitPendingWrites()

        let aDir = await store.assetsDir(a.id)
        let bDir = await store.assetsDir(b.id)
        #expect(try Data(contentsOf: aDir.appendingPathComponent("x.png")) == Data("A".utf8))
        #expect(try Data(contentsOf: bDir.appendingPathComponent("x.png")) == Data("B".utf8))
        // Same preferredName in a *different* item does not disambiguate (separate assets/ dirs).
        #expect(!FileManager.default.fileExists(atPath: aDir.appendingPathComponent("x-1.png").path))
    }

    @Test("addAsset throws when no item is targeted")
    func throwsWithoutTarget() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }
        let asset = ItemAssetStore(store: store, root: store.rootURL, itemID: nil)
        #expect(throws: ItemAssetStoreError.self) {
            _ = try asset.addAsset(Data("x".utf8), preferredName: "x.png")
        }
        #expect(asset.resolveAsset("assets/x.png") == nil)
    }

    // MARK: - NoteStore.writeReservedAsset guarantees (never-overwrite + component boundary)

    @Test("writeReservedAsset never overwrites an existing file")
    func writeReservedNeverOverwrites() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }
        let item = makeItem()
        _ = try await store.create(item)

        try await store.writeReservedAsset(Data("KEEP".utf8), name: "a.png", into: item.id)
        await #expect(throws: NoteStore.StoreError.self) {
            try await store.writeReservedAsset(Data("CLOBBER".utf8), name: "a.png", into: item.id)
        }
        let dir = await store.assetsDir(item.id)
        #expect(try Data(contentsOf: dir.appendingPathComponent("a.png")) == Data("KEEP".utf8))
    }

    @Test("writeReservedAsset rejects a name that escapes the assets dir")
    func writeReservedRejectsTraversal() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }
        let item = makeItem()
        _ = try await store.create(item)

        for bad in ["../evil.png", "sub/evil.png", "..", "."] {
            await #expect(throws: NoteStore.StoreError.self) {
                try await store.writeReservedAsset(Data("x".utf8), name: bad, into: item.id)
            }
        }
        // Nothing escaped into the item dir's parent (the `items/` folder) or the store root.
        let itemsDir = tmp.appendingPathComponent("items")
        #expect(!FileManager.default.fileExists(atPath: itemsDir.appendingPathComponent("evil.png").path))
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("evil.png").path))
    }
}
