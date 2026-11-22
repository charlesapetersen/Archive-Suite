import ArchiveCore
import Darwin
import Foundation

/// A frozen filing request that survives relaunch or a partially published pair.
struct ProcessorCatalogueFiling: Codable, Sendable {
    let operationID: UUID
    let root: URL
    let rootInstanceID: UUID
    let relativePath: String
    let destination: CataloguePairFiler.Destination
    private var occurrence: CatalogueAssociation.Occurrence {
        CatalogueAssociation.Occurrence(rootInstanceID: rootInstanceID, relativePath: relativePath)
    }

    init(operationID: UUID, root: URL, rootInstanceID: UUID, destination: URL) throws {
        let directory = root.standardizedFileURL
        let relative = try Self.relativeComponents(destination, in: directory)
        guard !relative.isEmpty else { throw ItemFacts.Unavailable.invalid(.root) }
        try Self.withDirectory(destination.deletingLastPathComponent(), in: directory) { _ in }
        let path = relative.joined(separator: "/")
        let occurrence = CatalogueAssociation.Occurrence(rootInstanceID: rootInstanceID, relativePath: path)
        let filer = try Self.filer(root: directory, instance: rootInstanceID)
        self.operationID = operationID
        self.root = directory
        self.rootInstanceID = rootInstanceID
        relativePath = path
        self.destination = try filer.destination(at: occurrence)
    }

    func file(preparedPDF: URL, record data: Data) throws -> CataloguePairFiler.Receipt {
        let filer = try Self.filer(root: root, instance: rootInstanceID)
        return try filer.filePair(operationID: operationID, at: occurrence, record: CatalogueRecord(json: data),
                                  preparedPDF: preparedPDF, destination: destination)
    }

    private static func filer(root: URL, instance: UUID) throws -> CataloguePairFiler {
        try CataloguePairFiler(reader: CatalogueReader(grantedRoot: root, rootInstanceID: instance, mode: .adopted,
                                                      identifyPDF: CataloguePDFIdentity.identify))
    }

    private static func relativeComponents(_ url: URL, in root: URL) throws -> [String] {
        let base = root.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        guard url.isFileURL, root.isFileURL, path.starts(with: base, by: { $0.utf8.elementsEqual($1.utf8) }) else {
            throw ItemFacts.Unavailable.invalid(.root)
        }
        return Array(path.dropFirst(base.count))
    }

    /// Create/open directories under the selected root without following links inside it.
    private static func withDirectory<T>(_ folder: URL, in root: URL, body: (Int32) throws -> T) throws -> T {
        let components = try relativeComponents(folder, in: root)
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var parent = open(root.path, flags)
        guard parent >= 0 else { throw ioError() }
        defer { close(parent) }
        try requireLocal(parent)
        for name in components {
            guard mkdirat(parent, name, 0o755) == 0 || errno == EEXIST else { throw ioError() }
            let next = openat(parent, name, flags)
            guard next >= 0 else { throw ioError() }
            close(parent)
            parent = next
            try requireLocal(parent)
        }
        return try body(parent)
    }

    /// File a secondary export after the authoritative pair verifies. The working export is available
    /// until the enclosing Finish commits its ledger.
    func fileExport(_ source: URL, to export: URL) throws {
        let pdfParent = Array(relativePath.split(separator: "/").dropLast().map(String.init))
        let exportParent = try Self.relativeComponents(export.deletingLastPathComponent(), in: root)
        let child = exportParent == pdfParent + ["JSON Output"] ? "JSON Output" : nil
        guard child != nil || exportParent == pdfParent else { throw ItemFacts.Unavailable.invalid(.root) }
        let filer = try Self.filer(root: root, instance: rootInstanceID)
        try filer.withDestinationDirectory(at: occurrence, matching: destination) { parent in
            guard let child else {
                try Self.copyExport(source, to: export.lastPathComponent, in: parent)
                return
            }
            guard mkdirat(parent, child, 0o755) == 0 || errno == EEXIST else { throw Self.ioError() }
            let directory = openat(parent, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw Self.ioError() }
            defer { close(directory) }
            try Self.requireLocal(directory)
            try Self.copyExport(source, to: export.lastPathComponent, in: directory)
            guard fsync(parent) == 0 else { throw Self.ioError() }
        }
    }

    private static func copyExport(_ source: URL, to name: String, in parent: Int32) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard input >= 0 else { throw ioError() }
        defer { close(input) }
        var sourceInfo = stat()
        guard fstat(input, &sourceInfo) == 0, sourceInfo.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        let pending = ".archivesuite-export-" + UUID().uuidString.lowercased()
        let output = openat(parent, pending, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ioError() }
        defer { close(output) }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw ioError() }

        let original = FileHandle(fileDescriptor: input, closeOnDealloc: false)
        let staged = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        try original.seek(toOffset: 0)
        try staged.seek(toOffset: 0)
        while let bytes = try original.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            guard try staged.read(upToCount: bytes.count) == bytes else { throw CocoaError(.fileWriteUnknown) }
        }
        var after = stat(), made = stat(), named = stat()
        guard fstat(input, &after) == 0, fstat(output, &made) == 0, made.st_size == after.st_size,
              after.st_size == sourceInfo.st_size, after.st_ctimespec.tv_sec == sourceInfo.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == sourceInfo.st_ctimespec.tv_nsec,
              fstatat(parent, pending, &named, AT_SYMLINK_NOFOLLOW) == 0,
              made.st_dev == named.st_dev, made.st_ino == named.st_ino else { throw CocoaError(.fileWriteUnknown) }
        guard fcntl(output, F_FULLFSYNC) == 0,
              renameatx_np(parent, pending, parent, name, UInt32(RENAME_EXCL)) == 0,
              fsync(parent) == 0,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              made.st_dev == named.st_dev, made.st_ino == named.st_ino else { throw ioError() }
    }

    private static func ioError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func requireLocal(_ directory: Int32) throws {
        var volume = statfs()
        guard fstatfs(directory, &volume) == 0 else { throw ioError() }
        guard volume.f_flags & UInt32(MNT_LOCAL) != 0 else { throw CatalogueWriter.Failure.unsupportedVolume }
    }
}
