import Testing
import Foundation
@testable import ArchiveNotes

/// W49.notes-auto-copy-images — an image a note names outside its `assets/` is copied in instead of
/// showing Blocked. Scratch temp stores only (never the real Notes store or the corpus). The read seam
/// itself is unchanged (`AssetPathResolverTests`, `InlineImageReadSeamTests`); these pin what is copied
/// automatically, what is offered to pick, what stays Blocked, and that the body is rewritten through the
/// editor's ordinary checked save.
@Suite("Images named outside assets/ are copied in (W49.notes-auto-copy-images)")
@MainActor
struct StrayImageAdoptionTests {

    @MainActor
    private struct Scratch {
        let root: URL
        let store: NoteStore
        let item = UUID()
        let other = UUID()
        var itemDir: URL { NoteStore.itemDir(root: root, id: item) }
        var assetsDir: URL { NoteStore.assetsDir(root: root, id: item) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("StrayImageAdoption-\(UUID().uuidString)", isDirectory: true)
            store = NoteStore(root: root)
            for id in [item, other] {
                try FileManager.default.createDirectory(at: NoteStore.assetsDir(root: root, id: id),
                                                        withIntermediateDirectories: true)
            }
        }

        func put(_ bytes: Data, at relative: String, in id: UUID? = nil) throws {
            let url = NoteStore.itemDir(root: root, id: id ?? item).appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: url)
        }

        func assets() -> ItemAssetStore { ItemAssetStore(store: store, root: root, itemID: item) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private let bytesA = Data("image A".utf8)
    private let bytesB = Data("image B".utf8)

    // MARK: - Classification

    @Test("an image inside the note's own folder is copied automatically; elsewhere is offered; nothing there stays Blocked")
    func classification() throws {
        let s = try Scratch()
        defer { s.cleanup() }
        try s.put(bytesA, at: "photo.png")
        try s.put(bytesA, at: "scans/page 1.jpg")
        try s.put(bytesA, at: "notes.md")
        try s.put(bytesB, at: "assets/x.png", in: s.other)
        let outsideFile = s.root.appendingPathComponent("outside.png")
        try bytesB.write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: s.itemDir.appendingPathComponent("link.png"),
                                                   withDestinationURL: outsideFile)

        func kind(_ ref: String) -> StrayImageAdoption.Kind? {
            StrayImageAdoption.classify(ref, inItemDirectory: s.itemDir)
        }
        let canonicalDir = s.itemDir.resolvingSymlinksInPath().standardizedFileURL
        #expect(kind("photo.png") == .inNoteFolder(canonicalDir.appendingPathComponent("photo.png")))
        #expect(kind("./photo.png") == .inNoteFolder(canonicalDir.appendingPathComponent("photo.png")))
        #expect(kind("scans/page 1.jpg") == .inNoteFolder(canonicalDir.appendingPathComponent("scans/page 1.jpg")))
        #expect(kind("assets/../photo.png") == .inNoteFolder(canonicalDir.appendingPathComponent("photo.png")))

        // Outside the note's folder: never opened unasked (another note's file is the W23.m3 hole).
        #expect(kind("../\(s.other.uuidString)/assets/x.png") == .outsideNoteFolder)
        #expect(kind(outsideFile.path) == .outsideNoteFolder)
        #expect(kind("~/Pictures/x.png") == .outsideNoteFolder)
        #expect(kind("file:///tmp/x.png") == .outsideNoteFolder)
        #expect(kind("link.png") == .outsideNoteFolder, "a symlink inside the folder pointing out counts as out")

        // Nothing readable there, or not an image: stays Blocked.
        #expect(kind("gone.png") == .notFound)
        #expect(kind("notes.md") == .notFound)
        #expect(kind("scans") == .notFound)

        // Not this type's business: the read seam's own references, and remote ones.
        #expect(kind("assets/photo.png") == nil)
        #expect(kind("https://example.com/x.png") == nil)
        #expect(StrayImageAdoption.hasCandidates("![a](assets/x.png) and ![b](https://e.com/b.png)") == false)
        #expect(StrayImageAdoption.hasCandidates("text ![a](photo.png)") == true)
    }

    @Test("rewriting keeps the label byte for byte and spells the destination as the app writes it")
    func rewriting() {
        let body = #"one ![A \] b](photo.png) two ![c](other.png) three ![d](photo.png)"#
        let out = StrayImageAdoption.rewriting(body, ["photo.png": "assets/photo copy.png"])
        #expect(out == #"one ![A \] b](<assets/photo copy.png>) two ![c](other.png) three ![d](<assets/photo copy.png>)"#)
    }

    // MARK: - The copy

    @Test("the copy lands in assets/, the reference resolves, the original stays, and a second pass reuses it")
    func copiesIntoAssets() async throws {
        let s = try Scratch()
        defer { s.cleanup() }
        try s.put(bytesA, at: "photo.png")
        let assets = s.assets()

        let body = "Before ![p](photo.png) after"
        let outcome = await assets.adoptStrayImages(in: body, for: s.item)
        #expect(outcome.body == "Before ![p](assets/photo.png) after")
        #expect(outcome.copied == ["photo.png"])
        #expect(outcome.toPick.isEmpty)
        #expect(try Data(contentsOf: s.assetsDir.appendingPathComponent("photo.png")) == bytesA)
        #expect(FileManager.default.fileExists(atPath: s.itemDir.appendingPathComponent("photo.png").path),
                "copied, not moved: the user's file is left where it was")
        guard case .resolved = assets.resolve("assets/photo.png") else {
            Issue.record("the rewritten reference must resolve through the unchanged read seam"); return
        }

