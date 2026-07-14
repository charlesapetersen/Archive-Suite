import Testing
import Foundation
@testable import ArchiveNotes

/// W8-S1 §1.1 (block-header slice) — the §6 `<!-- block: … -->` grammar at the storage layer
/// (`BlockParser`). Complements `BlockParserTests` (W2-S1) and `BlockChipTests` (editor layer)
/// by pinning every block KIND round-trips, unrecognized header fields survive verbatim, and the
/// two graceful-degradation rules (headerless body; malformed header) behave as §6 specifies.
@Suite("BlockHeaderTests — W8-S1 §6 block-header grammar")
struct BlockHeaderTests {

    /// A representative source anchor per kind (freeform carries none).
    private func anchor(for kind: Block.Kind) -> SourceAnchor? {
        switch kind {
        case .freeform:
            return nil
        case .readerPage:
            return SourceAnchor(link: "archivereader://reveal?root=G&rel=doc.pdf&page=3",
                                display: "Some Doc", page: 3, thumbRef: "assets/p3-thumb.png")
        case .readerDoc:
            return SourceAnchor(link: "archivereader://reveal?root=G&rel=doc.pdf", display: "Some Doc")
        case .zoteroItem:
            return SourceAnchor(display: "Lovelace 1843",
                                zoteroSelect: "zotero://select/library/items/ABCD1234")
        case .zoteroAttachment:
            return SourceAnchor(display: "Scan.pdf",
                                zoteroSelect: "zotero://select/library/items/EFGH5678")
        case .notePassage:
            return SourceAnchor(display: "Source Note",
                                noteRef: "archivenotes://open?id=11111111-2222-3333-4444-555555555555#block-2")
        }
    }

    /// Every block kind survives serialize → parse identically (kind, source, markdown).
    @Test
    func everyBlockKindRoundTrips() {
        let kinds: [Block.Kind] = [.freeform, .readerPage, .readerDoc,
                                   .zoteroItem, .zoteroAttachment, .notePassage]
        for kind in kinds {
            let original = Block(kind: kind, source: anchor(for: kind),
                                 markdown: "Body for \(kind.rawValue).\n",
                                 unknownHeaderFields: [])
            let body = BlockParser.serialize(leadingText: nil, blocks: [original])
            let (leading, blocks) = BlockParser.parse(body)
            #expect(leading == nil, "\(kind.rawValue): unexpected leading text")
            #expect(blocks.count == 1, "\(kind.rawValue): expected exactly one block")
            #expect(blocks.first == original, "\(kind.rawValue): block not preserved")
        }
    }

    /// Unrecognized header fields are preserved verbatim (key + value, in order) through a round-trip.
    @Test
    func unrecognizedHeaderFieldsPreservedVerbatim() {
        let original = Block(
            kind: .readerPage,
            source: SourceAnchor(link: "archivereader://reveal?root=G&rel=d.pdf", display: "Doc"),
            markdown: "Body.\n",
            unknownHeaderFields: [("future_field", "value-one"), ("vendor_x", "value-two")]
        )
        let body = BlockParser.serialize(leadingText: nil, blocks: [original])
        let (_, blocks) = BlockParser.parse(body)
        #expect(blocks.count == 1)
        let round = blocks.first?.unknownHeaderFields ?? []
        #expect(round.count == 2)
        #expect(round.first?.0 == "future_field" && round.first?.1 == "value-one")
        #expect(round.last?.0 == "vendor_x" && round.last?.1 == "value-two")
    }

    /// §6 graceful degradation: a body region with NO block header is a single implicit freeform
    /// region — the storage layer represents it as leading text with zero explicit blocks, and it
    /// round-trips byte-for-byte. ("Single freeform block" in the plan == this one unattributed region.)
    @Test
    func headerlessBodyIsSingleFreeformRegion() {
        let body = "Just some prose.\n\nNo block headers here at all.\n"
        let (leading, blocks) = BlockParser.parse(body)
        #expect(leading == body)
        #expect(blocks.isEmpty)
        #expect(BlockParser.serialize(leadingText: leading, blocks: blocks) == body)
    }

    /// §6 graceful degradation: a header opener with no closing `-->` never crashes and never drops
    /// text — the segment degrades to a freeform block whose markdown is the raw (unclosed) content.
    @Test
    func malformedHeaderDegradesToFreeform() {
        let body = "<!-- block: reader-page\n     link: x\nsome text and no close marker"
        let (leading, blocks) = BlockParser.parse(body)
        #expect(leading == nil)
        #expect(blocks.count == 1)
        #expect(blocks.first?.kind == .freeform)
        #expect(blocks.first?.source == nil)
        #expect(blocks.first?.markdown == body)  // text preserved verbatim
    }

    /// Pin the on-disk §6 wire format itself (not just serialize∘parse agreement): hand-written
    /// canonical header strings for the two most-used kinds parse into the right kind + fields.
    @Test
    func canonicalGrammarStringsParse() {
        let body = """
        Intro line.
        <!-- block: reader-page
             link: archivereader://reveal?root=G&rel=d.pdf&page=7
             display: "Page Seven"
             page: 7 -->
        A quoted passage.
        <!-- block: note-passage
             note: archivenotes://open?id=abcdef00-0000-0000-0000-000000000000#block-1
             display: "Origin" -->
        The extracted text.
        """
        let (leading, blocks) = BlockParser.parse(body)
        #expect(leading == "Intro line.\n")
        #expect(blocks.count == 2)
        #expect(blocks.first?.kind == .readerPage)
        #expect(blocks.first?.source?.page == 7)
        #expect(blocks.first?.source?.display == "Page Seven")
        #expect(blocks.last?.kind == .notePassage)
        #expect(blocks.last?.source?.noteRef?.contains("#block-1") == true)
    }
}
