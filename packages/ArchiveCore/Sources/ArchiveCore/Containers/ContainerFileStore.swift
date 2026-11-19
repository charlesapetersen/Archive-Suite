import Foundation
import Darwin

// MARK: - Reading and writing the container file and the level map (W47.ct-spec, Tier-2)
//
// A new write class in the corpus (`SPEC/containers.md` §File safety): only `<directory>/.archivesuite/containers.json`
// and `<root>/.archivesuite/container-levels.json` and `container-names.json` are ever written, through a temporary file in `.archivesuite`
// renamed over the old one. Every step after opening `.archivesuite` goes through its file descriptor (`openat`,
// `renameatx_np`, `unlinkat`), so a link swapped in for it or for the document cannot send a write elsewhere. Writers
// hold `flock` on that descriptor from the check to the rename, so two apps never overwrite each other unnoticed.
// Nothing outside `.archivesuite` is touched, and nothing is deleted but the writer's own temporary file. Links, files
// of the wrong kind, documents without a readable `schemaVersion` or of a newer one, documents holding values this
// build does not read, and documents changed since the writer read them are refused, never overwritten.

/// What a file was when it was read: a writer passes it back so a change in between is caught.
public struct ContainerFileStamp: Equatable, Sendable {
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int
    /// The document held something this build drops on reading (a field, source or level it does not know). Such a
    /// document is shown but never overwritten, so a newer build's values are not erased.
    public let droppedOnReading: Bool
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
    /// The directory, `.archivesuite` or the document is a link or not of the expected kind.
    case notOrdinary(String)
    /// The document on disk is newer, unreadable, too big or holds values this build drops; it is left as it is.
    case refusedExisting(String)
    /// The document changed (or appeared) since the writer read it.
    case changedSinceRead
    /// Another writer held the lock for longer than `lockWait`.
    case busy
    case tooBig
    case io(String, Int32)
}

public enum ContainerFileStore {
    /// How long a writer waits for another's lock before giving up with `.busy`.
    public static let lockWait: TimeInterval = 5

