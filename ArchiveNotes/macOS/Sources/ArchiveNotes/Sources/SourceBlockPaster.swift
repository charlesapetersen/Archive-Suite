import AppKit
import ArchiveCore

/// Reads archive-link payloads from the pasteboard, imports thumbnail assets,
/// and produces source-block entries ready for editor insertion.
///
/// Two recognition paths (tried in order):
/// 1. Custom UTI (`com.archivesuite.archive-links`) — rich JSON from Reader's "Copy Archive Link(s)".
/// 2. Plain-text fallback — scans for `archivereader://` URLs, one per line.
///
/// Thumbnails (base64 in the payload) are imported via the editor's `EditorAssetStore`.
/// When no thumbnail is available (plain-text path, or missing in payload), the block
/// degrades to text-only provenance — link + display are always preserved.
struct SourceBlockPaster {

    /// A parsed paste entry ready for block insertion.
    struct PasteEntry {
        var kind: Block.Kind
        var anchor: SourceAnchor
        var thumbnailData: Data?
    }

    // MARK: - Pasteboard reading

    /// Read the general pasteboard for archive link entries.
    /// Returns entries if recognized, empty array otherwise.
    @MainActor
    static func readPasteboard(from pasteboard: NSPasteboard = .general) -> [PasteEntry] {
        // 1. Custom UTI (preferred — rich payload from Reader)
        let utiType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        if let data = pasteboard.data(forType: utiType),
           let payload = try? JSONDecoder().decode(ArchiveLinkPayload.self, from: data) {
            return entriesFromPayload(payload)
        }
        // 2. Plain text fallback — scan for archivereader:// URLs
        if let text = pasteboard.string(forType: .string) {
            return scanURLs(in: text)
        }
        return []
    }

    /// Check if the pasteboard contains recognizable archive links without fully parsing.
    @MainActor
    static func pasteboardHasArchiveLinks(_ pasteboard: NSPasteboard = .general) -> Bool {
        let utiType = NSPasteboard.PasteboardType(ArchiveLinkUTI.type)
        if pasteboard.data(forType: utiType) != nil { return true }
        if let text = pasteboard.string(forType: .string) {
            return text.contains("archivereader://")
        }
        return false
    }

    // MARK: - Entry extraction

    /// Build entries from a decoded custom-UTI payload.
    static func entriesFromPayload(_ payload: ArchiveLinkPayload) -> [PasteEntry] {
        payload.entries.compactMap { entry in
            // Validate each link via DurableLink (treat payload as untrusted). A `rel` carrying a line
            // terminator can only name a path that does not exist, so the entry is dropped rather than
            // filed as provenance that never resolves — the same rule `scanURLs` applies, because a
            // percent-encoded terminator reaches this path too (W3.notes-paste-url-line-split).
            guard let url = URL(string: entry.link),
                  case .readerReveal(_, let rel, _) = DurableLink(url: url),
                  !BlockParser.containsLineTerminator(rel) else { return nil }

            let kind: Block.Kind = entry.page != nil ? .readerPage : .readerDoc

            // Size-cap base64 thumbnails (untrusted pasteboard data): reject > 5 MB
            var thumbData: Data?
            if let b64 = entry.thumbPNGBase64, b64.count <= 5_000_000 {
                thumbData = Data(base64Encoded: b64)
            }

            return PasteEntry(
                kind: kind,
                anchor: SourceAnchor(
                    link: entry.link,
                    display: entry.display,
                    page: entry.page
                ),
                thumbnailData: thumbData
            )
        }
    }

    /// Scan text for `archivereader://` URLs and produce paste entries (no thumbnails).
    ///
    /// The line split goes through `BlockParser.splitLines` and the trim through
    /// `.whitespacesAndNewlines` — both halves are required (W3.notes-paste-url-line-split, the sixth
    /// instance of the `W3.notes-cr-line-start` family). This is the plain-text pasteboard FALLBACK, i.e.
    /// the "operator copied this out of an email, a chat or a Word doc" path, which is exactly where CRLF
    /// comes from; `split(separator: "\n")` did not split a CRLF or lone-CR paste at all, and
    /// `.whitespaces` is space + tab, so the terminator survived into the URL. `URL(string:)` does not
    /// reject a control character — it percent-encodes it — so the failure was silent either way:
    /// measured, a CRLF-separated pair of PAGE links yielded ZERO blocks (the terminator lands on the
    /// trailing `page=` item, `Int("1\r\n")` is nil, the whole link is rejected), and a pair of
    /// doc-level links yielded ONE block whose `relativePath` had swallowed the next link
    /// (`"A.pdf\r\narchivereader://reveal?root=…"`).
    static func scanURLs(in text: String) -> [PasteEntry] {
        var entries: [PasteEntry] = []
        for line in BlockParser.splitLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed),
                  case .readerReveal(_, let rel, let page) = DurableLink(url: url),
                  !BlockParser.containsLineTerminator(rel) else {
                continue
            }
            let basename = URL(fileURLWithPath: rel).lastPathComponent
            let name = basename.hasSuffix(".pdf") || basename.hasSuffix(".PDF")
                ? String(basename.dropLast(4)) : basename
            let display = page.map { "\(name) \u{2014} p. \($0)" } ?? name

            entries.append(PasteEntry(
                kind: page != nil ? .readerPage : .readerDoc,
                anchor: SourceAnchor(
                    link: trimmed,
                    display: display,
                    page: page
                ),
                thumbnailData: nil
            ))
        }
        return entries
    }

    // MARK: - Thumbnail import

    /// Import thumbnail PNG data as an asset. Returns the `assets/…` relative path, or nil on failure.
    @MainActor
    static func importThumbnail(
        _ data: Data, page: Int?, assetStore: EditorAssetStore
    ) -> String? {
        let name = page.map { "p\($0)-thumb.png" } ?? "doc-thumb.png"
        return try? assetStore.addAsset(data, preferredName: name)
    }
}
