import ArchiveCore
import Darwin
import Foundation

/// Frozen source proof and page mapping. The original stays recoverable until this filing succeeds.
struct ProcessorPreservationFiling: Codable, Sendable {
    struct Intake: Codable, Sendable {
        let url: URL
        private let resolvedInput: URL?
        let source: PreservationCopy.Source

        init(url: URL, resolveSelectedLink: Bool = false) throws {
            guard let format = PreservationCopy.Format(extension: url.pathExtension) else {
                throw PreservationCopy.Failure.unverified
            }
            self.url = url
            resolvedInput = resolveSelectedLink ? url.resolvingSymlinksInPath() : nil
            let fingerprint = try Self.withInput(resolvedInput ?? url) { try PreservationCopy.Fingerprint(reading: $0) }
            guard fingerprint.byteCount > 0 else { throw PreservationCopy.Failure.unverified }
            source = .init(name: url.lastPathComponent, format: format, fingerprint: fingerprint)
        }

        init(capturedJPEG url: URL, fingerprint: PreservationCopy.Fingerprint) {
            self.url = url
            resolvedInput = nil
            source = .init(name: url.lastPathComponent, format: .jpeg, fingerprint: fingerprint)
        }

        func read<T>(_ operation: (Int32) throws -> T) throws -> T {
            if let resolvedInput, url.resolvingSymlinksInPath() != resolvedInput {
                throw PreservationCopy.Failure.unverified
            }
            return try Self.withInput(resolvedInput ?? url, operation)
        }

