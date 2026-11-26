import ArchiveCore
import Foundation

/// Inventories the complete granted root once, independently of Finder metadata.
struct ReaderCatalogueScan: Sendable {
    let reader: CatalogueReader?
    let snapshot: CatalogueReader.Snapshot?
    let rows: [ArchiveFile]
    let health: CorpusScanResult
    let rootStability: RootStability
    /// The walker's spelling of the root the rows were found under, and whether that inventory was a complete,
    /// clean walk: what `revise` needs to carry this pass forward (W49.reader-catalogue-scale).
    let rootPath: String?
    let walkIsComplete: Bool
    /// `rows`' inventory entries, in row order.
    let candidates: [Candidate]
    /// The paths a revision read again; empty for a full pass, which read them all.
    var rereadPaths: Set<String> = []

    /// One PDF the inventory holds, with the file facts its row shows.
    struct Candidate: Sendable {
        let url: URL
        let relativePath: String
        let contentModified: Date?
        let contentIdentity: ContentIdentity?
        let isDataless: Bool
    }

    /// A full pass. `memory` (the previous pass's, or the warm cache's) lets each unchanged PDF and companion
    /// skip its parse; every file is still opened and checked. `warm`, when it belongs to this root, is shown
    /// through `onWarm` before the walk starts: rows as of the cache, never written from.
    static func run(root: URL, instance: UUID, memory: CatalogueReader.ReadMemory? = nil,
                    warm: ReaderCatalogueCache? = nil, isCancelled: @Sendable () -> Bool,
                    onWarm: (@Sendable ([ArchiveFile], Date) -> Void)? = nil,
                    onProgress: @escaping @Sendable (Int) -> Void) -> Self {
        CorpusWalker.withDatalessMaterializationDisabled {
            let before = CorpusRootFingerprint.capture(root)
            let reader = try? CatalogueReader(grantedRoot: root, rootInstanceID: instance,
                                              mode: .adopted, identifyPDF: CataloguePDFIdentity.identify)
            // The cache's rows name files under the root's path when it was saved: a root that has moved since
            // shows nothing warm rather than rows that point where the files no longer are.
            if let warm, let onWarm, let reader, warm.instance == instance,
               warm.rootPath == CorpusWalker.discoveredPathPrefix(for: root),
               let snapshot = reader.rememberedSnapshot(warm.memory) {
                onWarm(rows(ordered(warm.candidates()), snapshot: snapshot, provenance: .cache(asOf: warm.savedAt)),
                       warm.savedAt)
            }
            let scan = CorpusWalker.scanFingerprints(root: root, options: .init(enumerationOptions: []),
                                                     followFileSymlinks: false, isCancelled: isCancelled,
                                                     onProgress: onProgress)
            let candidates = scan.entries.compactMap { entry -> Candidate? in
                guard let rootPath = scan.rootPath, entry.url.pathExtension.lowercased() == "pdf",
                      let path = relativePath(of: entry.url, under: rootPath) else { return nil }
                return Candidate(entry, relativePath: path)
            }
            let walkIsComplete = scan.isClean && scan.vanishedMidScan == 0
            let snapshot = isCancelled() ? nil : reader?.snapshot(
                .init(relativePDFPaths: candidates.map(\.relativePath), isComplete: walkIsComplete),
                remembering: memory ?? warm?.memory
            )
            let after = CorpusRootFingerprint.capture(root)
            let stability = RootStability.between(before, after)
            let scopedSnapshot = stability == .heldStill ? snapshot : nil
            let health = CorpusScanResult(entries: [], unreadable: scan.unreadable,
                                          directoryErrors: scan.directoryErrors, filesSeen: scan.filesSeen,
                                          vanishedMidScan: scan.vanishedMidScan,
                                          rootUnreadable: scan.rootUnreadable || reader == nil,
                                          cancelled: scan.cancelled)
            let ordered = ordered(candidates)
            return Self(reader: scopedSnapshot == nil ? nil : reader, snapshot: scopedSnapshot,
                        rows: rows(ordered, snapshot: scopedSnapshot, provenance: .disk(readAt: Date())),
                        health: health, rootStability: stability, rootPath: scan.rootPath,
                        walkIsComplete: walkIsComplete, candidates: ordered)
        }
    }

