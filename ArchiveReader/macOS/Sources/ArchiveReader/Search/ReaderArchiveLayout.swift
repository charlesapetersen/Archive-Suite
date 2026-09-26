import Foundation
import ArchiveCore

/// The single granted folder that contains the PDF archive and its JPEG partner subtree.
///
/// Reader's bookmark must cover the common parent: a bookmark for `Archival Photos` alone cannot open
/// its sibling `Archival Photos JPEGS`. The caller still scans the granted parent through the normal
/// Reader pipeline; this value only identifies the MAIN tree used for stem/context matching.
struct ReaderArchiveLayout: Equatable, Sendable {
    static let mainDirectoryName = "Archival Photos"
    static let jpegDirectoryName = "Archival Photos JPEGS"

    let grantedRoot: URL
    let mainRoot: URL
    let jpegRoot: URL
    let needsCommonParentGrant: Bool

    init(grantedRoot: URL) {
        self.grantedRoot = grantedRoot
        let mainCandidate = grantedRoot.appendingPathComponent(Self.mainDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        let containsMainTree = FileManager.default.fileExists(atPath: mainCandidate.path,
                                                               isDirectory: &isDirectory) && isDirectory.boolValue
        mainRoot = containsMainTree ? mainCandidate : grantedRoot
        jpegRoot = grantedRoot.appendingPathComponent(Self.jpegDirectoryName, isDirectory: true)
        needsCommonParentGrant = grantedRoot.lastPathComponent == Self.mainDirectoryName
            || grantedRoot.lastPathComponent == Self.jpegDirectoryName
    }

    static func isSupportedImage(_ pathExtension: String) -> Bool {
        JPEGPartnerIndex.isSupportedImageExtension(pathExtension)
    }

    static func isContained(_ url: URL, inRootPath rootPath: String) -> Bool {
        // The bookmark can retain a symlink spelling while CorpusWalker reports the resolved spelling.
        // Compare both through realpath when available, so a valid linked root stays writable and a
        // symlink that escapes MAIN cannot widen the tag-write boundary.
        let path = CorpusWalker.discoveredPathPrefix(for: url)
            ?? url.withUnsafeFileSystemRepresentation { raw in raw.map(String.init(cString:)) ?? url.path }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let resolvedRoot = CorpusWalker.discoveredPathPrefix(for: rootURL) ?? rootPath
        return isContained(path: path, underRootPath: resolvedRoot)
    }

    /// Byte-exact path containment. Swift string equality and prefix checks consider canonically
    /// equivalent Unicode spellings equal, while the filesystem may hold them as distinct paths.
    static func isContained(path: String, underRootPath rootPath: String) -> Bool {
        let slash: UInt8 = 0x2f
        var prefix = Array(rootPath.utf8)
        if prefix.last != slash { prefix.append(slash) }
        let pathBytes = Array(path.utf8)
        guard pathBytes.count > prefix.count, pathBytes.starts(with: prefix) else { return false }
        let relative = pathBytes.dropFirst(prefix.count)
        return !relative.isEmpty
            && !relative.split(separator: slash).contains { $0 == [0x2e] || $0 == [0x2e, 0x2e] }
    }
}
