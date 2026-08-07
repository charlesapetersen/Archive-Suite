// ReaderLinkResolver.swift — resolve DurableLink.readerReveal to a file URL
// Part of Archive Notes (W4-S5). W23.m14: the basename fallback moved off the
// main actor into a cancellable, bounded, progress-reporting search.
// W23.l1: containment is canonical (symlink-resolving), not merely lexical.
// W26.notesabsence: absence requires a walk that could actually READ the tree —
// the root is probed with `CorpusWalker.canonicalRoot` and the enumerator has an
// `errorHandler:`, so a symlinked, denied or partly-denied root reports
// `.searchIncomplete` instead of insisting the file is not there.

import Foundation
import ArchiveCore

/// The result of resolving an `archivereader://reveal` link from within Notes.
enum LinkResolution: Sendable, Equatable {
    /// The file was found within a live security scope (caller stops scope when done).
    case resolved(URL)
    /// The GUID is unknown on this machine — user must grant the Reader root.
    case needsRootGrant(guid: UUID)
    /// The exact path wasn't found, but a file with the same basename exists elsewhere.
    case renamedCandidate(URL)
    /// The file doesn't exist under the granted root, and the whole root was searched.
    case notFound
    /// The exact path was missing and the basename search did **not** finish — it was
    /// cancelled, or it hit its entry bound. Absence was never established, so this must
    /// never be reported as `.notFound` (W23.m14).
    case searchIncomplete(scanned: Int)
    /// The folder the user chose could not be granted at all — `refusal.message` says why.
    ///
    /// Never `.notFound` and never `.needsRootGrant`: nothing was searched, and asking again for
    /// the same folder without saying anything is the defect this case exists to stop
    /// (W26.notesabsence-fu1).
    case grantRefused(ReaderRootGrantRefusal)
}

/// The outcome of the walk-free stage of resolution.
///
/// Splitting resolution in two is the point of W23.m14: everything cheap and synchronous
/// stays on the main actor, and the one step that can walk 100k–150k files is handed to
/// `resolve(rootGUID:relativePath:progress:)`, which runs it off-actor.
enum FastLinkResolution: Sendable, Equatable {
    /// Resolution finished without touching the directory tree.
    case decided(LinkResolution)
    /// The exact path is missing; only a basename search under `root` can decide.
    /// The search is deliberately NOT run here.
    case needsBasenameSearch(root: URL, basename: String)
}

/// The result of one bounded basename search.
struct BasenameScan: Sendable, Equatable {
    /// Why the walk stopped.
    enum Stop: Sendable, Equatable {
        /// Every entry under the root was examined — absence is established.
        case exhausted
        /// The `limit` was reached first — absence is NOT established.
        case hitLimit
        /// The enclosing task was cancelled — absence is NOT established.
        case cancelled
        /// **Some part of the tree could not be read, so absence is NOT established.**
        ///
        /// Named for the case that used to be the only one it covered. Since `W26.notesabsence`
        /// it also covers a walk that started fine and then met a directory it could not descend
        /// into: an unreadable *subtree* is every bit as fatal to a claim of absence as an
        /// unreadable root, because the file being looked for may be sitting in it.
        case unreadableRoot
    }

    var match: URL?
    var scanned: Int
    var stop: Stop

    /// Upper bound on entries examined by one basename search.
    ///
    /// Deliberately far above any real corpus, so the fallback behaves exactly as it
    /// always has: the archive is ~100k–150k PDFs, and counting their JPEG partners and
    /// the folders holding them the walk still sees only a few hundred thousand entries.
    /// The bound exists to stop a pathological tree (a large network mount) searching
    /// forever, NOT to cap a legitimate archive — so it is set an order of magnitude
    /// clear of one. Hitting it reports `.searchIncomplete`, never `.notFound`.
    static let defaultLimit = 1_000_000
}