    /// Carry `previous` forward through one batch of file-system events instead of walking and reading the
    /// whole root again. Only the PDFs the batch names, the PDFs whose companions it names, and the PDFs under
    /// the folders it names are listed or read again; every other row keeps its read, and owners are resolved
    /// again across the whole inventory, so a moved or removed owner still updates its members.
    ///
    /// Nil asks the caller for a full pass instead: no usable previous pass, a path outside its root, a folder
    /// that did not list cleanly, a path that could not be examined, a root that did not hold still, or
    /// cancellation. A full pass is always correct; this is only ever a cheaper way to the same answer.
    static func revise(_ previous: Self, root: URL, paths: [String], subtrees: [String],
                       isCancelled: @Sendable () -> Bool) -> Self? {
        // An incomplete inventory is not carried: owners it could not resolve may resolve now, and only a walk
        // can say the inventory is complete again.
        guard let reader = previous.reader, let snapshot = previous.snapshot, let rootPath = previous.rootPath,
              previous.rootStability == .heldStill, previous.walkIsComplete,
              previous.candidates.count == previous.rows.count else { return nil }
        return CorpusWalker.withDatalessMaterializationDisabled { () -> Self? in
            let before = CorpusRootFingerprint.capture(root)
            var candidates: [String: Candidate] = [:]
            var previousIndex: [String: Int] = [:]
            candidates.reserveCapacity(previous.candidates.count)
            previousIndex.reserveCapacity(previous.candidates.count)
            for (index, candidate) in previous.candidates.enumerated() {
                candidates[candidate.relativePath] = candidate
                previousIndex[candidate.relativePath] = index
            }
            var reread = Set<String>()
            // Folders whose previous rows are void (re-listed, or gone); applied once, at the end.
            var cleared = Set<String>()
            let companionSuffix = CatalogueRecord.companionFilename(forPDFFilename: "")

            func relative(_ path: String) -> String? {
                relativePath(of: ExactFileURL.make(path), under: rootPath)
            }
            /// A row the reader refused as an invalid PDF may have been one of two hard links, which a full read
            /// refuses together: when one link goes, the other may read again, and no event names it. Only the
            /// link that went is named, so its going asks for a full pass.
            func mayBeHardLinked(_ relativePath: String) -> Bool {
                guard let index = previousIndex[relativePath],
                      case .failure(.invalid(.pdf))? = previous.rows[index].catalogueFacts?.file else { return false }
                return true
            }
            /// List one folder again, replacing every row under it. False when it could not be listed cleanly.
            func list(_ folder: String) -> Bool {
                guard let prefix = relative(folder) else { return false }
                cleared.insert(prefix)
                let url = ExactFileURL.make(folder, isDirectory: true)
                switch Examined(url) {
                case .directory:
                    let scan = CorpusWalker.scanFingerprints(root: url, options: .init(enumerationOptions: []),
                                                             followFileSymlinks: false, isCancelled: isCancelled)
                    guard scan.isClean, scan.vanishedMidScan == 0 else { return false }
                    for entry in scan.entries where entry.url.pathExtension.lowercased() == "pdf" {
                        guard let path = relativePath(of: entry.url, under: rootPath) else { return false }
                        candidates[path] = Candidate(entry, relativePath: path)
                        reread.insert(path)
                    }
                    return true
                case .vanished, .other, .file:
                    return true   // gone, or no longer a folder: its rows go with `cleared`
                case .failed:
                    return false
                }
            }

            let folders = subtrees.sorted { $0.utf8.count < $1.utf8.count }
            for folder in folders {
                guard !isCancelled(), list(folder) else { return nil }
            }
            for path in paths.sorted() {
                guard !isCancelled() else { return nil }
                guard !folders.contains(where: { CorpusWatchRequest.contains(path, under: $0) }) else { continue }
                guard let relativePath = relative(path) else { return nil }
                if relativePath.hasSuffix(companionSuffix) {
                    // A companion names its PDF: read the PDF again if the inventory holds it.
                    let pdf = String(relativePath.dropLast(companionSuffix.count))
                    if candidates[pdf] != nil { reread.insert(pdf) }
                    continue
                }
                let url = ExactFileURL.make(path)
                switch Examined(url) {
                case .directory:
                    guard list(path) else { return nil }
                case .file(let fingerprint, let links) where url.pathExtension.lowercased() == "pdf":
                    // A new hard link changes a second path's read too, and no event names that path.
                    guard links == 1 else { return nil }
                    candidates[relativePath] = Candidate(CorpusFingerprintEntry(url: url, fingerprint: fingerprint),
                                                         relativePath: relativePath)
                    reread.insert(relativePath)
                case .file, .other, .vanished:
                    // Not a PDF the walk would list (a symlink or a folder link included), or gone. A gone path
                    // may have been a folder, so whatever was listed under it goes too.
                    guard !mayBeHardLinked(relativePath) else { return nil }
                    candidates[relativePath] = nil
                    cleared.insert(relativePath)
                case .failed:
                    return nil
                }
            }
            guard !isCancelled() else { return nil }
            if !cleared.isEmpty {
                candidates = candidates.filter { reread.contains($0.key) || !Self.isUnder($0.key, anyOf: cleared) }
            }
            // The previous order holds for every row still listed; only new rows need a place.
            var ordered: [Candidate] = []
            ordered.reserveCapacity(candidates.count)
            for candidate in previous.candidates {
                if let kept = candidates[candidate.relativePath] { ordered.append(kept) }
            }
            for added in Self.ordered(candidates.values.filter { previousIndex[$0.relativePath] == nil }) {
                ordered.insert(added, at: insertionIndex(of: added, in: ordered))
            }
            let revised = reader.snapshot(revising: snapshot,
                                          inventory: .init(relativePDFPaths: ordered.map(\.relativePath),
                                                           isComplete: previous.walkIsComplete),
                                          rereading: reread)
            guard !isCancelled(), RootStability.between(before, CorpusRootFingerprint.capture(root)) == .heldStill else {
                return nil
            }
            let health = CorpusScanResult(entries: [], unreadable: [], directoryErrors: [], filesSeen: ordered.count,
                                          vanishedMidScan: 0, rootUnreadable: false, cancelled: false)
            // A row read again, new, or depending on another file's facts is made again; any other row's facts
            // depend only on its own unchanged read, so the previous row stands.
            let readAt = Date()
            let rows = ordered.map { candidate -> ArchiveFile in
                if !reread.contains(candidate.relativePath), let index = previousIndex[candidate.relativePath],
                   Self.standsAlone(previous.rows[index]) {
                    return previous.rows[index]
                }
                return row(candidate, snapshot: revised, provenance: .disk(readAt: readAt))
            }
            var result = Self(reader: reader, snapshot: revised, rows: rows, health: health, rootStability: .heldStill,
                              rootPath: rootPath, walkIsComplete: previous.walkIsComplete, candidates: ordered)
            result.rereadPaths = reread
            return result
        }
    }

