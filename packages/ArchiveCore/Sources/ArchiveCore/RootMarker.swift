// RootMarker.swift — portable root-folder identity (ArchiveCore)
// Serialized as `.archive-suite-root.json` at a granted root folder.

import Foundation

/// Identifies whether a root belongs to Archive Reader or Archive Notes.
public enum RootKind: String, Codable, Sendable {
    case reader
    case notes
}

/// A tiny JSON marker dropped at a user-granted root folder to give it a portable identity.
///
/// Serialized with explicit Codable: `guid` is a **lowercased** UUID string and `createdAt`
/// is ISO-8601 (`yyyy-MM-dd'T'HH:mm:ssZ`), not Swift's default float-based Date encoding.
public struct RootMarker: Equatable, Sendable {
    public let guid: UUID
    public var name: String
    public let kind: RootKind
    public let createdAt: Date

    public init(guid: UUID, name: String, kind: RootKind, createdAt: Date) {
        self.guid = guid
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
    }

    /// The filename used when writing this marker to disk.
    public static let filename = ".archive-suite-root.json"
}

// MARK: - Explicit Codable (lowercased UUID string + ISO-8601 date)

extension RootMarker: Codable {
    private enum CodingKeys: String, CodingKey {
        case guid, name, kind, createdAt
    }

    private static func formatISO8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(guid.uuidString.lowercased(), forKey: .guid)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(Self.formatISO8601(createdAt), forKey: .createdAt)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let guidStr = try container.decode(String.self, forKey: .guid)
        guard let uuid = UUID(uuidString: guidStr) else {
            throw DecodingError.dataCorruptedError(
                forKey: .guid, in: container,
                debugDescription: "Invalid UUID string: \(guidStr)"
            )
        }
        self.guid = uuid
        self.name = try container.decode(String.self, forKey: .name)
        self.kind = try container.decode(RootKind.self, forKey: .kind)
        let dateStr = try container.decode(String.self, forKey: .createdAt)
        guard let date = Self.parseISO8601(dateStr) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt, in: container,
                debugDescription: "Invalid ISO-8601 date: \(dateStr)"
            )
        }
        self.createdAt = date
    }
}
