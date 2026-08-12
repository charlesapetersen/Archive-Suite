import Testing
import AppKit
@testable import ArchiveNotes

@Suite("Image serialization round-trip")
@MainActor
struct ImageSerializationTests {

    // MARK: - Attachment ↔ ![alt](path) round-trip

    @Test("Inline image attachment serializes to ![alt](path)")
    func attachmentRoundTrip() {
        let md = "Before ![photo](assets/photo.png) after"
        let parsed = MarkdownBridge.parse(markdown: md, fontSize: 14)
        let serialized = MarkdownBridge.serialize(parsed)

        #expect(serialized.contains("![photo](assets/photo.png)"))
        #expect(serialized.contains("Before"))
        #expect(serialized.contains("after"))
    }

    @Test("Missing asset preserves the relative path on round-trip")
    func missingAssetPreservesPath() {
        let md = "Text ![](assets/missing.png) more"
        let parsed = MarkdownBridge.parse(markdown: md, fontSize: 14)
        let serialized = MarkdownBridge.serialize(parsed)

        #expect(serialized.contains("![](assets/missing.png)"))
        #expect(serialized.contains("Text"))
        #expect(serialized.contains("more"))
    }

    @Test("Multiple images in one paragraph preserve all paths")
    func multipleImagesPreservePaths() {
        let md = "![a](assets/1.png) and ![b](assets/2.png)"
        let parsed = MarkdownBridge.parse(markdown: md, fontSize: 14)
        let serialized = MarkdownBridge.serialize(parsed)

        #expect(serialized.contains("![a](assets/1.png)"))
        #expect(serialized.contains("![b](assets/2.png)"))
    }

    @Test("Image with empty alt text round-trips")
    func emptyAltText() {
        let md = "![](assets/pic.png)"
        let parsed = MarkdownBridge.parse(markdown: md, fontSize: 14)
        let serialized = MarkdownBridge.serialize(parsed)

        #expect(serialized.contains("![](assets/pic.png)"))
    }

