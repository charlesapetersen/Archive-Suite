import AppKit

/// Reads/writes the `com.archivenotes.passage` pasteboard representation (07-extracts §5): the
/// copy-in-Notes → paste-into-Extract provenance carrier. This is the dependency-free codec half of
/// W7-S2 — it turns a `NotesPassagePayload` into a multi-representation pasteboard item and back,
/// with no dependency on the live editor. It mirrors `SourceBlockPaster`'s custom-UTI idiom and the
/// Reader's Copy-Archive-Link pasteboard writer (00-overview §8.4).
///
/// Two representations are written for a passage copy:
///   * the durable custom UTI (`com.archivenotes.passage`, declared Exported in Info.plist) — the
///     JSON that lets an Extract paste restore full provenance (source note + block ordinal + bytes);
///   * a plain-string fallback — what an external app (Scrivener, TextEdit) or a non-Extract target
///     receives, and what degrades to a `freeform` paste (no source) per §5.
///
/// The *live* copy path (S2-live, pending the editor↔item wiring) builds the `NotesPassagePayload`
/// from the current editor selection and adds a system RTF representation from the attributed
/// substring; the extract editor's paste branch calls `read(from:)` → `ExtractBuilder`. Both halves
/// route through this one codec so the copy/paste round-trip is symmetric and unit-testable.
enum PassagePasteboard {

    /// Custom pasteboard type (declared in Info.plist `UTExportedTypeDeclarations`, W7-S2).
    static let type = NSPasteboard.PasteboardType(NotesPassagePayload.uti)

    /// The plain-text fallback for a payload: each segment's Markdown, paragraph-separated. What an
    /// external app (or a non-Extract paste target) receives when it can't read the custom UTI.
    static func plainText(for payload: NotesPassagePayload) -> String {
        payload.segments
            .map { $0.markdown.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Write a multi-representation pasteboard item: the durable `com.archivenotes.passage` JSON, an
    /// optional system RTF representation (the live copy path passes the selection's attributed
    /// substring so an external app / a note paste gets styled text), plus a plain-string fallback.
    /// Clears the pasteboard first (single-item copy), matching the Reader's `copyLinks()` idiom.
    /// Returns false only if the payload unexpectedly fails to encode.
    @discardableResult
    static func write(_ payload: NotesPassagePayload, rtf: Data? = nil,
                      to pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = payload.data else { return false }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        if let rtf { item.setData(rtf, forType: .rtf) }
        item.setString(plainText(for: payload), forType: .string)
        return pasteboard.writeObjects([item])
    }

    /// Read a `NotesPassagePayload` from the pasteboard's custom UTI. Returns nil when the UTI is
    /// absent (a plain-text / external paste has no provenance → the caller inserts a `freeform`
    /// block) or the payload is malformed (tolerant decode — never a crash, §Risks).
    static func read(from pasteboard: NSPasteboard = .general) -> NotesPassagePayload? {
        guard let data = pasteboard.data(forType: type) else { return nil }
        return NotesPassagePayload(data: data)
    }

    /// Quick check for a passage payload without decoding (mirrors `pasteboardHasArchiveLinks`).
    static func hasPassage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.data(forType: type) != nil
    }
}
