import Testing
@testable import ArchiveNotes

/// Pure presentation logic for the Zotero chip (label / glyph / a11y id), extracted
/// from `ZoteroChipView` so it is testable without instantiating a SwiftUI view (W5-S4).
@Suite("ZoteroChipPresentation")
struct ZoteroChipPresentationTests {

    private func ref(kind: ZoteroRefKind = .item, citation: String? = nil) -> ZoteroRef {
        ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                  itemKey: "ABCD1234", library: .user, kind: kind, citation: citation)
    }

    @Test("item with no citation → book glyph + itemKey label")
    func itemNoCitation() {
        let p = ZoteroChipPresentation(ref: ref())
        #expect(p.systemImage == "book.closed")
        #expect(p.label == "ABCD1234")
        #expect(p.accessibilityID == "ar.zotero.chip.ABCD1234")
    }

    @Test("citation used as the label when present")
    func citationLabel() {
        let p = ZoteroChipPresentation(ref: ref(citation: "Moore, Gordon E. Oral History. 2001."))
        #expect(p.label == "Moore, Gordon E. Oral History. 2001.")
    }

    @Test("attachment → paperclip glyph")
    func attachmentGlyph() {
        #expect(ZoteroChipPresentation(ref: ref(kind: .attachment)).systemImage == "paperclip")
    }

    @Test("empty citation falls back to itemKey")
    func emptyCitationFallsBack() {
        #expect(ZoteroChipPresentation(ref: ref(citation: "")).label == "ABCD1234")
    }

    @Test("help prefers citation, else the select link")
    func helpText() {
        #expect(ZoteroChipPresentation(ref: ref()).help == "zotero://select/library/items/ABCD1234")
        #expect(ZoteroChipPresentation(ref: ref(citation: "Cite")).help == "Cite")
    }
}
