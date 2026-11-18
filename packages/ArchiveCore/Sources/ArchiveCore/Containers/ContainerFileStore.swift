import Foundation
import Darwin

// MARK: - Reading and writing the container file and the level map (W47.ct-spec, Tier-2)
//
// A new write class in the corpus (`SPEC/containers.md` §File safety): only `<directory>/.archivesuite/containers.json`
// and `<root>/.archivesuite/container-levels.json` are ever written, through a temporary file in `.archivesuite`
// renamed over the old one. Nothing outside `.archivesuite` is touched, and nothing is deleted but the writer's own
// temporary file. Links, files of the wrong kind, documents this build cannot read or of a newer `schemaVersion`, and
// documents changed since the writer read them are refused, never overwritten.

/// What a file was when it was read: a writer passes it back so a change in between is caught.
public struct ContainerFileStamp: Equatable, Sendable {
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int
}

public enum ContainerLoad<Document: Equatable & Sendable>: Equatable, Sendable {
    /// No document yet; a writer passes `expecting: nil`.
    case missing
    case loaded(Document, ContainerFileStamp)
    /// Of a newer `schemaVersion`: not interpreted, never overwritten.
    case newer
    /// A link, not a regular file, over the size cap, or not JSON this build reads. Left alone.
    case unreadable(String)

    public var document: Document? {
        if case .loaded(let d, _) = self { return d }
        return nil
    }

    public var stamp: ContainerFileStamp? {
        if case .loaded(_, let s) = self { return s }
        return nil
    }
}

public enum ContainerWriteError: Error, Equatable {
    /// `.archivesuite` or the document is a link or not of the expected kind.
    case notOrdinary(String)
    /// The document on disk is newer, unreadable or too big; it is left as it is.
    case refusedExisting(String)
    /// The document changed (or appeared) since the writer read it.
    case changedSinceRead
    case tooBig
    case io(String, Int32)
}

public enum ContainerFileStore {
    public static func containerFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            .appendingPathComponent(ContainerFile.fileName)
    }

    public static func levelMapURL(in root: URL) -> URL {
        root.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            .appendingPathComponent(ContainerLevelMap.fileName)
    }

    public static func load(directory: URL) -> ContainerLoad<ContainerFile> {
        read(containerFileURL(in: directory), version: ContainerFile.schemaVersion)
    }

    public static func loadLevelMap(root: URL) -> ContainerLoad<ContainerLevelMap> {
        read(levelMapURL(in: root), version: ContainerLevelMap.schemaVersion)
    }

    /// Writes `file` as `directory`'s container file. `expecting` is the stamp of the load it was edited from, or
    /// nil when that load found none.
    public static func write(_ file: ContainerFile, directory: URL, expecting: ContainerFileStamp?) throws {
        try write(file, to: containerFileURL(in: directory), version: ContainerFile.schemaVersion, expecting: expecting)
    }

    public static func writeLevelMap(_ map: ContainerLevelMap, root: URL, expecting: ContainerFileStamp?) throws {
        try write(map, to: levelMapURL(in: root), version: ContainerLevelMap.schemaVersion, expecting: expecting)
    }

    /// The nearest level map at or above `directory`, stopping at `root` (inclusive); nil outside it.
    public static func locateLevelMap(from directory: URL, within root: URL) -> URL? {
        var folder = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for _ in 0..<64 {
            let parts = folder.pathComponents
            guard parts.count >= rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
            if fileType(levelMapURL(in: folder)) == S_IFREG { return folder }
            if parts.count == rootParts.count { return nil }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: Reading

    private struct VersionDTO: Decodable { let schemaVersion: Int }

    static func read<D: Decodable & Equatable & Sendable>(_ url: URL, version: Int) -> ContainerLoad<D> {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            return errno == ENOENT ? .missing : .unreadable("cannot look at \(url.lastPathComponent) (errno \(errno))")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .unreadable("not an ordinary file") }
        guard st.st_size <= Int64(ContainerFile.maxFileBytes) else { return .unreadable("over 1 MB") }
        guard let data = readNoFollow(url) else { return .unreadable("cannot read") }
        let stamp = makeStamp(st)
        if let v = try? decoder.decode(VersionDTO.self, from: data), v.schemaVersion > version { return .newer }
        guard let doc = try? decoder.decode(D.self, from: data) else { return .unreadable("not a document this build reads") }
        return .loaded(doc, stamp)
    }

    private static func readNoFollow(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { return data }
            data.append(buffer, count: n)
            if data.count > ContainerFile.maxFileBytes { return nil }
        }
    }

    // MARK: Writing

    static func write<D: Encodable & Decodable & Equatable & Sendable>(
        _ document: D, to url: URL, version: Int, expecting: ContainerFileStamp?
    ) throws {
        let data = try encoder.encode(document)
        guard data.count <= ContainerFile.maxFileBytes else { throw ContainerWriteError.tooBig }
        let dir = url.deletingLastPathComponent()

        switch fileType(dir) {
        case nil:
            if mkdir(dir.path, 0o755) != 0 && errno != EEXIST { throw ContainerWriteError.io("mkdir", errno) }
            guard fileType(dir) == S_IFDIR else { throw ContainerWriteError.notOrdinary(ContainerFile.folderName) }
        case S_IFDIR?: break
        default: throw ContainerWriteError.notOrdinary(ContainerFile.folderName)
        }

        func checkCurrent() throws {
            let current: ContainerLoad<D> = read(url, version: version)
            switch current {
            case .missing:
                if expecting != nil { throw ContainerWriteError.changedSinceRead }
            case .loaded(_, let stamp):
                if stamp != expecting { throw ContainerWriteError.changedSinceRead }
            case .newer:
                throw ContainerWriteError.refusedExisting("of a newer schemaVersion")
            case .unreadable(let why):
                if fileType(url) != S_IFREG { throw ContainerWriteError.notOrdinary(url.lastPathComponent) }
                throw ContainerWriteError.refusedExisting(why)
            }
        }
        try checkCurrent()

        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ContainerWriteError.io("create", errno) }
        var ok = false
        defer { if !ok { unlink(temp.path) } }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 { if errno == EINTR { continue }; throw ContainerWriteError.io("write", errno) }
                    off += n
                }
            }
            guard fsync(fd) == 0 else { throw ContainerWriteError.io("fsync", errno) }
        }
        // Checked again just before the rename, so the window for another writer is the rename itself.
        try checkCurrent()
        guard rename(temp.path, url.path) == 0 else { throw ContainerWriteError.io("rename", errno) }
        ok = true
    }

    // MARK: Helpers

    static func fileType(_ url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    private static func makeStamp(_ st: stat) -> ContainerFileStamp {
        ContainerFileStamp(inode: UInt64(st.st_ino), size: Int64(st.st_size),
                           modifiedSeconds: Int(st.st_mtimespec.tv_sec),
                           modifiedNanoseconds: Int(st.st_mtimespec.tv_nsec))
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            let whole = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = whole.date(from: s) ?? fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not ISO 8601"))
        }
        return d
    }
}
