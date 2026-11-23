import Foundation
import ArchiveCore

/// W47.ct-processor-intake — Route B in Process Files: a folder given as a tree ("Glotzer papers/Box 17/Folder 8") is
/// read recursively (`ContainerTree`), and each output is filed in the same folders below the output folder, so the
/// tree and the level map at the output folder give it its path values (`SPEC/containers.md` §Route B in Process
/// Files). The pre-OCRed route tags its inputs where they are and has no tree. Collection organisation leaves a tree's
/// outputs where the tree put them, and a merged document stays within one folder.
extension OCRProcessor {
    /// The folder `sourceURL`'s output goes in: its tree folder below `outputDirectory`, made if missing, or
    /// `outputDirectory` itself for a source not from a tree. Each folder on the way is made only inside the one
    /// before it and must be a real folder, never a link, so an output never lands outside `outputDirectory`; where
    /// one cannot be made, the output goes in `outputDirectory` and the run's summary names it (`treeFallbackSuffix`).
    func outputFolder(for sourceURL: URL, in outputDirectory: URL) -> URL {
        guard let relative = outputSubfolders[sourceURL.standardizedFileURL.path] else { return outputDirectory }
        func outside() -> URL {
            let path = sourceURL.standardizedFileURL.path
            if !outputsOutsideTheirTree.contains(path) { outputsOutsideTheirTree.append(path) }
            return outputDirectory
        }
        guard let parts = ContainerTree.components(ofRelativePath: relative) else { return outside() }
        var folder = outputDirectory
        for part in parts {
            folder = folder.appendingPathComponent(part, isDirectory: true)
            var info = stat()
            if lstat(folder.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { return outside() }
            } else if mkdir(folder.path, 0o755) != 0, errno != EEXIST {
                return outside()
            } else if lstat(folder.path, &info) != 0 || info.st_mode & S_IFMT != S_IFDIR {
                return outside()
            }
        }
        return folder
    }

    /// For the run's summary: the outputs that could not be filed in their tree's folders.
    var treeFallbackSuffix: String {
        guard !outputsOutsideTheirTree.isEmpty else { return "" }
        let n = outputsOutsideTheirTree.count
        return " ⚠️ \(n) PDF\(n == 1 ? "" : "s") could not be filed in \(n == 1 ? "its" : "their") folder"
            + " (\(Self.namesForWarning(outputsOutsideTheirTree.map { ($0 as NSString).lastPathComponent }))): a file or link was in the folder's place, so"
            + " \(n == 1 ? "it is" : "they are") in the output folder itself."
    }

    /// The collections organisation files: those with an output outside a tree.
    var collectionsOutsideTrees: [CollectionSegment] {
        guard !outputSubfolders.isEmpty else { return collectionSegments }
        let outside = outputURLMapOutsideTrees
        return collectionSegments.filter { $0.fileURLs.contains { outside[$0] != nil } }
    }

    /// `outputURLMap` without a tree's outputs, for collection organisation: the tree already says where they go.
    var outputURLMapOutsideTrees: [URL: URL] {
        outputSubfolders.isEmpty ? outputURLMap
            : outputURLMap.filter { outputSubfolders[$0.key.standardizedFileURL.path] == nil }
    }

    /// Indices in the original order where a different tree folder begins. If its first page was
    /// removed, carry the break to the next retained page, even if it returns to an earlier folder.
    func treeFolderStarts(in files: [URL], excluding removed: Set<URL> = []) -> Set<Int> {
        guard !outputSubfolders.isEmpty else { return [] }
        var starts = Set<Int>()
        var previousFolder: String?
        var previousSourceFolder: URL?
        var pendingBreak = false
        for (i, file) in files.enumerated() {
            let source = file.standardizedFileURL
            let folder = outputSubfolders[source.path]
            let sourceFolder = folder.map { _ in source.deletingLastPathComponent() }
            if i > 0, folder != previousFolder || sourceFolder != previousSourceFolder {
                pendingBreak = true
            }
            if pendingBreak, !removed.contains(file) {
                starts.insert(i)
                pendingBreak = false
            }
            previousFolder = folder
            previousSourceFolder = sourceFolder
        }
        return starts
    }

