import Foundation
import UniformTypeIdentifiers

/// A syscall-fresh identity/freshness tuple for one regular corpus file.
///
/// `mtime` is content freshness; `ctime` is metadata freshness and is load-bearing because a Finder
/// tag-only write changes ctime without changing mtime. `size` and `inode` close same-timestamp rewrite
/// and path-replacement holes. Values come from one following `stat(2)`, never `URL.resourceValues`,
/// whose backing `NSURL` caches values and can make a revalidation silently observe its old answer.
public struct CorpusFileFingerprint: Sendable, Equatable {
    public let mtime: TimeInterval
    public let ctime: TimeInterval
    public let size: Int64
    public let inode: UInt64
    public let isDataless: Bool

    public init(mtime: TimeInterval, ctime: TimeInterval, size: Int64, inode: UInt64,
                isDataless: Bool) {
        self.mtime = mtime
        self.ctime = ctime
        self.size = size
        self.inode = inode
        self.isDataless = isDataless
    }
}

/// One file the walk found and could fully read.
///
/// Deliberately NOT `ArchiveFile` (the Reader's row model): this is the shared, UI-free shape both apps
/// build their own model from, so the walker can live in ArchiveCore without either app's display
/// concerns leaking into it.
public struct CorpusEntry: Sendable, Equatable {
    public let url: URL
    /// The raw tag names, exactly as `TagReading.read` returned them — never a parsed/normalised form,
    /// because the parse belongs to the caller (`DocumentTags.parse`) and a lossy walker would make
    /// discovery and writes disagree.
    public let tagNames: [String]
    public let labelNumber: Int?
    /// **Content** modification date (`.contentModificationDateKey`). A Finder-tag write changes
    /// `ctime`, not `mtime`, so this is the right key for a content-index freshness check and the
    /// WRONG one for detecting a tag change (plan §5.12).
    public let contentModified: Date?
    public let contentTypeIdentifier: String?
    /// True when the file is a cloud placeholder whose data is not on disk (`SF_DATALESS`). Reading
    /// tags does not materialise it; opening it for text extraction WOULD (plan §7a.10), so this
    /// travels with the entry to let a later indexer skip it rather than download the corpus.
    public let isDataless: Bool
    /// The fresh `stat(2)` tuple captured by the same inspection that read these tags. Optional only
    /// for source compatibility with synthetic test rows; real `CorpusWalker` results always set it.
    public let fingerprint: CorpusFileFingerprint?

    public init(url: URL, tagNames: [String], labelNumber: Int?, contentModified: Date?,
                contentTypeIdentifier: String?, isDataless: Bool,
                fingerprint: CorpusFileFingerprint? = nil) {
        self.url = url
        self.tagNames = tagNames
        self.labelNumber = labelNumber
        self.contentModified = contentModified
        self.contentTypeIdentifier = contentTypeIdentifier
        self.isDataless = isDataless
        self.fingerprint = fingerprint
    }
}

/// One entry in the cheap, tag-free revalidation walk.
public struct CorpusFingerprintEntry: Sendable, Equatable {
    public let url: URL
    public let fingerprint: CorpusFileFingerprint

    public init(url: URL, fingerprint: CorpusFileFingerprint) {
        self.url = url
        self.fingerprint = fingerprint
    }
}

/// What a fingerprint-only walk established. It deliberately has the same honest absence gate as
/// `CorpusScanResult`: a cancelled/denied/partial walk cannot turn missing cache rows into deletions.
public struct CorpusFingerprintScanResult: Sendable {
    public let entries: [CorpusFingerprintEntry]
    public let unreadable: [CorpusReadFailure]
    public let directoryErrors: [CorpusReadFailure]
    public let filesSeen: Int
    public let vanishedMidScan: Int
    /// The root itself could not be opened, so this pass examined nothing at all — see
    /// `CorpusScanResult.rootUnreadable`, which this mirrors exactly.
    public let rootUnreadable: Bool
    public let cancelled: Bool

    public var completed: Bool { !rootUnreadable && !cancelled }
    public var isClean: Bool { completed && unreadable.isEmpty && directoryErrors.isEmpty }

    public init(entries: [CorpusFingerprintEntry], unreadable: [CorpusReadFailure],
                directoryErrors: [CorpusReadFailure], filesSeen: Int, vanishedMidScan: Int,
                rootUnreadable: Bool, cancelled: Bool) {
        self.entries = entries
        self.unreadable = unreadable
        self.directoryErrors = directoryErrors
        self.filesSeen = filesSeen
        self.vanishedMidScan = vanishedMidScan
        self.rootUnreadable = rootUnreadable
        self.cancelled = cancelled
    }
}

/// Something the walk could not read, with the reason. Surfaced, never swallowed — see
/// `CorpusScanResult.isClean`.
public struct CorpusReadFailure: Sendable, Equatable {
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) { self.url = url; self.reason = reason }
}

