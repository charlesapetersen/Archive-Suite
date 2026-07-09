import Foundation
import Combine

/// Persists (as a security-scoped bookmark) the archive root folder the user granted, so v1 can
/// search + read within the sandbox across launches. The only access granted is to that folder;
/// `TagWriter`'s metadata-only writes happen within this scope. Non-sandboxed whole-Mac search is a
/// planned switch (see `CLAUDE.md` §Stack & Build — access is meant to sit behind this abstraction).
@MainActor
final class RootFolderStore: ObservableObject {
    @Published private(set) var root: URL?

    private var accessing: URL?
    private let key = "archiveRootBookmark"

    init() { resolveSaved() }

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
        } catch {
            NSLog("RootFolderStore: could not bookmark \(url.path): \(error)")
        }
    }

    func clear() {
        stopAccessing()
        UserDefaults.standard.removeObject(forKey: key)
        root = nil
    }

    private func resolveSaved() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            // A resolved bookmark MUST have its scope started; if that fails we truly have no access,
            // so leave `root` nil (user re-picks) rather than appearing connected. (Fix)
            guard url.startAccessingSecurityScopedResource() else {
                NSLog("RootFolderStore: saved root is no longer accessible; user must re-pick.")
                return
            }
            accessing = url
            root = url
            // Refresh a stale bookmark WHILE access is still held — never drop the scope first. (Fix)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: key)
            }
        } catch {
            NSLog("RootFolderStore: could not resolve saved bookmark: \(error)")
        }
    }

    private func stopAccessing() {
        if let a = accessing { a.stopAccessingSecurityScopedResource(); accessing = nil }
    }
}
