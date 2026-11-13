import ArchiveCore
import Foundation

// MARK: - Improve OCR: finding the files someone flagged (W44.reocr-processor)

/// The PDFs under a folder that carry the `OCR Poor` flag in any spelling, for the dialog's "flagged files" entry point.
/// Read-only: it lists folders and reads tags, nothing else. Folders it cannot read are counted and reported, never
/// silently skipped. Stops at `limit` files, and says so, so a whole corpus does not become one dialog.
enum ReOCRFlaggedFinder {
    struct Found: Equatable, Sendable {
        let files: [URL]
        let scanned: Int
        let unreadableFolders: Int
        let truncated: Bool
    }

    static func find(in folder: URL, limit: Int = 500) -> Found {
        final class Errors: @unchecked Sendable { var count = 0 }
        let errors = Errors()
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                         errorHandler: { _, _ in errors.count += 1; return true }) else {
            return Found(files: [], scanned: 0, unreadableFolders: 1, truncated: false)
        }
        var files: [URL] = [], scanned = 0, truncated = false
        for case let url as URL in walker where url.pathExtension.lowercased() == "pdf" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            scanned += 1
            guard let tags = TagReading.read(url).tagNames, tags.contains(where: { isSameTag($0, DocumentTags.poorOCRTag) }) else { continue }
            if files.count == limit { truncated = true; break }
            files.append(url)
        }
        return Found(files: files.sorted { $0.path < $1.path }, scanned: scanned, unreadableFolders: errors.count, truncated: truncated)
    }
}
