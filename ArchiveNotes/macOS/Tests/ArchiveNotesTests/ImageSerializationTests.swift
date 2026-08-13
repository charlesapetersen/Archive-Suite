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

    // MARK: - W3.notes-image-dest-paren — the destination half of the same grammar

    /// The filed bug, measured. The destination group was `[^)]+`, so it stopped at the first `)`:
    /// the path came back truncated to `assets/photo (1` **and** the tail `.png)` re-serialized as a
    /// new body line — prose the operator never typed.
    @Test("A parenthesis in the path keeps the whole reference and spills no prose")
    func parenthesisedPathKeepsItsWholeReference() {
        let parsed = MarkdownBridge.parse(markdown: "![p](assets/photo (1).png)", fontSize: 14)

        var relPath: String?
        parsed.enumerateAttribute(.noteImageRelPath,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let p = val as? String { relPath = p }
        }
        #expect(relPath == "assets/photo (1).png",
                "the destination was truncated at the first ')': \(relPath ?? "nil")")

        let serialized = MarkdownBridge.serialize(parsed)
        #expect(serialized.contains("![p](<assets/photo (1).png>)"),
                "the reference was not re-emitted in the angle form: \(serialized.debugDescription)")
        #expect(!serialized.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n"),
                "the tail of the path became a body line: \(serialized.debugDescription)")
    }

    /// Self-healing has to CONVERGE. The lenient bare reading is re-emitted in CommonMark's angle
    /// form, and that form has to survive unchanged — otherwise every save rewrites the note again.
    /// Pre-fix, two saves produced two different files, which is what made the truncation corrupting
    /// rather than merely lossy. Three round-trips, because a one-shot comparison cannot see drift.
    @Test("A parenthesised path is a fixed point after the first save")
    func parenthesisedPathIsAFixedPoint() {
        let first = MarkdownBridge.serialize(
            MarkdownBridge.parse(markdown: "![p](assets/photo (1).png)", fontSize: 14))
        let second = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: first, fontSize: 14))
        let third = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: second, fontSize: 14))

        #expect(first == second,
                "save 2 changed the line: \(first.debugDescription) → \(second.debugDescription)")
        #expect(second == third,
                "save 3 changed the line: \(second.debugDescription) → \(third.debugDescription)")
    }

    /// The latent divergence the same fix closes: CommonMark forbids a space in a bare destination,
    /// so a path with one was readable here and broken in every other Markdown viewer. We still READ
    /// the bare form — that is what lets a hand-edited note heal — but we no longer WRITE it.
    @Test("A path with a space is written in CommonMark's angle-bracket form")
    func spacedPathIsWrittenInAngleBrackets() {
        let serialized = MarkdownBridge.serialize(
            MarkdownBridge.parse(markdown: "![a](assets/two words.png)", fontSize: 14))
        #expect(serialized.contains("![a](<assets/two words.png>)"),
                "a space still went out bare: \(serialized.debugDescription)")
    }

    /// The balanced-parenthesis rule has to stop at the reference's OWN closing paren. If it ran to
    /// the last `)` on the line instead, this pair would merge into one reference, the prose between
    /// them would be absorbed and one asset orphaned — the failure shape of
    /// `W3.notes-image-label-trailing-backslash`, relocated to the destination.
    @Test("Two references on one line stay two when the first path has parentheses")
    func balancedDestinationDoesNotSwallowTheNextReference() {
        let serialized = MarkdownBridge.serialize(
            MarkdownBridge.parse(markdown: "![a](assets/x (1).png) and ![b](assets/y.png)",
                                 fontSize: 14))
        #expect(serialized.contains("![a](<assets/x (1).png>)"), "\(serialized)")
        #expect(serialized.contains("![b](assets/y.png)"), "\(serialized)")
        #expect(serialized.contains(" and "),
                "the prose between the two references was absorbed: \(serialized.debugDescription)")
    }

    /// The over-fix guard: an ordinary path is written exactly as before, no angle brackets. Passes
    /// against both versions on purpose — it constrains the fix rather than proving it.
    @Test("An ordinary path is not angle-bracketed")
    func ordinaryPathIsNotAngleBracketed() {
        let serialized = MarkdownBridge.serialize(
            MarkdownBridge.parse(markdown: "![a](assets/p1-thumb.png)", fontSize: 14))
        #expect(serialized.contains("![a](assets/p1-thumb.png)"))
        #expect(!serialized.contains("<"))
    }

    /// `decodeDestination` must be a true inverse of `destination` — the same requirement the alt
    /// text's escape pair carries, and for the same reason: a decoder that is not an inverse changes
    /// the path on every save. Pathological inputs, so the angle branch and its escapes are covered.
    @Test("Every destination spelling round-trips through decode")
    func destinationSpellingsRoundTrip() {
        for path in ["assets/p1.png", "assets/photo (1).png", "assets/two words.png",
                     "assets/a<b>.png", #"assets/back\slash.png"#, #"assets/a\.png"#,
                     "assets/unbalanced(.png", "assets/)leading.png", "assets/tab\there.png",
                     "assets/(all)(balanced).png", ""] {
            let written = InlineImageMarkdown.destination(path)
            let back = InlineImageMarkdown.decodeDestination(written)
            #expect(back == path,
                    "\(path.debugDescription) → \(written.debugDescription) → \(back.debugDescription)")
        }
    }

    // MARK: - W3.notes-image-label-trailing-backslash — a KEPT behaviour, pinned so it stays a choice
    //
    // A label ending in a lone `\` lets the label cross the escaped `]`, so `![a\](x) and ![b](y)` is
    // ONE reference (alt `a\](x) and ![b`, path `y`) where the pre-fu1 bracket-free pattern found two.
    // That reads like a bug and is not one: it is CommonMark's own parse, every other viewer agrees,
    // and the app cannot produce the input — `escapeAlt` doubles a backslash. Refusing a lone trailing
    // backslash would be one line and a divergence from the spec the emitter now conforms to, so the
    // behaviour is KEPT. These two tests are what make that a decision rather than an accident: the
    // first fails if someone "fixes" the reading, the second fails if the emitter ever starts writing
    // the input that reaches it.

    /// The kept reading, pinned in FULL: not just "one reference" but *which* one — the label crosses
    /// the escaped `]` and swallows `](x) and ![b`, which is where the prose goes and why `x` is
    /// orphaned. Asserting only the count would let a different wrong parse through.
    @Test("A label ending in a lone backslash reads as CommonMark reads it: one reference")
    func loneTrailingBackslashLabelIsOneReferenceByDesign() {
        let parsed = MarkdownBridge.parse(markdown: #"![a\](x) and ![b](y)"#, fontSize: 14)
        var paths: [String] = []
        var alts: [String] = []
        parsed.enumerateAttribute(.noteImageRelPath,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let p = val as? String { paths.append(p) }
        }
        parsed.enumerateAttribute(.attachment,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let a = val as? InlineImageAttachment { alts.append(a.altText) }
        }
        #expect(paths == ["y"],
                """
                The label-crossing reading changed. It is a deliberate CommonMark conformance, not a \
                bug — read W3.notes-image-label-trailing-backslash before changing it. Got: \(paths)
                """)
        #expect(alts == [#"a](x) and ![b"#],
                "the swallowed prose is the damage this item declines to fix; it moved: \(alts)")
    }

    /// Why the above is affordable: the emitter can never write a label ending in a lone backslash, so
    /// the merge is reachable only by hand-editing raw markdown. A `display` ending in `\` round-trips.
    @Test("An alt text ending in a backslash is emitted doubled, and round-trips as two references")
    func emitterCannotWriteALoneTrailingBackslashLabel() {
        let emitted = InlineImageMarkdown.emit(alt: #"a\"#, path: "x")
        #expect(emitted == #"![a\\](x)"#, "the emitter stopped doubling the backslash: \(emitted)")

        let line = emitted + " and " + InlineImageMarkdown.emit(alt: "b", path: "y")
        let parsed = MarkdownBridge.parse(markdown: line, fontSize: 14)
        var paths: [String] = []
        parsed.enumerateAttribute(.noteImageRelPath,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let p = val as? String { paths.append(p) }
        }
        #expect(paths == ["x", "y"], "the emitted pair did not read back as two references: \(paths)")

        let serialized = MarkdownBridge.serialize(parsed)
        #expect(serialized.contains(#"![a\\](x)"#), "\(serialized.debugDescription)")
        #expect(serialized.contains("![b](y)"), "\(serialized.debugDescription)")
        #expect(serialized.contains(" and "),
                "the prose between the two references was absorbed: \(serialized.debugDescription)")
    }

    /// An unbalanced `(` in the path is not a reference at all — CommonMark's reading, and the safe
    /// one: it stays the operator's own text instead of matching a truncated path and re-emitting a
    /// line they never wrote.
    @Test("An unterminated parenthesis in the path reads as prose, not as a truncated reference")
    func unterminatedParenthesisIsNotAReference() {
        let parsed = MarkdownBridge.parse(markdown: "![a](assets/x (1.png)", fontSize: 14)
        var relPath: String?
        parsed.enumerateAttribute(.noteImageRelPath,
                                  in: NSRange(location: 0, length: parsed.length)) { val, _, _ in
            if let p = val as? String { relPath = p }
        }
        #expect(relPath == nil, "it matched a truncated destination: \(relPath ?? "nil")")
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
