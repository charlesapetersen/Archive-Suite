import ArchiveCore
import Darwin
import Foundation

// MARK: - Improve OCR: receiving a hand-off (W44.reocr-processor)

/// Receives an `archiveprocessor://improve-ocr` request (`execution-plans/reocr/00-plan.md` §3). A request only opens
/// the review dialog: nothing here reads a corpus file, spends money, changes a flag or writes a PDF.
///
/// A manifest is resolved by its UUID under `<shared support>/Requests/`, never by a path from the URL. The folder
/// must be a real directory owned by this user with no group or other access; the manifest a regular file, not a
/// link, owned by this user, mode 0600 or tighter, at most 1 MiB. Each request ID opens the dialog once: the ID is
/// recorded as one file created exclusively under the Processor's own `Consumed/`, so a repeat (a replayed URL, a
/// second click) focuses what is open instead of starting again, and no shared JSON is read, changed and rewritten.
struct ImproveOCRRequestStore {
    /// The connected shared support folder (`~/Library/Application Support/ArchiveSuite/ImproveOCR` by default).
    let sharedSupport: URL
    /// The Processor's own state folder for the feature, where consumed request IDs are recorded.
    let privateState: URL

    struct Entry: Equatable, Sendable {
        let relativePath: String
        let pairIndices: [Int]?
        /// What the sender saw, from a manifest; nil for an inline request. Checked again at open and at commit.
        let expectedFileNumber: UInt64?
        let expectedByteCount: Int64?
        let expectedSHA256: String?
    }

    struct Resolved: Equatable, Sendable {
        let requestID: UUID
        let rootGUID: UUID
        /// Only a way to locate the folder; the Processor's own grant and the root marker decide.
        let rootPathHint: String?
        let entries: [Entry]
    }

    enum Outcome: Equatable, Sendable {
        case open(Resolved)
        /// This request was received before: focus its dialog or result, never run it again.
        case alreadyOpened(UUID)
        /// "Select the files again": the request is older than a day, or its manifest is gone.
        case selectAgain(UUID, String)
        case refused(String)
    }

    static let requestsFolder = "Requests"
    static let consumedFolder = "Consumed"

    /// `consumes: false` checks without recording the ID, so a request that cannot be shown yet (no archive, a
    /// dialog already up) stays pending; the caller then records it with `markOpened` just before showing it.
    func receive(_ request: ImproveOCRRequest, now: Date = Date(), consumes: Bool = true) -> Outcome {
        let id = request.requestID
        func record() -> Outcome? { consumes ? consume(id) : (isConsumed(id) ? .alreadyOpened(id) : nil) }
        switch request {
        case .inline(_, let root, let paths):
            // A staged manifest under the same ID is a conflicting second form of one request.
            if manifestExists(id) { return .refused("this request names its files twice, in the link and in a manifest") }
            if let o = record() { return o }
            return .open(Resolved(requestID: id, rootGUID: root, rootPathHint: nil, entries: paths.map {
                Entry(relativePath: $0, pairIndices: nil, expectedFileNumber: nil, expectedByteCount: nil, expectedSHA256: nil)
            }))
        case .manifest:
            if isConsumed(id) { return .alreadyOpened(id) }
            let data: Data
            switch readManifest(id) {
            case .success(let d): data = d
            case .failure(.missing): return .selectAgain(id, "the request's list of files is gone")
            case .failure(.unsafe(let why)): return .refused(why)
            }
            let manifest: ImproveOCRManifest
            do {
                manifest = try ImproveOCRManifest.decode(data, expecting: id, now: now)
            } catch ImproveOCRManifest.ValidationError.expired {
                return .selectAgain(id, "the request is more than a day old")
            } catch {
                return .refused("the request's list of files is not valid (\(error))")
            }
            if let o = record() { return o }
            return .open(Resolved(requestID: id, rootGUID: manifest.rootGUID, rootPathHint: manifest.rootPathHint,
                                  entries: manifest.entries.map {
                Entry(relativePath: $0.relativePath, pairIndices: $0.pairIndices.map { Array(Set($0)).sorted() },
                      expectedFileNumber: $0.fileNumber, expectedByteCount: $0.byteCount, expectedSHA256: $0.sha256)
            }))
        }
    }

