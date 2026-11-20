import Foundation
import ArchiveCore

/// What the content index compares to decide a file's JSON sidecar names are current (W49.reader-sidecar-names-refresh):
/// the sidecar `ZoteroSidecar.locate` finds, by where it is, its modification time in nanoseconds, its size and its
/// inode. Empty when the file has none. The Processor writes the sidecar after the PDF, and a tagging re-run may
/// rewrite only the sidecar, so the text's stamp cannot stand for it.
///
/// `stat(2)` rather than `URL.resourceValues`, which caches on a reused URL. Per folder, `JSON Output` is looked
/// up once; per file, one `stat` of `<name>.json` beside it and, only where that is missing and the folder has a
/// `JSON Output`, one more there.
enum SidecarStamp {
    /// The stamp of each of `files` that has a sidecar. Dataless files are left out, as the index has no row for them.
    static func stamps(of files: [ArchiveFile]) -> [String: String] {
        var out: [String: String] = [:]
        // String slicing, not `URL` or `NSString` calls (measured slower): this runs for every file on every pass.
        // Discovery lists a folder's files together, so its `JSON Output` lookup is reused until the folder changes.
        var folder = "", jsonOutput = "", lookIn = false
        for file in files where !file.isDataless {
            let path = file.path
            guard let slash = path.lastIndex(of: "/") else { continue }
            if !path[..<slash].elementsEqual(folder) {
                folder = String(path[..<slash])
                jsonOutput = folder + "/" + ZoteroSidecar.folderName
                lookIn = isDirectory(jsonOutput)
            }
            let name = path[path.index(after: slash)...]
            let stem = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? name[..<$0] : nil } ?? name
            let base = "/" + stem + ".json"
            if let s = stamp(folder + base, kind: "b") {
                out[path] = s
            } else if lookIn, let s = stamp(jsonOutput + base, kind: "j") {
                out[path] = s
            }
        }
        return out
    }

    /// The stamp of the regular file at `path`; nil when there is none (a directory of that name is no sidecar, as
    /// `ZoteroSidecar.locate` skips it).
    private static func stamp(_ path: String, kind: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        return "\(kind):\(ns):\(st.st_size):\(st.st_ino)"
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
