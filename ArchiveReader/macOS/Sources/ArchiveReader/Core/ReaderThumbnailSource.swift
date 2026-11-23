import ArchiveCore
import Foundation

/// Cache freshness for rendered PDF pixels. The physical stamp distinguishes copied markers,
/// same-date replacements and identical leaf names. A whole-root rename leaves leaf stamps alone.
struct ReaderThumbnailSource: Equatable, Sendable {
    let version: String
    let mtime: Date

    static func capture(_ path: String) -> Self? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              !ViewerCloudFile.isDataless(path, flags: info.st_flags) else { return nil }
        let birth = info.st_birthtimespec
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        let version = "\(info.st_dev):\(info.st_ino):\(birth.tv_sec):\(birth.tv_nsec):\(info.st_size)"
            + ":\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)"
        let mtime = Date(timeIntervalSince1970: TimeInterval(modified.tv_sec)
                         + TimeInterval(modified.tv_nsec) / 1_000_000_000)
        return Self(version: version, mtime: mtime)
    }

    fileprivate func cacheKey(for occurrence: String) -> String {
        "v2:\(version):\(occurrence)"
    }
}

extension PDFThumbnailer {
    /// Recheck on the renderer actor, where the actual open will run, after any queue delay.
    func readerPNG(fileURL: URL, page: Int, spec: Spec = Spec(), occurrence: String,
                   source: ReaderThumbnailSource, scope: ReaderRootCacheScope? = nil) async -> Data? {
        guard !Task.isCancelled, scope?.isCurrent != false, ReaderThumbnailSource.capture(fileURL.path) == source
        else { return nil }
        let image = await png(fileURL: fileURL, page: page, spec: spec,
                              linkKey: source.cacheKey(for: occurrence), mtime: source.mtime)
        guard !Task.isCancelled, scope?.isCurrent != false, ReaderThumbnailSource.capture(fileURL.path) == source
        else { return nil }
        return image
    }
}
