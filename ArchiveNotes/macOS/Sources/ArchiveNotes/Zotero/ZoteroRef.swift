import Foundation

/// Which Zotero library a reference belongs to (00-overview §D.1).
/// Front-matter: `.user` → `"library"`, `.group(n)` → `"\(n)"`.
enum ZoteroLibrary: Sendable, Equatable, Hashable {
    case user
    case group(Int)

    var frontMatterValue: String {
        switch self {
        case .user: return "library"
        case .group(let gid): return String(gid)
        }
    }

    /// Parse from the front-matter string. Accepts `"library"` (case-insensitive) or an integer.
    /// Unrecognized values default to `.user`.
    static func from(frontMatter value: String) -> ZoteroLibrary {
        if value.caseInsensitiveCompare("library") == .orderedSame { return .user }
        if let gid = Int(value) { return .group(gid) }
        return .user
    }
}

extension ZoteroLibrary: Codable {
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = .from(frontMatter: s)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(frontMatterValue)
    }
}

/// Whether a Zotero reference points to an item or an attachment.
enum ZoteroRefKind: String, Sendable, Codable { case item, attachment }

/// A reference to a Zotero library item or attachment (00-overview §3.4, §D.1).
struct ZoteroRef: Sendable, Equatable, Identifiable {
    var selectLink: String
    var itemKey: String
    var library: ZoteroLibrary
    var kind: ZoteroRefKind
    var parentKey: String?
    var citation: String?
    var fetchedAt: Date?

    /// Unknown front-matter keys preserved for round-trip fidelity (§6).
    var unknown: [UnknownKey]

    var id: String { selectLink }

    init(selectLink: String, itemKey: String, library: ZoteroLibrary,
         kind: ZoteroRefKind = .item, parentKey: String? = nil,
         citation: String? = nil, fetchedAt: Date? = nil,
         unknown: [UnknownKey] = []) {
        self.selectLink = selectLink
        self.itemKey = itemKey
        self.library = library
        self.kind = kind
        self.parentKey = parentKey
        self.citation = citation
        self.fetchedAt = fetchedAt
        self.unknown = unknown
    }
}
