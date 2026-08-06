import Foundation
import Combine
import ArchiveCore

/// Persists (as a security-scoped bookmark) the archive root folder the user granted, so v1 can
/// search + read within the sandbox across launches. The only access granted is to that folder;
/// `TagWriter`'s metadata-only writes happen within this scope. Non-sandboxed whole-Mac search is a
/// planned switch (see `CLAUDE.md` §Stack & Build — access is meant to sit behind this abstraction).
@MainActor
final class RootFolderStore: ObservableObject {
    @Published private(set) var root: URL?

    /// The prefix every path a discovery pass reports under `root` is spelled with — computed once
    /// here, at adoption, and `nil` exactly when there is no root.
    ///
    /// **This, not `root.path`, is what a discovered path must be compared against.** The enumerator
    /// hands back fully `realpath`-resolved paths, so under any root whose spelling differs from its
    /// resolved one — a symlinked component, or merely an aliased ancestor like `/var/folders` →
    /// `/private/var/folders` — a comparison against `root.path` rejects every path the walk just
    /// produced. (`W26.symroot-fu1`; the primitive and its measurements are
    /// `CorpusWalker.discoveredPathPrefix`.)
    ///
    /// ⛔ **In-memory only, and for comparison only.** It is never persisted (never near
    /// `archiveRootBookmark` — the 2026-07-11 incident) and never opened: it carries no security
    /// scope, so `root` remains the only URL any I/O may go through.
    @Published private(set) var discoveredPathPrefix: String?

    /// The granted root's link identity, including *why* it is unusable when it is. (W23.m6)
    @Published private(set) var markerState: RootMarkerState = .noRoot

    /// The marker durable links may be minted from — `nil` whenever the identity is degraded, so a
    /// GUID that only exists in memory (or one we failed to read) can never reach a copied link.
    var rootMarker: RootMarker? { markerState.durableMarker }

    private var accessing: URL?
    private let key = "archiveRootBookmark"
    /// Injected so the adoption path — which WRITES `archiveRootBookmark` — is testable without going
    /// anywhere near the owner's real root (the 2026-07-11 incident). Production always passes
    /// `.standard`; only tests pass a throwaway suite.
    private let defaults: UserDefaults
    var hasSavedBookmark: Bool { defaults.data(forKey: key) != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
#if DEBUG
        // XCUITest sets -ARUITestRootPath <path> via launchArguments. The argument domain is
        // volatile (never written to disk), so this can never shadow a normal launch. We set
        // `root` directly without persisting a bookmark and without reading/writing
        // `archiveRootBookmark` — the real root is never touched.
        if let path = defaults.string(forKey: "ARUITestRootPath"), !path.isEmpty {
            adoptTestRoot(URL(fileURLWithPath: path, isDirectory: true))
            return
        }
#endif
        resolveSaved()
    }

    /// Why a chosen folder could not be adopted. Returned so the caller can *say so* — until
    /// `W26.symroot-fu1` both failures were an `NSLog` and nothing else, i.e. a pick that left the
    /// window with no root, no scan and no explanation.
    enum RootPickRefusal: Equatable, Sendable {
        /// The folder cannot be opened at all: missing, permission-denied, a dangling symlink, an
        /// `ELOOP` cycle, or not a directory.
        case unreadable(URL)
        /// It opens, but macOS refused to mint a security-scoped bookmark for it, so access could
        /// not survive the launch — adopting it anyway would work until the next one and then not.
        case couldNotBookmark(URL, String)

        var message: String {
            switch self {
            case let .unreadable(url):
                return "Could not open “\(url.lastPathComponent)”. "
                    + "Check that the folder still exists and that you have permission to read it."
            case let .couldNotBookmark(url, _):
                return "Could not keep access to “\(url.lastPathComponent)”, so it was not opened."
            }
        }
    }

