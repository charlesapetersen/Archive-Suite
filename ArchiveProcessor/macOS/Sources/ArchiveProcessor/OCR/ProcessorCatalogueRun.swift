import ArchiveCore
import CryptoKit
import Darwin
import Foundation

/// Frozen Process Files outputs. A completed pair can be reverified after relaunch without
/// rerunning OCR or reserving a new destination.
struct ProcessorCatalogueRun: Codable, Sendable {
    final class Lease {
        private let descriptor: Int32

        init(journal: URL) throws {
            let url = journal.deletingLastPathComponent().appendingPathComponent("catalogue-processing.lock")
            let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                throw CatalogueWriter.Failure.busy
            }
            descriptor = fd
        }

        deinit { close(descriptor) }
    }

    struct Export: Codable, Sendable {
        let prepared: URL
        let destination: URL
    }

    struct File: Codable, Sendable {
        let workingPDF: URL
        let prepared: URL
        let sources: [URL]
        let destination: URL
        let record: Data
        let filing: ProcessorCatalogueFiling
        let exports: [Export]
    }

    let outputRoot: URL
    let workingRoot: URL
    let openedAt: Date
    let sources: [URL]
    var files: [File]?

    private struct Envelope: Codable {
        let contents: Data
        let digest: Data
    }

    static func create(outputRoot: URL, sources: [URL], journal: URL) throws -> Self {
        let working = journal.deletingLastPathComponent()
            .appendingPathComponent("catalogue-work-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let run = Self(outputRoot: outputRoot.standardizedFileURL, workingRoot: working,
                       openedAt: Date(), sources: sources)
        try run.save(to: journal, new: true)
        return run
    }

    static func load(from journal: URL) throws -> Self {
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: journal))
        guard envelope.digest == Data(SHA256.hash(data: envelope.contents)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let run = try decoder.decode(Self.self, from: envelope.contents)
        let stateRoot = journal.deletingLastPathComponent().standardizedFileURL
        let name = run.workingRoot.lastPathComponent
        let prefix = "catalogue-work-"
        guard run.workingRoot.deletingLastPathComponent().standardizedFileURL == stateRoot,
              name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
              run.outputRoot.isFileURL,
              (run.files ?? []).allSatisfy({ run.contains($0.workingPDF) && run.contains($0.prepared) && $0.filing.root == run.outputRoot
                  && $0.exports.allSatisfy { run.contains($0.prepared) } }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return run
    }

    func save(to journal: URL, new: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        let envelope = try encoder.encode(Envelope(contents: data, digest: Data(SHA256.hash(data: data))))
        try envelope.write(to: journal, options: new ? .withoutOverwriting : .atomic)
        try Self.flushFileAndParent(journal)
    }

    static func flushFileAndParent(_ file: URL) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let dir = open(file.deletingLastPathComponent().path, O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard dir >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(dir) }
        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) == 0, fsync(dir) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func contains(_ url: URL) -> Bool {
        let base = workingRoot.standardizedFileURL.pathComponents
        let path = url.standardizedFileURL.pathComponents
        return path.count > base.count && path.starts(with: base, by: { $0.utf8.elementsEqual($1.utf8) })
    }

    func copyPreOCRSource(_ source: URL, to working: URL) throws {
        guard contains(working) else { throw CocoaError(.fileWriteInvalidFileName) }
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        let copy = open(working.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard copy >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(copy) }
        var after = stat(), written = stat()
        guard fcopyfile(input, copy, nil, copyfile_flags_t(COPYFILE_ALL)) == 0,
              fstat(input, &after) == 0, fstat(copy, &written) == 0,
              before.st_size == after.st_size, after.st_size == written.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func fileOutputs() throws -> [URL] {
        guard let files else { throw CocoaError(.fileReadCorruptFile) }
        for file in files {
            try Task.checkCancellation()
            _ = try file.filing.file(preparedPDF: file.prepared, record: file.record)
        }
        var unfiled: [URL] = []
        for file in files {
            for export in file.exports {
                do { try file.filing.fileExport(export.prepared, to: export.destination) }
                catch { unfiled.append(export.prepared) }
            }
        }
        return unfiled
    }
}