/// What one pass of the walk established — **including what it could not establish.**
///
/// The incident this whole subsystem exists to end (2026-08-04) was an app that said *"no tagged PDFs
/// were found in this folder"* about 1,849 correctly-tagged files, because its discovery layer had no
/// way to say *"I could not look."* So every count here that means "I don't know" is separate from the
/// entries, and `isClean` is the single gate a caller must consult before treating an absence as real.
public struct CorpusScanResult: Sendable {
    /// Files that matched the predicate, in enumeration order.
    public let entries: [CorpusEntry]

    /// Files whose tags could not be read (`TagReading.read` → `.failure`). NEVER coerced to
    /// "untagged": that coercion is the tag-destroying bug fixed in `W26.deny`. A caller that already
    /// has a row for one of these URLs must KEEP it and mark it unverified (plan §7a.3).
    public let unreadable: [CorpusReadFailure]

    /// Directories the enumerator could not descend into (its `errorHandler:` fired). The overload
    /// *without* that handler — the one the pre-W26 fixture loader used — skips these in silence,
    /// which is the second way the fix could have reproduced the bug (plan §4a.2).
    public let directoryErrors: [CorpusReadFailure]

    /// Regular files encountered (matched or not, readable or not). Excludes directories, non-regular
    /// entries, and entries that vanished before they could be classified.
    public let filesSeen: Int

    /// Entries that disappeared between being enumerated and being read (`ENOENT`). Normal churn, NOT
    /// a denial: excluded from `entries`, and deliberately **not** counted as unreadable, so a rename
    /// during the walk cannot make the pass look degraded (plan §7a.12).
    public let vanishedMidScan: Int

    /// **The root itself could not be opened, so this pass examined nothing at all** — it is not a
    /// statement about the tree's contents, and `completed` is false because of it.
    ///
    /// Covers a root that does not exist, one whose permissions deny us, one that is not a directory,
    /// and an unmounted or disconnected volume. It is *not* set by a denial anywhere below the root:
    /// that is `directoryErrors`, which costs the pass `isClean` but leaves what it did read
    /// authoritative.
    public let rootUnreadable: Bool

    /// The caller's cancellation predicate returned true mid-pass.
    public let cancelled: Bool

    /// True only when the enumerator ran to its natural end.
    public var completed: Bool { !rootUnreadable && !cancelled }

    /// **The absence gate.** True only when the pass completed AND read everything it saw. Anything
    /// else means an unseen file may be present-and-unreadable rather than gone, so absence is not
    /// actionable: do not prune, do not report "nothing here" (plan §5.13 tier 1).
    public var isClean: Bool { completed && directoryErrors.isEmpty && unreadable.isEmpty }

    /// Public so a *consumer's* health mapping can be tested without staging a filesystem that
    /// reproduces every outcome (`W26.walk2`'s `DiscoveryHealth`). The walker is still the only thing
    /// that produces one from a real tree.
    public init(entries: [CorpusEntry], unreadable: [CorpusReadFailure],
                directoryErrors: [CorpusReadFailure], filesSeen: Int, vanishedMidScan: Int,
                rootUnreadable: Bool, cancelled: Bool) {
        self.entries = entries
        self.unreadable = unreadable
        self.directoryErrors = directoryErrors
        self.filesSeen = filesSeen
        self.vanishedMidScan = vanishedMidScan
        self.rootUnreadable = rootUnreadable
        self.cancelled = cancelled
    }
}

/// A batch of entries plus the running total, so a caller can populate a list progressively.
public struct CorpusScanBatch: Sendable {
    /// Entries discovered since the previous batch (never cumulative).
    public let entries: [CorpusEntry]
    /// Regular files seen so far across the whole pass.
    public let filesSeen: Int

    public init(entries: [CorpusEntry], filesSeen: Int) {
        self.entries = entries
        self.filesSeen = filesSeen
    }
}

/// The authoritative read-side classification of one path.
///
/// `CorpusWatcher` uses this for file-granular FSEvents. Keeping the primitive beside the full walker
/// matters: a live event and a launch walk must agree about regular files, symlinks, vanished paths,
/// cloud placeholders, Finder-tag failures and the Read/Unread membership predicate. In particular,
/// `.untracked` means "we successfully read the tags and the predicate did not match"; it is never a
/// coercion of an unreadable tag attribute to an empty array.
public enum CorpusPathInspection: Sendable, Equatable {
    case tracked(CorpusEntry)
    case untracked
    case directory
    /// A path whose target is a directory but whose directory entry is a symbolic link. The full
    /// walker never descends directory symlinks, so a live-event consumer must not turn this into a
    /// subtree walk (which could otherwise escape the selected root).
    case directorySymbolicLink
    case nonRegular
    case vanished
    case unreadable(CorpusReadFailure)
}

