import XCTest
import AppKit
@testable import ArchiveNotes
import ArchiveCore

/// W7-S2 — the `com.archivenotes.passage` pasteboard codec (copy-in-Notes → paste-into-Extract, §5),
/// plus the payload → passage-blocks bridge and the extract-references-notes-only coercion the paste
/// branch keys off. Pure/pasteboard-only (no live editor, no file writes) — Tier-1.
final class PasteboardPassageTests: XCTestCase {

    // MARK: - Fixtures

    /// A two-segment payload from one source note, the second segment carrying an inline-image byte
    /// blob so we exercise the asset round-trip through JSON.
    private func samplePayload(
        id: UUID = UUID(uuidString: "7F3A9C21-4B2E-4D1A-9C33-8E5F0A1B2C3D")!
    ) -> NotesPassagePayload {
        NotesPassagePayload(
            sourceNoteId: id,
            sourceTitle: "Moore on Intel culture",
            sourceDateDisplay: "1968",
            segments: [
                .init(sourceBlockIndex: 2,
                      markdown: "Moore says he and Noyce were **responsible** for the early culture."),
                .init(sourceBlockIndex: 5,
                      markdown: "![fig](assets/fig-1.png)\nAnd the photo above.",
                      assetPNGs: ["fig-1.png": Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])])
            ]
        )
    }

    private func namedPasteboard(_ tag: String) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("test-passage-\(tag)-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    // MARK: - Round-trip (write → read)

    @MainActor
    func testWriteThenReadRoundTrip() {
        let pb = namedPasteboard("roundtrip")
        let payload = samplePayload()

        XCTAssertTrue(PassagePasteboard.write(payload, to: pb))

        let read = PassagePasteboard.read(from: pb)
        XCTAssertEqual(read, payload, "Payload should survive a pasteboard round-trip unchanged")
    }

    @MainActor
    func testWriteRoundTripPreservesAssetBytes() {
        let pb = namedPasteboard("assets")
        let payload = samplePayload()

        PassagePasteboard.write(payload, to: pb)
        let read = try? XCTUnwrap(PassagePasteboard.read(from: pb))

        XCTAssertEqual(read?.segments[1].assetPNGs["fig-1.png"],
                       Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03]),
                       "Inline-image bytes must survive the JSON round-trip (snapshot independence)")
    }

    // MARK: - Multi-representation

    @MainActor
    func testWriteSetsPlainTextFallback() {
        let pb = namedPasteboard("plain")
        PassagePasteboard.write(samplePayload(), to: pb)

        let expected = """
        Moore says he and Noyce were **responsible** for the early culture.

        ![fig](assets/fig-1.png)
        And the photo above.
        """
        XCTAssertEqual(pb.string(forType: .string), expected,
                       "External apps (no passage UTI) should receive the segments' Markdown, paragraph-separated")
    }

    @MainActor
    func testPlainTextSkipsEmptySegments() {
        let payload = NotesPassagePayload(
            sourceNoteId: UUID(), sourceTitle: "T", sourceDateDisplay: "",
            segments: [
                .init(sourceBlockIndex: 0, markdown: "\n\n"),
                .init(sourceBlockIndex: 1, markdown: "Real text.")
            ])
        XCTAssertEqual(PassagePasteboard.plainText(for: payload), "Real text.")
    }

    // MARK: - Read precedence / degradation

    @MainActor
    func testReadPrefersPassageUTIWhenBothPresent() {
        let pb = namedPasteboard("prefer")
        PassagePasteboard.write(samplePayload(), to: pb)
        // Both the custom UTI and .string are present; read must return the rich payload.
        XCTAssertNotNil(PassagePasteboard.read(from: pb))
        XCTAssertTrue(PassagePasteboard.hasPassage(pb))
    }

    @MainActor
    func testReadReturnsNilForPlainTextOnly() {
        let pb = namedPasteboard("textonly")
        pb.setString("Just some copied text with no provenance.", forType: .string)

        XCTAssertNil(PassagePasteboard.read(from: pb),
                     "A plain-text paste carries no passage → nil (caller inserts a freeform block)")
        XCTAssertFalse(PassagePasteboard.hasPassage(pb))
    }

    @MainActor
    func testReadReturnsNilForMalformedPayload() {
        let pb = namedPasteboard("malformed")
        let item = NSPasteboardItem()
        item.setData(Data("not json".utf8), forType: PassagePasteboard.type)
        pb.writeObjects([item])

        // hasPassage sees the type, but a tolerant decode must yield nil (never a crash, §Risks).
        XCTAssertTrue(PassagePasteboard.hasPassage(pb))
        XCTAssertNil(PassagePasteboard.read(from: pb))
    }

    @MainActor
    func testReadReturnsNilForEmptyPasteboard() {
        let pb = namedPasteboard("empty")
        XCTAssertNil(PassagePasteboard.read(from: pb))
        XCTAssertFalse(PassagePasteboard.hasPassage(pb))
    }

    // MARK: - Paste bridge: payload → passage blocks (what the extract editor inserts)

    @MainActor
    func testPasteboardPayloadBuildsNotePassageBlocks() throws {
        let pb = namedPasteboard("bridge")
        let id = UUID(uuidString: "B1D4E0F7-1111-2222-3333-444455556666")!
        PassagePasteboard.write(samplePayload(id: id), to: pb)

        let payload = try XCTUnwrap(PassagePasteboard.read(from: pb))
        let passages = ExtractBuilder.passageBlocks(from: payload)

        XCTAssertEqual(passages.count, 2)
        XCTAssertTrue(passages.allSatisfy { $0.block.kind == .notePassage })

        // Each block anchors back to the right source note + block ordinal (§8.2 canonical URL).
        XCTAssertEqual(passages[0].block.source?.notePassageTarget?.id, id)
        XCTAssertEqual(passages[0].block.source?.notePassageTarget?.block, 2)
        XCTAssertEqual(passages[1].block.source?.notePassageTarget?.block, 5)

        // The provenance label carries the snapshot title + date.
        XCTAssertEqual(passages[0].block.source?.display, "Moore on Intel culture — 1968")
        // Inline-image bytes ride along for the store to copy into the extract's own assets/.
        XCTAssertEqual(passages[1].pendingAssets["fig-1.png"]?.count, 7)
    }

    // MARK: - Extract-references-notes-only invariant (the paste-branch coercion, §5)

    func testCoercionKeepsWellFormedPassageBlocks() {
        let payload = samplePayload()
        let blocks = ExtractBuilder.passageBlocks(from: payload).map { $0.block }
        let coerced = ExtractBuilder.coercedToNotesOnly(blocks)

        XCTAssertEqual(coerced, blocks, "Well-formed note-passage blocks pass coercion unchanged")
        XCTAssertTrue(coerced.allSatisfy { $0.kind == .notePassage && $0.source?.notePassageTarget != nil })
    }

    func testCoercionDropsReaderSourceToFreeform() {
        // A pasteboard that ALSO carried a Reader archive link must not attach an outside-doc source
        // to an extract: coercion strips it to freeform text (extracts reference NOTES only, §D7).
        let readerBlock = Block(
            kind: .readerPage,
            source: SourceAnchor(link: "archivereader://reveal?root=X&rel=a.pdf&page=1",
                                 display: "A doc — p. 1", page: 1),
            markdown: "Some pasted reader text.",
            unknownHeaderFields: [])
        let coerced = ExtractBuilder.coercedToNotesOnly([readerBlock])

        XCTAssertEqual(coerced.count, 1)
        XCTAssertEqual(coerced[0].kind, .freeform)
        XCTAssertNil(coerced[0].source, "Non-note source must be stripped")
        XCTAssertEqual(coerced[0].markdown, "Some pasted reader text.", "Text is preserved")
    }

    func testCoercionDropsMalformedNotePassageToFreeform() {
        // A note-passage block whose noteRef doesn't parse (garbage target) coerces to freeform.
        let broken = Block(
            kind: .notePassage,
            source: SourceAnchor(display: "Broken", noteRef: "not-a-url"),
            markdown: "Text.",
            unknownHeaderFields: [])
        let coerced = ExtractBuilder.coercedToNotesOnly([broken])
        XCTAssertEqual(coerced[0].kind, .freeform)
        XCTAssertNil(coerced[0].source)
    }

    // MARK: - Copy side: selection → payload (W7-S2 (d))

    @MainActor
    func testPassagePayloadFromSelectionBuildsSegments() throws {
        let nid = UUID()
        // Selection spans two blocks (§Algorithm: one segment per covered source block).
        let src = FakeSelectionSource(sourceNoteId: nid, sourceTitle: "Src", sourceDateDisplay: "1968",
                                      fullText: "AAAA\nBBBB\n",
                                      selectedRanges: [NSRange(location: 2, length: 6)],
                                      blockRanges: [(0, NSRange(location: 0, length: 5)),
                                                    (1, NSRange(location: 5, length: 5))])
        let payload = try XCTUnwrap(ExtractBuilder.passagePayload(fromSelectionIn: src))
        XCTAssertEqual(payload.sourceNoteId, nid)
        XCTAssertEqual(payload.sourceTitle, "Src")
        XCTAssertEqual(payload.segments.map(\.sourceBlockIndex), [0, 1])
    }

    @MainActor
    func testPassagePayloadEmptySelectionIsNil() {
        let src = FakeSelectionSource(fullText: "abc",
                                      selectedRanges: [NSRange(location: 0, length: 0)],
                                      blockRanges: [(0, NSRange(location: 0, length: 3))])
        XCTAssertNil(ExtractBuilder.passagePayload(fromSelectionIn: src))
    }

    /// A note selection round-trips copy → paste: `passagePayload` → pasteboard → `pastedExtractMarkdown`
    /// reparses to the same note-passage blocks (the full (d)→(e) provenance-preserving round-trip).
    @MainActor
    func testCopyPastePayloadRoundTripPreservesProvenance() throws {
        let pb = namedPasteboard("copypaste")
        let nid = UUID()
        let src = FakeSelectionSource(sourceNoteId: nid, sourceTitle: "Src", sourceDateDisplay: "1968",
                                      fullText: "Hello there",
                                      selectedRanges: [NSRange(location: 0, length: 5)],
                                      blockRanges: [(4, NSRange(location: 0, length: 11))])
        let payload = try XCTUnwrap(ExtractBuilder.passagePayload(fromSelectionIn: src))
        XCTAssertTrue(PassagePasteboard.write(payload, to: pb))

        let read = try XCTUnwrap(PassagePasteboard.read(from: pb))
        let (_, blocks) = BlockParser.parse(ExtractBuilder.pastedExtractMarkdown(from: read))
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .notePassage)
        XCTAssertEqual(blocks[0].source?.notePassageTarget?.id, nid)
        XCTAssertEqual(blocks[0].source?.notePassageTarget?.block, 4)
    }

    // MARK: - Paste side: payload → insertable markdown (W7-S2 (e))

    func testPastedExtractMarkdownReparsesToNotePassageBlocks() {
        let markdown = ExtractBuilder.pastedExtractMarkdown(from: samplePayload())
        let (_, blocks) = BlockParser.parse(markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.allSatisfy { $0.kind == .notePassage })
        XCTAssertEqual(blocks[0].source?.notePassageTarget?.block, 2)
        XCTAssertEqual(blocks[1].source?.notePassageTarget?.block, 5)
    }

    func testPastedExtractMarkdownEmptyPayloadIsEmpty() {
        let payload = NotesPassagePayload(sourceNoteId: UUID(), sourceTitle: "T",
                                          sourceDateDisplay: "", segments: [])
        XCTAssertEqual(ExtractBuilder.pastedExtractMarkdown(from: payload), "")
    }

    // MARK: - Multi-representation: system RTF (W7-S2 (d))

    @MainActor
    func testWriteWithRTFIncludesAllThreeRepresentations() throws {
        let pb = namedPasteboard("rtf")
        let styled = NSAttributedString(string: "Hello", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let rtf = try styled.data(from: NSRange(location: 0, length: styled.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertTrue(PassagePasteboard.write(samplePayload(), rtf: rtf, to: pb))
        XCTAssertNotNil(pb.data(forType: .rtf), "system RTF representation present")
        XCTAssertNotNil(pb.string(forType: .string), "plain-text fallback present")
        XCTAssertNotNil(PassagePasteboard.read(from: pb), "passage payload still readable alongside RTF")
    }
}
