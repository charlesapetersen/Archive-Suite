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
    /// A marker file may well exist, but could not be READ — no permission, an I/O error, a
    /// coordination failure. Deliberately distinct from absence: a root whose identity is merely
    /// *unreadable right now* must never be treated as a root that has *no* identity, because the
    /// repair for absence is to mint a new GUID, and that orphans every link already copied from
    /// this root. (W23.m6)
    case unreadable(url: URL, underlying: Error)
    /// No **durable** identity could be established: the marker write failed (read-only volume, no
    /// permission, disk full) or could not be confirmed on disk afterwards. `provisional` is the
    /// marker that *would* have been written — it lives only in memory, so it is a different GUID
    /// after the next launch and any link minted from it can never resolve. Callers must degrade
    /// visibly rather than accept it as a normal marker. (W23.m6)
    case readOnly(url: URL, provisional: RootMarker, underlying: Error?)
}

extension RootMarker {

    /// Decode the marker file at `fileURL` **without** taking a coordination claim — the caller
    /// already holds one. (Nesting a second `NSFileCoordinator` inside an accessor block deadlocks,
    /// which is why `ensure` cannot simply call `read` from inside its write claim.)
    ///
    /// - Returns: the marker, or `nil` **only** when the file is genuinely absent.
    private static func decode(atFile fileURL: URL) throws -> RootMarker? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw RootMarkerError.unreadable(url: fileURL, underlying: error)
        }
        do {
            return try JSONDecoder().decode(RootMarker.self, from: data)
        } catch {
            throw RootMarkerError.malformed(url: fileURL, underlying: error)
        }
    }

    /// Read the marker at `directory/.archive-suite-root.json`, if present.
    ///
    /// Returns `nil` **only** when the file is absent. A file that exists but cannot be read throws
    /// `.unreadable`, and one that cannot be decoded throws `.malformed` — neither is reported as
    /// absence, and neither is ever silently overwritten.
    public static func read(at directory: URL) throws -> RootMarker? {
        let fileURL = directory.appendingPathComponent(filename)

        var coordinatorError: NSError?
        var outcome: Result<RootMarker?, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: fileURL,
            options: .withoutChanges,
            error: &coordinatorError
        ) { coordURL in
            outcome = Result { try decode(atFile: coordURL) }
        }

        if let coordinatorError {
            throw RootMarkerError.unreadable(url: fileURL, underlying: coordinatorError)
        }
        guard let outcome else {
            // The accessor never ran and coordination reported no error: we know nothing about the
            // file, which is emphatically not the same as knowing it is absent.
            throw RootMarkerError.unreadable(url: fileURL, underlying: CocoaError(.fileReadUnknown))
        }
        return try outcome.get()
    }

    /// Idempotent: read an existing marker if present (never overwrite its guid); else create one.
    ///
    /// The returned marker is always **durable** — read from disk, or written to disk and read back.
    /// Anything less throws, because the only thing callers do with a marker is mint links that must
    /// still resolve after a relaunch:
    /// - `.malformed` — an existing file that will not decode (left untouched, never overwritten);
    /// - `.unreadable` — an existing file that will not read (so we must not mint a replacement);
    /// - `.readOnly` — the write failed or could not be confirmed. The in-memory marker rides along
    ///   as `provisional` so a caller can say *which* identity was lost, but it is not on disk and
    ///   must never be used to mint a link.
    ///
    /// - Parameters:
    ///   - directory: The granted root URL. Caller must have started any security scope.
    ///   - kind: `.reader` or `.notes`.
    ///   - name: Human label (typically `directory.lastPathComponent`).
    /// - Returns: The effective, durable marker (existing or newly created).
    public static func ensure(
        at directory: URL,
        kind: RootKind,
        name: String
    ) throws -> RootMarker {
        let fileURL = directory.appendingPathComponent(filename)

        // 1. Fast path — an existing marker is the answer, and that is every launch after the
        //    first. A read failure propagates instead of falling through to step 2: minting a
        //    replacement over a marker we merely failed to read is the data loss. (W23.m6)
        if let existing = try read(at: directory) {
            return existing
        }

        // 2. Nothing visible — create one. The absence re-check, the write and the confirmation all
        //    happen INSIDE one write claim, because two processes that each saw absence must not
        //    each mint a GUID: the loser would hand out links naming a root the disk no longer
        //    identifies as, and those links resolve nowhere. (W23.l3)
        let provisional = RootMarker(
            guid: UUID(),
            name: name,
            kind: kind,
            createdAt: Date()
        )
        let data = try JSONEncoder().encode(provisional)

        var coordinatorError: NSError?
        var outcome: Result<RootMarker, Error>?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: [],
            error: &coordinatorError
        ) { coordURL in
            outcome = Result {
                // Re-check under the claim: a racing process may have created it since step 1.
                if let winner = try decode(atFile: coordURL) {
                    return winner   // adopt the winner rather than overwrite it
                }
                do {
                    try data.write(to: coordURL, options: .atomic)
                } catch {
                    throw RootMarkerError.readOnly(
                        url: fileURL, provisional: provisional, underlying: error
                    )
                }
                // A write that "succeeded" but left nothing readable behind is not an identity.
                guard let confirmed = try decode(atFile: coordURL) else {
                    throw RootMarkerError.readOnly(
                        url: fileURL, provisional: provisional, underlying: nil
                    )
                }
                return confirmed
            }
        }

        if let coordinatorError {
            throw RootMarkerError.readOnly(
                url: fileURL, provisional: provisional, underlying: coordinatorError
            )
        }
        guard let outcome else {
            throw RootMarkerError.readOnly(url: fileURL, provisional: provisional, underlying: nil)
        }
        return try outcome.get()
    }
}
