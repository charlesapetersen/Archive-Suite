import Foundation

/// The identity of a scan root, cheap enough to capture both **before and after** every pass.
///
/// Why this exists (plan §7a.11). `CorpusScanResult.completed` means only *"the enumerator ended."*
/// If the root is replaced or unmounted mid-walk — an external drive ejected, a File Provider domain
/// dropping out — the remaining top-level children can list **empty rather than error**, so the pass
/// finishes with `filesSeen: 40_000`, `directoryErrors: []`, `completed: true`: clean and complete by
/// every counter the walker has. Every gate built on `isClean` would then treat a truncated walk as
/// authoritative, and pruning would evict index rows for ~110,000 files that are perfectly fine.
///
/// So: a pass is authoritative only if the root it *started* on is the root it *ended* on — same
/// filesystem, same directory inode, still readable. Two `stat`-class syscalls per pass.
///
/// Read-only by construction: `stat`, `statfs` and `access` are the only calls made here.
public struct CorpusRootFingerprint: Sendable, Equatable {
    /// `statfs.f_fsid`, packed into one integer. Distinguishes two mounts that reuse inode numbers.
    public let filesystemID: Int64
    /// `stat.st_dev` — the device the root directory lives on.
    public let deviceID: Int64
    /// `stat.st_ino` — the root directory's inode. A directory swapped for a different one under the
    /// same path changes this even when the path string does not.
    public let inode: UInt64

    public init(filesystemID: Int64, deviceID: Int64, inode: UInt64) {
        self.filesystemID = filesystemID
        self.deviceID = deviceID
        self.inode = inode
    }

    /// Capture `root`'s identity, or `nil` when it is gone, is not a directory, or is not readable.
    ///
    /// `nil` is deliberately not an error case with a reason: the only question a caller asks is
    /// *"is this the same readable root as before?"*, and every way of answering "no" is the same
    /// answer. A pass whose before- **or** after-capture is `nil` is not authoritative.
    public static func capture(_ root: URL) -> CorpusRootFingerprint? {
        root.withUnsafeFileSystemRepresentation { rawPath -> CorpusRootFingerprint? in
            guard let rawPath else { return nil }
            guard access(rawPath, R_OK) == 0 else { return nil }
            var st = stat()
            guard stat(rawPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
            var fs = statfs()
            guard statfs(rawPath, &fs) == 0 else { return nil }
            // `f_fsid` is imported as a two-word tuple; pack it so the whole value participates in
            // equality (comparing only one word would silently ignore half the identity).
            let packed = (Int64(fs.f_fsid.val.0) << 32) | Int64(UInt32(bitPattern: fs.f_fsid.val.1))
            return CorpusRootFingerprint(filesystemID: packed,
                                         deviceID: Int64(st.st_dev),
                                         inode: UInt64(st.st_ino))
        }
    }

    /// The §7a.11 gate: did the root hold still across the pass?
    ///
    /// Both captures must exist and be identical. A vanished root, an unreadable root, or a different
    /// directory under the same path all mean the pass's absences are not evidence of anything.
    public static func rootHeldStill(before: CorpusRootFingerprint?,
                                     after: CorpusRootFingerprint?) -> Bool {
        guard let before, let after else { return false }
        return before == after
    }
}
