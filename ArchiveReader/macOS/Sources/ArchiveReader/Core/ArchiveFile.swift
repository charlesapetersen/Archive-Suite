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
    let name: String
    let fileType: String        // short label, e.g. "PDF"
    let tags: DocumentTags
    let contentModified: Date?
    let isDataless: Bool
    let provenance: ArchiveFileProvenance

    init(url: URL, name: String, fileType: String, tags: DocumentTags,
         contentModified: Date?, isDataless: Bool = false,
         provenance: ArchiveFileProvenance = .disk(readAt: Date())) {
        self.url = url
        self.name = name
        self.fileType = fileType
        self.tags = tags
        self.contentModified = contentModified
        self.isDataless = isDataless
        self.provenance = provenance
    }

    /// Discovery and index reconstruction build URLs from filesystem representations; URL equality
    /// then keeps their byte-distinct spellings separate in table diffing and selection.
    var id: URL { url }

    var sortDate: Int? { tags.sortDate }
    var dateIsSpeculative: Bool { tags.dateIsSpeculative }
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