    /// One `lstat(2)` of an event path, in the walk's terms: it lists regular files and folders, never follows a
    /// symbolic link, and records the same fingerprint fields.
    private enum Examined {
        case file(CorpusFileFingerprint, links: Int), directory, other, vanished, failed

        init(_ url: URL) {
            self = url.withUnsafeFileSystemRepresentation { raw -> Examined in
                guard let raw else { return .failed }
                var info = stat()
                guard lstat(raw, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .vanished : .failed }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    return .directory
                case S_IFREG:
                    func seconds(_ value: timespec) -> TimeInterval {
                        TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
                    }
                    return .file(CorpusFileFingerprint(mtime: seconds(info.st_mtimespec), ctime: seconds(info.st_ctimespec),
                                                       size: info.st_size, inode: UInt64(info.st_ino),
                                                       isDataless: info.st_flags & UInt32(SF_DATALESS) != 0),
                                 links: Int(info.st_nlink))
                default:
                    return .other
                }
            }
        }
    }

    /// What a later launch needs to show this pass at once. Nil when there is no snapshot to remember.
    func cache(instance: UUID, savedAt: Date = Date()) -> ReaderCatalogueCache? {
        guard let memory = snapshot?.memory, let rootPath else { return nil }
        return ReaderCatalogueCache(instance: instance, rootPath: rootPath, savedAt: savedAt, memory: memory,
                                    files: candidates.map {
            ReaderCatalogueCache.File(path: $0.relativePath, mtime: $0.contentModified?.timeIntervalSince1970,
                                      inode: $0.contentIdentity?.inode, size: $0.contentIdentity?.size,
                                      isDataless: $0.isDataless)
        })
    }

    /// Whether a row's facts come from its own read alone: no companion, or one whose every document is owned
    /// by, and enclosed with, the file itself. Such a row cannot change when another file does.
    static func standsAlone(_ row: ArchiveFile) -> Bool {
        guard let facts = row.catalogueFacts else { return false }
        guard case .success(let file) = facts.file else { return true }
        let fileID = file.pair.record.fileID
        return file.pair.record.documents.allSatisfy {
            $0.ownerFileID == fileID && ($0.enclosedWith == nil || $0.enclosedWith?.ownerFileID == fileID)
        }
    }

    /// Whether `key`, or a folder above it, is in `prefixes`. Splits on the slash byte, as the filesystem does.
    static func isUnder(_ key: String, anyOf prefixes: Set<String>) -> Bool {
        if prefixes.contains(key) { return true }
        let bytes = Array(key.utf8)
        var end = bytes.count
        while let slash = bytes[..<end].lastIndex(of: UInt8(ascii: "/")) {
            if prefixes.contains(String(decoding: bytes[..<slash], as: UTF8.self)) { return true }
            end = slash
        }
        return false
    }

    /// Candidates in the order the list shows rows.
    static func ordered(_ candidates: [Candidate]) -> [Candidate] {
        candidates.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    private static func insertionIndex(of candidate: Candidate, in ordered: [Candidate]) -> Int {
        var low = 0, high = ordered.count
        let path = candidate.url.path
        while low < high {
            let middle = (low + high) / 2
            if ordered[middle].url.path.localizedStandardCompare(path) == .orderedAscending { low = middle + 1 }
            else { high = middle }
        }
        return low
    }

    /// One row per candidate, in the candidates' order.
    static func rows(_ candidates: [Candidate], snapshot: CatalogueReader.Snapshot?,
                     provenance: ArchiveFileProvenance) -> [ArchiveFile] {
        candidates.map { row($0, snapshot: snapshot, provenance: provenance) }
    }

    static func row(_ candidate: Candidate, snapshot: CatalogueReader.Snapshot?,
                    provenance: ArchiveFileProvenance) -> ArchiveFile {
        let facts = snapshot?.facts(at: candidate.relativePath)
        let record = (try? facts?.file.get())?.pair.record
        let pageByDocument = record?.pages.reduce(into: [UUID: Int]()) {
            $0[$1.documentID] = min($0[$1.documentID] ?? $1.physicalIndex, $1.physicalIndex)
        } ?? [:]
        let selections = (record?.documents ?? []).compactMap { document in
            pageByDocument[document.id].flatMap { snapshot?.facts(at: candidate.relativePath, physicalPageIndex: $0) }
        }
        return ArchiveFile(url: candidate.url, name: candidate.url.lastPathComponent, fileType: "PDF",
                           tags: ReaderCatalogueFacets.tags(file: facts, document: facts),
                           contentModified: candidate.contentModified, contentIdentity: candidate.contentIdentity,
                           isDataless: candidate.isDataless, provenance: provenance, isCatalogue: true,
                           catalogueFacts: facts, catalogueDocuments: selections)
    }

    static func relativePath(of url: URL, under rootPath: String) -> String? {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return url.withUnsafeFileSystemRepresentation { representation in
            guard let representation, let path = String(validatingCString: representation),
                  path.utf8.starts(with: prefix.utf8) else { return nil }
            return String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        }
    }
}

