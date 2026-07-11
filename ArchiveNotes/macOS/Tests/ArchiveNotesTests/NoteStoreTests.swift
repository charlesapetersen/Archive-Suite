import Testing
import Foundation
@testable import ArchiveNotes

@Suite("NoteStore — UUID-folder CRUD")
struct NoteStoreTests {

    private func makeScratchStore() throws -> (NoteStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (NoteStore(root: tmp), tmp)
    }

    private func makeItem(title: String = "Test Note", kind: Item.Kind = .note) -> Item {
        Item(
            id: UUID(),
            kind: kind,
            title: title,
            authors: ["Author A"],
            date: "1980",
            datePrecision: .year,
            dateUncertain: false,
            quality: nil,
            tags: ["test"],
            zotero: [],
            roundup: false,
            created: Date(),
            modified: Date(),
            schema: 1,
            blocks: [],
            unknownFrontMatter: [],
            trailingBodyRaw: nil
        )
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Create

    @Test("create writes item dir + .md + assets dir")
    func createBasic() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let item = makeItem(title: "My First Note")
        let ref = try await store.create(item)

        #expect(ref.id == item.id)
        #expect(FileManager.default.fileExists(atPath: ref.url.path))
        #expect(ref.url.lastPathComponent == "My First Note.md")

        // Assets dir should exist.
        let assetsDir = await store.assetsDir(item.id)
        #expect(FileManager.default.fileExists(atPath: assetsDir.path))
    }

    // MARK: - Load round-trip

    @Test("create then load round-trips the item")
    func createLoadRoundTrip() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let item = makeItem(title: "Round Trip")
        _ = try await store.create(item)
        let loaded = try await store.load(item.id)

        #expect(loaded.id == item.id)
        #expect(loaded.title == "Round Trip")
        #expect(loaded.kind == .note)
        #expect(loaded.authors == ["Author A"])
        #expect(loaded.tags == ["test"])
    }

    // MARK: - Save (retitle -> rename)

    @Test("save retitles the file when title changes")
    func saveRetitle() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        var item = makeItem(title: "Original")
        _ = try await store.create(item)

        item.title = "Renamed"
        item.modified = Date()
        let ref = try await store.save(item)

        #expect(ref.url.lastPathComponent == "Renamed.md")
        // Old file should not exist.
        let oldURL = await store.itemDir(item.id).appendingPathComponent("Original.md")
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        // New file should load.
        let loaded = try await store.load(item.id)
        #expect(loaded.title == "Renamed")
    }

    @Test("save without title change preserves filename")
    func saveNoRetitle() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        var item = makeItem(title: "Stable")
        _ = try await store.create(item)

        item.tags = ["updated"]
        item.modified = Date()
        let ref = try await store.save(item)

        #expect(ref.url.lastPathComponent == "Stable.md")
        let loaded = try await store.load(item.id)
        #expect(loaded.tags == ["updated"])
    }

    // MARK: - Delete (goes to Trash)

    @Test("delete moves item dir to Trash, not removeItem")
    func deleteGoesToTrash() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let item = makeItem()
        _ = try await store.create(item)
        let dir = await store.itemDir(item.id)
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try await store.delete(item.id)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("delete nonexistent throws notFound")
    func deleteNotFound() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        do {
            try await store.delete(UUID())
            Issue.record("Expected notFound error")
        } catch is NoteStore.StoreError {
            // expected
        }
    }

    // MARK: - allItemIDs

    @Test("allItemIDs returns created item UUIDs")
    func allItemIDs() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let item1 = makeItem(title: "A")
        let item2 = makeItem(title: "B")
        _ = try await store.create(item1)
        _ = try await store.create(item2)

        let ids = await store.allItemIDs()
        #expect(ids.contains(item1.id))
        #expect(ids.contains(item2.id))
        #expect(ids.count == 2)
    }

    // MARK: - Assets

    @Test("importAsset writes file and returns relative path")
    func importAsset() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let item = makeItem()
        _ = try await store.create(item)

        let assetData = Data("hello".utf8)
        let relPath = try await store.importAsset(assetData, preferredName: "photo.png", into: item.id)

        #expect(relPath == "assets/photo.png")
        let fullURL = await store.itemDir(item.id).appendingPathComponent(relPath)
        #expect(FileManager.default.fileExists(atPath: fullURL.path))
    }

    @Test("importAsset disambiguates on collision")
    func importAssetCollision() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let item = makeItem()
        _ = try await store.create(item)

        let data1 = Data("first".utf8)
        let data2 = Data("second".utf8)
        let path1 = try await store.importAsset(data1, preferredName: "img.png", into: item.id)
        let path2 = try await store.importAsset(data2, preferredName: "img.png", into: item.id)

        #expect(path1 == "assets/img.png")
        #expect(path2 == "assets/img-1.png")
    }

    // MARK: - Filename sanitization

    @Test("sanitizedTitle replaces illegal chars and trims")
    func sanitizedTitle() {
        #expect(NoteStore.sanitizedTitle("Hello/World") == "Hello-World")
        #expect(NoteStore.sanitizedTitle("Note: Important") == "Note- Important")
        #expect(NoteStore.sanitizedTitle("  .dotfile.  ") == "dotfile")
        #expect(NoteStore.sanitizedTitle("") == "Untitled")
        #expect(NoteStore.sanitizedTitle("...") == "Untitled")
    }

    @Test("sanitizedTitle caps length")
    func sanitizedTitleLength() {
        let longTitle = String(repeating: "A", count: 300)
        let sanitized = NoteStore.sanitizedTitle(longTitle)
        #expect(sanitized.utf16.count <= 200)
    }

    // MARK: - mdURL

    @Test("mdURL finds the .md file in item dir")
    func mdURL() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let item = makeItem(title: "FindMe")
        _ = try await store.create(item)

        let url = try await store.mdURL(for: item.id)
        #expect(url.lastPathComponent == "FindMe.md")
    }

    @Test("mdURL throws for nonexistent item")
    func mdURLNotFound() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        do {
            _ = try await store.mdURL(for: UUID())
            Issue.record("Expected notFound error")
        } catch is NoteStore.StoreError {
            // expected
        }
    }
}