/// Containment for the granted Reader root — the one place that decides whether a path
/// the resolver is about to hand back is really *inside* the root the user granted.
///
/// **W23.l1 — canonical, not lexical.** `standardizedFileURL` normalizes `.`/`..`
/// **lexically** and does not resolve symlinks, while `FileManager.fileExists` **does**
/// follow them. So `<root>/alias.pdf` → `/elsewhere/private.pdf` passed the old boundary
/// test (the path is literally under the root) and came back `.resolved`, against the
/// resolver's stated granted-root contract. Only `resolvingSymlinksInPath()` exposes where
/// the path actually lands.
///
/// Both sides are canonicalized identically, which is what keeps a root that is *itself*
/// reached through a symlink — or through the `/var` ↔ `/private/var` alias — containing its
/// own files. And the comparison is component-wise, because a string prefix would accept a
/// sibling whose name merely starts with the root's (`…/Archive Extra` vs `…/Archive`).
///
/// File-scope (not a member of the `@MainActor` resolver) so the off-actor walk can use it.
enum ReaderRootContainment {

    /// The form both sides of every comparison are put in.
    ///
    /// Applied to a path that does **not** exist it still resolves the symlinks in the part
    /// that does, which is what makes `<root>/aliased-dir/missing.pdf` refusable before
    /// anything is opened.
    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Is `url` the root itself, or strictly under it?
    ///
    /// `canonicalRoot` must already have been through `canonical(_:)` — the caller usually
    /// has one root and many candidates, so hoisting it out keeps the walk's per-match cost
    /// to a single `realpath`. `url` is canonicalized here.
    static func isContained(_ url: URL, inCanonicalRoot canonicalRoot: URL) -> Bool {
        let rootComponents = canonicalRoot.pathComponents
        let urlComponents = canonical(url).pathComponents
        guard urlComponents.count >= rootComponents.count else { return false }
        return Array(urlComponents.prefix(rootComponents.count)) == rootComponents
    }
}

/// Is there *nothing* at `url` — as distinct from something we are not allowed to look at?
///
/// This is the sole gate on the one branch of the basename search that still establishes absence,
/// so it must be far pickier than the `FileManager.fileExists` it replaced. `fileExists` answers
/// `false` for a path denied by a `0o000` ancestor exactly as readily as for one that was never
/// there, which is this wave's defect in miniature: a permission error read as an empty archive.
///
/// `lstat(2)` and not `stat(2)`: a **dangling** symlink root is a root we cannot reach — the target
/// may be an unmounted volume — not a root that is provably empty, so it must fall through to
/// `.unreadableRoot`. This is the one behaviour the fix deliberately changes for a path that
/// previously reported `.exhausted`.
///
/// `ENOTDIR` counts as absent alongside `ENOENT`: it means a component of the path is a plain file,
/// so nothing can exist at the path either.
private func rootIsWhollyAbsent(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { rawPath -> Bool in
        guard let rawPath else { return false }
        var linkInfo = stat()
        guard lstat(rawPath, &linkInfo) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }
}

/// Records that the enumerator hit a directory it could not descend into.
///
/// A reference type because FileManager stores the handler and calls it synchronously from inside
/// `nextObject()` — a captured `var` would not satisfy Swift 6. Only the *fact* is kept: the caller
/// reports one `.unreadableRoot`, it does not enumerate the failures. (`ArchiveCore`'s equivalent,
/// `CorpusWalker`'s `ErrorSink`, keeps the list because its result type exposes one; it is `private`
/// to that file, which is why this is not it.)
private final class ScanErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var _sawError = false

    func record() { lock.lock(); _sawError = true; lock.unlock() }
    var sawError: Bool { lock.lock(); defer { lock.unlock() }; return _sawError }
}

/// Each a multiple of the one before, so a single modulo gates the rest.
/// File-scope (not members of the `@MainActor` resolver) so the off-actor walk can read them.
/// The cancellation check is the tightest of the three: on a slow volume an entry can cost
/// milliseconds, and this is how long a dismissed popover keeps a thread walking.
private let cancellationStride = 64
private let progressStride = 2_048
private let yieldStride = 8_192

