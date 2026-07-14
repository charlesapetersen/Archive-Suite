import Foundation
import ArchiveCore

// W7-S1 — extract provenance anchors (00-overview §3.3, §8.2).
//
// An *extract* block's provenance is "this passage came from note X, block b". The durable target
// is the canonical §8.2 URL `archivenotes://open?id=<UUID>#block-<n>`, built + parsed by
// `ArchiveCore.DurableLink` (the scheme owner, W4) so W7 never re-defines the grammar.
//
// Reconciliation vs. the 07-extracts.md sketch (the plan pre-dates W2's shipped types):
//   * `SourceAnchor` has NO `type`/`kind` field — `Block.kind` carries `.notePassage`. The URL lives
//     in `noteRef` (serialized as the block header's `note:` field, per BlockParser), NOT `link`.
//   * The canonical URL comes from `DurableLink.notesOpen`, which lowercases the UUID.
extension SourceAnchor {

    /// Build an extract's provenance anchor pointing back to a source note + block ordinal.
    /// `sourceDateDisplay` is the already-rendered date string (caller uses the shared date
    /// formatter — W7 does not hand-roll date formatting); empty ⟹ the label is just the title.
    static func notePassage(sourceNoteId: UUID,
                            sourceBlockIndex: Int,
                            sourceTitle: String,
                            sourceDateDisplay: String) -> SourceAnchor {
        let trimmedDate = sourceDateDisplay.trimmingCharacters(in: .whitespaces)
        let label = trimmedDate.isEmpty ? sourceTitle : "\(sourceTitle) — \(trimmedDate)"
        let url = DurableLink.notesOpen(id: sourceNoteId, block: sourceBlockIndex).url
        return SourceAnchor(link: nil,
                            display: label,
                            page: nil,
                            thumbRef: nil,
                            zoteroSelect: nil,
                            noteRef: url.absoluteString)
    }

    /// Parse `(id, block?)` out of a note-passage `noteRef`. Returns nil for a non-passage anchor
    /// (reader/zotero link, no `noteRef`) or a malformed URL — this is what the
    /// extract-references-notes-only coercion keys off. Tolerates the canonical §8.2
    /// `open?id=<UUID>#block-<n>` (via `DurableLink`) and, read-only for forward safety, the older
    /// §6 sketch spelling `archivenotes://note/<UUID>#block-<n>` that no shipped writer emits.
    var notePassageTarget: (id: UUID, block: Int?)? {
        guard let ref = noteRef, let url = URL(string: ref) else { return nil }
        if case let .notesOpen(id, block)? = DurableLink(url: url) {
            return (id, block)
        }
        // Legacy read-only tolerance (never written by shipped code).
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme == DurableLink.notesScheme,
              comps.host == "note" else { return nil }
        let raw = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let id = UUID(uuidString: raw) else { return nil }
        var block: Int?
        if let f = comps.fragment, f.hasPrefix("block-") {
            block = Int(f.dropFirst("block-".count))
        }
        return (id, block)
    }
}

extension Sequence where Element == Block {
    /// Distinct source-note count for the extract "Sources" column (W7-S4, 07-extracts §4): the number
    /// of **unique source-note UUIDs** among this item's `.notePassage` blocks — a segmented extract
    /// appended from two different notes reports 2, one appended twice from the same note reports 1.
    /// Notes (which never carry note-passage provenance) and freeform / reader / zotero blocks
    /// contribute 0, so a plain note or a source-less extract reports 0 (the column renders blank).
    /// Pure + deterministic; the index projects it so the list never re-reads `.md` files.
    var distinctSourceNoteCount: Int {
        var ids = Set<UUID>()
        for block in self where block.kind == .notePassage {
            if let id = block.source?.notePassageTarget?.id { ids.insert(id) }
        }
        return ids.count
    }
}