    @Test("Second round-trip is a no-op for images")
    func secondRoundTripNoOp() {
        let md = "Hello ![img](assets/test.png) world"
        let first = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: md, fontSize: 14))
        let second = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: first, fontSize: 14))
        #expect(first == second)
    }

    @Test("Image alongside bold text preserves both")
    func imageWithFormatting() {
        let md = "**Bold** ![pic](assets/pic.png)"
        let parsed = MarkdownBridge.parse(markdown: md, fontSize: 14)
        let serialized = MarkdownBridge.serialize(parsed)

        #expect(serialized.contains("**Bold**"))
        #expect(serialized.contains("![pic](assets/pic.png)"))
    }

    // MARK: - Asset store integration

    @Test("Pasted image writes to scratch store, not corpus")
    func pastedImageWritesToScratchStore() throws {
        let store = ScratchAssetStore()
        // Create a minimal 1x1 PNG
        let pngData = createMinimalPNG()

        let relPath = try store.addAsset(pngData, preferredName: "pasted-test.png")
        #expect(relPath == "assets/pasted-test.png")

        // Verify file exists under scratch root, not elsewhere
        let resolved = store.resolveAsset(relPath)
        #expect(resolved != nil)
        #expect(resolved!.path.hasPrefix(store.root.path))
    }

    @Test("Scratch store disambiguates on collision")
    func scratchStoreDisambiguates() throws {
        let store = ScratchAssetStore()
        let data1 = createMinimalPNG()
        let data2 = createMinimalPNG()

        let path1 = try store.addAsset(data1, preferredName: "img.png")
        let path2 = try store.addAsset(data2, preferredName: "img.png")

        #expect(path1 != path2)
        #expect(path1 == "assets/img.png")
        #expect(path2 == "assets/img-1.png")
    }

    @Test("resolveAsset returns nil for non-existent path")
    func resolveAssetNil() {
        let store = ScratchAssetStore()
        #expect(store.resolveAsset("assets/nope.png") == nil)
    }

    // MARK: - InlineImageAttachment

    @Test("InlineImageAttachment preserves relativePath and altText")
    func attachmentPreservesMetadata() {
        let attachment = InlineImageAttachment(
            relativePath: "assets/photo.png", altText: "My photo"
        )
        #expect(attachment.relativePath == "assets/photo.png")
        #expect(attachment.altText == "My photo")
        // Missing-asset placeholder image should be set
        #expect(attachment.image != nil)
    }

    @Test("Downsample produces an image without touching the source data")
    func downsampleDoesNotTouchSource() {
        let data = createMinimalPNG()
        let original = data
        let thumb = InlineImageAttachment.downsampledThumbnail(from: data)
        #expect(thumb != nil)
        // Original data is unchanged
        #expect(data == original)
    }

    @Test("Downsample returns nil for non-image data")
    func downsampleNilForNonImage() {
        let data = Data("not an image".utf8)
        let thumb = InlineImageAttachment.downsampledThumbnail(from: data)
        #expect(thumb == nil)
    }

    @Test("Parse with asset store loads thumbnails")
    func parseWithAssetStore() throws {
        let store = ScratchAssetStore()
        let pngData = createMinimalPNG()
        let relPath = try store.addAsset(pngData, preferredName: "thumb.png")

        let md = "![](\(relPath))"
        let parsed = MarkdownBridge.parse(markdown: md, fontSize: 14, assetStore: store)

        // Should contain an attachment character
        #expect(parsed.length > 0)
        // The noteImageRelPath attribute should be set
        var found = false
        parsed.enumerateAttribute(.noteImageRelPath,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let path = val as? String, path == relPath { found = true }
        }
        #expect(found)
    }

    // MARK: - Bracketed alt text (W3.notes-thumb-line-duplicates-fu1)

    /// The bug, at the grammar level: a `]` in the alt text used to end the label early, so the line
    /// matched nothing, reloaded as prose and the reference was gone. The alt is a block's `display`,
    /// i.e. a Reader document title, and `Moore [draft]` is an ordinary one.
    @Test("An alt text containing brackets keeps its reference across a round-trip")
    func bracketedAltKeepsItsReference() {
        let parsed = MarkdownBridge.parse(markdown: "![Moore \\[draft\\]](assets/p1.png)",
                                          fontSize: 14)
        let serialized = MarkdownBridge.serialize(parsed)

        #expect(serialized.contains("![Moore \\[draft\\]](assets/p1.png)"),
                "The bracketed reference did not survive: \(serialized)")
        #expect(!serialized.contains("prose"))

        var relPath: String?
        parsed.enumerateAttribute(.noteImageRelPath,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let p = val as? String { relPath = p }
        }
        #expect(relPath == "assets/p1.png", "It parsed as prose, not as an image reference")
    }

    /// The alt text the app holds in memory is the DECODED one — the escaping belongs to the file,
    /// not to the attachment. If this drifts, the accessibility description and every future
    /// consumer of `altText` read backslashes the operator never typed.
    @Test("The attachment's alt text is decoded, not the escaped form")
    func attachmentAltTextIsDecoded() {
        let parsed = MarkdownBridge.parse(markdown: "![Moore \\[draft\\]](assets/p1.png)",
                                          fontSize: 14)
        var alt: String?
        parsed.enumerateAttribute(.attachment,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let a = val as? InlineImageAttachment { alt = a.altText }
        }
        #expect(alt == "Moore [draft]")
    }

    /// The reason the unescaper has to be a real inverse rather than a bracket-stripper: `escapeAlt`
    /// escapes the backslash itself, so a decoder that left `\\` alone would add one backslash per
    /// save. Three round-trips, because a one-shot comparison cannot see growth.
    @Test("A backslash in the alt text does not grow on repeated saves")
    func backslashInAltDoesNotGrow() {
        let first = MarkdownBridge.serialize(
            MarkdownBridge.parse(markdown: "![a\\\\b](assets/p1.png)", fontSize: 14))
        let second = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: first, fontSize: 14))
        let third = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: second, fontSize: 14))

        #expect(first == second, "Round-trip 2 changed the line: \(first) → \(second)")
        #expect(second == third, "Round-trip 3 changed the line: \(second) → \(third)")
        #expect(first.contains("![a\\\\b](assets/p1.png)"), "Lost the literal backslash: \(first)")
    }

    /// The over-fix guard: an ordinary alt gains no escaping. Passes against both versions on
    /// purpose — it constrains the fix rather than proving it.
    @Test("An ordinary alt text is not escaped")
    func ordinaryAltIsNotEscaped() {
        let serialized = MarkdownBridge.serialize(
            MarkdownBridge.parse(markdown: "![Doc (draft) p.41](assets/p1.png)", fontSize: 14))
        #expect(serialized.contains("![Doc (draft) p.41](assets/p1.png)"))
        #expect(!serialized.contains("\\"))
    }

    // MARK: - Helpers

    /// Create a minimal valid 1x1 white PNG.
    private func createMinimalPNG() -> Data {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return png
    }
}
