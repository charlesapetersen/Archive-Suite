import CryptoKit
import Darwin
import Foundation
import ArchiveCore

// MARK: - Improve OCR: building the hand-off to the Processor (W44.reocr-reader)

/// Builds the `archiveprocessor://improve-ocr` link for a selection (`SPEC/improve-ocr.md` §2). Up to eight files go
/// in the link itself; a larger selection, or one whose link would pass 8 KiB, is staged as a manifest in the shared
/// support folder with each file's inode, size and SHA-256, so the Processor can refuse a file that changed since.
/// Reading only: the files are read to hash them, never written; the manifest is ArchiveCore's exclusive publish.
/// The link only opens the Processor's review dialog. It never runs OCR, spends, clears a flag or writes a file.
enum ImproveOCRHandoff {
    enum Problem: Error, Equatable, CustomStringConvertible {
        case nothingToSend
        case noArchiveIdentity
        case twoArchives
        case tooMany(Int)
        case unreadable(String)
        case staging(String)

        var description: String {
            switch self {
            case .nothingToSend: "Select the PDFs whose OCR should be improved."
            case .noArchiveIdentity: PoorOCRFlagGuard.Refusal.noArchiveIdentity.description
            case .twoArchives: "The selection holds files from two archive folders; send each folder's files on its own."
            case .tooMany(let n): "Improve OCR takes at most \(ImproveOCRManifest.maxEntries) files at a time; \(n) are selected."
            case .unreadable(let name): "\(name) cannot be read, so it cannot be sent to Archive Processor."
            case .staging(let why): "The list of files could not be saved for Archive Processor (\(why))."
            }
        }
    }

    /// The link for `files`, keyed by their archive (`ImproveOCRArchive.root(for:)`, the same root the flag records
    /// use), staging a manifest in `support` when the selection does not fit in a link.
    static func link(for files: [URL], archive: ImproveOCRArchive, support: URL,
                     requestID: UUID = UUID(), now: Date = Date()) throws -> URL {
        let pdfs = files.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else { throw Problem.nothingToSend }
        guard pdfs.count <= ImproveOCRManifest.maxEntries else { throw Problem.tooMany(pdfs.count) }
        var archiveRoot: ImproveOCRArchive.Root?
        for file in pdfs {
            switch archive.root(for: file) {
            case .root(let r):
                if let archiveRoot, archiveRoot != r { throw Problem.twoArchives }
                archiveRoot = r
            case .outside: throw Problem.unreadable(file.lastPathComponent)
            case .noIdentity: throw Problem.noArchiveIdentity
            }
        }
        guard let archiveRoot else { throw Problem.nothingToSend }
        let root = archiveRoot.url, rootGUID = archiveRoot.guid
        var keyed: [(url: URL, path: String)] = []
        for file in pdfs {
            guard let key = try? ImproveOCRFlagStore.FileKey(rootGUID: rootGUID, root: root, file: file) else {
                throw Problem.unreadable(file.lastPathComponent)
            }
            keyed.append((file, key.relativePath))
        }
        if keyed.count <= ImproveOCRRequest.maxInlineFiles,
           let url = try? ImproveOCRRequest.inline(requestID: requestID, rootGUID: rootGUID,
                                                    relativePaths: keyed.map(\.path)).url() {
            return url
        }
        var entries: [ImproveOCRManifest.Entry] = []
        for item in keyed {
            guard let seen = fingerprint(item.url) else { throw Problem.unreadable(item.url.lastPathComponent) }
            entries.append(.init(relativePath: item.path, fileNumber: seen.inode, byteCount: seen.size, sha256: seen.sha256))
        }
        let manifest = ImproveOCRManifest(requestID: requestID, createdAt: now, rootGUID: rootGUID,
                                          rootPathHint: root.path, entries: entries)
        do { try manifest.stage(in: support, now: now) } catch { throw Problem.staging(ImproveOCRSupport.describe(error)) }
        return try ImproveOCRRequest.manifest(requestID: requestID).url()
    }

    /// The file the Reader sees now: inode, size and the SHA-256 of its bytes, read through one descriptor opened
    /// without following a link. Nil when it is not a readable regular file.
    static func fingerprint(_ url: URL) -> (inode: UInt64, size: Int64, sha256: String)? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size > 0 else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            hasher.update(data: buffer[0..<n])
            total += Int64(n)
        }
        guard total == st.st_size else { return nil }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (UInt64(st.st_ino), Int64(st.st_size), digest)
    }
}