    /// Set the archive root from a user-selected folder (via an open panel).
    ///
    /// Returns `nil` when the folder was adopted, otherwise why it was refused.
    ///
    /// The folder is adopted as `CorpusWalker.canonicalRoot(url)` rather than as picked, because
    /// `bookmarkData(options: .withSecurityScope)` **cannot open a symbolic link** — measured
    /// 2026-08-06, it throws `NSCocoaErrorDomain 256` "Could not open() the item" for a link to a
    /// perfectly readable directory while succeeding on that same directory. So before this, picking
    /// a symlinked folder threw straight into the `catch` below and the user was told nothing at all.
    /// It differs from the picked URL *only* for a symlinked final component (`canonicalRoot` returns
    /// every other root byte-unchanged), so no root that works today can shift — and the bookmark is
    /// minted for the same URL that is adopted, so the scope belongs to the root we keep.
    @discardableResult
    func setRoot(_ url: URL) -> RootPickRefusal? {
        guard let target = CorpusWalker.canonicalRoot(url) else { return .unreadable(url) }
        // `target` is freshly chosen in an open panel (accessible this session). Persist a
        // security-scoped bookmark to regain access on relaunch, then adopt the new scope and release
        // the previous one.
        do {
            let data = try target.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(data, forKey: key)
            let previous = accessing
            _ = target.startAccessingSecurityScopedResource() // true for bookmark URLs; no-op for panel URLs
            accessing = target
            if let previous, previous != target { previous.stopAccessingSecurityScopedResource() }
            adopt(target)
            loadOrEnsureMarker(at: target)
            return nil
        } catch {
            NSLog("RootFolderStore: could not bookmark \(target.path): \(error)")
            return .couldNotBookmark(target, "\(error)")
        }
    }

    func clear() {
        stopAccessing()
        defaults.removeObject(forKey: key)
        root = nil
        discoveredPathPrefix = nil
        markerState = .noRoot
    }

    /// Re-resolve the persisted bookmark after FSEvents reports RootChanged/Mount/Unmount.
    ///
    /// A moved granted directory can resolve to a new path; a removed/ejected one becomes no root
    /// rather than leaving the library watching a dead pathname. The bookmark remains persisted so a
    /// later window activation can retry after the volume is mounted again.
    @discardableResult
    func reResolveSavedRoot() -> URL? {
        guard let data = defaults.data(forKey: key) else {
            stopAccessing()
            root = nil
            discoveredPathPrefix = nil
            markerState = .noRoot
            return nil
        }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            // A resolved bookmark MUST have its scope started; if that fails we truly have no access,
            // so leave `root` nil (user re-picks) rather than appearing connected. (Fix)
            guard url.startAccessingSecurityScopedResource() else {
                NSLog("RootFolderStore: saved root is no longer accessible; user must re-pick.")
                stopAccessing()
                root = nil
                discoveredPathPrefix = nil
                markerState = .noRoot
                return nil
            }
            let previous = accessing
            accessing = url
            previous?.stopAccessingSecurityScopedResource() // balance the old lifetime after new access is live
            adopt(url)
            loadOrEnsureMarker(at: url)
            // Refresh a stale bookmark WHILE access is still held — never drop the scope first. (Fix)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: key)
            }
            return url
        } catch {
            NSLog("RootFolderStore: could not resolve saved bookmark: \(error)")
            stopAccessing()
            root = nil
            discoveredPathPrefix = nil
            markerState = .noRoot
            return nil
        }
    }

    /// The ONE place `root` is set to a usable value, so its comparison spelling can never be
    /// forgotten at one of the three adoption sites (panel pick, bookmark re-resolve, DEBUG fixture).
    ///
    /// `discoveredPathPrefix` deliberately falls back to `url.path` rather than to `nil` if
    /// `realpath` fails: it only fails when the path does not resolve at all, and a root that has
    /// momentarily gone away still needs *a* spelling for the comparisons — the same reasoning that
    /// keeps the primitive from probing openability. Every caller's old behaviour is that fallback.
    private func adopt(_ url: URL) {
        root = url
        discoveredPathPrefix = CorpusWalker.discoveredPathPrefix(for: url) ?? url.path
    }

    private func resolveSaved() { _ = reResolveSavedRoot() }

    private func stopAccessing() {
        if let a = accessing { a.stopAccessingSecurityScopedResource(); accessing = nil }
    }

    /// Read or create the `.archive-suite-root.json` marker at the granted root.
    /// On failure (read-only volume, unreadable or malformed existing file) the state records *why*
    /// and `rootMarker` stays nil — the app still reads normally, but link minting is refused and
    /// the reason is shown when they try, rather than a link being copied that can never resolve.
    private func loadOrEnsureMarker(at url: URL) {
        markerState = .ensuring(url)
    }

#if DEBUG
    /// Set root for UI testing without persisting a bookmark or starting a security scope.
    /// The fixture path is accessible via the UITest-only temporary-exception entitlement,
    /// so no security-scoped resource dance is needed. This method does NOT read or write
    /// `archiveRootBookmark` in UserDefaults — the real root bookmark is never touched.
    private func adoptTestRoot(_ url: URL) {
        adopt(url)
        // `accessing` stays nil — no scope to release. No bookmark persisted.
        // Read (but don't create) a marker if present — tests may provide one.
        markerState = .reading(url)
    }
#endif
}