        static func withInput<T>(_ url: URL, _ operation: (Int32) throws -> T) throws -> T {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw ProcessorPreservationFiling.ioError() }
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
                throw PreservationCopy.Failure.unverified
            }
            let value = try operation(fd)
            guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw PreservationCopy.Failure.unverified
            }
            return value
        }
    }

    struct LogicalPage {
        let source: Intake
        let originalPageIndex: Int
    }

    let sources: [Intake]
    let manifest: PreservationCopy.Manifest

    init(fileID: UUID, pages: [ProcessorCatalogueRecord.SourcePage], inputs: [LogicalPage]) throws {
        guard pages.count == inputs.count else { throw PreservationCopy.Failure.unverified }
        var unique: [Intake] = []
        var indices: [URL: Int] = [:]
        let mappings = zip(pages, inputs).map { page, input in
            let index = indices[input.source.url] ?? unique.count
            if index == unique.count {
                unique.append(input.source)
                indices[input.source.url] = index
            }
            return PreservationCopy.Page(id: page.id, sourceIndex: index, originalPageIndex: input.originalPageIndex)
        }
        sources = unique
        manifest = .init(fileID: fileID, sources: sources.map(\.source), pages: mappings)
    }

    /// Borrows the pinned destination parent under the existing catalogue lock.
    func file(in parent: Int32, record: CatalogueRecord) throws {
        try manifest.validate(against: record)
        guard try manifest.digest() == record.preservationManifestSHA256,
              sources.map(\.source) == manifest.sources, let document = record.documents.first,
              record.documents.count == 1 else { throw PreservationCopy.Failure.unverified }
        let paths = PreservationCopy.folderComponents(documentID: document.id, fileID: record.fileID)
        try Self.withDirectory(paths[0], in: parent, create: true) { preservation in
            try Self.withDirectory(paths[1], in: preservation, create: true) { documents in
                let final = paths[2]
                var existing = stat()
                if fstatat(documents, final, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
                    guard errno == ENOENT else { throw Self.ioError() }
                    try publish(final, in: documents)
                }
                try Self.withDirectory(final, in: documents) { try verify(in: $0) }
                guard fsync(documents) == 0 else { throw Self.ioError() }
            }
            guard fsync(preservation) == 0 else { throw Self.ioError() }
        }
        guard fsync(parent) == 0 else { throw Self.ioError() }
    }

    private func publish(_ final: String, in parent: Int32) throws {
        let pending = ".archivesuite-preservation-" + final
        if mkdirat(parent, pending, 0o700) != 0, errno != EEXIST { throw Self.ioError() }
        try Self.withDirectory(pending, in: parent, renamedTo: final) { folder in
            var info = stat()
            guard fstat(folder, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
                throw PreservationCopy.Failure.unverified
            }
            let map = try manifest.encoded()
            if try !Self.exists(PreservationCopy.manifestName, in: folder) {
                try Self.publishFile(PreservationCopy.manifestName, in: folder, stagingIn: parent) { fd in
                    try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: map)
                }
            }
            try Self.verifyMap(map, in: folder)

            // A resume adopts only complete files that match the frozen source proof. An unknown
            // file at a reserved name stops filing without being replaced.
            for (index, input) in sources.enumerated() {
                try Task.checkCancellation()
                let name = input.source.storedName(at: index)
                if try Self.exists(name, in: folder) {
                    try Self.verifySource(name, fingerprint: input.source.fingerprint, in: folder)
                } else {
                    try Self.publishFile(name, in: folder, stagingIn: parent) { fd in
                        try input.read { original in
                            guard fcopyfile(original, fd, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                                throw Self.ioError()
                            }
                        }
                        guard try PreservationCopy.Fingerprint(reading: fd) == input.source.fingerprint else {
                            throw PreservationCopy.Failure.unverified
                        }
                    }
                }
            }
            guard fsync(folder) == 0, Self.sameEntry(folder, named: pending, in: parent),
                  renameatx_np(parent, pending, parent, final, UInt32(RENAME_EXCL)) == 0 else { throw Self.ioError() }
        }
    }

    private static func publishFile(_ name: String, in folder: Int32, stagingIn parent: Int32,
                                    _ write: (Int32) throws -> Void) throws {
        let temporary = ".archivesuite-preservation-incoming-" + UUID().uuidString.lowercased()
        let fd = try create(temporary, in: parent)
        defer {
            if sameEntry(fd, named: temporary, in: parent) { _ = unlinkat(parent, temporary, 0) }
            close(fd)
        }
        try write(fd)
        guard fcntl(fd, F_FULLFSYNC) == 0, sameEntry(fd, named: temporary, in: parent),
              renameatx_np(parent, temporary, folder, name, UInt32(RENAME_EXCL)) == 0,
              fsync(folder) == 0, fsync(parent) == 0 else { throw ioError() }
    }

    private func verify(in folder: Int32) throws {
        try Self.verifyMap(manifest.encoded(), in: folder)
        for (index, input) in sources.enumerated() {
            try Self.verifySource(input.source.storedName(at: index), fingerprint: input.source.fingerprint, in: folder)
        }
    }

    private static func verifyMap(_ expected: Data, in folder: Int32) throws {
        try withStableFile(PreservationCopy.manifestName, in: folder) { fd, size in
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard size == expected.count, try file.read(upToCount: expected.count + 1) == expected else {
                throw PreservationCopy.Failure.unverified
            }
        }
    }

    private static func verifySource(_ name: String, fingerprint: PreservationCopy.Fingerprint, in folder: Int32) throws {
        try withStableFile(name, in: folder) { fd, size in
            guard size == fingerprint.byteCount, try PreservationCopy.Fingerprint(reading: fd) == fingerprint else {
                throw PreservationCopy.Failure.unverified
            }
        }
    }

    private static func withStableFile(_ name: String, in folder: Int32, _ operation: (Int32, off_t) throws -> Void) throws {
        let fd = try openFile(name, in: folder)
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0 else { throw ioError() }
        try operation(fd, before.st_size)
        guard fstatat(folder, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw PreservationCopy.Failure.unverified
        }
    }

    private static func exists(_ name: String, in parent: Int32) throws -> Bool {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw ioError() }
        return false
    }

    private static func withDirectory<T>(_ name: String, in parent: Int32, create: Bool = false,
                                         renamedTo: String? = nil, _ operation: (Int32) throws -> T) throws -> T {
        if create, mkdirat(parent, name, 0o755) != 0, errno != EEXIST { throw ioError() }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ioError() }
        defer { close(fd) }
        guard sameEntry(fd, named: name, in: parent) else { throw PreservationCopy.Failure.unverified }
        var volume = statfs()
        guard fstatfs(fd, &volume) == 0, volume.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw CatalogueWriter.Failure.unsupportedVolume
        }
        let result = try operation(fd)
        guard sameEntry(fd, named: renamedTo ?? name, in: parent) else { throw PreservationCopy.Failure.unverified }
        return result
    }

    private static func sameEntry(_ fd: Int32, named name: String, in parent: Int32) -> Bool {
        var named = stat(), opened = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(fd, &opened) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else { return false }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &path) == 0 else { return false }
        return path.withUnsafeBufferPointer { buffer in
            guard let start = buffer.baseAddress, let resolved = String(validatingCString: start) else { return false }
            return resolved.utf8.split(separator: UInt8(ascii: "/")).last?.elementsEqual(name.utf8) == true
        }
    }

    private static func openFile(_ name: String, in parent: Int32) throws -> Int32 {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { throw PreservationCopy.Failure.unverified }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ioError() }
        guard sameEntry(fd, named: name, in: parent), fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_flags & UInt32(SF_DATALESS) == 0 else {
            close(fd)
            throw PreservationCopy.Failure.unverified
        }
        return fd
    }

    private static func create(_ name: String, in parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw ioError() }
        return fd
    }

    private static func ioError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