    /// The planned tree keyed as `outputSubfolders` keeps it, its folders checked (`ContainerTree.relativePath`).
    nonisolated static func keyedSubfolders(_ planned: [URL: String]) -> [String: String] {
        var keyed: [String: String] = [:]
        for (url, relative) in planned where ContainerTree.components(ofRelativePath: relative) != nil {
            keyed[url.standardizedFileURL.path] = relative
        }
        return keyed
    }

    /// `IncrementalSkip.partition` with each source checked against the folder its output would go in, keeping the
    /// order of `files`.
    nonisolated static func incrementalPartition(_ files: [URL], outputDirectory: URL,
                                                 subfolders: [URL: String],
                                                 requiresCatalogue: Bool = false) -> IncrementalSkip.Decision {
        var groups: [String: [URL]] = [:]
        for url in files { groups[subfolders[url] ?? "", default: []].append(url) }
        var skipped = Set<URL>()
        for (relative, inputs) in groups {
            let folder = relative.isEmpty ? outputDirectory
                : ContainerTree.components(ofRelativePath: relative).map {
                    $0.reduce(outputDirectory) { $0.appendingPathComponent($1, isDirectory: true) }
                }
            // A folder that is not plain is never skipped: its source is processed, as any doubt is.
            guard let folder else { continue }
            let reader = requiresCatalogue ? try? CatalogueReader(
                grantedRoot: folder, rootInstanceID: UUID(), mode: .adopted, identifyPDF: CataloguePDFIdentity.identify
            ) : nil
            skipped.formUnion(IncrementalSkip.partition(inputs: inputs, outputDirectory: folder) { candidate in
                guard requiresCatalogue else { return true }
                guard let reader else { return false }
                let name = candidate.lastPathComponent
                let snapshot = reader.snapshot(.init(relativePDFPaths: [name], isComplete: false))
                return (try? snapshot.facts(at: name).file.get()) != nil
            }.skipped)
        }
        return IncrementalSkip.Decision(toProcess: files.filter { !skipped.contains($0) },
                                        skipped: files.filter { skipped.contains($0) })
    }
}

/// What a drop or the Add Files panel gives Process Files (W47.ct-processor-intake).
enum ProcessFilesTree {
    struct Intake: Equatable {
        var files: [URL] = []
        /// For each file from a folder read as a tree, its folder below the output folder (`ContainerTree.relativePath`).
        var subfolders: [URL: String] = [:]
        var foldersBeyondDepth: [URL] = []
        var flatDotFolders: [URL: String] = [:]
    }

    static func depthWarning(_ folders: [URL]) -> String? {
        guard let first = folders.first else { return nil }
        let count = folders.count
        return "Skipped \(count) folder branch\(count == 1 ? "" : "es") more than \(ContainerTree.maxDepth) levels deep. "
            + "First skipped folder: \(first.path)"
    }

    /// The files Process Files takes: images and PDFs, or PDFs only for pre-OCRed input (`OCRView.isImageFile`).
    nonisolated static func isInput(_ url: URL, preOCRed: Bool) -> Bool {
        let ext = url.pathExtension.lowercased()
        if preOCRed { return ext == "pdf" }
        return ext == "pdf" || ImageEncoding.acceptedImageExtensions.contains(ext)
    }

    /// Whether `url` is a folder holding a folder of its own (not hidden, a package or a link): only then is the user
    /// asked whether to read the folders inside. One level is read, so it is quick for a folder of any size.
    nonisolated static func hasSubfolders(_ url: URL) -> Bool {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else { return false }
        return items.contains { item in
            let v = try? item.resourceValues(forKeys: Set(keys))
            return v?.isDirectory == true && v?.isSymbolicLink != true && v?.isPackage != true
        }
    }

