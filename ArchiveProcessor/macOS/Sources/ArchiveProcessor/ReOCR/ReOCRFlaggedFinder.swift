import ArchiveCore
import Foundation

// MARK: - Improve OCR: finding the files someone flagged (W44.reocr-processor)

/// The PDFs under a folder that carry the `OCR Poor` flag in any spelling, for the dialog's "flagged files" entry point.
/// A PDF with a catalogue companion beside it is flagged by its record's OCR Poor field, not its Finder tags: filed
/// output carries no Finder tags unless the archive mirrors them (W49.storage-finder), and an old tag on such a PDF
/// is not a second answer. A companion that cannot be read leaves its PDF unlisted.
/// Read-only: it lists folders and reads tags and companions, nothing else. Folders it cannot read are counted and reported, never
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
            guard isFlagged(url) else { continue }
            if files.count == limit { truncated = true; break }
            files.append(url)
        }
        return Found(files: files.sorted { $0.path < $1.path }, scanned: scanned, unreadableFolders: errors.count, truncated: truncated)
    }

    private static let largestCompanion = 16 << 20

    private static func isFlagged(_ pdf: URL) -> Bool {
        let companion = pdf.deletingLastPathComponent()
            .appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: pdf.lastPathComponent))
        var info = stat()
        guard lstat(companion.path, &info) == 0 else {
            return TagReading.read(pdf).tagNames?.contains { isSameTag($0, DocumentTags.poorOCRTag) } == true
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= largestCompanion,
              let data = try? Data(contentsOf: companion), let record = try? CatalogueRecord(json: data),
              case .value(true)? = record.fileFields.ocrPoor?.current else { return false }
        return true
    }
}
