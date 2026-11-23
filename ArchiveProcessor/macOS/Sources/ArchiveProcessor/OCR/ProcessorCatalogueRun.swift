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
        var preservation: ProcessorPreservationFiling? = nil
    }

    let outputRoot: URL
    let workingRoot: URL
    private let workingDirectory: DirectoryIdentity?
    let openedAt: Date
    let sources: [URL]
    var preservationIntake: [URL: ProcessorPreservationFiling.Intake]?
    var files: [File]?
    var inputJournalDigests: [String: String]?

    private struct DirectoryIdentity: Codable, Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    var hasWorkingDirectory: Bool {
        guard let live = DirectoryIdentity(workingRoot) else { return false }
        return workingDirectory.map { $0 == live } ?? true
    }

    private struct Envelope: Codable {
        let contents: Data
        let digest: Data
    }

    static func create(outputRoot: URL, sources: [URL], journal: URL,
                       preservationIntake: [URL: ProcessorPreservationFiling.Intake]?) throws -> Self {
        let working = journal.deletingLastPathComponent()
            .appendingPathComponent("catalogue-work-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let identity = DirectoryIdentity(working) else { throw CocoaError(.fileWriteNoPermission) }
        let run = Self(outputRoot: outputRoot.standardizedFileURL, workingRoot: working, workingDirectory: identity,
                       openedAt: Date(), sources: sources, preservationIntake: preservationIntake)
        do {
            try run.save(to: journal, new: true)
            return run
        } catch {
            if !OCRProcessor.workingOutputOccupied(journal) && run.hasWorkingDirectory {
                try? FileManager.default.removeItem(at: working)
            }
            throw error
        }
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
              run.outputRoot.isFileURL, run.hasWorkingDirectory,
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
        guard hasWorkingDirectory, contains(working) else { throw CocoaError(.fileWriteInvalidFileName) }
        let input = open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(input) }
        var before = stat()
        guard fstat(input, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnknown)
        }
        let copy = open(working.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard copy >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var copied = false
        defer {
            close(copy)
            if !copied { unlink(working.path) }
        }
        var after = stat(), written = stat()
        guard fcopyfile(input, copy, nil, copyfile_flags_t(COPYFILE_ALL)) == 0,
              fstat(input, &after) == 0, fstat(copy, &written) == 0,
              before.st_size == after.st_size, after.st_size == written.st_size,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              fcntl(copy, F_FULLFSYNC) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        copied = true
    }

    private struct PreservationFilingError: LocalizedError {
        let filename: String
        let underlying: Error
        var errorDescription: String? { "Could not file “\(filename)” with its originals. \(underlying.localizedDescription)" }
    }

    func fileOutputs() throws -> [URL] {
        guard hasWorkingDirectory, let files else { throw CocoaError(.fileReadCorruptFile) }
        for file in files {
            try Task.checkCancellation()
            do {
                _ = try file.filing.file(preparedPDF: file.prepared, record: file.record, preservation: file.preservation)
            } catch where file.preservation != nil {
                throw PreservationFilingError(filename: file.destination.lastPathComponent, underlying: error)
            }
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
