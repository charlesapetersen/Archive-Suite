// ReaderLinkResolver.swift — resolve DurableLink.readerReveal to a file URL
// Part of Archive Notes (W4-S5). W23.m14: the basename fallback moved off the
// main actor into a cancellable, bounded, progress-reporting search.
// W23.l1: containment is canonical (symlink-resolving), not merely lexical.

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
        /// The root could not be enumerated at all — absence is NOT established.
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
        guard let marker = rootStore.grantRoot(url) else {
            return .notFound
        }
        guard marker.guid == rootGUID else {
            // Wrong folder — the user chose a root with a different GUID.
            return .needsRootGrant(guid: rootGUID)
        }
        return await resolve(rootGUID: rootGUID, relativePath: relativePath, progress: progress)
    }

    /// Stop the security scope for a given root (e.g. after a popover closes).
    func stopAccessing(guid: UUID) {
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
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                // The root exists but cannot be walked, so absence is NOT established.
                return BasenameScan(match: nil, scanned: 0, stop: .unreadableRoot)
            }
        } else {
            // The root itself is gone: nothing can be under a directory that isn't there,
            // so absence IS established. (This is the shipped W8-S9 computer-move
            // contract — a stale root reports the file missing, never a wrong file.)
            return BasenameScan(match: nil, scanned: 0, stop: .exhausted)
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return BasenameScan(match: nil, scanned: 0, stop: .unreadableRoot)
        }

        var scanned = 0
        // `nextObject()` rather than `for … in enumerator`: NSEnumerator's Sequence
        // conformance is unavailable from an async context.
        while let entry = enumerator.nextObject() {
            guard let fileURL = entry as? URL else { continue }
            scanned += 1
            if fileURL.lastPathComponent == name {
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
        return BasenameScan(match: nil, scanned: scanned, stop: .exhausted)
    }
}
