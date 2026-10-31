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

/// One row in the navigation window: a tagged file discovered by the library.
///
/// `tags` are parsed for display/sort/filter from ArchiveCore's on-disk read. `url` is the identity used
/// for opening and for `TagWriter` mutations. UI-free.
struct ArchiveFile: Identifiable, Sendable {
    let url: URL
    /// `url.path`, built once. URL rebuilds it on every access, and the list reads it for every row on
    /// every tag edit (filters, signatures, the prune set, the sort's tiebreak): at 116k rows that was
    /// most of what remained of a tag edit's cost (W40.fix-reader-list-recompute-at-size).
    let path: String
    /// `path`'s UTF-8 hash, for the change signatures (`LibraryChangeSignature`), which hash every row's
    /// path on every library change.
    let pathHash: Int
    let name: String
    let fileType: String        // short label, e.g. "PDF"
    let tags: DocumentTags
    let contentModified: Date?
    let isDataless: Bool
    let provenance: ArchiveFileProvenance
    /// W40.fix-reader-date-ambiguity: date facets that carried two tags, worked out once per row so the
    /// filter and the list never re-classify every subject of every file.
    let dateAmbiguities: [DateAmbiguity]

    init(url: URL, name: String, fileType: String, tags: DocumentTags,
         contentModified: Date?, isDataless: Bool = false,
         provenance: ArchiveFileProvenance = .disk(readAt: Date())) {
        self.url = url
        // Native UTF-8, made once here: a bridged string (what the walk and URL hand over) is copied
        // to UTF-8 on every byte-hash, which made each sort's 116k key lookups slower, not faster.
        var path = url.path, name = name
        path.makeContiguousUTF8()
        name.makeContiguousUTF8()
        self.path = path
        self.pathHash = UTF8Key(path).hashValue
        self.name = name
        self.fileType = fileType
        self.tags = tags
        self.contentModified = contentModified
        self.isDataless = isDataless
        self.provenance = provenance
        self.dateAmbiguities = tags.dateAmbiguities
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
    var color: ArchiveColor? { tags.color }
}

// Row *identity* is the file URL (see `id`); row *equality* is by VALUE and must include `tags`.
// SwiftUI's `Table` diffs elements by Equatable: a url-only `==` made it treat a row whose tags
// changed (e.g. Unread→Read) as unchanged and skip re-rendering the cell — so marking a file Read
// left the row visibly "Unread". Comparing the displayed fields forces the row to re-render on edit.
extension ArchiveFile: Hashable {
    static func == (lhs: ArchiveFile, rhs: ArchiveFile) -> Bool {
        lhs.url == rhs.url && lhs.name == rhs.name && lhs.fileType == rhs.fileType
            && lhs.tags == rhs.tags && lhs.contentModified == rhs.contentModified
            && lhs.isDataless == rhs.isDataless && lhs.provenance == rhs.provenance
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
