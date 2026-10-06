import Foundation
import ArchiveCore

/// A row of extracted content ready for batch insertion into the index. `Sendable` so
/// task-group children can return it safely from off-actor extraction.
struct NoteIndexRow: Sendable {
    let id: UUID
    let mtime: Double
    let title: String
    let kind: Item.Kind
    let tags: String          // space-joined for FTS
    let authors: String       // space-joined for FTS
    let authorsJSON: String   // JSON array for the items table
    let body: String          // markdown body text
    let date: String?
    let datePrecision: Item.DatePrecision?
    let dateUncertain: Bool
    let sortDate: Int?
    let quality: Int?
    let created: Date
    let modified: Date
    let managedTags: String   // JSON array for the items table
    /// Distinct source-note count (extract provenance) — the "Sources" column (W7-S4). 0 for notes
    /// and source-less extracts. Projected into `items.source_count` so the list never reads `.md`.
    let sourceCount: Int
    var roundup: Bool = false
    /// W37.dual-date: the role-labelled sent-with date, stored in its own columns of the SAME items
    /// row — either date matches a filter without a second row per UUID. `sortDate` above already
    /// carries the own-date-else-sent-with fallback.
    var sentWith: ArchiveDate? = nil
    var sentWithUncertain: Bool = false
}

extension NoteIndexRow {
    /// Build a row straight from an in-memory `Item` + its file mtime — the single-item re-index path
    /// used after an edit (W6-S7 `NotesModel.setDate`/`setQuality`). Mirrors `NotesIndexer.extractRow`
    /// field-for-field (same body join, same JSON encoding) so a one-item upsert lands identically to a
    /// full off-actor scan; `extractRow` delegates here to keep the mapping DRY.
    init(item: Item, mtime: Double) {
        let bodyText = item.blocks.map(\.markdown).joined(separator: "\n")
        let fullBody = item.trailingBodyRaw.map { $0 + "\n" + bodyText } ?? bodyText
        let encoder = JSONEncoder()
        let tagsJSON = (try? encoder.encode(item.tags)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let authorsJSON = (try? encoder.encode(item.authors)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        self.init(
            id: item.id,
            mtime: mtime,
            title: item.title,
            kind: item.kind,
            tags: item.tags.joined(separator: " "),
            authors: item.authors.joined(separator: " "),
            authorsJSON: authorsJSON,
            body: fullBody,
            date: item.date,
            datePrecision: item.datePrecision,
            dateUncertain: item.dateUncertain,
            sortDate: item.sortDate,
            quality: item.quality,
            created: item.created,
            modified: item.modified,
            managedTags: tagsJSON,
            sourceCount: item.blocks.distinctSourceNoteCount,
            roundup: item.roundup,
            sentWith: item.sentWith,
            sentWithUncertain: item.sentWith != nil && item.sentWithUncertain
        )
    }
}

/// Lightweight projection of an indexed item — every field the list/sort UI needs
/// without reading .md files (closes the W6 gap per §16.5).
struct ItemSummary: Sendable, Identifiable {
    let id: UUID
    let title: String
    let kind: Item.Kind
    let date: String?
    let datePrecision: Item.DatePrecision?
    let dateUncertain: Bool
    let authors: [String]
    let sortDate: Int?
    let quality: Int?
    let created: Date
    let modified: Date
    let mtime: Double
    let managedTags: [String]
    /// Distinct source-note count for the extract "Sources" column (W7-S4). Trailing + defaulted so
    /// existing `ItemSummary(...)` call sites (tests, older projections) keep compiling; the index
    /// projection (`NotesIndex.readSummaryRow`) supplies the real value from `items.source_count`.
    var sourceNoteCount: Int = 0
    var roundup: Bool = false
    /// W37.dual-date: the covering letter's date (nil when none) and its own uncertainty flag.
    var sentWith: ArchiveDate? = nil
    var sentWithUncertain: Bool = false
}

extension ItemSummary {
    /// The own date's sort key alone, never the fallback. Without a sent-with date the stored
    /// `sortDate` IS the own key (so a summary built from just a sort key keeps filtering as before);
    /// with one, re-derive it from `date`/`datePrecision` by the same parse `Item.ownSortDate` uses.
    var ownSortDate: Int? {
        sentWith == nil ? sortDate : Item.sortKey(date: date, precision: datePrecision)
    }

    /// True when the list sorts this row by its sent-with date because it has no own date.
    var sortsBySentWith: Bool { ownSortDate == nil && sentWith != nil }

    /// Each role's sort key, for a date filter that matches either date (`DateRangeFilter`).
    var dateKeysByRole: [DateRole: Int] { Item.dateKeysByRole(own: ownSortDate, sentWith: sentWith) }
}
