import AppKit
import ArchiveCore

// W7-S2 (b) — the READ side of Extracts: turn a live note-editor selection into the ordinal
// "source blocks" the snapshot builder anchors to.
//
// `ExtractBuilder` (W7-S1) already turns a `PassageSelectionSource` into extract `Block`s /
// persists an extract; W7-S1 supplied only a test fake for the seam. This file supplies the REAL
// implementation over the live editor text (`EditorPassageSource`) and the pure block-ordinal
// derivation both the copy side (here) and the future jump-to-source side (S3) share.

/// Pure decomposition of a rendered note body into ordinal "blocks" for extract provenance.
///
/// A note renders (via `MarkdownBridge.parse`) as: optional leading prose, then one source-block
/// **chip** (`.noteBlockSource`) plus its body per on-disk `Block`. The extract anchor's
/// `#block-<n>` ordinal (§8.2) indexes these structural segments in document order — the SAME chip
/// boundaries `MarkdownBridge.serialize` splits on — so the mapping is deterministic and can be
/// reproduced on the jump-to-source side (S3) from the source note's rendered text alone.
///
/// Ordinals shift if the source note is edited between snapshot and jump; that is accepted (plan
/// §Risks / §OQ1 — stable per-block GUIDs are deferred) and handled by S3's graceful degradation.
/// The snapshot *text* is always self-contained, so nothing is ever lost.
enum NotePassageBlockMap {

    /// Split `rendered` into disjoint, document-ordered block ranges — one per structural segment:
    /// the leading prose (if any), then each source-block chip together with the body up to the next
    /// chip. A note with no source-block chips is a single block `[0, length)`. Empty text ⟹ `[]`.
    ///
    /// Nonisolated/pure: reads only immutable attributes of the passed string, so it unit-tests off
    /// the main actor and is reused verbatim by S3.
    static func blockRanges(in rendered: NSAttributedString) -> [(blockIndex: Int, range: NSRange)] {
        let length = rendered.length
        guard length > 0 else { return [] }

        // Segment starts = position 0 (leading prose / first chip) plus every chip position. A chip
        // is a single `.noteBlockSource` attachment character, so each attributed run carrying it is
        // one chip; `!= starts.last` collapses a chip that sits exactly at an existing start (the
        // note-starts-with-a-chip case) so we never emit a zero-length segment.
        var starts: [Int] = [0]
        rendered.enumerateAttribute(.noteBlockSource,
                                    in: NSRange(location: 0, length: length)) { value, range, _ in
            guard value != nil, range.location != starts.last else { return }
            starts.append(range.location)
        }

        var result: [(blockIndex: Int, range: NSRange)] = []
        result.reserveCapacity(starts.count)
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : length
            guard end > start else { continue }
            result.append((blockIndex: result.count,
                           range: NSRange(location: start, length: end - start)))
        }
        return result
    }
}

/// A `PassageSelectionSource` backed by a *snapshot* of a note editor's rendered text.
///
/// Holds the rendered `NSAttributedString` **by value** (the live convenience init copies the text
/// storage) so a subsequent edit to the source note can never mutate an in-flight snapshot — the D7
/// independence guarantee. Reading only ever touches this copy; the source note's files are never
/// mutated by an extract operation (that is what keeps W7 Tier-1).
@MainActor
struct EditorPassageSource: PassageSelectionSource {
    let sourceNoteId: UUID
    let sourceTitle: String
    let sourceDateDisplay: String

    /// A value snapshot of the editor's text storage at selection time.
    let rendered: NSAttributedString
    /// Selected character ranges (UTF-16) in `rendered`; zero-length ranges ⟹ no selection.
    let selectedRanges: [NSRange]
    /// Resolve an `assets/…` relative path to its snapshot bytes (from the source note's asset
    /// store), or nil when the asset is unavailable. Called on the main actor.
    let assetBytes: @MainActor (_ relativePath: String) -> Data?

    var blockRanges: [(blockIndex: Int, range: NSRange)] {
        NotePassageBlockMap.blockRanges(in: rendered)
    }

    /// Snapshot a covered sub-range into CommonMark plus the inline-image bytes it references (keyed
    /// by bare filename, matching `NotesPassagePayload.Segment.assetPNGs` / `ExtractBuilder.persist`).
    /// A value copy — the source note is never mutated.
    func snapshotMarkdown(in range: NSRange) -> (markdown: String, assets: [String: Data]) {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: rendered.length))
        guard clamped.length > 0 else { return ("", [:]) }

        let sub = rendered.attributedSubstring(from: clamped)
        let markdown = MarkdownBridge.serialize(sub)

        var assets: [String: Data] = [:]
        sub.enumerateAttribute(.noteImageRelPath,
                               in: NSRange(location: 0, length: sub.length)) { value, _, _ in
            guard let relativePath = value as? String else { return }
            let bare = (relativePath as NSString).lastPathComponent
            guard assets[bare] == nil, let bytes = assetBytes(relativePath) else { return }
            assets[bare] = bytes
        }
        return (markdown, assets)
    }
}

extension EditorPassageSource {

    /// Build a passage source from a **live** editor text view (the S2 command wiring will use this).
    /// Snapshots the text storage by value up front, so edits made to the source note after the
    /// command fires do not change what gets extracted (D7). `assetStore` is the source note's own
    /// asset store; a nil store (or an unreadable file) yields a passage with no embedded bytes — the
    /// markdown reference is still preserved.
    init(textView: NSTextView,
         sourceNoteId: UUID,
         sourceTitle: String,
         sourceDateDisplay: String,
         assetStore: EditorAssetStore?) {
        let snapshot = (textView.textStorage?.copy() as? NSAttributedString) ?? NSAttributedString()
        let ranges: [NSRange]
        let values = textView.selectedRanges
        if !values.isEmpty {
            ranges = values.map { $0.rangeValue }
        } else {
            ranges = [textView.selectedRange()]
        }
        self.init(sourceNoteId: sourceNoteId,
                  sourceTitle: sourceTitle,
                  sourceDateDisplay: sourceDateDisplay,
                  rendered: snapshot,
                  selectedRanges: ranges,
                  assetBytes: { relativePath in
                      guard let url = assetStore?.resolveAsset(relativePath) else { return nil }
                      return try? Data(contentsOf: url)
                  })
    }
}
