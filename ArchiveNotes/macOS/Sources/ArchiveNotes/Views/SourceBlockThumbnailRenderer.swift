import Foundation
import ArchiveCore

/// Renders a thumbnail for a pasted Reader *page* link when that pasteboard payload did not include
/// one. It resolves only the exact, already-granted target path: a paste must never start a basename
/// walk or prompt for a folder merely to improve its presentation. All source access is read-only; the
/// renderer's only write is its app-owned, disposable thumbnail cache.
@MainActor
final class SourceBlockThumbnailRenderer {
    private let rootStore: ReaderRootStore
    private let thumbnailer: PDFThumbnailer

    init(rootStore: ReaderRootStore, thumbnailer: PDFThumbnailer) {
        self.rootStore = rootStore
        self.thumbnailer = thumbnailer
    }

    /// Returns a PNG only for an exact, granted Reader page link. Every fast-resolution outcome that
    /// would require user interaction or an archive walk deliberately degrades to `nil`.
    func png(for anchor: SourceAnchor) async -> Data? {
        guard let linkString = anchor.link,
              let linkURL = URL(string: linkString),
              case .readerReveal(let rootGUID, let relativePath, let linkPage, _) = DurableLink(url: linkURL),
              let page = linkPage, page > 0,
              anchor.page == page else {
            return nil
        }

        // This deliberately does not use the popover's `ReaderLinkResolver`: that resolver retains
        // a root scope until the visible preview dismisses, and releasing a shared store scope here
        // would prematurely close that preview. Start and balance this renderer's own short lease.
        guard let rootURL = rootStore.knownRoot(for: rootGUID) else { return nil }
        let startedScope = rootURL.startAccessingSecurityScopedResource()
        defer {
            if startedScope {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileURL = rootURL.appendingPathComponent(relativePath)
        let canonicalRoot = ReaderRootContainment.canonical(rootURL)
        guard ReaderRootContainment.isContained(fileURL, inCanonicalRoot: canonicalRoot),
              FileManager.default.fileExists(atPath: fileURL.standardizedFileURL.path) else {
            return nil
        }

        let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        return await thumbnailer.png(
            fileURL: fileURL, page: page, linkKey: linkString, mtime: mtime
        )
    }
}