extension ReaderCatalogueScan.Candidate {
    init(_ entry: CorpusFingerprintEntry, relativePath: String) {
        self.init(url: entry.url, relativePath: relativePath,
                  contentModified: Date(timeIntervalSince1970: entry.fingerprint.mtime),
                  contentIdentity: ContentIdentity(entry.fingerprint), isDataless: entry.fingerprint.isDataless)
    }
}

/// The catalogue list as of its last pass, saved so the next launch can show it before the walk finishes
/// (W49.reader-catalogue-scale). A cache, never a source: its rows are shown as of `savedAt` and replaced by
/// the revalidating pass, and every read it saves is reused only for a file whose version is unchanged.
struct ReaderCatalogueCache: Codable, Sendable {
    static let schema = 1

    struct File: Codable, Sendable {
        let path: String
        let mtime: TimeInterval?
        let inode: UInt64?
        let size: Int64?
        let isDataless: Bool
    }

    var schema = Self.schema
    /// The build that saved it. Another build's cache is not used: what it remembers about each PDF (its embedded
    /// identity, or that it has none) is what that build's reader found, and a later reader may find more.
    var build = Self.currentBuild
    let instance: UUID
    let rootPath: String
    let savedAt: Date
    let memory: CatalogueReader.ReadMemory
    let files: [File]