/// Read-only, deterministic corpus discovery — the replacement for Spotlight (`NSMetadataQuery`).
///
/// **It never writes, moves, renames or deletes.** Enumeration, `stat`, `resourceValues` and
/// `getxattr` (inside `TagReading`) are the only filesystem calls it makes; the write-surface lint
/// (`ArchiveReader/scripts/lint-write-surface.sh`) covers this package and is part of this item's gate.
///
/// Why a filesystem walk is affordable — measured read-only on the owner's real corpus, 2026-08-04:
/// **123,028 files / 102,478 PDFs / depth 7 in 10.15 s single-threaded** (82 µs/file). The Spotlight
/// path's justification ("no per-file disk I/O, the fast path at 150k") was already void, because
/// `ContentIndexer` opens and extracts text from every PDF anyway.
///
/// Three design points a maintainer will otherwise re-litigate:
///
/// 1. **Synchronous by design.** `scan` is a plain function, not `async`. Two existing Reader test
///    files (`DocumentPageLinkTests`, `RootMarkerStateTests`) assert synchronously that a
///    freshly-tagged scratch PDF is discoverable the moment the model finishes initialising, and the
///    thread-scoped dataless policy below is only sound if no `await` can move the work to another
///    thread mid-pass. Off-main callers use `scanOnDedicatedThread`/`scanDetached`.
/// 2. **Everything tagged is returned.** User-excluded folders are filtered *after* discovery by the
///    Reader (`NavigationModel`), on purpose: excluded files are visible in the UI but absent from
///    the content index. A walker that skipped them during enumeration would silently drop them from
///    the UI while producing an identical index (plan §5.17).
/// 3. **Tags come from `TagReading.read`,** the same primitive the write path reads through, so
///    discovery and writes agree by construction — including on the "could not read" answer.
public enum CorpusWalker {

    // MARK: - Options

    public struct Options: Sendable {
        /// Matches the enumeration options of the pre-W26 fixture loader, so membership is unchanged.
        public var enumerationOptions: FileManager.DirectoryEnumerationOptions
        /// Regular files examined per `onBatch` call. A batch may contain no matching entries: progress
        /// must still advance across a large untagged tree. Batches only affect delivery, never the result.
        public var batchSize: Int

        public init(enumerationOptions: FileManager.DirectoryEnumerationOptions =
                        [.skipsHiddenFiles, .skipsPackageDescendants],
                    batchSize: Int = 500) {
            self.enumerationOptions = enumerationOptions
            self.batchSize = max(1, batchSize)
        }
    }

    // MARK: - Predicates

    /// The suite's master membership rule: a file belongs to the library iff it carries a `Read` or
    /// `Unread` tag. Case-insensitive, matching the shipped Spotlight predicate and the fixture
    /// loader it replaces — `NavigationUITests` pins this end to end.
    public static let tracksReadState: @Sendable ([String]) -> Bool = { tagNames in
        tagNames.contains {
            $0.caseInsensitiveCompare(ReadState.read.rawValue) == .orderedSame ||
            $0.caseInsensitiveCompare(ReadState.unread.rawValue) == .orderedSame
        }
    }

    /// Everything with at least one tag — for a vocabulary harvest rather than a library.
    public static let hasAnyTag: @Sendable ([String]) -> Bool = { !$0.isEmpty }

    // MARK: - The walk

