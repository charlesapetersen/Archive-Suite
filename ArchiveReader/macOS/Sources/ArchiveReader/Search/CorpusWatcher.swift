import Foundation
import CoreServices
import ArchiveCore

/// The two recovery primitives an FSEvents batch can request.
///
/// Paths stay byte-for-byte filesystem paths. No Unicode normalisation or symlink resolution belongs
/// here: the watcher is reporting the namespace that changed, and the corpus contains decomposed names.
struct CorpusWatchRequest: Sendable, Equatable {
    var paths: Set<String> = []
    var subtrees: Set<String> = []
    var fullRescan = false
    var reResolveRoot = false

    var isEmpty: Bool { paths.isEmpty && subtrees.isEmpty && !fullRescan && !reResolveRoot }

    mutating func merge(_ other: CorpusWatchRequest) {
        if other.reResolveRoot {
            self = CorpusWatchRequest(reResolveRoot: true)
            return
        }
        guard !reResolveRoot else { return }
        if other.fullRescan {
            paths.removeAll()
            subtrees.removeAll()
            fullRescan = true
            return
        }
        guard !fullRescan else { return }
        paths.formUnion(other.paths)
        subtrees.formUnion(other.subtrees)
        compactSubtrees()
        paths = paths.filter { path in !subtrees.contains { Self.contains(path, under: $0) } }
    }

    /// Reduce one callback without trusting semantic item flags. Flags choose only recovery scope or
    /// work that may be skipped (`OwnEvent` and known atomic-write siblings); every retained path is
    /// subsequently re-statted and re-read.
    static func reduce(root: URL, paths: [String], flags: [FSEventStreamEventFlags]) -> CorpusWatchRequest {
        let rootPath = canonicalRootPath(root.path)
        var request = CorpusWatchRequest()

        for (path, eventFlags) in zip(paths, flags) {
            // Root replacement outranks every other bit in a unioned event. In particular,
            // RootChanged|UserDropped must re-resolve the bookmark; walking the old pathname is the
            // weaker recovery and may inspect a different object after a rename/replacement.
            if has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)) {
                request.reResolveRoot = true
                continue
            }

            // Stream-wide recovery flags are deliberately checked BEFORE path containment. The SDK
            // says a dropped-event sentinel may carry `/`, and HistoryDone's path is meaningless.
            // Dropped events require a scan of every directory monitored by this stream — not merely
            // the callback path — so the only safe response for this one-root stream is a root pass.
            if has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped))
                || has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone))
                || has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped))
                || has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)) {
                request.fullRescan = true
                continue
            }

            guard contains(path, under: rootPath) else { continue }

            if has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagMount))
                || has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)) {
                request.reResolveRoot = true
                continue
            }

            if has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)) {
                guard !isAtomicWriteTemporarySibling(path) else { continue }
                if path == rootPath { request.fullRescan = true }
                else { request.subtrees.insert(path) }
                continue
            }

            if has(eventFlags, FSEventStreamEventFlags(kFSEventStreamEventFlagOwnEvent)) { continue }
            guard !isAtomicWriteTemporarySibling(path) else { continue }
            if path == rootPath { request.fullRescan = true }
            else { request.paths.insert(path) }
        }

        if request.reResolveRoot {
            return CorpusWatchRequest(reResolveRoot: true)
        }
        if request.fullRescan {
            return CorpusWatchRequest(fullRescan: true)
        }
        request.compactSubtrees()
        request.paths = request.paths.filter { path in
            !request.subtrees.contains { contains(path, under: $0) }
        }
        return request
    }

    /// Foundation atomic saves observed in the corpus use `a.txt.sb-858602c2-RXb79N`. Ignore that
    /// exact temporary-sibling shape; an ordinary user file merely containing `.sb-` must still be read.
    static func isAtomicWriteTemporarySibling(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.range(
            of: #"\.sb-[0-9A-Fa-f]{8}-[A-Za-z0-9]{6}$"#,
            options: .regularExpression
        ) != nil
    }

    private mutating func compactSubtrees() {
        var kept: [String] = []
        for candidate in subtrees.sorted(by: { $0.count < $1.count }) {
            if !kept.contains(where: { Self.contains(candidate, under: $0) }) {
                kept.append(candidate)
            }
        }
        subtrees = Set(kept)
    }

    static func contains(_ path: String, under root: String) -> Bool {
        path == root || path.hasPrefix(canonicalRootPath(root) + "/")
    }

    private static func canonicalRootPath(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func has(_ flags: FSEventStreamEventFlags,
                            _ flag: FSEventStreamEventFlags) -> Bool {
        (flags & flag) != 0
    }
}

enum CorpusWatcherStartResult: Equatable, Sendable {
    case started
    /// Stream creation or `FSEventStreamStart` failed. A successful start is the direct capability
    /// check: device UUID probes return nil for some valid read-only/firmlink arrangements, while a
    /// running stream proves the chosen root actually has a usable event channel.
    case journalUnavailable
}