    public static func containerFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            .appendingPathComponent(ContainerFile.fileName)
    }

    public static func levelMapURL(in root: URL) -> URL {
        root.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            .appendingPathComponent(ContainerLevelMap.fileName)
    }

    public static func load(directory: URL) -> ContainerLoad<ContainerFile> {
        load(directory, ContainerFile.fileName, version: ContainerFile.schemaVersion)
    }

    public static func loadLevelMap(root: URL) -> ContainerLoad<ContainerLevelMap> {
        load(root, ContainerLevelMap.fileName, version: ContainerLevelMap.schemaVersion)
    }

    /// Writes `file` as `directory`'s container file. `expecting` is the stamp of the load it was edited from, or
    /// nil when that load found none. Pass resolved URLs (`resolvingSymlinksInPath`): a directory that is itself a
    /// link is refused. Call it off the main thread; it may wait up to `lockWait` for another writer.
    ///
    /// `settingAside`: only on the user's explicit say-so, when the document on disk is unreadable or holds values
    /// this build drops. That document is renamed, not deleted, to `<name>.set-aside-<UTC stamp>-<id>` in
    /// `.archivesuite`, and the new one written in its place. A newer document is never set aside.
    public static func write(_ file: ContainerFile, directory: URL, expecting: ContainerFileStamp?,
                             settingAside: Bool = false) throws {
        try write(file, in: directory, name: ContainerFile.fileName, version: ContainerFile.schemaVersion,
                  expecting: expecting, settingAside: settingAside)
    }

    public static func writeLevelMap(_ map: ContainerLevelMap, root: URL, expecting: ContainerFileStamp?) throws {
        try write(map, in: root, name: ContainerLevelMap.fileName, version: ContainerLevelMap.schemaVersion,
                  expecting: expecting)
    }

    public static func namesURL(in root: URL) -> URL {
        root.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            .appendingPathComponent(ContainerNames.fileName)
    }

    public static func loadNames(root: URL) -> ContainerLoad<ContainerNames> {
        load(root, ContainerNames.fileName, version: ContainerNames.schemaVersion)
    }

    public static func writeNames(_ names: ContainerNames, root: URL, expecting: ContainerFileStamp?) throws {
        try write(names, in: root, name: ContainerNames.fileName, version: ContainerNames.schemaVersion,
                  expecting: expecting)
    }

    /// The nearest folder at or above `directory` holding a level map, stopping at `root` (inclusive); nil outside it.
    public static func locateLevelMap(from directory: URL, within root: URL) -> URL? {
        locate(ContainerLevelMap.fileName, from: directory, within: root)
    }

    /// The nearest folder at or above `directory` holding the user's standard names, as `locateLevelMap`.
    public static func locateNames(from directory: URL, within root: URL) -> URL? {
        locate(ContainerNames.fileName, from: directory, within: root)
    }

    private static func locate(_ name: String, from directory: URL, within root: URL) -> URL? {
        var folder = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for _ in 0..<64 {
            let parts = folder.pathComponents
            guard parts.count >= rootParts.count, Array(parts.prefix(rootParts.count)) == rootParts else { return nil }
            let suite = folder.appendingPathComponent(ContainerFile.folderName, isDirectory: true)
            if fileType(suite) == S_IFDIR, fileType(suite.appendingPathComponent(name)) == S_IFREG { return folder }
            if parts.count == rootParts.count { return nil }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: The `.archivesuite` descriptor

    private enum SuiteFolderError: Error { case missing, notOrdinary(String), io(String, Int32) }

    /// Reads one document. A linked or misshapen directory or `.archivesuite` reads as unreadable, not as missing.
    private static func load<D: Codable & Equatable & Sendable>(_ directory: URL, _ name: String,
                                                               version: Int) -> ContainerLoad<D> {
        switch openSuiteFolder(directory, create: false) {
        case .success(let sfd):
            defer { close(sfd) }
            return read(sfd, name, version: version)
        case .failure(.missing): return .missing
        case .failure(.notOrdinary(let what)): return .unreadable("\(what) is a link or not a folder")
        case .failure(.io(let what, let e)): return .unreadable("\(what) failed (errno \(e))")
        }
    }

    /// Opens `directory` and its `.archivesuite` without following a link at either. With `create`, makes
    /// `.archivesuite` (and only it) when it is missing.
    private static func openSuiteFolder(_ directory: URL, create: Bool) -> Result<Int32, SuiteFolderError> {
        let dfd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dfd >= 0 else {
            let e = errno
            return .failure(e == ENOENT ? .missing : e == ELOOP || e == ENOTDIR ? .notOrdinary("the directory")
                                                                                  : .io("open directory", e))
        }
        defer { close(dfd) }
        if create, mkdirat(dfd, ContainerFile.folderName, 0o755) != 0 {
            let e = errno
            if e != EEXIST { return .failure(.io("mkdir", e)) }
        }
        let sfd = openat(dfd, ContainerFile.folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sfd >= 0 else {
            let e = errno
            return .failure(e == ENOENT ? .missing : e == ELOOP || e == ENOTDIR
                            ? .notOrdinary(ContainerFile.folderName) : .io("open", e))
        }
        return .success(sfd)
    }

    // MARK: Reading

    private struct VersionDTO: Decodable { let schemaVersion: Int }

    static func read<D: Codable & Equatable & Sendable>(_ sfd: Int32, _ name: String, version: Int) -> ContainerLoad<D> {
        let fd = openat(sfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            return e == ENOENT ? .missing : .unreadable(e == ELOOP ? "a link" : "cannot open (errno \(e))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable("cannot look at it") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .unreadable("not an ordinary file") }
        guard st.st_size <= Int64(ContainerFile.maxFileBytes) else { return .unreadable("over 1 MB") }
        guard let data = readAll(fd) else { return .unreadable("cannot read") }
        guard let v = try? decoder.decode(VersionDTO.self, from: data) else { return .unreadable("no schemaVersion") }
        if v.schemaVersion > version { return .newer }
        let log = ContainerDropLog()
        let d = decoder
        d.userInfo[ContainerDropLog.key] = log
        guard v.schemaVersion >= 1, let doc = try? d.decode(D.self, from: data) else {
            return .unreadable("not a document this build reads")
        }
        return .loaded(doc, makeStamp(st, dropped: log.dropped))
    }

    private static func readAll(_ fd: Int32) -> Data? {
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

    static func write<D: Codable & Equatable & Sendable>(
        _ document: D, in directory: URL, name: String, version: Int, expecting: ContainerFileStamp?,
        settingAside: Bool = false
    ) throws {
        let data = try encoder.encode(document)
        guard data.count <= ContainerFile.maxFileBytes else { throw ContainerWriteError.tooBig }

        let sfd: Int32
        switch openSuiteFolder(directory, create: true) {
        case .success(let fd): sfd = fd
        case .failure(.missing): throw ContainerWriteError.io("open directory", ENOENT)
        case .failure(.notOrdinary(let what)): throw ContainerWriteError.notOrdinary(what)
        case .failure(.io(let what, let e)): throw ContainerWriteError.io(what, e)
        }
        defer { close(sfd) }

        // Held from the check to the rename; advisory, and every writer goes through here.
        let deadline = Date().addingTimeInterval(lockWait)
        while flock(sfd, LOCK_EX | LOCK_NB) != 0 {
            let e = errno
            if e == ENOTSUP || e == EOPNOTSUPP { break }   // a volume without locks: the checks below still hold
            guard e == EWOULDBLOCK || e == EINTR else { throw ContainerWriteError.io("flock", e) }
            guard Date() < deadline else { throw ContainerWriteError.busy }
            usleep(20_000)
        }
        defer { flock(sfd, LOCK_UN) }

        var exists = true
        let current: ContainerLoad<D> = read(sfd, name, version: version)
        switch current {
        case .missing:
            if expecting != nil { throw ContainerWriteError.changedSinceRead }
            exists = false
        case .loaded(_, let stamp):
            guard let expecting, stamp == expecting else { throw ContainerWriteError.changedSinceRead }
            if stamp.droppedOnReading {
                guard settingAside else {
                    throw ContainerWriteError.refusedExisting("holds values this build does not read")
                }
                try setAside(sfd, name)
                exists = false
            }
        case .newer:
            throw ContainerWriteError.refusedExisting("of a newer schemaVersion")
        case .unreadable(let why):
            var st = stat()
            if fstatat(sfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFREG {
                throw ContainerWriteError.notOrdinary(name)
            }
            guard settingAside else { throw ContainerWriteError.refusedExisting(why) }
            try setAside(sfd, name)
            exists = false
        }

        let temp = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(sfd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ContainerWriteError.io("create", errno) }
        var renamed = false
        defer { if !renamed { unlinkat(sfd, temp, 0) } }
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
        // A first document is put in place only if none appeared meanwhile, even from a writer that skips the lock.
        var flags: UInt32 = exists ? 0 : UInt32(RENAME_EXCL)
        while renameatx_np(sfd, temp, sfd, name, flags) != 0 {
            let e = errno
            if e == EEXIST { throw ContainerWriteError.changedSinceRead }
            // A volume without exclusive rename: the check above, under the lock where there is one, stands in.
            guard flags != 0, e == ENOTSUP || e == EOPNOTSUPP || e == EINVAL else {
                throw ContainerWriteError.io("rename", e)
            }
            var st = stat()
            if fstatat(sfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 { throw ContainerWriteError.changedSinceRead }
            flags = 0
        }
        renamed = true
    }

    /// Renames the document in place to `<name>.set-aside-<UTC stamp>-<id>`, never over another file.
    private static func setAside(_ sfd: Int32, _ name: String) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let aside = "\(name).set-aside-\(f.string(from: Date()))-\(UUID().uuidString.prefix(8))"
        guard renameatx_np(sfd, name, sfd, aside, UInt32(RENAME_EXCL)) == 0 else {
            throw ContainerWriteError.io("set aside", errno)
        }
    }

    // MARK: Helpers

    static func fileType(_ url: URL) -> mode_t? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    private static func makeStamp(_ st: stat, dropped: Bool) -> ContainerFileStamp {
        ContainerFileStamp(inode: UInt64(st.st_ino), size: Int64(st.st_size),
                           modifiedSeconds: Int(st.st_mtimespec.tv_sec),
                           modifiedNanoseconds: Int(st.st_mtimespec.tv_nsec), droppedOnReading: dropped)
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
