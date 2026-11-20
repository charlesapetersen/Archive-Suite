import Testing
import AppKit
@testable import ArchiveNotes

/// W49.notes-suspects-text — the reproduce attempts for suspects S-019, S-020 and S-009 (phase rule 5a), and
/// W49.notes-s043-reproduce's for S-043: each
/// runs the user's own path on scratch data. A note file is written to a scratch `NoteStore` the way a cut-off
/// or hand-edited file arrives, loaded, rendered into a real `EditorTextView` as the editor renders it, edited
/// through the text view's own editing calls, saved with `saveBody` and loaded again.
///
/// S-019 and S-009 reproduced on 2026-11-20, so their checks are known issues: the run stays green while the defect is
/// there and fails once it is gone, when the fix removes the `withKnownIssue`. Phase rule 5a(4): a second session on
/// another model checks each reproduction before a fix item is filed (`W49.notes-suspects-text-check`).
@Suite("Notes text-loss suspects — reproduce attempts (W49.notes-suspects-text)")
@MainActor
struct NotesTextLossSuspectTests {
    /// A block header cut off before its `-->`: §6 degrades it to a headerless freeform block.
    private static let degradedBody = "<!-- block: reader-doc\n     link: archivereader://reveal?rel=a.pdf\n"

    private func scratchStore() throws -> (NoteStore, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesTextLossSuspectTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (NoteStore(root: tmp), tmp)
    }

    private func blankItem() -> Item {
        Item(id: UUID(), kind: .note, title: "Degraded", date: nil, datePrecision: nil, dateUncertain: false,
             quality: nil, tags: [], zotero: [], roundup: false, created: Date(), modified: Date(), schema: 1,
             blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
    }

    /// Writes a note whose body on disk is `body`, appended by hand after the front matter, and returns its id.
    private func writeNote(_ body: String, in store: NoteStore) async throws -> UUID {
        let item = blankItem()
        _ = try await store.create(item)
        let url = try await store.mdURL(for: item.id)
        let raw = try String(contentsOf: url, encoding: .utf8)
        try (raw + body).write(to: url, atomically: true, encoding: .utf8)
        return item.id
    }

    private func loadedBody(_ id: UUID, in store: NoteStore) async throws -> String {
        let item = try await store.load(id)
        return BlockParser.serialize(leadingText: item.trailingBodyRaw, blocks: item.blocks)
    }

    /// The editor's styled text view holding the note as loaded, caret at the end.
    private func editor(showing body: String) throws -> (EditorTextView, NSTextStorage) {
        let tv = EditorTextView()
        let storage = try #require(tv.textStorage)
        storage.setAttributedString(MarkdownBridge.parse(markdown: body))
        tv.setSelectedRange(NSRange(location: storage.length, length: 0))
        return (tv, storage)
    }

    // MARK: - S-019

    /// S-019: typing prose and then a line holding `-->` after an unclosed header, saving and reopening.
    /// `returnFirst`: the user presses Return before typing, so the prose has a line of its own.
    @Test("S-019: typed prose after an unclosed header survives a typed --> and a reopen",
          arguments: [false, true])
    func s019TypedCloserAfterUnclosedHeader(returnFirst: Bool) async throws {
        let (store, tmp) = try scratchStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let id = try await writeNote(Self.degradedBody, in: store)
        let before = try await loadedBody(id, in: store)
        let (tv, storage) = try editor(showing: before)
        if returnFirst { tv.insertNewline(nil) }
        tv.insertText("Some prose", replacementRange: tv.selectedRange())
        tv.insertNewline(nil)
        tv.insertText("A --> B", replacementRange: tv.selectedRange())
        let saved = MarkdownBridge.serialize(storage)
        _ = try await store.saveBody(saved, basedOn: before, for: id)

        let reopened = try await store.load(id)
        let text = ([reopened.trailingBodyRaw ?? ""] + reopened.blocks.map(\.markdown)).joined()
        let onDisk = try String(contentsOf: await store.mdURL(for: id), encoding: .utf8)
        withKnownIssue("S-019: the typed --> closes the unclosed header, and the prose before it leaves the text") {
            #expect(text.contains("Some prose"), "the typed line is gone after the reopen; the file holds:\n\(onDisk)")
        }
    }

    // MARK: - S-043

    /// S-043 (W49.notes-s043-reproduce): the S-019 run without `-->`. The user types at the end of the loaded
    /// degraded note with no Return first, saves and reopens. Cleared 2026-11-20: the join is real, but the editor
    /// shows it before the save. The opener is ordinary visible text whose trailing newline is dropped on load
    /// (`MarkdownBridge.dropRawHTMLLineEnd`), so the caret stands at the end of the `link:` line and the typed text
    /// appears on it; the file and the reopened note hold exactly what the editor showed, and nothing is lost.
    @Test("S-043: text typed at the end of a degraded note is saved and reopened as the editor showed it")
    func s043TypedTextAfterUnclosedHeader() async throws {
        let (store, tmp) = try scratchStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let id = try await writeNote(Self.degradedBody, in: store)
        let before = try await loadedBody(id, in: store)
        let (tv, storage) = try editor(showing: before)
        // Before typing: the caret is on the `link:` line, not on a new line after it.
        #expect(storage.string.hasSuffix("link: archivereader://reveal?rel=a.pdf"), "\(storage.string.debugDescription)")
        tv.insertText("Some prose", replacementRange: tv.selectedRange())
        let shown = storage.string
        let lastLine = shown.components(separatedBy: "\n").last ?? ""
        #expect(lastLine == "     link: archivereader://reveal?rel=a.pdfSome prose", "the editor shows \(shown.debugDescription)")
        // The opener is drawn like the typed text: the system text colour at the body size, nothing hidden.
        let ns = shown as NSString
        let opener = storage.attributes(at: ns.range(of: "link:").location, effectiveRange: nil)
        let typed = storage.attributes(at: ns.range(of: "Some prose").location, effectiveRange: nil)
        #expect(opener[.foregroundColor] as? NSColor == typed[.foregroundColor] as? NSColor)
        #expect((opener[.font] as? NSFont)?.pointSize == (typed[.font] as? NSFont)?.pointSize)
        #expect(((opener[.font] as? NSFont)?.pointSize ?? 0) >= 10)

        let saved = MarkdownBridge.serialize(storage)
        _ = try await store.saveBody(saved, basedOn: before, for: id)
        let onDisk = try String(contentsOf: await store.mdURL(for: id), encoding: .utf8)
        #expect(onDisk.hasSuffix("<!-- block: reader-doc\n     link: archivereader://reveal?rel=a.pdfSome prose"),
                "\(onDisk.debugDescription)")
        // Reopened, the note shows what the editor showed before the save, typed text included.
        let reopened = try await store.load(id)
        let (_, again) = try editor(showing: BlockParser.serialize(leadingText: reopened.trailingBodyRaw,
                                                                   blocks: reopened.blocks))
        #expect(again.string == shown, "reopened as \(again.string.debugDescription)")
    }

