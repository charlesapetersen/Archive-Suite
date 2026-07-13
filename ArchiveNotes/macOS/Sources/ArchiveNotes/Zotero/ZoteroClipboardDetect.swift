import Foundation

/// Pure, UI-free clipboard detection for Zotero select links (00-overview §D.5).
///
/// Given the raw pasteboard string and the set of already-attached *canonical*
/// select links, returns a `ZoteroRef` iff the clipboard holds a **new**
/// (not-yet-attached) recognized zotero link. It has no `NSPasteboard`
/// dependency, so it is fully unit-testable (see `ZoteroClipboardDetectTests`).
enum ZoteroClipboardDetect {

    /// - Parameters:
    ///   - pasteboardString: the current `NSPasteboard.general.string(forType: .string)`
    ///     (may be `nil` when the pasteboard holds no plain text).
    ///   - attachedLinks: canonical `selectLink`s already attached to the note / its blocks.
    /// - Returns: the parsed ref when the clipboard holds a recognized, not-yet-attached
    ///   zotero link; otherwise `nil`.
    static func detect(pasteboardString: String?,
                       attachedLinks: Set<String> = []) -> ZoteroRef? {
        guard let raw = pasteboardString,
              let ref = ZoteroSelectLink.parse(raw) else { return nil }
        // Dedup against already-attached links using the canonical form so a legacy
        // variant of an already-attached link is still recognized as a duplicate.
        guard !attachedLinks.contains(ref.selectLink) else { return nil }
        return ref
    }
}