protocol CorpusWatching: AnyObject {
    func start() -> CorpusWatcherStartResult
    func stop()
    @discardableResult func flushSync() -> Bool
}

/// A per-root FSEvents stream. It owns one additional security-scope access for exactly the stream's
/// lifetime, and it deliberately persists no event ID: launch does a full walk, then watches SinceNow.
final class CorpusWatcher: CorpusWatching, @unchecked Sendable {
    typealias Handler = @Sendable (CorpusWatchRequest) -> Void

    private final class CallbackBox: @unchecked Sendable {
        weak var owner: CorpusWatcher?
        init(owner: CorpusWatcher? = nil) { self.owner = owner }
    }

    private let root: URL
    private let handler: Handler
    private let startSecurityScope: @Sendable (URL) -> Bool
    private let stopSecurityScope: @Sendable (URL) -> Void
    private let queue = DispatchQueue(label: "ArchiveReader.CorpusWatcher", qos: .utility)
    private let callbackBox = CallbackBox()
    private var stream: FSEventStreamRef?
    private var holdsSecurityScope = false

    init(root: URL,
         startSecurityScope: @escaping @Sendable (URL) -> Bool = {
             $0.startAccessingSecurityScopedResource()
         },
         stopSecurityScope: @escaping @Sendable (URL) -> Void = {
             $0.stopAccessingSecurityScopedResource()
         },
         handler: @escaping Handler) {
        self.root = root
        self.startSecurityScope = startSecurityScope
        self.stopSecurityScope = stopSecurityScope
        self.handler = handler
        callbackBox.owner = self
    }

    func start() -> CorpusWatcherStartResult {
        if stream != nil { return .started }

        // `false` means the URL did not vend a security scope (normal for test/scratch URLs), not that
        // the path is inaccessible. Only a successful start increments the scope count and needs a stop.
        holdsSecurityScope = startSecurityScope(root)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            guard let owner = box.owner else { return }
            let array = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue()
            let paths = array as NSArray as? [String] ?? []
            let n = min(Int(count), paths.count)
            guard n > 0 else { return }
            owner.receive(paths: Array(paths.prefix(n)), flags: Array(UnsafeBufferPointer(start: rawFlags,
                                                                                         count: n)))
        }

        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagMarkSelf
        )
        guard let made = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            createFlags
        ) else {
            releaseSecurityScope()
            return .journalUnavailable
        }

        FSEventStreamSetDispatchQueue(made, queue)
        guard FSEventStreamStart(made) else {
            // `Stop` is valid only after a successful `Start` (FSEvents.h). The stream is scheduled,
            // so invalidate while it is still scheduled, then release.
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
            releaseSecurityScope()
            return .journalUnavailable
        }
        stream = made
        return .started
    }

    func stop() {
        guard let active = stream else {
            releaseSecurityScope()
            return
        }
        // FSEvents.h requires this exact order. `Stop` also waits for any callback in flight before
        // returning, so releasing the callback box's unretained context afterwards is safe.
        FSEventStreamStop(active)
        FSEventStreamInvalidate(active)       // while still scheduled on `queue`
        FSEventStreamRelease(active)
        stream = nil
        releaseSecurityScope()
    }

    @discardableResult
    func flushSync() -> Bool {
        guard let stream else { return false }
        FSEventStreamFlushSync(stream)
        return true
    }

    deinit { stop() }

    /// Internal injection point for the flag reducer. It enters through the same method as the C
    /// callback; tests use it for recovery flags the kernel cannot be forced to emit deterministically.
    func receiveForTesting(paths: [String], flags: [FSEventStreamEventFlags]) {
        receive(paths: paths, flags: flags)
    }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        let request = CorpusWatchRequest.reduce(root: root, paths: paths, flags: flags)
        if !request.isEmpty { handler(request) }
    }

    private func releaseSecurityScope() {
        if holdsSecurityScope {
            stopSecurityScope(root)
            holdsSecurityScope = false
        }
    }
}

// MARK: - Read work (never on the FSEvents queue or main actor)

struct CorpusPathChange: Sendable {
    let url: URL
    let inspection: CorpusPathInspection
}

struct CorpusSubtreeChange: Sendable {
    let url: URL
    let pass: DiscoveryPass
}

struct CorpusWatchChangeSet: Sendable {
    let paths: [CorpusPathChange]
    let subtrees: [CorpusSubtreeChange]
}

/// One-way cancellation shared by the main actor and one live-event read thread.
final class CorpusWatchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