    /// The path the walk must actually enumerate for `root` — or `nil` when this root cannot be opened
    /// at all, which is what every walk below reports as `rootUnreadable`.
    ///
    /// **Why a probe at all.** `FileManager.enumerator(at:)` **returns a live enumerator for a root it
    /// cannot open.** Measured 2026-08-06 across all three ways a root goes bad — a path that does not
    /// exist (`ENOENT`), a `0o000` directory (`EACCES`), and a regular file passed as a root
    /// (`ENOTDIR`): in every case the enumerator is non-nil, reports the root once to `errorHandler:`,
    /// and immediately ends. The pass therefore came back `completed == true`,
    /// `rootUnreadable == false`, `filesSeen == 0`, making a walk that read **nothing**
    /// indistinguishable from a walk that **found** nothing to any caller gating on `completed` — the
    /// shape of the 2026-08-04 incident, one layer down. The `guard let enumerator … else` branches
    /// below are kept as a defensive floor, but they are not the branch that fires.
    ///
    /// `opendir(3)` is the discriminator, deliberately *not* "did the error handler report the root":
    /// for the `0o000` case FileManager hands back `/private/var/…` while the caller passed `/var/…`,
    /// so a path or byte comparison answers "that was not the root" for the very case this must catch
    /// (the `/private` alias trap). `opendir` is also the exact operation enumeration needs and costs
    /// one syscall per pass.
    ///
    /// **A root that is ITSELF a symbolic link (`W26.symroot`).** `FileManager.enumerator(at:)` will
    /// not enumerate one: it reports the link to `errorHandler:` and yields nothing, even when the
    /// target is a perfectly readable directory full of tagged files (measured 2026-08-06; still
    /// measured through a trailing-slash spelling, which changes nothing). So such a root is walked
    /// **through its `realpath(3)`**, and the caller's link spelling never reaches the enumerator.
    ///
    /// Two decisions that a maintainer will otherwise re-litigate, both settled by measurement:
    ///
    /// 1. **Identity follows enumeration, not the other way round.** Entries under a symlinked root
    ///    come back spelled under the *target*. `W26.symroot` was filed expecting the opposite — walk
    ///    the target but rewrite every discovered path back under the caller's link prefix, to protect
    ///    the byte-exact `(root, path)` contract `LibraryIndex` keys on. Measured, that premise does
    ///    not hold: the enumerator **already** hands back fully ancestor-resolved paths — a root
    ///    spelled `/var/folders/…` yields entries spelled `/private/var/folders/…` — so the caller's
    ///    spelling was never what the walk emitted. Rewriting would invent a third spelling that
    ///    neither FileManager nor FSEvents ever produces, and `CorpusWatcher`'s live events (which
    ///    arrive realpath'd) would then match no row: every tag write under such a root would look
    ///    like a brand-new file.
    /// 2. **Only a symlinked FINAL component is canonicalised.** For every other root this returns the
    ///    caller's URL *unchanged*, byte for byte, so no existing root's spelling — and therefore no
    ///    cached row — can shift underneath the index. An aliased *ancestor* (`/var` → `/private/var`,
    ///    which every temp fixture and much of the corpus path sits under) is deliberately left alone
    ///    here; the enumerator resolves it either way, and calling `realpath` on every root would also
    ///    silently rewrite a case-mismatched spelling on a case-insensitive volume.
    ///
    /// Aligning a *caller's* own root-relative logic (the Reader's folder tree, exclusions and
    /// relative-path link writing all compare against its granted root spelling) is `W26.symroot-fu1`
    /// — it cannot be done here, and the naive version there loses the sandbox security scope.
    public static func canonicalRoot(_ root: URL) -> URL? {
        root.withUnsafeFileSystemRepresentation { rawPath -> URL? in
            guard let rawPath else { return nil }
            var linkInfo = stat()
            guard lstat(rawPath, &linkInfo) == 0 else { return nil }
            guard (linkInfo.st_mode & S_IFMT) == S_IFLNK else {
                guard let dir = opendir(rawPath) else { return nil }
                closedir(dir)
                return root
            }
            // `realpath` and not a manual `readlink` chase: it resolves a link-to-a-link, a relative
            // destination and an `ELOOP` cycle in one syscall, and fails outright on a dangling one.
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(rawPath, &resolved) != nil else { return nil }
            // The target still has to be an openable DIRECTORY: `realpath` succeeds for a link to a
            // regular file, and for a link into a directory we are denied.
            guard let dir = opendir(resolved) else { return nil }
            closedir(dir)
            return URL(fileURLWithFileSystemRepresentation: resolved,
                       isDirectory: true, relativeTo: nil)
        }
    }

