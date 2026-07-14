import AppKit
import ArchiveCore

// W7-S3 — jump-to-source resolution + provenance-chip labeling for extract note-passage blocks.
//
// An extract block carries a `note-passage` provenance anchor (W7-S1): the durable §8.2 URL
// `archivenotes://open?id=<UUID>#block-<n>` in `SourceAnchor.noteRef`, plus a snapshot `display`
// label captured when the extract was made. S3 turns that anchor into a live, best-effort jump back
// to the source note and a chip that prefers the note's CURRENT title (a renamed source updates) and
// falls back to the snapshot label. All of this is pure over an in-memory `[ItemSummary]` (the shared
// `NotesModel.allItems`, §16.5) so it unit-tests without a store or a window server.
//
// Ordinal `#block-<n>` anchors are best-effort (plan §Risks / §OQ1 — stable per-block GUIDs deferred):
// they can go stale if the source note is edited between snapshot and jump. Every degradation here is
// non-crashing and never loses data — the extract's snapshot text is self-contained.

/// The outcome of resolving a note-passage anchor against the current item set.
enum PassageResolution: Equatable {
    /// The source exists and is a note. `liveTitle`/`dateDisplay` are its CURRENT (possibly renamed)
    /// values; `block` is the snapshot ordinal (may be out of range now — the scroll side degrades).
    case resolved(id: UUID, block: Int?, liveTitle: String, dateDisplay: String)
    /// The anchor points at an id that is no longer in the store (deleted / trashed note).
    case sourceDeleted(id: UUID)
    /// The anchor resolves to an item that exists but is not a `.note` (defensive; e.g. an extract).
    case wrongKind(id: UUID)
    /// The anchor is not a note-passage anchor at all (no `noteRef` / malformed URL).
    case malformed
}

/// Pure helpers for the S3 provenance chip + jump-to-source. No actor state; testable off-main
/// except `scrollRange`, which reads a rendered `NSAttributedString`.
enum NotePassageResolve {

    /// Resolve a block's provenance anchor against the shared item summaries. Pure.
    static func resolve(anchor: SourceAnchor, among summaries: [ItemSummary]) -> PassageResolution {
        guard let target = anchor.notePassageTarget else { return .malformed }
        guard let summary = summaries.first(where: { $0.id == target.id }) else {
            return .sourceDeleted(id: target.id)
        }
        guard summary.kind == .note else { return .wrongKind(id: target.id) }
        return .resolved(id: target.id,
                         block: target.block,
                         liveTitle: summary.title,
                         dateDisplay: summary.displayDate ?? "")
    }

    /// The label to show on the provenance chip: the CURRENT source-note title (+ date) when the
    /// source resolves, else the snapshot `display` captured at extract time, else a neutral fallback.
    /// Mirrors `SourceAnchor.notePassage`'s "title — date" formatting for the live case, so a renamed
    /// source updates the chip while a deleted source keeps the last-known label.
    static func chipLabel(anchor: SourceAnchor, among summaries: [ItemSummary]) -> String {
        switch resolve(anchor: anchor, among: summaries) {
        case let .resolved(_, _, liveTitle, dateDisplay):
            let trimmed = dateDisplay.trimmingCharacters(in: .whitespaces)
            let title = liveTitle.trimmingCharacters(in: .whitespaces)
            let base = title.isEmpty ? "Untitled note" : title
            return trimmed.isEmpty ? base : "\(base) — \(trimmed)"
        case .sourceDeleted, .wrongKind, .malformed:
            let snapshot = anchor.display?.trimmingCharacters(in: .whitespaces) ?? ""
            return snapshot.isEmpty ? "Source note" : snapshot
        }
    }

    /// Whether the chip should render in a "source removed" (greyed) style — the source note is gone
    /// or the anchor no longer resolves to a note. A well-formed anchor whose note is present ⟹ false.
    static func isSourceMissing(anchor: SourceAnchor, among summaries: [ItemSummary]) -> Bool {
        switch resolve(anchor: anchor, among: summaries) {
        case .resolved: return false
        case .sourceDeleted, .wrongKind, .malformed: return true
        }
    }

    /// Map a note-passage `#block-<n>` ordinal to the character range it occupies in the source note's
    /// RENDERED text — the same `.noteBlockSource` chip boundaries `MarkdownBridge`/`EditorPassageSource`
    /// use (`NotePassageBlockMap`). Returns nil when there is no ordinal, the ordinal is out of range
    /// (source edited since snapshot — the caller degrades to "scroll to top"), or the text is empty.
    static func scrollRange(forBlock block: Int?, in rendered: NSAttributedString) -> NSRange? {
        guard let block, block >= 0 else { return nil }
        let ranges = NotePassageBlockMap.blockRanges(in: rendered)
        guard block < ranges.count else { return nil }
        return ranges[block].range
    }
}
