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

// MARK: - Disk I/O (coordinated read/write at a root directory)

public enum RootMarkerError: Error, Sendable {
    /// An existing marker file was found but could not be decoded.
    case malformed(url: URL, underlying: Error)
    /// The directory is read-only; a transient in-memory marker is returned instead.
    case readOnly(url: URL)
}

extension RootMarker {

    /// Read the marker at `directory/.archive-suite-root.json`, if present.
    /// Returns `nil` when the file is absent. Throws `RootMarkerError.malformed`
    /// if the file exists but cannot be decoded (never silently overwrites it).
    public static func read(at directory: URL) throws -> RootMarker? {
        let fileURL = directory.appendingPathComponent(filename)

        var coordinatorError: NSError?
        var result: Result<RootMarker?, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: fileURL,
            options: .withoutChanges,
            error: &coordinatorError
        ) { coordURL in
            do {
                let data = try Data(contentsOf: coordURL)
                let marker = try JSONDecoder().decode(RootMarker.self, from: data)
                result = .success(marker)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
                result = .success(nil)
            } catch let decodingError as DecodingError {
                result = .failure(RootMarkerError.malformed(url: fileURL, underlying: decodingError))
            } catch {
                // Other read error (permissions, etc.) — treat as absent
                result = .success(nil)
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }
        switch result {
        case .success(let marker): return marker
        case .failure(let error): throw error
        case .none: return nil
        }
    }

    /// Idempotent: read an existing marker if present (never overwrite its guid);
    /// else create one. A malformed existing file is left untouched and surfaced as
    /// `.malformed` (never silently overwritten). On a read-only directory the write
    /// is skipped and a fresh in-memory marker is returned (caller should note
    /// degraded portability).
    ///
    /// - Parameters:
    ///   - directory: The granted root URL. Caller must have started any security scope.
    ///   - kind: `.reader` or `.notes`.
    ///   - name: Human label (typically `directory.lastPathComponent`).
    /// - Returns: The effective marker (existing or newly created).
    public static func ensure(
        at directory: URL,
        kind: RootKind,
        name: String
    ) throws -> RootMarker {
        let fileURL = directory.appendingPathComponent(filename)

        // 1. Try to read an existing marker first.
        if let existing = try read(at: directory) {
            return existing
        }

        // 2. No marker on disk — create one.
        let marker = RootMarker(
            guid: UUID(),
            name: name,
            kind: kind,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(marker)

        var coordinatorError: NSError?
        var writeError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: [],
            error: &coordinatorError
        ) { coordURL in
            do {
                try data.write(to: coordURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinatorError {
            throw coordinatorError
        }

        if writeError != nil {
            // Read-only volume / permission denied — return the in-memory marker
            // (degraded portability; caller should surface a note to the user).
            return marker
        }

        // 3. Re-read to confirm (idempotency: another process might have beaten us).
        if let confirmed = try read(at: directory) {
            return confirmed
        }
        return marker
    }
}