    /// The prefix every path this walker reports under `root` is spelled with — or `nil` when the root
    /// cannot be resolved at all.
    ///
    /// This is what a caller needs in order to ask *"is this discovered path inside my granted root?"*,
    /// or to turn a discovered path back into a root-relative one. `canonicalRoot` is **not** that
    /// value, and the difference is measured rather than stylistic:
    ///
    /// | root as the caller spells it | what the enumerator reports |
    /// | --- | --- |
    /// | `/tmp/x/real` (aliased ancestor: `/tmp` → `/private/tmp`) | `/private/tmp/x/real/…` |
    /// | `/tmp/x/link/sub` (`link` → `real`, a MID-PATH symlink) | `/private/tmp/x/real/sub/…` |
    ///
    /// `canonicalRoot` resolves only a symlinked FINAL component, because that is the one thing the
    /// enumerator cannot do for itself, and deliberately leaves every other root byte-identical so no
    /// existing `LibraryIndex` row can shift (see its own notes). The enumerator resolves all the rest
    /// itself — measured 2026-08-06: entries come back spelled at the root's full `realpath(3)`. Row 2
    /// is why this has to be a second function: `canonicalRoot` returns that root *unchanged* (its final
    /// component `sub` is not a link), so a caller comparing against it would reject every path the walk
    /// had just handed it. Row 1 is not exotic either — every `/var/folders` fixture root is one, which
    /// is why the Reader's folder tree has never placed a file under a fixture root.
    ///
    /// **For COMPARISON and relative-path arithmetic only.** A `String` and not a `URL` on purpose: this
    /// spelling carries no sandbox security scope (a URL rebuilt from it is a different instance from
    /// the one the bookmark granted), so it must never be opened, and it must never be persisted —
    /// `W26.symroot-fu1`, and the 2026-07-11 incident for the persistence half.
    ///
    /// Openability is deliberately NOT probed here — that question is `canonicalRoot`'s, and a caller
    /// that holds a root it cannot currently reach still needs a spelling to compare with rather than a
    /// sudden `nil`. `realpath` fails only when the path does not resolve at all (`ENOENT`, a dangling
    /// link, `ELOOP`); a `0o000` directory resolves fine.
    public static func discoveredPathPrefix(for root: URL) -> String? {
        root.withUnsafeFileSystemRepresentation { rawPath -> String? in
            guard let rawPath else { return nil }
            var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(rawPath, &resolved) != nil else { return nil }
            // `realpath` never returns a trailing slash except for `/` itself, which every containment
            // check in the suite already special-cases; pass it through as-is rather than inventing a
            // spelling. Built through the filesystem representation so a decomposed on-disk name stays
            // byte-exact — `String(cString:)` would too, but this says so.
            return String(decoding: resolved.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        }
    }

    /// Re-stat and re-read one path through the same primitives as `scan`.
    ///
    /// The URL's resource-value cache is deliberately avoided by constructing a fresh filesystem URL
    /// before the resource read. FSEvents paths originate as strings, but callers may also pass a URL
    /// that has previously cached values; a Finder-tag-only change updates ctime, not content mtime,
    /// and must never be hidden behind an old backing `NSURL` cache.
    public static func inspect(_ path: URL,
                               predicate: @escaping @Sendable ([String]) -> Bool = tracksReadState)
        -> CorpusPathInspection {
        withDatalessMaterializationDisabled {
            // Reconstruct a fresh NSURL (to defeat resource-value caching) from the filesystem
            // representation, not `path.path`: `URL(fileURLWithPath:)` normalises composed Unicode
            // and violates the index's byte-exact path contract.
            let url = path.withUnsafeFileSystemRepresentation { raw in
                guard let raw else { return path }
                return URL(fileURLWithFileSystemRepresentation: raw,
                           isDirectory: false, relativeTo: nil)
            }
            switch FileStat.capture(url) {
            case .vanished:
                return .vanished
            case let .failed(reason):
                return .unreadable(CorpusReadFailure(url: url, reason: reason))
            case let .ok(isRegularFile, isDirectory, isDirectorySymbolicLink, fingerprint):
                if isDirectorySymbolicLink { return .directorySymbolicLink }
                if isDirectory { return .directory }
                guard isRegularFile else { return .nonRegular }

                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: [.contentModificationDateKey, .contentTypeKey])
                } catch {
                    if FileStat.isMissing(url) { return .vanished }
                    return .unreadable(CorpusReadFailure(url: url, reason: error.localizedDescription))
                }

                switch TagReading.read(url) {
                case let .failure(reason):
                    if FileStat.isMissing(url) { return .vanished }
                    return .unreadable(CorpusReadFailure(url: url, reason: reason))
                case let .success(tagNames, labelNumber):
                    guard predicate(tagNames) else { return .untracked }
                    return .tracked(CorpusEntry(url: url,
                                                tagNames: tagNames,
                                                labelNumber: labelNumber,
                                                contentModified: values.contentModificationDate,
                                                contentTypeIdentifier: values.contentType?.identifier,
                                                isDataless: fingerprint.isDataless,
                                                fingerprint: fingerprint))
                }
            }
        }
    }

    /// Walk `root` and return everything matching `predicate`, plus an honest account of what could
    /// not be read.
    ///
    /// Runs entirely on the calling thread and suppresses on-demand materialisation of cloud
    /// placeholders for the duration (see `withDatalessMaterializationDisabled`). `onBatch` is
    /// therefore invoked on the calling thread, synchronously, before this returns.
    ///
    /// - Parameter isCancelled: polled once per entry; a `true` leaves `cancelled == true`, which
    ///   makes the result not `isClean` — a cancelled pass can never authorise treating a file as gone.
    /// - Parameter onTagsRead: called for **every** regular file whose tags were read — matching or
    ///   not — with the raw tag names and the file's Finder label, on the walking thread, before the
    ///   predicate runs. Additive, optional, and never consulted for the result. It exists for callers
    ///   that want *facts about the tags* rather than a library of rows: such a caller leaves
    ///   `predicate` returning `false` so the walker accumulates no `CorpusEntry` at all, and observes
    ///   here instead. The Processor's vocabulary harvest is why it exists — its facet filter needs
    ///   `labelNumber` to tell a marker colour ("Red" on a red-labelled box) from a subject that
    ///   happens to be called "Red", and a `([String]) -> Bool` predicate cannot supply it.
    public static func scan(root: URL,
                            predicate: @escaping @Sendable ([String]) -> Bool = tracksReadState,
                            options: Options = Options(),
                            isCancelled: @Sendable () -> Bool = { false },
                            onTagsRead: (@Sendable ([String], Int?) -> Void)? = nil,
                            onBatch: (@Sendable (CorpusScanBatch) -> Void)? = nil) -> CorpusScanResult {
        withDatalessMaterializationDisabled {
            scanBody(root: root, predicate: predicate, options: options,
                     isCancelled: isCancelled, onTagsRead: onTagsRead, onBatch: onBatch)
        }
    }

    private static func scanBody(root: URL,
                                 predicate: @escaping @Sendable ([String]) -> Bool,
                                 options: Options,
                                 isCancelled: @Sendable () -> Bool,
                                 onTagsRead: (@Sendable ([String], Int?) -> Void)?,
                                 onBatch: (@Sendable (CorpusScanBatch) -> Void)?) -> CorpusScanResult {
        // Ask before walking: the enumerator will not tell us (see `canonicalRoot`). Reported with
        // empty failure lists, matching the nil-enumerator branch below, so a caller counting
        // "folders I could not read" is not handed the root twice for one failure.
        guard let enumerationRoot = canonicalRoot(root) else {
            return CorpusScanResult(entries: [], unreadable: [], directoryErrors: [],
                                    filesSeen: 0, vanishedMidScan: 0,
                                    rootUnreadable: true, cancelled: false)
        }

        var entries: [CorpusEntry] = []
        var unreadable: [CorpusReadFailure] = []
        var filesSeen = 0
        var vanished = 0
        var cancelled = false
        var batch: [CorpusEntry] = []

        // A private FileManager: the walk is driven off the main actor and must not share state with
        // whatever else is using `FileManager.default` (the pattern already reviewed in
        // ArchiveNotes' ReaderLinkResolver).
        let fm = FileManager()

        // `directoryErrors` is captured by the error handler, which FileManager may call from inside
        // `nextObject()` — i.e. synchronously on this same thread, between our own statements. A class
        // box keeps that legal without pretending the closure is concurrency-safe.
        let errorSink = ErrorSink()

        // `.contentTypeKey`/`.contentModificationDateKey` only: regular-file and dataless detection
        // come from the single `stat` below, which is cheaper than a third resource-value key and is
        // the only way to see `SF_DATALESS` at all.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentTypeKey]

        guard let enumerator = fm.enumerator(
            at: enumerationRoot,
            includingPropertiesForKeys: keys,
            options: options.enumerationOptions,
            // WITHOUT this handler the enumerator silently skips a directory it cannot descend into —
            // no error, no count, and the scan still reports complete. That is the second way this fix
            // could have reproduced the very bug it exists to fix (plan §4a.2). Returning `true`
            // continues the walk; the recorded error is what makes the pass not `isClean`.
            errorHandler: { url, error in
                errorSink.record(url: url, reason: error.localizedDescription)
                return true
            }
        ) else {
            return CorpusScanResult(entries: [], unreadable: [], directoryErrors: [],
                                    filesSeen: 0, vanishedMidScan: 0,
                                    rootUnreadable: true, cancelled: false)
        }

        // `nextObject()` rather than `for … in`: NSEnumerator's Sequence conformance is unavailable
        // from an async context, and this loop is meant to be callable from one.
        while let entry = enumerator.nextObject() {
            if isCancelled() { cancelled = true; break }
            guard let url = entry as? URL else { continue }

            switch FileStat.capture(url) {
            case .vanished:
                // Enumerated, then gone. Not a denial, not a tag failure, never persisted.
                vanished += 1
                continue
            case let .failed(reason):
                // We cannot even tell what this is. Honest answer: unknown, so the pass is not clean.
                unreadable.append(CorpusReadFailure(url: url, reason: reason))
                continue
            case let .ok(isRegularFile, _, _, fingerprint):
                guard isRegularFile else { continue }   // directories, symlinks to dirs, devices…
                filesSeen += 1
                // Progress is about files EXAMINED, not matches found. The old match-sized batching
                // left a 150k-file untagged tree at "0 scanned" until the pass ended — a real counter
                // that never moved was scarcely better than Spotlight's indeterminate spinner.
                defer {
                    if filesSeen.isMultiple(of: options.batchSize), let onBatch {
                        onBatch(CorpusScanBatch(entries: batch, filesSeen: filesSeen))
                        batch.removeAll(keepingCapacity: true)
                    }
                }

                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: Set(keys))
                } catch {
                    if FileStat.isMissing(url) { vanished += 1 } else {
                        unreadable.append(CorpusReadFailure(url: url, reason: error.localizedDescription))
                    }
                    continue
                }

                switch TagReading.read(url) {
                case let .failure(why):
                    // The case `W26.deny` exists to make honest. The code being replaced wrote
                    // `else { continue }` here, which lost the file with no error and no count.
                    if FileStat.isMissing(url) { vanished += 1 } else {
                        unreadable.append(CorpusReadFailure(url: url, reason: why))
                    }
                case let .success(tagNames, labelNumber):
                    // Every successful read is observable, matching or not — see `onTagsRead`.
                    onTagsRead?(tagNames, labelNumber)
                    guard predicate(tagNames) else { continue }
                    let e = CorpusEntry(url: url,
                                        tagNames: tagNames,
                                        labelNumber: labelNumber,
                                        contentModified: values.contentModificationDate,
                                        contentTypeIdentifier: values.contentType?.identifier,
                                        isDataless: fingerprint.isDataless,
                                        fingerprint: fingerprint)
                    entries.append(e)
                    batch.append(e)
                }
            }
        }

        if !filesSeen.isMultiple(of: options.batchSize), let onBatch {
            onBatch(CorpusScanBatch(entries: batch, filesSeen: filesSeen))
        }

        return CorpusScanResult(entries: entries,
                                unreadable: unreadable,
                                directoryErrors: errorSink.drain(),
                                filesSeen: filesSeen,
                                vanishedMidScan: vanished,
                                rootUnreadable: false,
                                cancelled: cancelled)
    }

    /// Walk only regular-file `stat(2)` fingerprints — no tag or content/resource-value reads.
    ///
    /// This is the warm-start revalidation first phase: one cheap, fresh syscall per enumerated path,
    /// then callers compare against a persisted map and run the full trustworthy tag read only for
    /// new/changed/unverified rows. Byte-exact paths are preserved exactly as enumeration returned.
    public static func scanFingerprints(
        root: URL,
        options: Options = Options(),
        isCancelled: @Sendable () -> Bool = { false },
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) -> CorpusFingerprintScanResult {
        withDatalessMaterializationDisabled {
            // Same root probe as `scanBody`, for the same measured reason: the warm-start revalidation
            // walk must not report a vanished or unmounted root as "completed, zero files", because the
            // caller then treats every cached row as gone. It must also resolve a symlinked root the
            // SAME way `scan` does, or a warm root would revalidate as zero files against rows the full
            // walk had just written — every one of them "deleted".
            guard let enumerationRoot = canonicalRoot(root) else {
                return CorpusFingerprintScanResult(entries: [], unreadable: [], directoryErrors: [],
                                                   filesSeen: 0, vanishedMidScan: 0,
                                                   rootUnreadable: true, cancelled: false)
            }

            var entries: [CorpusFingerprintEntry] = []
            var unreadable: [CorpusReadFailure] = []
            var filesSeen = 0
            var vanished = 0
            var cancelled = false
            let errorSink = ErrorSink()
            let fm = FileManager()

            guard let enumerator = fm.enumerator(
                at: enumerationRoot,
                includingPropertiesForKeys: nil,
                options: options.enumerationOptions,
                errorHandler: { url, error in
                    errorSink.record(url: url, reason: error.localizedDescription)
                    return true
                }
            ) else {
                return CorpusFingerprintScanResult(entries: [], unreadable: [], directoryErrors: [],
                                                   filesSeen: 0, vanishedMidScan: 0,
                                                   rootUnreadable: true, cancelled: false)
            }

            while let object = enumerator.nextObject() {
                if isCancelled() { cancelled = true; break }
                guard let url = object as? URL else { continue }
                switch FileStat.capture(url) {
                case .vanished:
                    vanished += 1
                case let .failed(reason):
                    unreadable.append(CorpusReadFailure(url: url, reason: reason))
                case let .ok(isRegularFile, _, _, fingerprint):
                    guard isRegularFile else { continue }
                    filesSeen += 1
                    entries.append(CorpusFingerprintEntry(url: url, fingerprint: fingerprint))
                    if filesSeen.isMultiple(of: options.batchSize) { onProgress?(filesSeen) }
                }
            }

            if !filesSeen.isMultiple(of: options.batchSize) { onProgress?(filesSeen) }

            return CorpusFingerprintScanResult(entries: entries,
                                               unreadable: unreadable,
                                               directoryErrors: errorSink.drain(),
                                               filesSeen: filesSeen,
                                               vanishedMidScan: vanished,
                                               rootUnreadable: false,
                                               cancelled: cancelled)
        }
    }

    // MARK: - Off-main execution

    /// Run `scan` on a **dedicated** `Thread` and hand the result to `completion` on that same thread.
    ///
    /// Not `Task.detached`, for two independent reasons: (a) the dataless I/O policy is per-thread and
    /// Swift's cooperative pool reuses threads, so a policy set inside a task can outlive the work
    /// that wanted it (plan §4a.4); (b) the pass is ~10 s of blocking I/O at corpus scale, which would
    /// starve the cooperative pool for its duration.
    @discardableResult
    public static func scanOnDedicatedThread(root: URL,
                                             predicate: @escaping @Sendable ([String]) -> Bool = tracksReadState,
                                             options: Options = Options(),
                                             qualityOfService: QualityOfService = .utility,
                                             isCancelled: @escaping @Sendable () -> Bool = { false },
                                             onTagsRead: (@Sendable ([String], Int?) -> Void)? = nil,
                                             onBatch: (@Sendable (CorpusScanBatch) -> Void)? = nil,
                                             completion: @escaping @Sendable (CorpusScanResult) -> Void) -> Thread {
        let thread = Thread {
            completion(scan(root: root, predicate: predicate, options: options,
                            isCancelled: isCancelled, onTagsRead: onTagsRead, onBatch: onBatch))
        }
        thread.name = "ArchiveCore.CorpusWalker"
        thread.qualityOfService = qualityOfService
        thread.start()
        return thread
    }

    /// `async` façade over `scanOnDedicatedThread`. Honours task cancellation in addition to
    /// `isCancelled`.
    public static func scanDetached(root: URL,
                                    predicate: @escaping @Sendable ([String]) -> Bool = tracksReadState,
                                    options: Options = Options(),
                                    qualityOfService: QualityOfService = .utility,
                                    onBatch: (@Sendable (CorpusScanBatch) -> Void)? = nil) async -> CorpusScanResult {
        let cancellation = CancellationFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                scanOnDedicatedThread(root: root, predicate: predicate, options: options,
                                      qualityOfService: qualityOfService,
                                      isCancelled: { cancellation.isSet },
                                      onBatch: onBatch) { result in
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.set()
        }
    }

    // MARK: - Cloud placeholders

    /// Run `body` with on-demand materialisation of dataless (cloud placeholder) files **disabled on
    /// the current thread**, restoring the previous policy afterwards.
    ///
    /// Verified 2026-08-04 against a real `~/Library/CloudStorage/GoogleDrive-…` directory (Drive
    /// installed, not signed in): without this, `getattrlistbulk` inside the enumerator **stalls and
    /// then fails with `ETIMEDOUT` after 0.54 s per call**, and the no-`errorHandler` enumerator turns
    /// that into a silent empty listing. With it, the stall becomes an immediate clean error the
    /// `errorHandler:` above records.
    ///
    /// Save-and-restore matters: the policy is thread-scoped, and leaking "off" into unrelated work on
    /// a reused thread would silently change the behaviour of code that never asked for it.
    public static func withDatalessMaterializationDisabled<T>(_ body: () throws -> T) rethrows -> T {
        let prior = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            // A negative `prior` means the policy could not be read (it does not fail in practice —
            // measured 0 here). Restore the DEFAULT rather than skip the restore: leaving a thread
            // pinned OFF would silently change unrelated work, and the default is `…_ON`-equivalent,
            // so the worst case of guessing is that we hand back the behaviour every other caller
            // already has. Skipping the SET instead would have quietly dropped the hang protection.
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                               prior >= 0 ? prior : IOPOL_DEFAULT)
        }
        return try body()
    }
}

