import Foundation
import PDFKit
import ArchiveCore

/// How the source-block preview opens its PDF without downloading a cloud placeholder (W49.notes-s007-fix).
///
/// A bare `PDFDocument(url:)` on a dataless OneDrive / iCloud / Google Drive file downloads the whole file:
/// 6.2 MB in 1.9 s on a real OneDrive placeholder, left materialised afterwards
/// (`verification/evidence/notes/W49.notes-s007-dataless-preview.md`). `W9.b4` promises Notes never does that
/// unasked, so the preview opens inside `CorpusWalker.withDatalessMaterializationDisabled` and, for a
/// placeholder, says so and offers to download it.
enum PreviewCloudFile {

    enum Opening {
        case show(PDFDocument)
        /// A cloud placeholder whose data is not on this Mac. Nothing was downloaded.
        case inCloud
        case unreadable
    }

    /// Decide what the preview shows. `isDataless` and `open` are seams for the unit tests: a test cannot make
    /// a dataless file, and an engine session runs with materialisation off process-wide anyway.
    ///
    /// The stat comes first so a placeholder is never even offered to PDFKit. The open is still guarded,
    /// because a file can be evicted between the stat and the open; a nil open on a file that is dataless by
    /// then is reported as in the cloud, not as unreadable.
    static func opening(
        _ fileURL: URL,
        isDataless: (URL) -> Bool = PreviewCloudFile.isDataless,
        open: (URL) -> PDFDocument? = { PDFDocument(url: $0) }
    ) -> Opening {
        if isDataless(fileURL) { return .inCloud }
        if let doc = CorpusWalker.withDatalessMaterializationDisabled({ open(fileURL) }) {
            return .show(doc)
        }
        return isDataless(fileURL) ? .inCloud : .unreadable
    }

    /// `SF_DATALESS` from a following `stat(2)`. False when the stat fails: the guarded open then decides.
    static func isDataless(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            var info = stat()
            guard stat(path, &info) == 0 else { return false }
            return (info.st_flags & UInt32(SF_DATALESS)) != 0
        }
    }

    /// Download a placeholder the user asked to see, by reading its first byte with materialisation turned
    /// **on** for this thread (a read is what makes the File Provider fetch the file). Blocks for the whole
    /// download, so call it off the main actor. Restores the thread's previous policy, as the guard does.
    ///
    /// - Returns: true when the file is no longer dataless afterwards.
    static func download(_ url: URL) -> Bool {
        let prior = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        defer {
            _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                               prior >= 0 ? prior : IOPOL_DEFAULT)
        }
        let fd = url.withUnsafeFileSystemRepresentation { path in path.map { Darwin.open($0, O_RDONLY) } ?? -1 }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var byte: UInt8 = 0
        guard read(fd, &byte, 1) >= 0 else { return false }
        return !isDataless(url)
    }
}
