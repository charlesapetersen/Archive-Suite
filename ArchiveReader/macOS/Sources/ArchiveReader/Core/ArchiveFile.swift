import Foundation
import ArchiveCore

/// Whether a displayed row was verified from disk in this process or restored from the disposable
/// warm-start cache. Cache provenance is load-bearing for bulk writes: a stale selection can outlive
/// Finder edits across a relaunch, so callers re-verify cache rows before deriving a selection/delta.
enum ArchiveFileProvenance: Hashable, Sendable {
    case disk(readAt: Date)
    /// `nil` means the newest persisted scan was partial/crashed and cannot make an as-of claim.
    case cache(asOf: Date?)

    var isCache: Bool {
        if case .cache = self { return true }
        return false
    }
}

/// A file's inode and byte size. A replacement that keeps the modification date (an Improve OCR
/// publication, a copy that restores the date) still changes one of them; a Finder-tag write, which only
/// sets an extended attribute in place, changes neither.
struct ContentIdentity: Hashable, Sendable {
    let inode: UInt64
    let size: Int64

    init(inode: UInt64, size: Int64) { self.inode = inode; self.size = size }
    init(_ fingerprint: CorpusFileFingerprint) { self.init(inode: fingerprint.inode, size: fingerprint.size) }
}

/// One row in the navigation window: a tagged file discovered by the library.
///
/// `tags` are parsed for display/sort/filter from ArchiveCore's on-disk read. `url` is the identity used
/// for opening and for `TagWriter` mutations. UI-free.
struct ArchiveFile: Identifiable, Sendable {
    /// The row's fields, held once and shared by every copy (W40.fix-reader-change-incremental). The list
    /// copies whole arrays of rows: the library's `files`, the presentation's filtered and sorted lists,
    /// the table's rows. Inline, each copy retained a dozen references per row and allocated about 300
    /// bytes per row, 75 ms and tens of megabytes at 116k rows; shared, a copy is one pointer per row.
    /// Every field is a `let`, so sharing cannot be seen from outside.
    private final class Fields: Sendable {
        let url: URL
        let path: String
        let pathHash: Int
        let name: String
        let fileType: String
        let tags: DocumentTags
        let contentModified: Date?
        let contentIdentity: ContentIdentity?
        let isDataless: Bool
        let provenance: ArchiveFileProvenance
        let dateAmbiguities: [DateAmbiguity]
        let subjectKeys: Set<String>

        init(url: URL, path: String, name: String, fileType: String, tags: DocumentTags,
             contentModified: Date?, contentIdentity: ContentIdentity?, isDataless: Bool,
             provenance: ArchiveFileProvenance) {
            self.url = url
            self.path = path
            self.pathHash = UTF8Key(path).hashValue
            self.name = name
            self.fileType = fileType
            self.tags = tags
            self.contentModified = contentModified
            self.contentIdentity = contentIdentity
            self.isDataless = isDataless
            self.provenance = provenance
            self.dateAmbiguities = tags.dateAmbiguities
            self.subjectKeys = Set(tags.subjects.map(tagKey))
        }
    }
    private let fields: Fields

    var url: URL { fields.url }
    /// `url.path`, built once. URL rebuilds it on every access, and the list reads it for every row on
    /// every tag edit (filters, signatures, the prune set, the sort's tiebreak): at 116k rows that was
    /// most of what remained of a tag edit's cost (W40.fix-reader-list-recompute-at-size).
    var path: String { fields.path }
    /// `path`'s UTF-8 hash, for the change signatures (`LibraryChangeSignature`), which hash every row's
    /// path on every library change.
    var pathHash: Int { fields.pathHash }
    var name: String { fields.name }
    var fileType: String { fields.fileType }        // short label, e.g. "PDF"
    var tags: DocumentTags { fields.tags }
    var contentModified: Date? { fields.contentModified }
    /// The inode and size discovery saw, beside the date in the content index's freshness key
    /// (W44.reocr-reader-freshness). Nil for a row built without a `stat(2)` (synthetic test rows).
    var contentIdentity: ContentIdentity? { fields.contentIdentity }
    var isDataless: Bool { fields.isDataless }
    var provenance: ArchiveFileProvenance { fields.provenance }
    /// W40.fix-reader-date-ambiguity: date facets that carried two tags, worked out once per row so the
    /// filter and the list never re-classify every subject of every file.
    var dateAmbiguities: [DateAmbiguity] { fields.dateAmbiguities }
    /// The subjects' tag identities (`tagKey`), worked out once per row: tags that differ only in case are
    /// one tag (W40.fix-tags-case-insensitive), and the filter tests every row against them.
    var subjectKeys: Set<String> { fields.subjectKeys }

