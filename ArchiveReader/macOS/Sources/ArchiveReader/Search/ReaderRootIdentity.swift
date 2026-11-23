import ArchiveCore
import Darwin
import Foundation

/// Local identity of a granted directory. A marker moves with its directory, but copies can
/// carry the same marker. Filesystem identity and directory birth time distinguish those copies
/// and prevent a recycled inode from claiming the previous directory's local state.
struct ReaderRootIdentity: Sendable {
    let key: String
    let previousCatalogueKey: String

    static func legacyCatalogueKey(for root: URL) -> String? {
        CorpusWalker.withDatalessMaterializationDisabled {
            CorpusRootFingerprint.capture(root).map { legacyCatalogueKey(stamp: stampKey($0), root: root) }
        }
    }

    private static func stampKey(_ value: CorpusRootFingerprint) -> String {
        "\(value.filesystemID).\(value.deviceID).\(value.inode)"
    }

    private static func legacyCatalogueKey(stamp: String, root: URL) -> String {
        "readerCatalogue.\(stamp).\(root.path)"
    }

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

            let stamp = stampKey(fingerprint)
            let birth = info.st_birthtimespec
            return Self(key: "\(stamp).\(birth.tv_sec).\(birth.tv_nsec)",
                        previousCatalogueKey: legacyCatalogueKey(stamp: stamp, root: root))
        }
    }
}

/// The marker identifies a collection. The local directory identity partitions copies of it.
/// Paths in this cache are byte-exact and relative to the resolved spelling of the granted root.
struct ReaderRootCacheScope: Sendable, Equatable {
    let key: String
    let root: LibraryIndexPath
    private let directoryKey: String
    private let prefix: String

    init(markerGUID: UUID, identity: ReaderRootIdentity, rootPath: String) {
        directoryKey = identity.key
        key = "\(markerGUID.uuidString.lowercased())-\(identity.key)"
        root = LibraryIndexPath(rootPath)
        prefix = rootPath == "/" ? "/" : rootPath + "/"
    }

    var isCurrent: Bool { ReaderRootIdentity.capture(root.fileURL)?.key == directoryKey }

    func relativePath(_ absolutePath: String) -> String? {
        guard absolutePath.utf8.starts(with: prefix.utf8) else { return nil }
        let relative = String(decoding: absolutePath.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        return Self.isRelativePath(relative) ? relative : nil
    }

    func absolutePath(_ relativePath: String) -> String? {
        guard Self.isRelativePath(relativePath) else { return nil }
        return prefix + relativePath
    }

    private static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.utf8.contains(0)
            && path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && !$0.elementsEqual(".".utf8) && !$0.elementsEqual("..".utf8)
            }
    }
}
