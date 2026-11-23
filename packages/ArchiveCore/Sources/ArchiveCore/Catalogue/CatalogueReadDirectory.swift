import Darwin
import Foundation

/// Read-only descriptor traversal. The caller holds the resolved root's security scope throughout.
struct CatalogueReadDirectory {
    typealias Status = ItemFacts.Unavailable
    typealias Artifact = ItemFacts.Artifact

    struct Identity: Codable, Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    struct FileVersion: Codable, Equatable, Sendable {
        let identity: Identity
        private let size: off_t
        private let mode: mode_t
        private let links: nlink_t
        private let flags: UInt32
        private let modifiedSeconds: Int
        private let modifiedNanoseconds: Int
        private let changedSeconds: Int
        private let changedNanoseconds: Int

        init(_ info: stat) {
            identity = Identity(info)
            size = info.st_size
            mode = info.st_mode
            links = info.st_nlink
            flags = info.st_flags
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }

        // A rename may advance ctime while leaving the file and its modification time intact.
        func matchesAcrossRename(_ other: Self) -> Bool {
            identity == other.identity && size == other.size && mode == other.mode && links == other.links
                && flags == other.flags && modifiedSeconds == other.modifiedSeconds
                && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    struct Entry {
        let descriptor: Int32
        let path: String
        let info: stat
    }

    var isDataless: @Sendable (stat) -> Bool

    func withoutDownload<T>(_ body: () throws -> T) throws -> T {
        let kind = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let scope = IOPOL_SCOPE_THREAD
        let previous = getiopolicy_np(kind, scope)
        guard previous >= 0, setiopolicy_np(kind, scope, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else {
            throw Status.offline(.root)
        }
        defer { _ = setiopolicy_np(kind, scope, previous) }
        return try body()
    }

    func withRoot<T>(_ url: URL, expected: Identity? = nil, _ body: (Entry) throws -> T) throws -> T {
        try url.withUnsafeFileSystemRepresentation { raw in
            guard let raw else { throw Status.invalid(.root) }
            var before = stat()
            guard lstat(raw, &before) == 0 else { throw Self.openError(errno, for: .root) }
            let identity = Identity(before)
            guard before.st_mode & S_IFMT == S_IFDIR, expected == nil || identity == expected else {
                throw Status.invalid(.root)
            }
            guard !isDataless(before) else { throw Status.offline(.root) }

            let fd = open(raw, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw Self.openError(errno, for: .root) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, Identity(info) == identity,
                  let path = Self.path(of: fd) else { throw Status.invalid(.root) }
            guard !isDataless(info) else { throw Status.offline(.root) }

            let result = try body(Entry(descriptor: fd, path: path, info: info))
            // A detached or replaced grant must never publish facts from its old directory.
            try validateRoot(url, identity: identity, entry: Entry(descriptor: fd, path: path, info: info))
            return result
        }
    }

    func validateRoot(_ url: URL, identity: Identity, entry: Entry) throws {
        try url.withUnsafeFileSystemRepresentation { raw in
            var current = stat()
            guard let raw, lstat(raw, &current) == 0, Identity(current) == identity,
                  Self.hasPath(entry.descriptor, entry.path) else { throw Status.invalid(.root) }
            guard !isDataless(current) else { throw Status.offline(.root) }
        }
    }

    func withParent<T>(_ components: ArraySlice<String>, in directory: Entry, _ body: (Entry) throws -> T) throws -> T {
        guard let name = components.first else { return try body(directory) }
        return try withEntry(name, in: directory, directory: true, artifact: .pdf) {
            try withParent(components.dropFirst(), in: $0, body)
        }
    }

    func withFile<T>(_ name: String, in parent: Entry, artifact: Artifact, _ body: (Entry) throws -> T) throws -> T {
        try withEntry(name, in: parent, directory: false, artifact: artifact, body)
    }

    private func withEntry<T>(_ name: String, in parent: Entry, directory: Bool, artifact: Artifact,
                              _ body: (Entry) throws -> T) throws -> T {
        var before = stat()
        guard fstatat(parent.descriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Self.openError(errno, for: artifact)
        }
        let expectedType = directory ? S_IFDIR : S_IFREG
        guard before.st_mode & S_IFMT == expectedType, directory || before.st_nlink == 1 else {
            throw Status.invalid(artifact)
        }
        guard !isDataless(before) else { throw Status.offline(artifact) }

        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        let fd = openat(parent.descriptor, name, directory ? flags | O_DIRECTORY : flags)
        guard fd >= 0 else { throw Self.openError(errno, for: artifact) }
        defer { close(fd) }

        let expectedPath = parent.path == "/" ? "/" + name : parent.path + "/" + name
        var opened = stat()
        guard fstat(fd, &opened) == 0, Identity(opened) == Identity(before),
              opened.st_mode & S_IFMT == expectedType, directory || opened.st_nlink == 1,
              Self.hasPath(fd, expectedPath) else { throw Status.invalid(artifact) }
        guard !isDataless(opened) else { throw Status.offline(artifact) }

        let result = try body(Entry(descriptor: fd, path: expectedPath, info: opened))
        var current = stat()
        guard fstatat(parent.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Identity(current) == Identity(opened), Self.hasPath(fd, expectedPath) else {
            throw Status.invalid(artifact)
        }
        guard !isDataless(current) else { throw Status.offline(artifact) }
        // Check file changes during the read. Directory contents may change independently.
        guard directory || (current.st_nlink == 1 && FileVersion(opened) == FileVersion(current)) else {
            throw Status.invalid(artifact)
        }
        return result
    }

    private static func openError(_ code: Int32, for artifact: Artifact) -> Status {
        switch code {
        case ENOENT: .missing(artifact)
        case ENODEV, ENXIO, ETIMEDOUT, ENOTCONN, EHOSTUNREACH: .offline(artifact)
        default: .invalid(artifact)
        }
    }

    private static func path(of fd: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { return nil }
        return bytes.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    static func hasPath(_ fd: Int32, _ expected: String) -> Bool {
        path(of: fd)?.utf8.elementsEqual(expected.utf8) == true
    }
}
