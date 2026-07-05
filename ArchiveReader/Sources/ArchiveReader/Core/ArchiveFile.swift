import Foundation

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

// Identity is the file URL — two records for the same file are the same row.
extension ArchiveFile: Hashable {
    static func == (lhs: ArchiveFile, rhs: ArchiveFile) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