/// Resolves `DurableLink.readerReveal` links to file URLs within a granted
/// Reader root's security scope. All writes go through `ReaderRootStore`;
/// this resolver is purely read-only w.r.t. the corpus.
@MainActor
final class ReaderLinkResolver {
    private let rootStore: ReaderRootStore
    private let scanLimit: Int

    /// The root whose security scope the most recent resolution left running, if any.
    ///
    /// Resolution starts a scope as a side effect (`ReaderRootStore.root(for:)`) and nothing ever
    /// gave one back: `stopAccessing(guid:)` had **no caller in the whole app**, so every root a
    /// session previewed stayed scoped until quit (`W26.notesabsence-fu3`). Remembering it here
    /// rather than in the popover is what makes "which root, and when" testable without a window —
    /// the popover's part is one call in `dismiss()`.
    private(set) var scopedRootGUID: UUID?

    init(rootStore: ReaderRootStore, scanLimit: Int = BasenameScan.defaultLimit) {
        self.rootStore = rootStore
        self.scanLimit = scanLimit
    }

    /// The walk-free stage of resolution — safe to call on the main actor.
    ///
    /// Returns `.needsBasenameSearch` instead of searching, so a caller cannot
    /// accidentally block the UI on a whole-archive walk.
    func resolveExact(rootGUID: UUID, relativePath: String) -> FastLinkResolution {
        guard let rootURL = rootStore.root(for: rootGUID) else {
            return .decided(.needsRootGrant(guid: rootGUID))
        }
        // A scope is live from here on. Recorded, not released — the caller may be about to read a
        // PDF out of this root, or to walk it. `releaseRootScope()` is the other half.
        //
        // A root replacing a *different* one is released now: only one preview is up at a time, so
        // the outgoing root has no reader left.
        if let outgoing = scopedRootGUID, outgoing != rootGUID {
            rootStore.stopAccessing(guid: outgoing)
        }
        scopedRootGUID = rootGUID

        let targetURL = rootURL.appendingPathComponent(relativePath)

        // Containment: the cited path must be the granted root itself or something under it,
        // *canonically*. This is what refuses both a `../../` escape (lexical) and a symlink
        // under the root whose target is outside it (W23.l1) — the latter is invisible to a
        // string comparison, because the cited path really is spelled under the root.
        let canonicalRoot = ReaderRootContainment.canonical(rootURL)
        guard ReaderRootContainment.isContained(targetURL, inCanonicalRoot: canonicalRoot) else {
            return .decided(.notFound)
        }

        // The URL handed back is the one the link named, not its canonical form: it is the
        // spelling the granted root's security scope covers, and containment is already proven.
        if FileManager.default.fileExists(atPath: targetURL.standardizedFileURL.path) {
            return .decided(.resolved(targetURL))
        }

        // Basename fallback: look for a file with the same name elsewhere under
        // the root. Offer (don't auto-open) to avoid silently switching files.
        return .needsBasenameSearch(root: rootURL, basename: targetURL.lastPathComponent)
    }

    /// Resolve a Reader link to a file URL.
    ///
    /// The exact-path hit costs one `fileExists`; only a miss pays for the basename
    /// search, which runs **off** the main actor, honours cancellation, and is bounded.
    ///
    /// - Parameters:
    ///   - rootGUID: The root marker GUID from the durable link.
    ///   - relativePath: The root-relative path from the durable link.
    ///   - progress: Called on the main actor with the running entry count while the
    ///     basename search is in flight. Ticks are throttled and may arrive out of
    ///     order — treat the value as a floor, not a total.
    /// - Returns: A `LinkResolution` describing the outcome.
    func resolve(
        rootGUID: UUID,
        relativePath: String,
        progress: (@MainActor @Sendable (Int) -> Void)? = nil
    ) async -> LinkResolution {
        switch resolveExact(rootGUID: rootGUID, relativePath: relativePath) {
        case .decided(let resolution):
            return resolution
        case .needsBasenameSearch(let root, let basename):
            var relay: (@Sendable (Int) -> Void)?
            if let report = progress {
                relay = { (count: Int) in Task { @MainActor in report(count) } }
            }
            let scan = await Self.scanForBasename(
                basename, under: root, limit: scanLimit, onProgress: relay
            )
            if let match = scan.match {
                return .renamedCandidate(match)
            }
            switch scan.stop {
            case .exhausted:
                return .notFound
            case .hitLimit, .cancelled, .unreadableRoot:
                return .searchIncomplete(scanned: scan.scanned)
            }
        }
    }