    // MARK: - S-020

    /// S-020: select all of a note holding a degraded block and make an extract of it.
    @Test("S-020: an extract of a degraded block keeps its text inside the passage")
    func s020ExtractOfDegradedBlock() async throws {
        let (store, tmp) = try scratchStore(); defer { try? FileManager.default.removeItem(at: tmp) }
        let id = try await writeNote("Intro line.\n\n" + Self.degradedBody + "Quoted prose.\n", in: store)
        let body = try await loadedBody(id, in: store)
        let (_, storage) = try editor(showing: body)
        let source = EditorPassageSource(
            sourceNoteId: id, sourceTitle: "Degraded", sourceDateDisplay: "",
            rendered: storage, selectedRanges: [NSRange(location: 0, length: storage.length)],
            assetBytes: { _ in nil })
        let created = try await ExtractBuilder(store: store).createExtract(fromSelectionIn: source)

        let extract = try await store.load(created.id)
        let onDisk = try String(contentsOf: await store.mdURL(for: created.id), encoding: .utf8)
        #expect(extract.trailingBodyRaw == nil, "text outside any passage: \(extract.trailingBodyRaw ?? "")")
        #expect(extract.blocks.allSatisfy { $0.kind == .notePassage && $0.source?.notePassageTarget != nil },
                "a block of the extract has no passage source:\n\(onDisk)")
        let passageText = extract.blocks.map(\.markdown).joined()
        #expect(passageText.contains("Quoted prose."), "the degraded block's text left its passage:\n\(onDisk)")
        #expect(passageText.contains("Intro line."))
    }

    // MARK: - S-009

    /// S-009: ⌘V of an image while the editor is in raw mode.
    @Test("S-009: pasting an image in raw mode writes no orphan asset and no U+FFFC into the note")
    func s009RawModeImagePaste() throws {
        let assets = ScratchAssetStore()
        defer { try? FileManager.default.removeItem(at: assets.root) }
        let tv = EditorTextView()
        tv.assetStore = assets
        tv.applyRawMode(true, fontSize: 13)
        tv.string = "Raw body\n"
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(image.representation(using: .png, properties: [:]))
        let pb = NSPasteboard.general
        defer { pb.clearContents() }
        pb.clearContents()
        pb.setData(png, forType: .png)
        tv.paste(nil)

        // Raw mode's write-back is the text view's string (`MarkdownEditorView.currentSerialization`).
        let written = tv.string
        let dir = assets.root.appendingPathComponent("assets")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let orphan = !files.isEmpty && !written.contains("](assets/")
        withKnownIssue("S-009: raw mode inserts an image attachment, which raw write-back saves as U+FFFC") {
            #expect(!orphan, "an asset was written that the note does not reference: \(files)")
            #expect(!written.unicodeScalars.contains("\u{FFFC}"), "the note gained U+FFFC: \(written.debugDescription)")
        }
    }
}
