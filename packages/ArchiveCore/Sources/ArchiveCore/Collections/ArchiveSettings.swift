import Darwin
import Foundation

/// The archive's own settings, shared by the apps (`SPEC/collection-settings.md` §"The archive's settings";
/// `W49.storage-finder-reader-mirror`). One small document at the archive root, the folder the Reader was
/// granted, which carries `RootMarker`: `<root>/.archivesuite/archive-settings.json`. Today it holds one
/// choice, whether the archive mirrors its fields to Finder tags (owner, 2026-11-27: off unless turned on).
public struct ArchiveSettings: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let folderName = ".archivesuite"
    public static let fileName = "archive-settings.json"
    static let maximumBytes = 64 * 1024

    public var mirrorFinderTags: Bool
    public var updatedAt: Date?

    public init(mirrorFinderTags: Bool, updatedAt: Date? = nil) {
        self.mirrorFinderTags = mirrorFinderTags
        self.updatedAt = updatedAt
    }

    public enum Failure: Error, Equatable {
        /// Written by a newer build: neither read nor replaced.
        case newer(Int)
        case unreadable(String)
        /// A link, or not an ordinary folder or file, where the document goes: left alone.
        case notOrdinary
        case io(String)
    }

    // MARK: Reading

    /// The archive's document, nil when it has none (the archive has not chosen: mirroring is off).
    public static func read(root: URL) throws -> ArchiveSettings? {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        defer { close(directory) }
        let folder = openat(directory, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            if errno == ENOENT { return nil }
            throw errno == ENOTDIR || errno == ELOOP ? Failure.notOrdinary : Failure.io(String(cString: strerror(errno)))
        }
        defer { close(folder) }
        let file = openat(folder, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw errno == ELOOP ? Failure.notOrdinary : Failure.io(String(cString: strerror(errno)))
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.notOrdinary }
        guard info.st_size <= maximumBytes else { throw Failure.unreadable("over 64 KB") }
        let data = try FileHandle(fileDescriptor: file, closeOnDealloc: false).readToEnd() ?? Data()
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> ArchiveSettings {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? Int else { throw Failure.unreadable("not an archive settings document") }
        guard version <= schemaVersion else { throw Failure.newer(version) }
        let updated = (object["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ArchiveSettings(mirrorFinderTags: object["mirrorFinderTags"] as? Bool ?? false, updatedAt: updated)
    }

    /// The archive root a folder belongs to: the nearest folder at or above it carrying a Reader `RootMarker`.
    /// Nil when there is none up to the volume's root. Read-only; a marker that cannot be read stops the walk
    /// as "unknown" (nil) rather than skipping past it.
    public static func archiveRoot(containing folder: URL) -> URL? {
        var directory = folder.standardizedFileURL
        while true {
            switch Result(catching: { try RootMarker.read(at: directory) }) {
            case .success(let marker?) where marker.kind == .reader: return directory
            case .success: break
            case .failure: return nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path || isVolumeRoot(directory) { return nil }
            directory = parent
        }
    }

    private static func isVolumeRoot(_ url: URL) -> Bool {
        (try? url.uncached.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    /// Whether filed output in `folder` mirrors its fields to Finder tags: the archive's own choice when the
    /// folder is inside an archive (its document, else off), else `outsideArchive` (the Processor's general
    /// setting). An archive document that cannot be read counts as off.
    public static func mirrorsFinderTags(inFolder folder: URL, outsideArchive: Bool) -> Bool {
        guard let root = archiveRoot(containing: folder) else { return outsideArchive }
        return ((try? read(root: root)) ?? nil)?.mirrorFinderTags ?? false
    }

    // MARK: Writing

    /// Record the archive's choice. Creates `.archivesuite` (one level) in an existing root, writes atomically
    /// (a temporary file renamed in the same folder), never through a link, and leaves a newer build's document
    /// alone.
    public static func write(_ settings: ArchiveSettings, root: URL) throws {
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        defer { close(directory) }
        guard mkdirat(directory, folderName, 0o755) == 0 || errno == EEXIST else {
            throw Failure.io(String(cString: strerror(errno)))
        }
        let folder = openat(directory, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else {
            throw errno == ENOTDIR || errno == ELOOP ? Failure.notOrdinary : Failure.io(String(cString: strerror(errno)))
        }
        defer { close(folder) }
        var existing = stat()
        if fstatat(folder, fileName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG else { throw Failure.notOrdinary }
            if case .newer(let version)? = Result(catching: { try read(root: root) }).failure as? Failure {
                throw Failure.newer(version)
            }
        } else if errno != ENOENT {
            throw Failure.io(String(cString: strerror(errno)))
        }
        let object: [String: Any] = [
            "schemaVersion": schemaVersion,
            "mirrorFinderTags": settings.mirrorFinderTags,
            "updatedAt": ISO8601DateFormatter().string(from: settings.updatedAt ?? Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        let temporary = ".\(fileName).\(UUID().uuidString.lowercased()).tmp"
        let file = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard file >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        var renamed = false
        defer {
            close(file)
            if !renamed { unlinkat(folder, temporary, 0) }
        }
        let written = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, data.count) }
        guard written == data.count, fsync(file) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
        guard renameat(folder, temporary, folder, fileName) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
        renamed = true
        _ = fsync(folder)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