    /// Register a newly-granted Reader root folder and retry resolution.
    func grantAndResolve(
        url: URL,
        rootGUID: UUID,
        relativePath: String,
        progress: (@MainActor @Sendable (Int) -> Void)? = nil
    ) async -> LinkResolution {
        switch rootStore.grantRoot(url) {
        case .refused(let refusal):
            // The folder could not be adopted, so no search happened. Reporting `.notFound` here
            // (what a marker-less pick used to get) claims the archive was looked through.
            return .grantRefused(refusal)
        case .granted(let marker):
            guard marker.guid == rootGUID else {
                // Wrong folder — the user chose a root with a different GUID.
                return .needsRootGrant(guid: rootGUID)
            }
            return await resolve(rootGUID: rootGUID, relativePath: relativePath, progress: progress)
        }
    }

    /// Give back the security scope the last resolution started (e.g. after a popover closes).
    ///
    /// Replaces `stopAccessing(guid:)`, which had no caller anywhere in the app — the popover
    /// dismissed and the scope stayed. Taking no GUID is deliberate: the caller that knows a preview
    /// is over does not know which root it was for, and asking it to remember is how the old API
    /// came to be dead.
    ///
    /// Safe to call while a basename search is still unwinding: the walk holds no reference to the
    /// scope beyond the open enumerator, so at worst a cancelled search records a few directory
    /// errors on its way out — and a cancelled search's answer is discarded by construction.
    func releaseRootScope() {
        guard let guid = scopedRootGUID else { return }
        scopedRootGUID = nil
        rootStore.stopAccessing(guid: guid)
    }

    // MARK: - The off-actor search

    /// Walk `root` for the first entry named `name`.
    ///
    /// `nonisolated` on purpose: an `async` nonisolated method does not inherit the
    /// caller's actor, so the walk runs on the cooperative pool and the main actor stays
    /// responsive while it does. Cancellation is checked as it goes, and the walk stops
    /// after `limit` entries — either way the caller learns the search did not finish.
    nonisolated static func scanForBasename(
        _ name: String,
        under root: URL,
        limit: Int = BasenameScan.defaultLimit,
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) async -> BasenameScan {
        // A private FileManager: the enumerator is driven off-actor and must not share
        // state with whatever the main actor is doing to `FileManager.default`.
        let fm = FileManager()

        // **Openability is a syscall, not a stat (`W26.notesabsence`).** This used to ask
        // `fileExists(atPath:isDirectory:)`, which follows symlinks and says "yes, a directory"
        // for roots the enumerator then reads *nothing* from. Measured 2026-08-07 with this
        // call's own options, each root holding a matching `doc.pdf`:
        //
        // | root | fileExists / isDirectory | entries yielded | old verdict |
        // | --- | --- | --- | --- |
        // | a symlink to the archive folder | true / true | 0 | `.exhausted` ⇒ **`.notFound`** |
        // | a `0o000` directory | true / true | 0 | `.exhausted` ⇒ **`.notFound`** |
        //
        // `FileManager.enumerator(at:)` is non-nil in both cases — it reports the root once to
        // `errorHandler:` and immediately ends — so the `guard let enumerator` below never fired
        // and the walk fell through to "every entry examined". `CorpusWalker.canonicalRoot` is
        // the shared probe for exactly this (`opendir(3)`, plus `realpath(3)` for a symlinked
        // final component so the target is walked); it is what that function was made public for.
        guard let walkRoot = CorpusWalker.canonicalRoot(root) else {
            guard rootIsWhollyAbsent(root) else {
                // The root is *there* and we cannot read it — a denial, an unmounted volume, a
                // plain file, a dangling link. Absence is NOT established.
                return BasenameScan(match: nil, scanned: 0, stop: .unreadableRoot)
            }
            // The root itself is gone: nothing can be under a directory that isn't there,
            // so absence IS established. (This is the shipped W8-S9 computer-move
            // contract — a stale root reports the file missing, never a wrong file.)
            return BasenameScan(match: nil, scanned: 0, stop: .exhausted)
        }

        // WITHOUT this handler the enumerator silently skips a directory it cannot descend into
        // and the walk still calls itself exhausted — the same bug one level down, and the reason
        // `lint-write-surface.sh` rule 3 bans the handler-less overload outright.
        let errorSink = ScanErrorSink()
        guard let enumerator = fm.enumerator(
            at: walkRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                errorSink.record()
                return true    // keep walking; the recorded error is what forbids claiming absence
            }
        ) else {
            return BasenameScan(match: nil, scanned: 0, stop: .unreadableRoot)
        }

