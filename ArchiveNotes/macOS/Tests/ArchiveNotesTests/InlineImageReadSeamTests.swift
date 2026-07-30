import Testing
import Foundation
import AppKit
@testable import ArchiveNotes

/// W23.m3 (Tier-2) — the inline-image read seam **end to end**, on scratch stores (temp dirs; never the
/// real Notes store or the archival corpus). `AssetPathResolverTests` covers the resolver in isolation;
/// this suite proves the two consumers actually honour it:
///   * the **renderer** (`MarkdownBridge.parse`) shows a refused reference as a distinct placeholder
///     instead of another item's image;
///   * the **copy/extract** path (`EditorPassageSource.assetBytes`) embeds no bytes for a refused
///     reference, so foreign bytes can never be snapshotted into a third item under a bare filename.
@Suite("Inline-image read seam — renderer + extract path (W23.m3)")
@MainActor
struct InlineImageReadSeamTests {

    // MARK: - Fixture: a real NoteStore-shaped scratch root with two items

    @MainActor
    private struct TwoItemStore {
        let root: URL
        let store: NoteStore
        let itemA: UUID
        let itemB: UUID

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("InlineImageReadSeam-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            store = NoteStore(root: root)
            itemA = UUID()
            itemB = UUID()
            for id in [itemA, itemB] {
                try fm.createDirectory(at: NoteStore.assetsDir(root: root, id: id),
                                       withIntermediateDirectories: true)
            }
        }

        func write(_ bytes: Data, named name: String, into id: UUID) throws {
            try bytes.write(to: NoteStore.assetsDir(root: root, id: id).appendingPathComponent(name))
        }

        /// Item A's relative reference that reaches into item B's assets — the reported escape.
        func escapeFromAToB(_ name: String) -> String {
            "../\(itemB.uuidString)/assets/\(name)"
        }

        func assetStore(for id: UUID) -> ItemAssetStore {
            ItemAssetStore(store: store, root: root, itemID: id)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// Minimal valid 1×1 PNG, so a *successful* resolve really does produce a thumbnail (otherwise a
    /// blocked read and an unreadable file would be indistinguishable in these assertions).
    private func onePixelPNG() -> Data {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1, height: 1)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return png
    }

    private func attachments(in styled: NSAttributedString) -> [InlineImageAttachment] {
        var found: [InlineImageAttachment] = []
        styled.enumerateAttribute(.attachment,
                                  in: NSRange(location: 0, length: styled.length)) { value, _, _ in
            if let attachment = value as? InlineImageAttachment { found.append(attachment) }
        }
        return found
    }

    // MARK: - The store seam

    @Test("ItemAssetStore refuses a reference reaching into another item, and keeps its own")
    func itemAssetStoreContainsToItsOwnItem() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        try fx.write(Data("A-OWN".utf8), named: "own.png", into: fx.itemA)
        try fx.write(Data("B-PRIVATE".utf8), named: "private.png", into: fx.itemB)

        let assetStore = fx.assetStore(for: fx.itemA)
        let escape = fx.escapeFromAToB("private.png")

