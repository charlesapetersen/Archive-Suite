import Foundation

// MARK: - Reading an existing corpus's markers (W47.ct-backfill; `SPEC/containers.md` §Backfill)
//
// Route A for material photographed before the apps: a folder the user chooses is walked as a tree, its box and
// folder photos found by their `Box` / `Folder` tag or the colour the user says older material used, and each
// directory's reads turned into proposed runs. Nothing is written until the user accepts a directory; then only that
// directory's `.archivesuite/containers.json`, and only if it is still as it was when the proposal was made. The
// folder names are Route B: the level map pre-filled from them is offered for the chosen folder, written only on Save.

public enum ContainerBackfill {
    /// The files a directory's runs count: photos and PDFs, as Process Files accepts them.
    public static let fileExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif"]

    /// One box or folder photo found in a directory.
    public struct Marker: Equatable, Sendable {
        public var fileName: String
        public var url: URL
        public var type: ItemType

        public init(fileName: String, url: URL, type: ItemType) {
            self.fileName = fileName
            self.url = url
            self.type = type
        }
    }

    /// One directory of the chosen folder that holds files.
    public struct Directory: Equatable, Sendable {
        public var url: URL
        /// The folders below the chosen folder, top first; empty for the chosen folder itself.
        public var components: [String]
        public var relativePath: String { components.joined(separator: "/") }
        public var fileCount: Int
        /// In `ContainerOrder`.
        public var markers: [Marker]
        /// Files whose tags could not be read: they may be markers, so the user is told.
        public var unreadableTags: Int

        public init(url: URL, components: [String], fileCount: Int, markers: [Marker], unreadableTags: Int = 0) {
            self.url = url
            self.components = components
            self.fileCount = fileCount
            self.markers = markers
            self.unreadableTags = unreadableTags
        }
    }

    /// What `scan` found under the chosen folder. Read only.
    public struct Scan: Equatable, Sendable {
        public var root: URL
        /// Every directory holding files, in tree order (`ContainerTree`).
        public var directories: [Directory]
        /// Each file's directory below the root, once per file: what the level map is pre-filled from.
        public var fileDirectories: [[String]]

        public var markerCount: Int { directories.reduce(0) { $0 + $1.markers.count } }
        public var fileCount: Int { directories.reduce(0) { $0 + $1.fileCount } }
        public var unreadableTags: Int { directories.reduce(0) { $0 + $1.unreadableTags } }
    }

    /// Walks `root` as `ContainerTree` does (hidden folders, packages, links to folders and depths past its limit are
    /// not entered) and finds each directory's markers: a file whose `Box` / `Folder` tag, or whose Finder colour under
    /// `colours`, names a type (`DocumentTags.itemType`). Reads tags only; writes nothing. Returns nil when cancelled.
    public static func scan(root: URL, colours: ItemTypeColors,
                            isCancelled: @escaping () -> Bool = { false }) -> Scan? {
        let base = root.standardizedFileURL
        let entries = ContainerTree.files(in: base) { url in
            fileExtensions.contains(url.pathExtension.lowercased()) && !isCancelled()
        }
        if isCancelled() { return nil }
        var order: [[String]] = []
        var byDirectory: [[String]: [URL]] = [:]
        var fileDirectories: [[String]] = []
        for entry in entries {
            let below = Array(entry.directory.dropFirst())
            if byDirectory[below] == nil { order.append(below) }
            byDirectory[below, default: []].append(entry.url)
            fileDirectories.append(below)
        }
        var directories: [Directory] = []
        for below in order {
            if isCancelled() { return nil }
            let files = byDirectory[below] ?? []
            var markers: [Marker] = []
            var unreadable = 0
            for url in files {
                switch TagReading.read(url) {
                case .success(let names, let label):
                    if let type = DocumentTags.parse(raw: names, labelNumber: label, colours: colours).itemType {
                        markers.append(Marker(fileName: url.lastPathComponent, url: url, type: type))
                    }
                case .failure:
                    unreadable += 1
                }
            }
            let url = below.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
            directories.append(Directory(url: url, components: below, fileCount: files.count, markers: markers,
                                         unreadableTags: unreadable))
        }
        return Scan(root: base, directories: directories, fileDirectories: fileDirectories)
    }