    /// Whether two rows are the same stored row (a copy of one), which makes them equal without comparing.
    func isSameStoredRow(as other: ArchiveFile) -> Bool { fields === other.fields }

    init(url: URL, name: String, fileType: String, tags: DocumentTags,
         contentModified: Date?, contentIdentity: ContentIdentity? = nil, isDataless: Bool = false,
         provenance: ArchiveFileProvenance = .disk(readAt: Date())) {
        // Native UTF-8, made once here: a bridged string (what the walk and URL hand over) is copied
        // to UTF-8 on every byte-hash, which made each sort's 116k key lookups slower, not faster.
        var path = url.path, name = name
        path.makeContiguousUTF8()
        name.makeContiguousUTF8()
        fields = Fields(url: url, path: path, name: name, fileType: fileType, tags: tags,
                        contentModified: contentModified, contentIdentity: contentIdentity,
                        isDataless: isDataless, provenance: provenance)
    }

    /// Discovery and index reconstruction build URLs from filesystem representations; URL equality
    /// then keeps their byte-distinct spellings separate in table diffing and selection.
    var id: URL { url }

    var sortDate: Int? { tags.sortDate }
    var dateIsAmbiguous: Bool { !dateAmbiguities.isEmpty }

    /// One line per ambiguous facet, naming the tag the last-wins rule set aside; nil when none.
    var dateAmbiguityText: String? {
        dateIsAmbiguous ? dateAmbiguities.map(\.summary).joined(separator: "\n") : nil
    }
    var dateIsSpeculative: Bool { tags.dateIsSpeculative }

    /// W37: the Date column text. The item's own date, plus the covering letter's date when the file
    /// is an enclosure ("Nov 3, 1957 · sent Mar 12, 1958"); with no own date, the labelled sent-with
    /// fallback that it sorts by ("Sent with Mar 12, 1958") — never presented as the item's own date.
    /// W24.cal1-reader: `dateCellText(in:)` shows it in a document's display calendar.
    var dateCellText: String { Self.dateCellText(own: tags.displayDate, sent: tags.displaySentWith) }

    /// Italic when the date that SORTS the row is speculative (own date, or the sent-with fallback).
    var dateCellIsSpeculative: Bool {
        tags.sortsBySentWith ? tags.sentWithUncertain || tags.sentWith?.precision == .decade : dateIsSpeculative
    }
    var readState: ReadState? { tags.readState }
    var quality: Int? { tags.quality }
    var subjects: [String] { tags.subjects }
    /// Whether the file carries `tag` in any case (W40.fix-tags-case-insensitive).
    func hasSubject(_ tag: String) -> Bool { subjectKeys.contains(tagKey(tag)) }
    /// W40.suite-item-types: Box or Folder, from the token or the root's older-material colours.
    var itemType: ItemType? { tags.itemType }
}

// Row *identity* is the file URL (see `id`); row *equality* is by VALUE and must include `tags`.
// SwiftUI's `Table` diffs elements by Equatable: a url-only `==` made it treat a row whose tags
// changed (e.g. Unread→Read) as unchanged and skip re-rendering the cell — so marking a file Read
// left the row visibly "Unread". Comparing the displayed fields forces the row to re-render on edit.
extension ArchiveFile: Hashable {
    static func == (lhs: ArchiveFile, rhs: ArchiveFile) -> Bool {
        lhs.isSameStoredRow(as: rhs)
            || (lhs.url == rhs.url && lhs.name == rhs.name && lhs.fileType == rhs.fileType
                && lhs.tags == rhs.tags && lhs.contentModified == rhs.contentModified
                && lhs.contentIdentity == rhs.contentIdentity
                && lhs.isDataless == rhs.isDataless && lhs.provenance == rhs.provenance)
    }
    // url-only hash stays valid: value-equal files share a url, so they share a hash (collisions OK).
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

extension ArchiveFile {
    /// Capture this file's on-disk identity ON DEMAND, for a §6 write-target re-verification
    /// (`TagWriter.apply(_:to:expecting:)` / `setReadState(_:on:expecting:)`). Deliberately a method,
    /// NOT a stored property: discovery fingerprints prove cache freshness, but a write needs identity
    /// captured immediately before mutation so a later same-path replacement is rejected inside
    /// coordination. Reusing the discovery inode here would widen that race window.
    /// Returns `nil` when the file has no resolvable identity (missing, or a volume that vends none) →
    /// the caller then passes no §6 check for that file, exactly as `expecting: nil` does by default.
    func liveIdentity() -> FileIdentity? { FileIdentity.capture(url) }
}
