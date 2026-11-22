import Foundation

// MARK: - A dropped folder read as a tree (W47.ct-processor-intake; `SPEC/containers.md` §Route B in Process Files)
//
// Route B for material that is not yet in an archive: Process Files is given a folder whose photos are sorted into
// subfolders named for the hierarchy ("Glotzer papers/Box 17/Folder 8"). The Processor files each output in the same
// folders below its output folder, so the tree, and the level map at the output folder, give every output its path
// values as they give the Reader's (path values are never stored). Read only: nothing here writes.

public enum ContainerTree {
    /// One file of a dropped folder.
    public struct Entry: Equatable, Sendable {
        public var url: URL
        /// The folders from the dropped folder itself down to the file's own, the dropped folder's name first: the
        /// folder its output goes in below the output folder, and the path the level map reads.
        public var directory: [String]

        public init(url: URL, directory: [String]) {
            self.url = url
            self.directory = directory
        }
    }

    /// Folders deeper than this below a dropped folder are not read (a tree of archival containers is a handful deep).
    public static let maxDepth = 12

    /// The files under `folder` that `accept` takes: each folder's own files in Finder order (`ContainerOrder`), then
    /// each subfolder's the same way, in Finder order. Hidden files and folders (`.archivesuite` among them), packages
    /// and links to folders are not entered. `onDepthLimit` receives the root of each skipped branch in walk order.
    public static func files(in folder: URL, onDepthLimit: ((URL) -> Void)? = nil, accept: (URL) -> Bool) -> [Entry] {
        var found: [Entry] = []
        walk(folder, path: [folder.lastPathComponent], accept: accept, onDepthLimit: onDepthLimit, into: &found)
        return found
    }

    /// Whether a dropped folder holds files in subfolders, so it is read as a tree rather than flat.
    public static func isTree(_ entries: [Entry]) -> Bool {
        entries.contains { $0.directory.count > 1 }
    }

    /// The folder below an output folder that `directory` names, as a relative path ("Box 17/Folder 8"); nil when a
    /// name could leave the output folder or is not a plain folder name.
    public static func relativePath(_ directory: [String]) -> String? {
        guard !directory.isEmpty, directory.allSatisfy(isPlainName) else { return nil }
        return directory.joined(separator: "/")
    }

    /// The components of `relativePath`'s result, or nil for one it would not give.
    public static func components(ofRelativePath path: String) -> [String]? {
        let parts = path.components(separatedBy: "/")
        return relativePath(parts) == nil ? nil : parts
    }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".") && !name.contains("/")
            && !name.contains("\0")
    }

    private static func walk(_ dir: URL, path: [String], accept: (URL) -> Bool,
                             onDepthLimit: ((URL) -> Void)?, into found: inout [Entry]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else { return }
        var subfolders: [URL] = []
        for item in items.sorted(by: { ContainerOrder.precedes($0.lastPathComponent, $1.lastPathComponent) }) {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink != true, values?.isDirectory == true {
                if values?.isPackage != true, isPlainName(item.lastPathComponent) { subfolders.append(item) }
                continue
            }
            if values?.isSymbolicLink == true,
               (try? item.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                continue
            }
            if accept(item) { found.append(Entry(url: item, directory: path)) }
        }
        for sub in subfolders {
            if path.count <= maxDepth {
                walk(sub, path: path + [sub.lastPathComponent], accept: accept, onDepthLimit: onDepthLimit, into: &found)
            } else {
                onDepthLimit?(sub)
            }
        }
    }
}