        let again = await assets.adoptStrayImages(in: body, for: s.item)
        #expect(again.body == outcome.body)
        let names = try FileManager.default.contentsOfDirectory(atPath: s.assetsDir.path)
        #expect(names == ["photo.png"], "the identical copy is reused, not made twice")
    }

    @Test("a different file with the same name takes the next free name; outside paths are offered; a missing one stays")
    func nameClashOutsideAndMissing() async throws {
        let s = try Scratch()
        defer { s.cleanup() }
        try s.put(bytesB, at: "assets/photo.png")
        try s.put(bytesA, at: "photo.png")
        let outside = "../\(s.other.uuidString)/assets/x.png"
        let body = "![p](photo.png) ![o](\(outside)) ![m](gone.png) ![o2](/Volumes/X/y.png) ![o](\(outside))"

        let outcome = await s.assets().adoptStrayImages(in: body, for: s.item)
        #expect(outcome.body == "![p](assets/photo-1.png) ![o](\(outside)) ![m](gone.png) ![o2](/Volumes/X/y.png) ![o](\(outside))")
        #expect(outcome.copied == ["photo-1.png"])
        #expect(outcome.toPick == [outside, "/Volumes/X/y.png"])
        #expect(try Data(contentsOf: s.assetsDir.appendingPathComponent("photo.png")) == bytesB,
                "the existing asset is never overwritten")
    }

    @Test("a picked file is copied in like any other")
    func pickedFile() async throws {
        let s = try Scratch()
        defer { s.cleanup() }
        let picked = s.root.appendingPathComponent("picked.jpg")
        try bytesA.write(to: picked)
        let path = try await s.assets().importFile(at: picked, into: s.item)
        #expect(path == "assets/picked.jpg")
        #expect(try Data(contentsOf: s.assetsDir.appendingPathComponent("picked.jpg")) == bytesA)
    }

    // MARK: - The editor

    @Test("opening a note copies its images in and saves the rewrite through the checked save")
    func openAdoptsAndSaves() async throws {
        let id = UUID()
        let model = NoteBodyEditorModel()
        model.saveDebounce = .milliseconds(20)
        model.load = { _ in "![p](photo.png) ![o](/elsewhere/o.png)" }
        var saved: [(String, String)] = []
        model.checkedSave = { _, body, baseline in saved.append((body, baseline)); return body }
        var adopted: [String] = []
        model.onImagesAdopted = { adopted = $0 }
        model.adoptImages = { _, body in
            StrayImageOutcome(body: body.replacingOccurrences(of: "](photo.png)", with: "](assets/photo.png)"),
                              copied: ["photo.png"], toPick: ["/elsewhere/o.png"])
        }

        await model.select(id)
        #expect(model.markdown == "![p](assets/photo.png) ![o](/elsewhere/o.png)")
        #expect(model.reloadGeneration == 1, "the editor is rebuilt so a focused text view can't write the old reference back")
        #expect(adopted == ["photo.png"])
        #expect(model.imagesToPick == ["/elsewhere/o.png"])
        await model.flushPending()
        #expect(saved.count == 1)
        #expect(saved.first?.0 == "![p](assets/photo.png) ![o](/elsewhere/o.png)")
        #expect(saved.first?.1 == "![p](photo.png) ![o](/elsewhere/o.png)", "saved against the body as loaded")

        model.applyPickedImage(reference: "/elsewhere/o.png", assetPath: "assets/o.png")
        #expect(model.markdown == "![p](assets/photo.png) ![o](assets/o.png)")
        #expect(model.imagesToPick.isEmpty)
        await model.flushPending()
        #expect(saved.count == 2)
    }

    @Test("a copy that finishes after another note was selected rewrites nothing and claims nothing")
    func switchDuringCopy() async {
        let a = UUID(), b = UUID()
        let model = NoteBodyEditorModel()
        model.load = { id in
            if id == b { try? await Task.sleep(for: .milliseconds(150)) }   // B's read is still in flight
            return id == a ? "![p](photo.png)" : "note B"
        }
        model.adoptImages = { _, body in
            try? await Task.sleep(for: .milliseconds(60))
            return StrayImageOutcome(body: "![p](assets/photo.png)", copied: ["photo.png"], toPick: [])
        }
        var claimed = 0
        model.onImagesAdopted = { _ in claimed += 1 }
        let first = Task { await model.select(a) }
        try? await Task.sleep(for: .milliseconds(20))
        await model.select(b)
        await first.value
        #expect(model.loadedID == b)
        #expect(model.markdown == "note B")
        #expect(claimed == 0, "no status line for a rewrite that was never kept")
    }

    @Test("a note with no stray image never calls the copy, and a body edited during the copy is left alone")
    func noCandidatesAndRace() async {
        let id = UUID()
        let model = NoteBodyEditorModel()
        var body = "plain ![a](assets/a.png)"
        model.load = { _ in body }
        var calls = 0
        model.adoptImages = { _, b in calls += 1; return StrayImageOutcome(body: b + "!", copied: [], toPick: []) }
        await model.select(id)
        #expect(calls == 0)

        body = "![p](photo.png)"
        let other = UUID()
        model.adoptImages = { [weak model] _, _ in
            calls += 1
            model?.markdown = "typed meanwhile"      // the user typed while the copy ran
            return StrayImageOutcome(body: "rewritten", copied: ["photo.png"], toPick: ["x"])
        }
        await model.select(other)
        #expect(calls == 1)
        #expect(model.markdown == "typed meanwhile")
        #expect(model.imagesToPick.isEmpty)
    }
}