// MARK: - stat classification

/// One following `stat(2)` answers "is this a regular file", "is it a cloud placeholder", and "did it
/// just disappear" — the last of which keeps normal churn out of denial counts. Directory targets get
/// one additional `lstat(2)` so live discovery cannot accidentally descend a directory symlink that
/// the full `FileManager` enumeration intentionally skips.
enum FileStat {
    case ok(isRegularFile: Bool, isDirectory: Bool,
            isDirectorySymbolicLink: Bool, fingerprint: CorpusFileFingerprint)
    case vanished
    case failed(String)

    /// The primary classification follows symlinks, exactly as `URL.resourceValues` and
    /// `TagReading.read` do: a symlink to a
    /// tagged PDF must be classified by its target, or the walk and the write path would disagree
    /// about the same entry (the symlink half of the `W26.deny` correction). Directory targets are
    /// the exception: an `lstat` records that the directory entry is a symlink so event-driven code
    /// can preserve the full walk's no-directory-symlink traversal rule.
    ///
    /// Consequence worth knowing: a **dangling** symlink therefore reports `.vanished` on every pass,
    /// not just the one it broke in. It is excluded from `entries` (as the Spotlight-era loader also
    /// excluded it) and deliberately does not make the pass unclean, so a tree full of dead links
    /// stays authoritative — but `vanishedMidScan` on such a tree is a floor, not a churn signal.
    static func capture(_ url: URL) -> FileStat {
        url.withUnsafeFileSystemRepresentation { rawPath -> FileStat in
            guard let rawPath else { return .failed("path has no filesystem representation") }
            var info = stat()
            errno = 0
            guard stat(rawPath, &info) == 0 else {
                let code = errno
                return code == ENOENT ? .vanished : .failed("stat failed: \(describe(code))")
            }
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            var linkInfo = stat()
            let isDirectorySymbolicLink = isDirectory
                && lstat(rawPath, &linkInfo) == 0
                && (linkInfo.st_mode & S_IFMT) == S_IFLNK
            let fingerprint = CorpusFileFingerprint(
                mtime: timestamp(info.st_mtimespec),
                ctime: timestamp(info.st_ctimespec),
                size: info.st_size,
                inode: UInt64(info.st_ino),
                isDataless: (info.st_flags & UInt32(SF_DATALESS)) != 0
            )
            return .ok(isRegularFile: (info.st_mode & S_IFMT) == S_IFREG,
                       isDirectory: isDirectory,
                       isDirectorySymbolicLink: isDirectorySymbolicLink,
                       fingerprint: fingerprint)
        }
    }

