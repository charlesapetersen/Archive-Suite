import Foundation

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
}
