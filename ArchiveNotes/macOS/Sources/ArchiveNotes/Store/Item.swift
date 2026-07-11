import Foundation

/// Preserves an unrecognized YAML key and its raw text for round-trip fidelity.
struct UnknownKey: Sendable, Equatable {
    let key: String
    let rawLines: [String]
}

/// A reference to a Zotero library item or attachment (00-overview §3.4).
struct ZoteroRef: Sendable, Equatable {
    var selectLink: String
    var itemKey: String
    var library: String

    enum Kind: String, Sendable, Codable { case item, attachment }
    var kind: Kind
    var citation: String?
    var fetched: Bool?
    var unknown: [UnknownKey]

    init(selectLink: String, itemKey: String, library: String, kind: Kind,
         citation: String? = nil, fetched: Bool? = nil, unknown: [UnknownKey] = []) {
        self.selectLink = selectLink
        self.itemKey = itemKey
        self.library = library
        self.kind = kind
        self.citation = citation
        self.fetched = fetched
        self.unknown = unknown
    }
}

/// The domain model for a note or extract (00-overview §3.1, §5).
/// Serialized to/from Markdown with YAML front-matter via `FrontMatterCodec`.
struct Item: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable, Codable { case note, extract }
    enum DatePrecision: String, Sendable, Codable { case decade, year, month, day }

    var id: UUID
    var kind: Kind
    var title: String
    var authors: [String]
    var date: String?
    var datePrecision: DatePrecision?
    var dateUncertain: Bool
    var quality: Int?
    var tags: [String]
    var zotero: [ZoteroRef]
    var roundup: Bool
    var created: Date
    var modified: Date
    var schema: Int

    var blocks: [Block]

    var unknownFrontMatter: [UnknownKey]
    /// Raw body text between the front-matter closing `---` and the first block header.
    /// nil when the body starts directly with a `<!-- block:` header (or is empty).
    var trailingBodyRaw: String?

    /// Chronological sort key reusing the SPEC formula (DocumentTags.swift:89-92).
    /// `year * 10_000 + month * 100 + day`; decade -> `decade * 10_000`; nil if no date.
    var sortDate: Int? {
        guard let date else { return nil }
        switch datePrecision {
        case .decade:
            guard let decade = Int(date) else { return nil }
            return decade * 10_000
        case .year, .none:
            guard let yr = Int(date) else { return nil }
            return yr * 10_000
        case .month:
            let parts = date.split(separator: "-")
            guard parts.count >= 2,
                  let yr = Int(parts[0]), let mo = Int(parts[1]) else { return nil }
            return yr * 10_000 + mo * 100
        case .day:
            let parts = date.split(separator: "-")
            guard parts.count >= 3,
                  let yr = Int(parts[0]), let mo = Int(parts[1]), let dy = Int(parts[2]) else { return nil }
            return yr * 10_000 + mo * 100 + dy
        }
    }
}
