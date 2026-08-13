import Foundation

/// One archive root the vocabulary has been fed from, plus when it was last harvested.
///
/// `harvestedAt == nil` means "recorded but never walked" — the next harvest picks it up. The stamp is
/// only ever set by a pass that actually *completed*, so an interrupted or denied walk retries rather
/// than silently claiming it covered the root.
public struct TagVocabularyRoot: Sendable, Equatable, Codable {
    public let path: String
    public var harvestedAt: Date?

    public init(path: String, harvestedAt: Date? = nil) {
        self.path = path
        self.harvestedAt = harvestedAt
    }
}

/// A persisted, monotonically-growing set of **subject** tag names, for autocomplete in a tagging UI.
///
/// ## Why this type exists (W26.vocab)
///
/// The Processor used to source its subject autocomplete from a Spotlight `NSMetadataQuery` scoped to
/// `NSMetadataQueryUserHomeScope` with `kMDItemUserTags LIKE "*"`. That is exactly the dependency the
/// 2026-08-04 incident condemned — when the volume's Spotlight index is dead the query returns *nothing*,
/// with no error, and the operator gets a silently-empty suggestion list. There is no filesystem walk that
/// reproduces a home-wide scope cheaply, so the replacement changes shape rather than mechanism: instead of
/// re-deriving the whole vocabulary on demand, **accumulate it and keep it.**
///
/// Three sources feed it, and none of them is Spotlight:
/// 1. a one-per-root **harvest** of the archive roots the app has been pointed at (`CorpusWalker`),
/// 2. every tag the operator types (the pre-existing `register(_:)` path), and
/// 3. every Finder-tag write the app performs, taken from the write's verified on-disk result.
///
/// After one session it is *better* than the Spotlight answer for this UI, because it is scoped to the
/// archive rather than to every tagged file in the home folder.
///
/// ## Subjects only — the vocabulary is facet-filtered on ingest
///
/// Every ingest path runs its raw tag names through `DocumentTags.parse` and keeps only `.subjects`, so
/// date tokens (`1968`, `03 March`, `Day 4`, `1970s`, `Date Uncertain`), quality (`Q1`…`Q3` plus the
/// retired `P7`…`P10` aliases), read state
/// (`Read`/`Unread`) and the file's own marker colour never become subject suggestions. This is load-bearing
/// rather than cosmetic: source 3 above writes a trailing `Unread` on *every* real-tagging output, so an
/// unfiltered vocabulary would guarantee "Unread" as a permanent suggestion in a field labelled *Subjects*.
/// (Spotlight's answer had the same pollution — it harvested every tag on every file — so this is a
/// deliberate improvement over the behaviour being replaced, not a regression of it.)
///
/// ## Disposable, monotonic, and never authoritative
///
/// The store holds no information that cannot be rebuilt by walking the roots again: it is a *cache of
/// strings* for a suggestion list. So it only ever grows (nothing prunes it — a tag that leaves the corpus
/// stays suggestable, which is harmless in a tagging UI and avoids ever needing an authoritative pass), and
/// a corrupt or unreadable file self-heals by starting empty with every root's harvest stamp cleared.
/// **It is never consulted by a write path.**
///
/// Thread-safe: `add` is called from the walker's dedicated thread, one call per corpus file, while the
/// main actor reads `snapshot()` to publish suggestions.
public final class TagVocabulary: @unchecked Sendable {

    /// Re-harvest the current root at most once a day. A harvest is ~12 s of `.utility` I/O over a
    /// 100k-file corpus, and the other two ingest sources keep the vocabulary current in between.
    public static let defaultStaleAfter: TimeInterval = 24 * 60 * 60

    /// Hard ceiling on distinct names. Measured 2026-08-04: `$HOME` holds ~7,051 distinct tag names, so
    /// this is ~7× headroom — it exists only so a pathological tree cannot grow the file without bound.
    public static let maxNames = 50_000

    /// Hard ceiling on remembered roots. Dropping the oldest record loses only its harvest *stamp*; the
    /// names it contributed are already in the set, because the set is never pruned.
    public static let maxRoots = 16

    private let fileURL: URL
    private let lock = NSLock()
    private let saveQueue: DispatchQueue

    private var names: Set<String> = []
    private var roots: [TagVocabularyRoot] = []
    private var savePending = false

    /// Non-nil when the last load found a file it could not use. Exposed so a caller (or a test) can tell
    /// "first run" from "the cache was corrupt and has been reset".
    public private(set) var loadFailure: String?