    private static func timestamp(_ value: timespec) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_nsec) / 1_000_000_000
    }

    /// Did this path disappear? Used to tell churn from denial when a *later* read fails.
    static func isMissing(_ url: URL) -> Bool {
        if case .vanished = capture(url) { return true }
        return false
    }

    private static func describe(_ code: Int32) -> String {
        switch code {
        case EACCES:  return "permission denied (EACCES)"
        case EPERM:   return "operation not permitted (EPERM)"
        case ELOOP:   return "too many symbolic links (ELOOP)"
        case EIO:     return "I/O error (EIO)"
        case ETIMEDOUT: return "operation timed out (ETIMEDOUT) — a cloud/network volume?"
        default:      return "errno \(code)"
        }
    }
}

// MARK: - Small boxes

/// Collects the enumerator's directory errors. FileManager calls the handler synchronously on the
/// walking thread, but the closure must be a `@Sendable`-safe reference type to satisfy Swift 6.
private final class ErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [CorpusReadFailure] = []

    func record(url: URL, reason: String) {
        lock.lock(); defer { lock.unlock() }
        failures.append(CorpusReadFailure(url: url, reason: reason))
    }

    func drain() -> [CorpusReadFailure] {
        lock.lock(); defer { lock.unlock() }
        return failures
    }
}

/// One-way cancellation bit shared between an `async` caller and the walking thread.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); defer { lock.unlock() }; flag = true }
}
