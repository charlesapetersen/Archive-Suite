import Testing
@testable import ArchiveNotes

/// Pure clipboard-detection logic for the Zotero attach affordance (W5-S4).
/// No `NSPasteboard` — the detector takes the raw string, so it is fully testable.
@Suite("ZoteroClipboardDetect")
struct ZoteroClipboardDetectTests {

    @Test("recognizes a fresh library link")
    func freshLibraryLink() {
        let ref = ZoteroClipboardDetect.detect(
            pasteboardString: "zotero://select/library/items/ABCD1234")
        #expect(ref?.itemKey == "ABCD1234")
        #expect(ref?.selectLink == "zotero://select/library/items/ABCD1234")
        #expect(ref?.library == .user)
    }

    @Test("nil pasteboard → nil")
    func nilString() {
        #expect(ZoteroClipboardDetect.detect(pasteboardString: nil) == nil)
    }

    @Test("non-link junk → nil")
    func junk() {
        #expect(ZoteroClipboardDetect.detect(pasteboardString: "just some text") == nil)
    }

    @Test("non-zotero URL → nil")
    func nonZoteroURL() {
        #expect(ZoteroClipboardDetect.detect(pasteboardString: "https://example.com/x") == nil)
    }

    @Test("already-attached (exact) → nil")
    func alreadyAttachedExact() {
        let attached: Set<String> = ["zotero://select/library/items/ABCD1234"]
        let ref = ZoteroClipboardDetect.detect(
            pasteboardString: "zotero://select/library/items/ABCD1234",
            attachedLinks: attached)
        #expect(ref == nil)
    }

    @Test("dedup uses canonical form — a legacy variant of an attached link → nil")
    func dedupCanonical() {
        // Legacy `items/1_KEY` canonicalizes to `library/items/KEY`.
        let attached: Set<String> = ["zotero://select/library/items/ABCD1234"]
        let ref = ZoteroClipboardDetect.detect(
            pasteboardString: "zotero://select/items/1_ABCD1234",
            attachedLinks: attached)
        #expect(ref == nil)
    }

    @Test("fresh link when others are attached → returns it")
    func freshWhenOthersAttached() {
        let attached: Set<String> = ["zotero://select/library/items/ZZZZ0000"]
        let ref = ZoteroClipboardDetect.detect(
            pasteboardString: "zotero://select/library/items/ABCD1234",
            attachedLinks: attached)
        #expect(ref?.itemKey == "ABCD1234")
    }

    @Test("group link recognized + canonicalized")
    func groupLink() {
        let ref = ZoteroClipboardDetect.detect(
            pasteboardString: "zotero://select/groups/12345/items/WXYZ5678")
        #expect(ref?.selectLink == "zotero://select/groups/12345/items/WXYZ5678")
        #expect(ref?.library == .group(12345))
    }

    @Test("surrounding whitespace tolerated")
    func whitespace() {
        let ref = ZoteroClipboardDetect.detect(
            pasteboardString: "  zotero://select/library/items/ABCD1234\n")
        #expect(ref?.itemKey == "ABCD1234")
    }
}