    func candidates() -> [ReaderCatalogueScan.Candidate] {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return files.map { file in
            ReaderCatalogueScan.Candidate(
                url: ExactFileURL.make(prefix + file.path), relativePath: file.path,
                contentModified: file.mtime.map { Date(timeIntervalSince1970: $0) },
                contentIdentity: file.inode.flatMap { inode in file.size.map { ContentIdentity(inode: inode, size: $0) } },
                isDataless: file.isDataless)
        }
    }

    static let currentBuild: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }()

    static func url(in directory: URL, instance: UUID) -> URL {
        directory.appendingPathComponent("\(instance.uuidString).plist")
    }

    /// The saved cache for `instance`, or nil when there is none, it does not decode, or it is another schema's.
    static func load(from directory: URL, instance: UUID) -> Self? {
        guard let data = try? Data(contentsOf: url(in: directory, instance: instance)),
              let cache = try? PropertyListDecoder().decode(Self.self, from: data),
              cache.schema == schema, cache.build == currentBuild, cache.instance == instance else { return nil }
        return cache
    }
}

/// Writes catalogue caches one at a time, off the main thread; a newer cache replaces one still waiting, so a
/// burst of event batches costs one write per burst rather than one per batch.
final class ReaderCatalogueCacheWriter: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var waiting: ReaderCatalogueCache?
    private var writing = false
    private let queue = DispatchQueue(label: "ArchiveReader.CatalogueCacheWriter", qos: .utility)

    init(directory: URL) { self.directory = directory }

    /// Save `cache` after `delay` seconds, unless a newer one replaces it first. A revision passes a delay, so
    /// that a stream of event batches is not one 50 MB write each (124,647 rows: 2.3 s to encode).
    func save(_ cache: ReaderCatalogueCache, after delay: TimeInterval = 0) {
        lock.lock()
        waiting = cache
        let start = !writing
        writing = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + delay) { self.drain() } }
    }

    /// Blocks until every cache handed to `save` so far is on disk. For tests, and only after an undelayed save.
    func flush() { queue.sync {} }

    private func drain() {
        while true {
            lock.lock()
            guard let next = waiting else {
                writing = false
                lock.unlock()
                return
            }
            waiting = nil
            lock.unlock()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let url = ReaderCatalogueCache.url(in: directory, instance: next.instance)
                try encoder.encode(next).write(to: url, options: .atomic)
            } catch {
                NSLog("ReaderCatalogueCache: could not save: \(error)")
            }
        }
    }
}