    /// One directory's proposed runs, for the user to accept or pass over.
    public struct Proposal: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// Accepting would write the proposed file.
            case ready
            /// The reads change nothing the directory's file holds.
            case unchanged
            /// The file on disk is newer, unreadable or holds values this build drops: never written here.
            case blocked(String)
        }

        public var directory: URL
        /// The directory's file as the proposal read it, nil when it had none.
        public var base: ContainerFile?
        public var stamp: ContainerFileStamp?
        public var proposed: ContainerFile
        public var warnings: [ContainerWarning]
        public var state: State

        /// The runs accepting would add or change, in the proposed file's order.
        public var changedRuns: [ContainerRun] {
            let before = base?.runs ?? []
            return proposed.runs.filter { !before.contains($0) }
        }
    }

    /// The runs `markers` (each with its read) give `directory`'s container file as it is now
    /// (`ContainerInference.applyMarkers`; no file counts as existing, since no marker here is the user's own start).
    public static func propose(_ markers: [ContainerMarker], in directory: URL) -> Proposal {
        let base: ContainerFile?
        let stamp: ContainerFileStamp?
        switch ContainerFileStore.load(directory: directory) {
        case .missing: (base, stamp) = (nil, nil)
        case .loaded(let d, let s):
            if s.droppedOnReading {
                return Proposal(directory: directory, base: d, stamp: s, proposed: d, warnings: [],
                                state: .blocked("its container file holds values this version does not read"))
            }
            (base, stamp) = (d, s)
        case .newer:
            return Proposal(directory: directory, base: nil, stamp: nil, proposed: ContainerFile(), warnings: [],
                            state: .blocked("its container file was written by a newer version"))
        case .unreadable(let why):
            return Proposal(directory: directory, base: nil, stamp: nil, proposed: ContainerFile(), warnings: [],
                            state: .blocked("its container file cannot be read (\(why))"))
        }
        let start = base ?? ContainerFile()
        let (applied, warnings) = ContainerInference.applyMarkers(markers, to: start)
        let unchanged = applied.runs == start.runs && applied.directory == start.directory
        return Proposal(directory: directory, base: base, stamp: stamp, proposed: applied, warnings: warnings,
                        state: unchanged ? .unchanged : .ready)
    }

    /// What `accept` did.
    public enum AcceptOutcome: Equatable, Sendable {
        case wrote
        /// Nothing to write.
        case unchanged
        /// The directory's file changed after the proposal was made (another app, an edit in the Reader): nothing was
        /// written; propose again and show the user the new proposal.
        case changedSinceRead
        /// Not written, with the reason.
        case refused(String)
    }

    /// Writes an accepted proposal: only `<directory>/.archivesuite/containers.json`, only when the file is still the
    /// one the proposal read, and only inside `root` with no link on the way. Call it off the main thread.
    public static func accept(_ proposal: Proposal, root: URL, now: Date = Date()) throws -> AcceptOutcome {
        switch proposal.state {
        case .unchanged: return .unchanged
        case .blocked(let why): return .refused(why)
        case .ready: break
        }
        guard let directory = realDirectory(proposal.directory, inside: root) else {
            return .refused("the folder is no longer a folder inside the chosen one")
        }
        switch ContainerFileStore.load(directory: directory) {
        case .missing:
            if proposal.base != nil || proposal.stamp != nil { return .changedSinceRead }
        case .loaded(let d, let s):
            if d != proposal.base || s != proposal.stamp { return .changedSinceRead }
        case .newer, .unreadable:
            return .changedSinceRead
        }
        var out = proposal.proposed
        out.updatedAt = now
        do {
            try ContainerFileStore.write(out, directory: directory, expecting: proposal.stamp)
        } catch ContainerWriteError.changedSinceRead {
            return .changedSinceRead
        }
        return .wrote
    }

    /// `directory` resolved, when it is a real folder below `root` reached through real folders only; else nil.
    static func realDirectory(_ directory: URL, inside root: URL) -> URL? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let given = directory.standardizedFileURL.pathComponents
        let rootGiven = root.standardizedFileURL.pathComponents
        guard given.count >= rootGiven.count, Array(given.prefix(rootGiven.count)) == rootGiven else { return nil }
        var url = URL(fileURLWithPath: NSString.path(withComponents: rootPath), isDirectory: true)
        for name in given.dropFirst(rootGiven.count) {
            url = url.appendingPathComponent(name, isDirectory: true)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return url
    }
}
