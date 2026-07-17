import Foundation
import ArchiveCore

/// One row in the navigation window: a tagged file discovered by the library.
///
/// `tags` are parsed for display/sort/filter (from the Spotlight-provided tag array — the fast path,
/// no per-file I/O). `url` is the identity used for opening and for `TagWriter` mutations. UI-free.
struct ArchiveFile: Identifiable, Sendable {
    let url: URL
    let name: String
    let fileType: String        // short label, e.g. "PDF"
    let tags: DocumentTags
    let contentModified: Date?

    var id: String { url.path }

    var sortDate: Int? { tags.sortDate }
    var dateIsSpeculative: Bool { tags.dateIsSpeculative }
    var readState: ReadState? { tags.readState }
    var priority: Int? { tags.priority }
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
    }
    // url-only hash stays valid: value-equal files share a url, so they share a hash (collisions OK).
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

extension ArchiveFile {
    /// Capture this file's on-disk identity ON DEMAND, for a §6 write-target re-verification
    /// (`TagWriter.apply(_:to:expecting:)` / `setReadState(_:on:expecting:)`). Deliberately a method,
    /// NOT a stored property: capturing identity is a per-file `stat` (I/O), so it is taken lazily ONLY
    /// for the handful of files actually being edited — never eagerly at library discovery, which would
    /// regress the "no per-file I/O" fast path this row model is built around (see the `tags` doc above).
    /// Returns `nil` when the file has no resolvable identity (missing, or a volume that vends none) →
    /// the caller then passes no §6 check for that file, exactly as `expecting: nil` does by default.
    func liveIdentity() -> FileIdentity? { FileIdentity.capture(url) }
}