enum CorpusWatchWork {
    static func onDedicatedThread(root: URL,
                                  request: CorpusWatchRequest,
                                  cancellation: CorpusWatchCancellation,
                                  startSecurityScope: @escaping @Sendable (URL) -> Bool = {
                                      $0.startAccessingSecurityScopedResource()
                                  },
                                  stopSecurityScope: @escaping @Sendable (URL) -> Void = {
                                      $0.stopAccessingSecurityScopedResource()
                                  },
                                  completion: @escaping @Sendable (CorpusWatchChangeSet) -> Void) {
        let thread = Thread {
            // RootFolderStore and CorpusWatcher both release their root-lifetime scopes on a root
            // switch. A subtree pass already in flight owns this third, operation-lifetime access so
            // it never continues I/O after both longer-lived grants have gone away. A cancelled task
            // that has not started reading avoids acquiring an obsolete root altogether.
            guard !cancellation.isCancelled else {
                DispatchQueue.main.async {
                    completion(CorpusWatchChangeSet(paths: [], subtrees: []))
                }
                return
            }
            let holdsSecurityScope = startSecurityScope(root)
            defer {
                if holdsSecurityScope { stopSecurityScope(root) }
            }

            var pathChanges: [CorpusPathChange] = []
            var subtreePaths = request.subtrees

            for path in request.paths.sorted() {
                guard !cancellation.isCancelled else { break }
                let url = URL(fileURLWithPath: path)
                let inspection = CorpusWalker.inspect(url)
                switch inspection {
                case .directory where CorpusWatchEligibility.includes(url, under: root):
                    subtreePaths.insert(path)
                case .directory:
                    // A hidden/package directory is outside the launch walk's universe. Remove any
                    // last-known descendants if its status changed since the previous pass.
                    pathChanges.append(CorpusPathChange(url: url, inspection: .nonRegular))
                case .directorySymbolicLink:
                    // The launch walk never traverses a directory symlink; do not expand one merely
                    // because FSEvents named it directly.
                    pathChanges.append(CorpusPathChange(url: url, inspection: .nonRegular))
                case .tracked where !CorpusWatchEligibility.includes(url, under: root):
                    pathChanges.append(CorpusPathChange(url: url, inspection: .untracked))
                default:
                    pathChanges.append(CorpusPathChange(url: url, inspection: inspection))
                }
            }

            let compacted = compact(subtreePaths)
            // A subtree supersedes exact changes below it, including an event that was delivered in
            // the same coalesced batch before the directory flag was known.
            pathChanges.removeAll { change in
                compacted.contains { CorpusWatchRequest.contains(change.url.path, under: $0) }
            }

            var subtreeChanges: [CorpusSubtreeChange] = []
            for path in compacted.sorted() {
                guard !cancellation.isCancelled else { break }
                let url = URL(fileURLWithPath: path)
                switch CorpusWalker.inspect(url) {
                case .directory where CorpusWatchEligibility.includes(url, under: root):
                    subtreeChanges.append(CorpusSubtreeChange(
                        url: url,
                        pass: LibraryScan.pass(root: url,
                                               isCancelled: { cancellation.isCancelled })
                    ))
                case .directory:
                    pathChanges.append(CorpusPathChange(url: url, inspection: .nonRegular))
                case .directorySymbolicLink:
                    // FileManager's launch walk sees but never descends a directory symlink. Preserve
                    // that universe for live events; following it here could enumerate outside root.
                    pathChanges.append(CorpusPathChange(url: url, inspection: .nonRegular))
                case let inspection:
                    // The directory may have been removed or replaced after FSEvents named it. That
                    // positive re-stat is enough to remove its old descendants; never trust ItemRemoved.
                    pathChanges.append(CorpusPathChange(url: url, inspection: inspection))
                }
            }
            let result = CorpusWatchChangeSet(paths: pathChanges, subtrees: subtreeChanges)
            DispatchQueue.main.async { completion(result) }
        }
        thread.name = "ArchiveReader.CorpusWatchWork"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func compact(_ paths: Set<String>) -> Set<String> {
        var kept: [String] = []
        for candidate in paths.sorted(by: { $0.count < $1.count }) {
            if !kept.contains(where: { CorpusWatchRequest.contains(candidate, under: $0) }) {
                kept.append(candidate)
            }
        }
        return Set(kept)
    }
}

/// Preserve the full walk's `.skipsHiddenFiles` / `.skipsPackageDescendants` universe for direct
/// events. Without this, touching `.hidden.pdf` (or a PDF inside an rtfd/app package) would make the
/// live library disagree with the next launch scan.
private enum CorpusWatchEligibility {
    static func includes(_ url: URL, under root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") && root.path.count > 1
            ? String(root.path.dropLast()) : root.path
        guard CorpusWatchRequest.contains(url.path, under: rootPath) else { return false }
        guard url.path != rootPath else { return true }

        let relative = String(url.path.dropFirst(rootPath.count + 1))
        var cursor = URL(fileURLWithPath: rootPath, isDirectory: true)
        for component in relative.split(separator: "/", omittingEmptySubsequences: false) {
            cursor.appendPathComponent(String(component))
            guard let values = try? URL(fileURLWithPath: cursor.path)
                .resourceValues(forKeys: [.isHiddenKey, .isPackageKey]) else {
                // A concurrent disappearance is classified by `CorpusWalker.inspect`; inability to
                // fetch optional eligibility metadata must not turn into a silent skip.
                return true
            }
            if values.isHidden == true || values.isPackage == true { return false }
        }
        return true
    }
}
