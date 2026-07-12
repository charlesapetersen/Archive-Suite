// ReaderRootStore.swift — GUID-keyed security-scoped bookmarks to Reader roots
// Part of Archive Notes (W4-S5).

import Foundation
import ArchiveCore

/// Manages security-scoped bookmarks to Archive Reader root folders,
/// keyed by their `RootMarker.guid`.
///
/// When Notes resolves a `DurableLink.readerReveal`, it looks up the root
/// GUID here. On first encounter (new machine or unknown GUID) the user
/// grants access via an open panel; the bookmark is stored for future use.
@MainActor
final class ReaderRootStore: ObservableObject {
    @Published private(set) var knownRoots: [UUID: URL] = [:]

    /// Active security scopes keyed by GUID, so we can stop them on removal.
    private var activeScopes: [UUID: URL] = [:]
    private let defaultsKey = "readerRootBookmarks"

    init() {
        loadSaved()
    }

    /// Look up a Reader root by its marker GUID.
    /// Starts the security scope if not already active; returns `nil` on miss.
    func root(for guid: UUID) -> URL? {
        if let url = activeScopes[guid] {
            return url
        }
        guard let url = knownRoots[guid] else { return nil }
        if url.startAccessingSecurityScopedResource() {
            activeScopes[guid] = url
            return url
        }
        // Bookmark is stale / no longer accessible — remove it.
        knownRoots.removeValue(forKey: guid)
        persistAll()
        return nil
    }

    /// Register a newly-granted Reader root. Reads its `RootMarker` to get
    /// the GUID, stores a security-scoped bookmark, and returns the marker.
    /// Returns `nil` if the folder has no valid marker.
    @discardableResult
    func grantRoot(_ url: URL) -> RootMarker? {
        guard let marker = try? RootMarker.read(at: url) else { return nil }

        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            // Store the raw bookmark data keyed by lowercased GUID string.
            var stored = savedBookmarks()
            stored[marker.guid.uuidString.lowercased()] = data
            UserDefaults.standard.set(stored, forKey: defaultsKey)

            _ = url.startAccessingSecurityScopedResource()
            activeScopes[marker.guid] = url
            knownRoots[marker.guid] = url
        } catch {
            NSLog("ReaderRootStore: could not bookmark \(url.path): \(error)")
        }
        return marker
    }

    /// Stop the security scope for the given root. Does not remove the bookmark.
    func stopAccessing(guid: UUID) {
        if let url = activeScopes.removeValue(forKey: guid) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Private

    private func savedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private func loadSaved() {
        for (guidStr, data) in savedBookmarks() {
            guard let guid = UUID(uuidString: guidStr) else { continue }
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                knownRoots[guid] = url
                // Don't start scope eagerly — do it on demand in root(for:).
                if stale {
                    refreshBookmark(guid: guid, url: url)
                }
            } catch {
                NSLog("ReaderRootStore: could not resolve bookmark for \(guidStr): \(error)")
            }
        }
    }

    private func refreshBookmark(guid: UUID, url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            var stored = savedBookmarks()
            stored[guid.uuidString.lowercased()] = fresh
            UserDefaults.standard.set(stored, forKey: defaultsKey)
        }
    }

    private func persistAll() {
        var stored: [String: Data] = [:]
        for (guid, url) in knownRoots {
            if let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                stored[guid.uuidString.lowercased()] = data
            }
        }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }
}
