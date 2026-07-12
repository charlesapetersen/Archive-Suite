// ReaderLinkResolver.swift — resolve DurableLink.readerReveal to a file URL
// Part of Archive Notes (W4-S5).

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
    /// The file doesn't exist under the granted root.
    case notFound
}

/// Resolves `DurableLink.readerReveal` links to file URLs within a granted
/// Reader root's security scope. All writes go through `ReaderRootStore`;
/// this resolver is purely read-only w.r.t. the corpus.
@MainActor
final class ReaderLinkResolver {
    private let rootStore: ReaderRootStore

    init(rootStore: ReaderRootStore) {
        self.rootStore = rootStore
    }

    /// Resolve a Reader link to a file URL.
    ///
    /// - Parameters:
    ///   - rootGUID: The root marker GUID from the durable link.
    ///   - relativePath: The root-relative path from the durable link.
    /// - Returns: A `LinkResolution` describing the outcome.
    func resolve(rootGUID: UUID, relativePath: String) -> LinkResolution {
        guard let rootURL = rootStore.root(for: rootGUID) else {
            return .needsRootGrant(guid: rootGUID)
        }

        let targetURL = rootURL.appendingPathComponent(relativePath)

        // Component-boundary containment check: the resolved path must be
        // strictly under the root (same as LibraryFilter.matches boundary
        // test). This prevents `../../` escapes.
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = targetURL.standardizedFileURL.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            return .notFound
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: targetPath) {
            return .resolved(targetURL)
        }

        // Basename fallback: look for a file with the same name elsewhere under
        // the root. Offer (don't auto-open) to avoid silently switching files.
        let basename = targetURL.lastPathComponent
        if let candidate = findByBasename(basename, under: rootURL, fm: fm) {
            return .renamedCandidate(candidate)
        }

        return .notFound
    }

    /// Register a newly-granted Reader root folder and retry resolution.
    func grantAndResolve(url: URL, rootGUID: UUID, relativePath: String) -> LinkResolution {
        guard let marker = rootStore.grantRoot(url) else {
            return .notFound
        }
        guard marker.guid == rootGUID else {
            // Wrong folder — the user chose a root with a different GUID.
            return .needsRootGrant(guid: rootGUID)
        }
        return resolve(rootGUID: rootGUID, relativePath: relativePath)
    }

    /// Stop the security scope for a given root (e.g. after a popover closes).
    func stopAccessing(guid: UUID) {
        rootStore.stopAccessing(guid: guid)
    }

    // MARK: - Private

    private func findByBasename(_ name: String, under root: URL, fm: FileManager) -> URL? {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent == name {
                return fileURL
            }
        }
        return nil
    }
}
