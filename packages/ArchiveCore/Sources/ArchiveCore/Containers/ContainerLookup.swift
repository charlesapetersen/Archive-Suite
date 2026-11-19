import Foundation

// MARK: - What a directory inherits, read from disk (W47.ct-zotero; `SPEC/containers.md` §The level map)
//
// The reading half of the Reader's container catalog, shared so Notes and the Zotero export resolve a file the same
// way the Reader's list does: the container file of every directory from the file's up to the tree's root, the
// nearest level map and the nearest standard names. Read only. Each directory is read once per lookup, whichever
// caller asks first; a lookup is not shared between threads.

public final class ContainerLookup {
    /// The archive's main folder: where the level map at the top sits and paths below it start.
    public let treeRoot: URL

    private var files: [String: ContainerFile?] = [:]
    private var maps: [String: ContainerLoad<ContainerLevelMap>] = [:]
    private var namesAt: [String: ContainerLoad<ContainerNames>] = [:]

    public init(treeRoot: URL) { self.treeRoot = treeRoot }

    /// The tree a granted Reader root holds: its `Archival Photos` folder when it has one, else the root itself
    /// (the Reader's `ReaderArchiveLayout.mainRoot`).
    public static let mainDirectoryName = "Archival Photos"
    public static func treeRoot(forGrantedRoot root: URL) -> URL {
        let main = root.appendingPathComponent(mainDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: main.path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? main : root
    }

    /// The directory below `treeRoot` (top first) and the name of `file`, by path components; nil outside the tree.
    public func split(_ file: URL) -> (directory: [String], name: String)? {
        let root = treeRoot.standardizedFileURL.pathComponents
        var parts = file.standardizedFileURL.pathComponents
        guard parts.count > root.count, Array(parts.prefix(root.count)) == root else { return nil }
        parts.removeFirst(root.count)
        guard !parts.contains(where: { $0 == ".." || $0 == "." }), let name = parts.popLast() else { return nil }
        return (parts, name)
    }

    public func url(_ components: [String]) -> URL {
        components.reduce(treeRoot) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    public func containerFile(_ components: [String]) -> ContainerFile? {
        let key = components.joined(separator: "/")
        if let cached = files[key] { return cached }
        let file = ContainerFileStore.load(directory: url(components)).document
        files[key] = file
        return file
    }

    public func levelMap(_ components: [String]) -> ContainerLoad<ContainerLevelMap> {
        let key = components.joined(separator: "/")
        if let cached = maps[key] { return cached }
        let map = ContainerFileStore.loadLevelMap(root: url(components))
        maps[key] = map
        return map
    }

    public func names(_ components: [String]) -> ContainerLoad<ContainerNames> {
        let key = components.joined(separator: "/")
        if let cached = namesAt[key] { return cached }
        let found = ContainerFileStore.loadNames(root: url(components))
        namesAt[key] = found
        return found
    }

    /// The scopes `ContainerResolver.resolve` takes for a file in the directory at `dir`, and the standard names
    /// that apply there. The nearest level map and names at or above the directory win, even when they cannot be
    /// read: their subtree then gets none, not an outer one's.
    public func context(directory dir: [String]) -> (scopes: [ContainerScope], names: ContainerNames?) {
        func isMissing<D>(_ load: ContainerLoad<D>) -> Bool {
            if case .missing = load { return true }
            return false
        }
        let mapDepth = (0...dir.count).reversed().first { !isMissing(levelMap(Array(dir[0..<$0]))) }
        let nameDepth = (0...dir.count).reversed().first { !isMissing(names(Array(dir[0..<$0]))) }
        var scopes: [ContainerScope]
        if let m = mapDepth, let map = levelMap(Array(dir[0..<m])).document {
            let below = Array(dir[m...])
            let chain = (0...below.count).map { containerFile(Array(dir[0..<(m + $0)])) }
            scopes = map.scopes(for: below, files: chain)
            // Above the map's folder, only the container files' directory values apply.
            scopes += (0..<m).reversed().map { ContainerScope(file: containerFile(Array(dir[0..<$0]))) }
        } else {
            scopes = (0...dir.count).reversed().map { ContainerScope(file: containerFile(Array(dir[0..<$0]))) }
        }
        return (scopes, nameDepth.flatMap { names(Array(dir[0..<$0])).document })
    }

    /// Every field of `file` as shown (`ContainerDisplay.values`); empty outside the tree or with no value.
    public func shown(for file: URL) -> [ContainerField: ContainerShownValue] {
        guard let (dir, name) = split(file) else { return [:] }
        let (scopes, names) = context(directory: dir)
        let record = ContainerResolver.resolve(fileName: name, scopes: scopes,
                                               fileFields: ContainerPatterns.fields(ofFileName: name))
        return record.values.isEmpty ? [:] : ContainerDisplay.values(record, names: names)
    }
}