    // MARK: Consumed IDs

    /// Records a request checked with `receive(consumes: false)` as opened; nil when this call recorded it, else the
    /// outcome to show instead (another link with the same ID got there first).
    func markOpened(_ id: UUID) -> Outcome? { consume(id) }

    private func consumedURL(_ id: UUID) -> URL {
        privateState.appendingPathComponent(Self.consumedFolder, isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased())
    }

    func isConsumed(_ id: UUID) -> Bool {
        var st = stat()
        return lstat(consumedURL(id).path, &st) == 0
    }

    /// Records the ID; nil when this call recorded it, else the outcome to return instead.
    private func consume(_ id: UUID) -> Outcome? {
        let dir = privateState.appendingPathComponent(Self.consumedFolder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .refused("the Processor cannot record the request (\(error.localizedDescription))")
        }
        let fd = open(consumedURL(id).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if fd < 0 {
            return errno == EEXIST ? .alreadyOpened(id)
                : .refused("the Processor cannot record the request (\(String(cString: strerror(errno))))")
        }
        fsync(fd)
        close(fd)
        let dfd = open(dir.path, O_RDONLY | O_DIRECTORY)
        if dfd >= 0 { fsync(dfd); close(dfd) }
        return nil
    }

    // MARK: The manifest

    enum ReadError: Error, Equatable {
        case missing
        case unsafe(String)
    }

    private func requestsDirectory() -> URL {
        sharedSupport.appendingPathComponent(Self.requestsFolder, isDirectory: true)
    }

    private func manifestURL(_ id: UUID) -> URL {
        requestsDirectory().appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func manifestExists(_ id: UUID) -> Bool {
        var st = stat()
        return lstat(manifestURL(id).path, &st) == 0
    }

    /// The manifest's bytes, read through one descriptor opened without following a link, so the checks and the read
    /// are of the same file.
    func readManifest(_ id: UUID) -> Result<Data, ReadError> {
        let dir = requestsDirectory().path
        var dst = stat()
        guard lstat(dir, &dst) == 0 else { return .failure(.missing) }
        guard (dst.st_mode & S_IFMT) == S_IFDIR else { return .failure(.unsafe("the requests folder is not a plain folder")) }
        guard dst.st_uid == getuid() else { return .failure(.unsafe("the requests folder belongs to another user")) }
        guard (dst.st_mode & 0o077) == 0 else { return .failure(.unsafe("other users can reach the requests folder")) }

        let fd = open(manifestURL(id).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            switch errno {
            case ENOENT: return .failure(.missing)
            case ELOOP: return .failure(.unsafe("the request's list of files is a link"))
            default: return .failure(.unsafe("the request's list of files cannot be read (\(String(cString: strerror(errno))))"))
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.unsafe("the request's list of files cannot be read")) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.unsafe("the request's list of files is not a plain file")) }
        guard st.st_uid == getuid() else { return .failure(.unsafe("the request's list of files belongs to another user")) }
        guard (st.st_mode & 0o077) == 0 else { return .failure(.unsafe("other users can read or change the request's list of files")) }
        guard st.st_size <= Int64(ImproveOCRManifest.maxBytes) else {
            return .failure(.unsafe("the request's list of files is larger than 1 MiB"))
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { return .failure(.unsafe("the request's list of files cannot be read")) }
            if n == 0 { break }
            data.append(buffer, count: n)
            if data.count > ImproveOCRManifest.maxBytes {
                return .failure(.unsafe("the request's list of files is larger than 1 MiB"))
            }
        }
        return .success(data)
    }
}