        // The pre-fix rule found item B's bytes from item A …
        #expect(FileManager.default.fileExists(
            atPath: NoteStore.itemDir(root: fx.root, id: fx.itemA)
                .appendingPathComponent(escape).path))
        // … the contained seam refuses it, and hands back no URL at all.
        #expect(assetStore.resolve(escape) == .outOfBounds)
        #expect(assetStore.resolveAsset(escape) == nil)

        // Its own asset still resolves, to its own bytes.
        guard case .resolved(let own) = assetStore.resolve("assets/own.png") else {
            Issue.record("the item's own asset must still resolve")
            return
        }
        #expect(try Data(contentsOf: own) == Data("A-OWN".utf8))
    }

    @Test("With no target item, nothing resolves (no boundary to check against)")
    func noTargetItemResolvesNothing() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        try fx.write(Data("A-OWN".utf8), named: "own.png", into: fx.itemA)

        let untargeted = ItemAssetStore(store: fx.store, root: fx.root, itemID: nil)
        #expect(untargeted.resolve("assets/own.png") == .missing)
        #expect(untargeted.resolveAsset("assets/own.png") == nil)
    }

    @Test("ScratchAssetStore enforces the same boundary as the production store")
    func scratchStoreContained() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory
            .appendingPathComponent("ScratchContained-\(UUID().uuidString)", isDirectory: true)
        let scratchRoot = parent.appendingPathComponent("item", isDirectory: true)
        try fm.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        try Data("OUTSIDE".utf8).write(to: parent.appendingPathComponent("outside.png"))

        let store = ScratchAssetStore(root: scratchRoot)
        let ref = try store.addAsset(Data("INSIDE".utf8), preferredName: "inside.png")

        guard case .resolved(let inside) = store.resolve(ref) else {
            Issue.record("a scratch-store paste must resolve back to its own bytes")
            return
        }
        #expect(try Data(contentsOf: inside) == Data("INSIDE".utf8))
        #expect(store.resolve("../outside.png") == .outOfBounds)
        #expect(store.resolve("assets/nope.png") == .missing)
    }

    // MARK: - The renderer seam

    @Test("Rendering a note whose image escapes the item shows the Blocked placeholder, not the image")
    func rendererRefusesEscapingReference() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let png = onePixelPNG()
        try fx.write(png, named: "private.png", into: fx.itemB)

        let escape = fx.escapeFromAToB("private.png")
        let styled = MarkdownBridge.parse(markdown: "Look: ![](\(escape))",
                                          assetStore: fx.assetStore(for: fx.itemA))

        let found = attachments(in: styled)
        #expect(found.count == 1)
        // No thumbnail was built from item B's bytes …
        #expect(found.first?.placeholder == .outOfBounds)
        // … while the reference itself is preserved, so re-serializing never rewrites the note body.
        #expect(found.first?.relativePath == escape)
        #expect(MarkdownBridge.serialize(styled).contains("![](\(escape))"))
    }

    @Test("Rendering the item's own image still loads a real thumbnail")
    func rendererLoadsOwnImage() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        try fx.write(onePixelPNG(), named: "own.png", into: fx.itemA)

        let styled = MarkdownBridge.parse(markdown: "![](assets/own.png)",
                                          assetStore: fx.assetStore(for: fx.itemA))
        let found = attachments(in: styled)
        #expect(found.count == 1)
        #expect(found.first?.placeholder == nil)
        #expect(found.first?.image != nil)
    }

    @Test("A dangling in-bounds reference still renders the Missing placeholder, not Blocked")
    func rendererKeepsMissingDistinctFromBlocked() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }

        let styled = MarkdownBridge.parse(markdown: "![](assets/gone.png)",
                                          assetStore: fx.assetStore(for: fx.itemA))
        #expect(attachments(in: styled).first?.placeholder == .missing)
    }

    @Test("The two placeholders are visually distinct (the refusal is actually legible on screen)")
    func placeholdersDrawDifferently() {
        let missing = InlineImageAttachment(relativePath: "assets/x.png", placeholder: .missing)
        let blocked = InlineImageAttachment(relativePath: "assets/x.png", placeholder: .outOfBounds)
        let missingPixels = missing.image?.tiffRepresentation
        let blockedPixels = blocked.image?.tiffRepresentation
        #expect(missingPixels != nil)
        #expect(blockedPixels != nil)
        #expect(missingPixels != blockedPixels)
    }

    // MARK: - The copy / extract seam (provenance)

    @Test("A passage snapshot embeds no bytes for a refused reference — provenance stays clean")
    func passageSnapshotSkipsRefusedBytes() throws {
        let fx = try TwoItemStore()
        defer { fx.cleanup() }
        let png = onePixelPNG()
        try fx.write(png, named: "private.png", into: fx.itemB)
        try fx.write(png, named: "own.png", into: fx.itemA)

        let escape = fx.escapeFromAToB("private.png")
        let assetStore = fx.assetStore(for: fx.itemA)
        let rendered = MarkdownBridge.parse(markdown: "![](assets/own.png)\n\n![](\(escape))",
                                            assetStore: assetStore)
        let source = EditorPassageSource(
            sourceNoteId: fx.itemA, sourceTitle: "A", sourceDateDisplay: "1980",
            rendered: rendered, selectedRanges: [NSRange(location: 0, length: rendered.length)],
            assetBytes: { assetStore.resolveAsset($0).flatMap { try? Data(contentsOf: $0) } })

        let (markdown, assets) = source.snapshotMarkdown(
            in: NSRange(location: 0, length: rendered.length))

        // Both references survive in the snapshot text — nothing is silently rewritten …
        #expect(markdown.contains("![](assets/own.png)"))
        #expect(markdown.contains("![](\(escape))"))
        // … but only the item's OWN bytes are carried, so a paste into a third item cannot import
        // item B's file under the bare name `private.png`.
        #expect(assets["own.png"] == png)
        #expect(assets["private.png"] == nil)
        #expect(assets.count == 1)
    }
}