    /// The files `urls` give. Without `readSubfolders`, or when no folder among them holds files in subfolders, as
    /// before the tree: a folder gives its own files, each folder's in Finder order, and with `sortAll` the whole list in
    /// Finder order (a drop). Finder order (`ContainerOrder`) compares a leading number by value, so a collection
    /// folder holding both five- and six-digit filed names (W49.proc-six-digit-names) is read in filing order. With it, when one does, every folder among them is read as a tree (`ContainerTree.files`):
    /// its files depth-first in Finder order, each with its folders from the given folder down, so the outputs are
    /// filed the same way below the output folder. A file given on its own is taken as it is, with no folder.
    nonisolated static func collect(_ urls: [URL], accept: (URL) -> Bool, sortAll: Bool,
                                    readSubfolders: Bool = true) -> Intake {
        let fm = FileManager.default
        func isFolder(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        var intake = Intake()
        let trees = urls.map { url -> [ContainerTree.Entry]? in
            guard readSubfolders, isFolder(url) else { return nil }
            return ContainerTree.files(in: url, onDepthLimit: {
                intake.foldersBeyondDepth.append($0.standardizedFileURL)
            }, accept: accept)
        }
        guard trees.contains(where: { $0.map(ContainerTree.isTree) == true }) else {
            var files: [URL] = []
            for url in urls {
                if isFolder(url) {
                    let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    let accepted = contents.filter(accept)
                    if readSubfolders && url.lastPathComponent.hasPrefix(".") {
                        for file in accepted { intake.flatDotFolders[file] = url.lastPathComponent }
                    }
                    files.append(contentsOf: sortAll ? accepted : accepted.sorted { ContainerOrder.precedes($0.lastPathComponent, $1.lastPathComponent) })
                } else if accept(url) {
                    files.append(url)
                }
            }
            intake.files = sortAll ? files.sorted { ContainerOrder.precedes($0.lastPathComponent, $1.lastPathComponent) } : files
            return intake
        }
        for (url, tree) in zip(urls, trees) {
            if let tree {
                for entry in tree {
                    intake.files.append(entry.url)
                    if let relative = ContainerTree.relativePath(entry.directory) {
                        intake.subfolders[entry.url] = relative
                    } else if url.lastPathComponent.hasPrefix(".") {
                        intake.flatDotFolders[entry.url] = url.lastPathComponent
                    }
                }
            } else if accept(url) {
                intake.files.append(url)
            }
        }
        return intake
    }

    /// The given folder of a tree whose outputs would land in the tree itself, or nil: the output folder is that
    /// folder, inside it, or the folder holding it (the outputs go in "<output>/<its name>/…", which is then the
    /// tree). Nothing may be written among the sources, so such a run does not start.
    nonisolated static func treeHoldingOutput(subfolders: [URL: String], outputDirectory: URL) -> String? {
        let out = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var seen = Set<String>()
        for (url, relative) in subfolders {
            guard let parts = ContainerTree.components(ofRelativePath: relative) else { continue }
            var root = url.deletingLastPathComponent()
            for _ in 1..<parts.count { root = root.deletingLastPathComponent() }
            let given = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard seen.insert(given.joined(separator: "/")).inserted else { continue }
            let insideOrSame = out.count >= given.count && Array(out.prefix(given.count)) == given
            let holdsIt = out == Array(given.dropLast())
            if insideOrSame || holdsIt { return parts[0] }
        }
        return nil
    }

    static func overlapMessage(_ tree: String) -> String {
        "The PDFs would be filed inside “\(tree)”, among the photos being read. Choose an output folder outside it "
            + "(not “\(tree)” itself, a folder in it, or the folder that holds it). Nothing was started."
    }

    /// The level map to offer at Start for `outputDirectory`, or nil: only for a tree's files, and only when the output
    /// folder has no map yet (one there, readable or not, is the user's and is left alone; the Reader edits it).
    static func levelsToOffer(files: [URL], subfolders: [URL: String], outputDirectory: URL) -> ContainerLevelsDraft? {
        let directories = files.compactMap { subfolders[$0].flatMap(ContainerTree.components(ofRelativePath:)) }
        guard !directories.isEmpty, ContainerFileStore.loadLevelMap(root: outputDirectory) == .missing else { return nil }
        return ContainerLevelsDraft.make(directories: directories, tree: outputDirectory, treePath: outputDirectory.path)
    }

    /// Writes the confirmed map at the output folder; the reason when it is refused.
    static func saveLevels(_ draft: ContainerLevelsDraft) -> String? {
        var map = draft.map
        map.updatedAt = Date()
        do {
            try ContainerFileStore.writeLevelMap(map, root: draft.tree.resolvingSymlinksInPath(), expecting: draft.expecting)
            return nil
        } catch {
            return "The folder levels were not saved: \(error.localizedDescription)"
        }
    }
}