        // Canonicalized ONCE, outside the loop: containment is only asked about an entry whose
        // name already matched, so the walk pays one `realpath` per candidate (rare) rather
        // than one per entry (100k–150k).
        //
        // Derived from `walkRoot`, not from `root`: containment must be asked in the spelling the
        // enumerator actually reports, which for a symlinked root is the target's. The two agree
        // today — `canonical(_:)` resolves symlinks on both sides — but deriving it from what the
        // walk was handed is what keeps them from drifting apart (`W26.symroot-fu1`, where a root
        // spelled one way and paths discovered another rejected every row). `walkRoot` is the same
        // directory as the granted root either way, so the granted-root contract is unchanged.
        let canonicalRoot = ReaderRootContainment.canonical(walkRoot)

        var scanned = 0
        // `nextObject()` rather than `for … in enumerator`: NSEnumerator's Sequence
        // conformance is unavailable from an async context.
        while let entry = enumerator.nextObject() {
            guard let fileURL = entry as? URL else { continue }
            scanned += 1
            // A name match is a candidate only if it is really inside the root. The enumerator
            // lists a symlink as an ordinary entry (it just won't descend into one), so
            // `<root>/x/doc.pdf` → a PDF outside the root would otherwise be offered as the
            // renamed candidate — the same escape the exact-path stage refuses, through a
            // different door (W23.l1). Skipping rather than stopping keeps the walk honest:
            // a genuine copy further on is still found, and absence is still established.
            if fileURL.lastPathComponent == name,
               ReaderRootContainment.isContained(fileURL, inCanonicalRoot: canonicalRoot) {
                onProgress?(scanned)
                return BasenameScan(match: fileURL, scanned: scanned, stop: .exhausted)
            }
            if scanned % cancellationStride == 0 {
                if Task.isCancelled {
                    return BasenameScan(match: nil, scanned: scanned, stop: .cancelled)
                }
                if scanned % progressStride == 0 {
                    onProgress?(scanned)
                }
                if scanned % yieldStride == 0 {
                    await Task.yield()
                }
            }
            if scanned >= limit {
                return BasenameScan(match: nil, scanned: scanned, stop: .hitLimit)
            }
        }

        // A cancellation landing between the last stride check and the end of the walk
        // would otherwise be reported as a completed search over a truncated tree.
        if Task.isCancelled {
            return BasenameScan(match: nil, scanned: scanned, stop: .cancelled)
        }
        onProgress?(scanned)
        // The walk reached the end — but "the end of what it was allowed to see" is not absence.
        // One skipped directory is enough: the file may be in it. `CorpusScanResult.isClean`
        // encodes the same rule for the Reader's discovery walk.
        return BasenameScan(match: nil, scanned: scanned,
                            stop: errorSink.sawError ? .unreadableRoot : .exhausted)
    }
}
