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

    /// W3.notes-frontmatter-codec-bypasses-the-leading-text-guard, proven at the level that matters:
    /// through the real `create` → `.md` on disk → `load` path, not just through the codec. Leading
    /// prose with no trailing newline used to be written flush against the first `<!-- block:` header,
    /// which `BlockParser.parse` only recognizes at a line start — so the block, and its provenance,
    /// was silently absorbed into the prose the next time the note was opened.
    @Test("a leading body with no trailing newline keeps its block through disk")
    func leadingBodyWithoutNewlineSurvivesDiskRoundTrip() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        var item = makeItem(title: "Fused Header")
        item.trailingBodyRaw = "Prose with no trailing newline."
        item.blocks = [
            Block(kind: .readerPage,
                  source: SourceAnchor(link: "archivereader://open?doc=abc", display: "Doc p.7", page: 7),
                  markdown: "Quoted passage.\n", unknownHeaderFields: []),
        ]

        let ref = try await store.create(item)
        let raw = try String(contentsOf: ref.url, encoding: .utf8)
        #expect(!raw.contains("newline.<!-- block:"))
        #expect(raw.contains("\n<!-- block: reader-page"))

        let loaded = try await store.load(item.id)
        #expect(loaded.blocks.count == 1)
        #expect(loaded.blocks.first?.source?.page == 7)
        #expect(loaded.blocks.first?.source?.link == "archivereader://open?doc=abc")
        #expect(loaded.trailingBodyRaw == "Prose with no trailing newline.\n")

        // And it is a fixed point: saving what we loaded does not keep growing the body.
        _ = try await store.save(loaded)
        let again = try await store.load(item.id)
        #expect(again.blocks.count == 1)
        #expect(again.trailingBodyRaw == loaded.trailingBodyRaw)
    }

    /// W3.notes-cr-line-start through the real `create` → `.md` on disk → `load` path.
    ///
    /// A body whose lines end in a lone `\r` (classic-Mac text, pasted into the editor) already ends
    /// its line, so the serializer must write the header straight after it. The old
    /// `hasSuffix("\n")` test said otherwise and appended a `\n`, which Swift merges into the
    /// preceding `\r` as ONE `"\r\n"` grapheme — so the operator's line endings were silently
    /// rewritten, and on the next decode `FrontMatterCodec`'s `\r\n` → `\n` normalization finished the
    /// job. Provenance happens to survive that particular laundering; the operator's text does not,
    /// which is what the raw-file and `trailingBodyRaw` expectations below pin down.
    @Test("a CR-delimited body keeps its line endings and its block through disk")
    func carriageReturnDelimitedBodySurvivesDiskRoundTrip() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        var item = makeItem(title: "Classic Mac Line Endings")
        item.trailingBodyRaw = "Prose ending in a classic-Mac line break.\r"
        item.blocks = [
            Block(kind: .readerPage,
                  source: SourceAnchor(link: "archivereader://open?doc=cr", display: "Doc p.7", page: 7),
                  markdown: "Quoted passage.\r", unknownHeaderFields: []),
        ]

        let ref = try await store.create(item)
        let raw = try String(contentsOf: ref.url, encoding: .utf8)
        #expect(raw.contains("\r<!-- block: reader-page"))
        #expect(!raw.contains("\r\n<!-- block:"))

        let loaded = try await store.load(item.id)
        #expect(loaded.trailingBodyRaw == "Prose ending in a classic-Mac line break.\r")
        #expect(loaded.blocks.count == 1)
        #expect(loaded.blocks.first?.source?.page == 7)
        #expect(loaded.blocks.first?.source?.link == "archivereader://open?doc=cr")
        #expect(loaded.blocks.first?.markdown == "Quoted passage.\r")

        // Fixed point: an autosaving editor must not grow or re-punctuate the body on every save.
        _ = try await store.save(loaded)
        let again = try await store.load(item.id)
        #expect(again.trailingBodyRaw == loaded.trailingBodyRaw)
        #expect(again.blocks.first?.markdown == loaded.blocks.first?.markdown)
        // Front matter carries a `modified` stamp, so compare the shape that matters, not the bytes.
        let rawAgain = try String(contentsOf: ref.url, encoding: .utf8)
        #expect(rawAgain.contains("\r<!-- block: reader-page"))
        #expect(!rawAgain.contains("\r\n<!-- block:"))
    }

    /// W3.notes-cr-line-start-fu1 — the other half of the asymmetry the test above pins, through the
    /// real `create` → `.md` on disk → `load` → `save` path.
    ///
    /// `FrontMatterCodec.decode` used to normalize `\r\n` → `\n` over the whole file, so a
    /// Windows-delimited body was rewritten on every read even though nothing downstream needs LF any
    /// more. On MIXED endings that was progressive rather than one-off: `"\r\r\n"` normalizes to
    /// `"\r\n"`, which the NEXT read normalizes to `"\n"`, so the blank line between two paragraphs is
    /// gone after two saves. Hence two save cycles here — one cycle looks stable.
    @Test("a CRLF-delimited body keeps its line endings and its blank line across repeated saves")
    func crlfDelimitedBodySurvivesDiskRoundTrip() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        var item = makeItem(title: "Windows Line Endings")
        item.trailingBodyRaw = "Para one.\r\r\nPara two.\r\n"
        item.blocks = [
            Block(kind: .readerPage,
                  source: SourceAnchor(link: "archivereader://open?doc=crlf", display: "Doc p.3", page: 3),
                  markdown: "Quoted passage.\r\n", unknownHeaderFields: []),
        ]

        let ref = try await store.create(item)
        let loaded = try await store.load(item.id)
        #expect(loaded.trailingBodyRaw == "Para one.\r\r\nPara two.\r\n")
        #expect(loaded.blocks.count == 1)
        #expect(loaded.blocks.first?.markdown == "Quoted passage.\r\n")
        #expect(loaded.blocks.first?.source?.page == 3)

        _ = try await store.save(loaded)
        let again = try await store.load(item.id)
        #expect(again.trailingBodyRaw == loaded.trailingBodyRaw)
        #expect(again.blocks.first?.markdown == loaded.blocks.first?.markdown)
        #expect(again.blocks.first?.source?.link == "archivereader://open?doc=crlf")

        // And the bytes on disk are the operator's, not a laundered copy of them.
        let raw = try String(contentsOf: ref.url, encoding: .utf8)
        #expect(raw.contains("Para one.\r\r\nPara two.\r\n"))
    }

    /// W3.notes-thumb-line-duplicates through the WHOLE autosave cycle the app actually runs:
    /// `.md` on disk → `NotesModel.loadBody`'s `BlockParser.serialize` → the EDITOR's
    /// `MarkdownBridge.parse`/`serialize` → `setBody`'s `BlockParser.parse` → atomic save. The defect
    /// lived in the editor half, so no storage test could see it; what it damaged was the file, so this
    /// asserts the RAW bytes — and does it twice, because unbounded growth is the claim.
    ///
    /// Scratch `mktemp` store only (Prime Directive #1). The two cycles are deliberate: the pre-fix
    /// count went 1 → 2 → 3, and a single cycle proves nothing about whether it settles.
    @MainActor
    @Test("a thumb block's image line does not multiply across editor autosave cycles")
    func thumbLineDoesNotMultiplyAcrossEditorSaveCycles() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        let thumbLine = "![Doc p.41](assets/p41-thumb.png)"
        var item = makeItem(title: "Moore Oral History")
        item.blocks = [
            Block(kind: .readerPage,
                  source: SourceAnchor(link: "archivereader://reveal?root=G&rel=Moore.pdf&page=41",
                                       display: "Doc p.41", page: 41,
                                       thumbRef: "assets/p41-thumb.png"),
                  markdown: "\(thumbLine)\n\nAnnotation.\n", unknownHeaderFields: []),
        ]
        let ref = try await store.create(item)

        let created = try String(contentsOf: ref.url, encoding: .utf8)
        #expect(occurrences(of: thumbLine, in: created) == 1,
                "fixture precondition: one thumb line on disk to begin with")

        for cycle in 1...2 {
            // Exactly what an autosave does, in the same order.
            let loaded = try await store.load(item.id)
            let editorMarkdown = BlockParser.serialize(leadingText: loaded.trailingBodyRaw,
                                                       blocks: loaded.blocks)
            let edited = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: editorMarkdown))
            let parsed = BlockParser.parse(edited)
            var next = loaded
            next.trailingBodyRaw = parsed.leadingText
            next.blocks = parsed.blocks
            _ = try await store.save(next)

            let raw = try String(contentsOf: ref.url, encoding: .utf8)
            #expect(occurrences(of: thumbLine, in: raw) == 1,
                    "cycle \(cycle): the note gained a duplicate thumbnail line:\n\(raw)")
            #expect(occurrences(of: "Annotation.", in: raw) == 1,
                    "cycle \(cycle): the block body text was duplicated:\n\(raw)")
            #expect(raw.contains("thumb: assets/p41-thumb.png"),
                    "cycle \(cycle): the durable thumb ref left the header:\n\(raw)")
            #expect(raw.contains("\n<!-- block: reader-page"),
                    "cycle \(cycle): the header no longer begins a line:\n\(raw)")
            let reloaded = try await store.load(item.id)
            #expect(reloaded.blocks.count == 1,
                    "cycle \(cycle): the block was lost or split:\n\(raw)")
            #expect(reloaded.blocks.first?.source?.thumbRef == "assets/p41-thumb.png")
            #expect(reloaded.blocks.first?.source?.page == 41)
        }
    }

    /// W3.notes-thumb-line-duplicates-fu1 — the Tier-2 functional check, on the same real autosave cycle
    /// as the test above, because the damage is measured in the FILE. A bracketed document title
    /// (`Moore [draft]`) used to leave the first save with no image reference at all: the line reloaded as
    /// escaped prose, so the imported asset was orphaned while the header's `thumb:` went on claiming a
    /// thumbnail. Two cycles, and the bytes asserted directly — an in-memory bridge test cannot see what
    /// landed on disk.
    ///
    /// Scratch `mktemp` store only (Prime Directive #1).
    @MainActor
    @Test("a bracketed display keeps its thumbnail reference across editor autosave cycles")
    func bracketedDisplayKeepsItsThumbnailAcrossEditorSaveCycles() async throws {
        let (store, tmp) = try makeScratchStore()
        defer { cleanup(tmp) }

        // What `buildInsertableBlock` writes for this display — escaped, and an image reference.
        let thumbLine = "![Moore \\[draft\\]](assets/p41-thumb.png)"
        var item = makeItem(title: "Moore Oral History")
        item.blocks = [
            Block(kind: .readerPage,
                  source: SourceAnchor(link: "archivereader://reveal?root=G&rel=Moore.pdf&page=41",
                                       display: "Moore [draft]", page: 41,
                                       thumbRef: "assets/p41-thumb.png"),
                  markdown: "\(thumbLine)\n\nAnnotation.\n", unknownHeaderFields: []),
        ]
        let ref = try await store.create(item)

        for cycle in 1...2 {
            let loaded = try await store.load(item.id)
            let editorMarkdown = BlockParser.serialize(leadingText: loaded.trailingBodyRaw,
                                                       blocks: loaded.blocks)
            let edited = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: editorMarkdown))
            let parsed = BlockParser.parse(edited)
            var next = loaded
            next.trailingBodyRaw = parsed.leadingText
            next.blocks = parsed.blocks
            _ = try await store.save(next)

            let raw = try String(contentsOf: ref.url, encoding: .utf8)
            #expect(occurrences(of: thumbLine, in: raw) == 1,
                    "cycle \(cycle): the thumbnail reference is gone or doubled on disk:\n\(raw)")
            #expect(!raw.contains("![Moore [draft]]"),
                    "cycle \(cycle): an UNESCAPED label reached the file, which cannot be parsed:\n\(raw)")
            #expect(raw.contains("display: \"Moore [draft]\""),
                    "cycle \(cycle): the header's display must stay the operator's own text:\n\(raw)")
            #expect(occurrences(of: "Annotation.", in: raw) == 1,
                    "cycle \(cycle): the block body text was duplicated:\n\(raw)")

            // The reference has to come back as an IMAGE, not as prose that merely looks like one.
            let reloaded = try await store.load(item.id)
            #expect(reloaded.blocks.count == 1, "cycle \(cycle): the block was lost or split:\n\(raw)")
            #expect(reloaded.blocks.first?.source?.thumbRef == "assets/p41-thumb.png")
            #expect(reloaded.blocks.first?.source?.display == "Moore [draft]")
            let styled = MarkdownBridge.parse(markdown: reloaded.blocks[0].markdown)
            var relPath: String?
            styled.enumerateAttribute(.noteImageRelPath,
                                      in: NSRange(location: 0, length: styled.length)) { v, _, _ in
                if let p = v as? String { relPath = p }
            }
            #expect(relPath == "assets/p41-thumb.png",
                    "cycle \(cycle): the thumbnail reloaded as prose, not as an image:\n\(raw)")
        }
    }

    /// Counting, not `contains` — a line written twice contains itself.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
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