    /// - Parameter fileURL: where the JSON lives. Injected rather than derived so each app owns its own
    ///   storage location (the Reader is sandboxed and the Processor is not, so there is deliberately no
    ///   shared store) and so tests never touch a real one.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.saveQueue = DispatchQueue(label: "ArchiveCore.TagVocabulary.save", qos: .utility)
        load()
    }

    // MARK: - Reading

    /// Every known subject name, ordered the way a suggestion list wants to show them.
    public func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return names.count
    }

    public func knownRoots() -> [TagVocabularyRoot] {
        lock.lock(); defer { lock.unlock() }
        return roots
    }

    /// Prefix-first, then substring suggestions (case-insensitive), excluding already-chosen tags.
    ///
    /// Moved here from the Processor's `SystemTagsProvider` so the ranking has tests: it is the only part
    /// of the old provider that was pure, and it was never covered because the type it lived on could not
    /// be constructed without starting a Spotlight query.
    public func suggestions(prefix: String, excluding: [String] = [], limit: Int = 8) -> [String] {
        let p = prefix.trimmingCharacters(in: .whitespaces).lowercased()
        let chosen = Set(excluding.map { $0.lowercased() })
        let pool = snapshot().filter { !chosen.contains($0.lowercased()) }
        guard !p.isEmpty else { return Array(pool.prefix(limit)) }
        let prefixMatches = pool.filter { $0.lowercased().hasPrefix(p) }
        let substringMatches = pool.filter { !$0.lowercased().hasPrefix(p) && $0.lowercased().contains(p) }
        return Array((prefixMatches + substringMatches).prefix(limit))
    }

    // MARK: - Ingest

    /// Absorb one file's (or one write's) raw Finder tag names, keeping only the subject facet.
    ///
    /// - Parameter labelNumber: the file's Finder label, when known. Pass it from a write result so a
    ///   marker colour token ("Red"/"Purple") that matches the actual label is recognised as the marker
    ///   and dropped — while a document genuinely tagged "Red" with no red label keeps it as a subject.
    /// - Returns: true when at least one name was new (the caller can skip a save otherwise).
    @discardableResult
    public func add(rawTags: [String], labelNumber: Int? = nil) -> Bool {
        let subjects = DocumentTags.parse(raw: rawTags, labelNumber: labelNumber).subjects
        var grew = false
        lock.lock()
        for subject in subjects {
            let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard names.count < Self.maxNames || names.contains(trimmed) else { continue }
            if names.insert(trimmed).inserted { grew = true }
        }
        lock.unlock()
        if grew { scheduleSave() }
        return grew
    }

    // MARK: - Roots

    /// Would harvesting this root be a legitimate archive walk, or the invasive `$HOME` sweep the owner's
    /// 2026-08-04 directive rules out?
    ///
    /// An archive root is a *specific* folder the operator pointed the app at. The rejected paths are the
    /// umbrella locations: a whole filesystem, a whole user, or one of the TCC-gated personal-data folders
    /// in the home directory. Walking one of those is slow, invasive, would trip authorisation prompts
    /// across unrelated directories, and — for `$HOME` itself — is precisely the Spotlight scope this whole
    /// change exists to stop emulating. It is a *capability* the Processor has (it is unsandboxed, so the
    /// walk would legally succeed); the reason not to do it is cost and invasiveness, not permission.
    ///
    /// Comparison is case-insensitive because the boot volume is: `/users/me/desktop` and
    /// `/Users/me/Desktop` are one directory, and a guard that only knew the canonical spelling would be
    /// bypassed by the other.
    public static func isHarvestableRoot(_ url: URL,
                                         home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> Bool {
        let path = normalizedPath(url)
        guard !path.isEmpty, path != "/" else { return false }

        let homePath = normalizedPath(home)
        if path.caseInsensitiveCompare(homePath) == .orderedSame { return false }

        // Whole-filesystem / whole-machine roots.
        for forbidden in ["/Users", "/Volumes", "/System", "/Library", "/Applications", "/private"]
        where path.caseInsensitiveCompare(forbidden) == .orderedSame {
            return false
        }

        // The personal-data folders directly inside the home directory.
        let personal = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music",
                       "Pictures", "Public", "Sites"]
        for name in personal
        where path.caseInsensitiveCompare(homePath + "/" + name) == .orderedSame {
            return false
        }
        return true
    }

    /// Record a root so it will be harvested. Ignores anything `isHarvestableRoot` rejects, and anything
    /// already known.
    /// - Returns: true when a new root was recorded.
    @discardableResult
    public func noteRoot(_ url: URL,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard Self.isHarvestableRoot(url, home: home) else { return false }
        let path = Self.normalizedPath(url)
        lock.lock()
        if roots.contains(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) {
            lock.unlock()
            return false
        }
        roots.append(TagVocabularyRoot(path: path, harvestedAt: nil))
        // Oldest-first eviction: the record only carries a harvest stamp, and the names are kept forever.
        while roots.count > Self.maxRoots { roots.removeFirst() }
        lock.unlock()
        scheduleSave()
        return true
    }

    /// Which roots to walk now: everything never harvested, plus `current` if its last harvest has gone
    /// stale. `current` comes first so the root the operator is actually filing into is covered first.
    ///
    /// Deliberately does NOT re-walk a *former* root once it is stale — its names are already kept, and
    /// re-walking every root the app was ever pointed at would turn one 12 s pass into several.
    public func rootsNeedingHarvest(current: URL?,
                                    now: Date = Date(),
                                    staleAfter: TimeInterval = TagVocabulary.defaultStaleAfter) -> [URL] {
        let currentPath = current.map { Self.normalizedPath($0) }
        lock.lock(); defer { lock.unlock() }
        var due: [String] = []
        for root in roots {
            let isCurrent = currentPath.map { root.path.caseInsensitiveCompare($0) == .orderedSame } ?? false
            if let stamp = root.harvestedAt {
                guard isCurrent, now.timeIntervalSince(stamp) >= staleAfter else { continue }
            }
            due.append(root.path)
        }
        if let currentPath, let idx = due.firstIndex(where: { $0.caseInsensitiveCompare(currentPath) == .orderedSame }) {
            due.insert(due.remove(at: idx), at: 0)
        }
        return due.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Stamp a root as harvested. Call this ONLY for a pass that completed — a cancelled or root-unreadable
    /// pass must retry, and stamping it would hide a root the app never actually read.
    public func markHarvested(_ url: URL, at date: Date = Date()) {
        let path = Self.normalizedPath(url)
        lock.lock()
        if let idx = roots.firstIndex(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) {
            roots[idx].harvestedAt = date
        }
        lock.unlock()
        scheduleSave()
    }

    // MARK: - Persistence

    private struct Payload: Codable {
        var version: Int
        var names: [String]
        var roots: [TagVocabularyRoot]
    }

    private static let currentVersion = 1

    /// Write now, synchronously. Used at the points where losing the write would be noticeable (a tag the
    /// operator just typed; the end of a harvest) and by tests, which must not wait on a debounce.
    public func flush() {
        guard let data = encodedSnapshot() else { return }
        saveQueue.sync { self.write(data) }
    }

    /// Coalesced save for hot paths: a harvest calls `add` once per corpus file, and encoding the whole set
    /// per new name would turn ~7,000 growth events into ~7,000 JSON writes. At most one save is ever
    /// pending, so a 12 s walk costs a dozen writes rather than thousands.
    private func scheduleSave() {
        lock.lock()
        if savePending { lock.unlock(); return }
        savePending = true
        lock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.savePending = false; self.lock.unlock()
            if let data = self.encodedSnapshot() { self.write(data) }
        }
    }

    /// Encode under the lock, write outside it — and never take the lock inside a `saveQueue` block that a
    /// `flush()` is waiting on, so `saveQueue.sync` above cannot deadlock against an in-flight `add`.
    private func encodedSnapshot() -> Data? {
        lock.lock()
        let payload = Payload(version: Self.currentVersion,
                              names: names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                              roots: roots)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    private func write(_ data: Data) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Load, or self-heal. There is no legacy format to read and no migration to write: this is a
    /// disposable cache of strings, so an unusable file is discarded rather than repaired, and every root's
    /// harvest stamp goes with it so the next harvest rebuilds the set.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else {
            loadFailure = "vocabulary file could not be read"
            return
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == Self.currentVersion else {
            loadFailure = "vocabulary file was not a readable v\(Self.currentVersion) payload"
            return
        }
        names = Set(payload.names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(Self.maxNames))
        roots = Array(payload.roots.suffix(Self.maxRoots))
    }

    /// A comparable path: no trailing slash, `~` expanded, `.`/`..` resolved. Symlinks are deliberately
    /// NOT resolved — the caller's spelling of the root is what the app was pointed at.
    private static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
