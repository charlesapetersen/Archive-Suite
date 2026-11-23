import ArchiveCore
import Darwin
import Foundation

/// Local identity of a granted directory. A marker moves with its directory, but copies can
/// carry the same marker. Filesystem identity and directory birth time distinguish those copies
/// and prevent a recycled inode from claiming the previous directory's local state.
struct ReaderRootIdentity: Sendable {
    let key: String
    let previousCatalogueKey: String

    static func capture(_ root: URL) -> Self? {
        CorpusWalker.withDatalessMaterializationDisabled {
            guard let fingerprint = CorpusRootFingerprint.capture(root) else { return nil }
            var info = stat()
            guard root.withUnsafeFileSystemRepresentation({ path in
                guard let path else { return false }
                return stat(path, &info) == 0
            }), Int64(info.st_dev) == fingerprint.deviceID,
                UInt64(info.st_ino) == fingerprint.inode,
                info.st_birthtimespec.tv_sec > 0 else { return nil }

            let stamp = "\(fingerprint.filesystemID).\(fingerprint.deviceID).\(fingerprint.inode)"
            let birth = info.st_birthtimespec
            return Self(key: "\(stamp).\(birth.tv_sec).\(birth.tv_nsec)",
                        previousCatalogueKey: "readerCatalogue.\(stamp).\(root.path)")
        }
    }
}
