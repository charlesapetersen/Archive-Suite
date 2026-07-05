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
        stopAccessing()
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            beginAccessing(url)
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
            beginAccessing(url)
            root = url
            if stale { setRoot(url) }   // refresh a stale bookmark
        } catch {
            NSLog("RootFolderStore: could not resolve saved bookmark: \(error)")
        }
    }

    private func beginAccessing(_ url: URL) {
        if url.startAccessingSecurityScopedResource() { accessing = url }
    }
    private func stopAccessing() {
        if let a = accessing { a.stopAccessingSecurityScopedResource(); accessing = nil }
    }
}
