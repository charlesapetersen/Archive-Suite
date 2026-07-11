import Foundation
import ArchiveCore

/// Persists (as a security-scoped bookmark) the Notes store root folder the user
/// granted, so the app can access it across launches within the sandbox.
///
/// Copied from Reader's `RootFolderStore` with the following changes:
/// - Defaults key is `"notesStoreRootBookmark"`.
/// - Provides a first-run app-default folder (`Application Support/ArchiveNotes/Store`).
/// - Calls `RootMarkerStore.ensureMarker` after resolving/setting a root.
@MainActor
final class RootFolderStore: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var marker: RootMarker?

    private var accessing: URL?
    private let key = "notesStoreRootBookmark"

    init() {
        resolveSaved()
        if root == nil {
            bootstrapDefaultRoot()
        }
    }

    /// Set the store root from a user-selected folder (via an open panel).
    func setRoot(_ url: URL) {
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: key)
            let previous = accessing
            _ = url.startAccessingSecurityScopedResource()
            accessing = url
            if let previous, previous != url { previous.stopAccessingSecurityScopedResource() }
            root = url
            ensureMarkerQuietly()
        } catch {
            NSLog("RootFolderStore(Notes): could not bookmark \(url.path): \(error)")
        }
    }

    func clear() {
        stopAccessing()
        UserDefaults.standard.removeObject(forKey: key)
        root = nil
        marker = nil
    }

    // MARK: - Private

    private func resolveSaved() {
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            // Must start scope; if that fails, leave root nil (user re-picks).
            guard url.startAccessingSecurityScopedResource() else {
                NSLog("RootFolderStore(Notes): saved root is no longer accessible; user must re-pick.")
                return
            }
            accessing = url
            root = url
            // Refresh a stale bookmark while access is still held.
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: key)
            }
            ensureMarkerQuietly()
        } catch {
            NSLog("RootFolderStore(Notes): could not resolve saved bookmark: \(error)")
        }
    }

    private func bootstrapDefaultRoot() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first else { return }
        let defaultDir = appSupport
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
            .appendingPathComponent("Store", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: defaultDir,
                                                    withIntermediateDirectories: true)
            root = defaultDir
            ensureMarkerQuietly()
        } catch {
            NSLog("RootFolderStore(Notes): could not create default store: \(error)")
        }
    }

    private func ensureMarkerQuietly() {
        guard let root else { return }
        do {
            marker = try RootMarkerStore.ensureMarker(at: root, kind: .notes)
        } catch {
            NSLog("RootFolderStore(Notes): marker error: \(error)")
            marker = nil
        }
    }

    private func stopAccessing() {
        if let a = accessing { a.stopAccessingSecurityScopedResource(); accessing = nil }
    }
}
