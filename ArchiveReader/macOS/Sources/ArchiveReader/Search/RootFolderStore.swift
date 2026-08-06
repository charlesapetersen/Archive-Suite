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

    /// The granted root's link identity, including *why* it is unusable when it is. (W23.m6)
    @Published private(set) var markerState: RootMarkerState = .noRoot

    /// The marker durable links may be minted from — `nil` whenever the identity is degraded, so a
    /// GUID that only exists in memory (or one we failed to read) can never reach a copied link.
    var rootMarker: RootMarker? { markerState.durableMarker }

    private var accessing: URL?
    private let key = "archiveRootBookmark"
    var hasSavedBookmark: Bool { UserDefaults.standard.data(forKey: key) != nil }

    init() {
#if DEBUG
        // XCUITest sets -ARUITestRootPath <path> via launchArguments. The argument domain is
        // volatile (never written to disk), so this can never shadow a normal launch. We set
        // `root` directly without persisting a bookmark and without reading/writing
        // `archiveRootBookmark` — the real root is never touched.
        if let path = UserDefaults.standard.string(forKey: "ARUITestRootPath"), !path.isEmpty {
            adoptTestRoot(URL(fileURLWithPath: path, isDirectory: true))
            return
        }
#endif
        resolveSaved()
    }

    /// Set the archive root from a user-selected folder (via an open panel).
    func setRoot(_ url: URL) {
        // `url` is freshly chosen in an open panel (accessible this session). Persist a security-scoped
        // bookmark to regain access on relaunch, then adopt the new scope and release the previous one.
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            let previous = accessing
            _ = url.startAccessingSecurityScopedResource()   // true for bookmark URLs; no-op for panel URLs
            accessing = url
            if let previous, previous != url { previous.stopAccessingSecurityScopedResource() }
            root = url
            loadOrEnsureMarker(at: url)
        } catch {
            NSLog("RootFolderStore: could not bookmark \(url.path): \(error)")
        }
    }

    func clear() {
        stopAccessing()
        UserDefaults.standard.removeObject(forKey: key)
        root = nil
        markerState = .noRoot
    }

    /// Re-resolve the persisted bookmark after FSEvents reports RootChanged/Mount/Unmount.
    ///
    /// A moved granted directory can resolve to a new path; a removed/ejected one becomes no root
    /// rather than leaving the library watching a dead pathname. The bookmark remains persisted so a
    /// later window activation can retry after the volume is mounted again.
    @discardableResult
    func reResolveSavedRoot() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            stopAccessing()
            root = nil
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
                markerState = .noRoot
                return nil
            }
            let previous = accessing
            accessing = url
            previous?.stopAccessingSecurityScopedResource() // balance the old lifetime after new access is live
            root = url
            loadOrEnsureMarker(at: url)
            // Refresh a stale bookmark WHILE access is still held — never drop the scope first. (Fix)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: key)
            }
            return url
        } catch {
            NSLog("RootFolderStore: could not resolve saved bookmark: \(error)")
            stopAccessing()
            root = nil
            markerState = .noRoot
            return nil
        }
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
        root = url
        // `accessing` stays nil — no scope to release. No bookmark persisted.
        // Read (but don't create) a marker if present — tests may provide one.
        markerState = .reading(url)
    }
#endif
}
