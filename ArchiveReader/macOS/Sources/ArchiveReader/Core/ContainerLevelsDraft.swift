import Foundation
import ArchiveCore

// MARK: - The level map, offered when a root is first added (W47.ct-reader-view; `SPEC/containers.md` §The level map)
//
// Route B: what each depth of folders below the archive's main folder names ("level 1 = Repository, level 2 =
// Collection, level 3 = Box"), pre-filled from the folder names (`ContainerLevelMap.prefilled`) and confirmed or
// edited once per root. Nothing is written until the user saves it; saving writes only
// `<root>/.archivesuite/container-levels.json`, through ArchiveCore's audited writer.

struct ContainerLevelsDraft: Equatable, Sendable {
    /// The map as the user is editing it.
    var map: ContainerLevelMap
    /// A few folder names at each depth of `map.levels`, the most common first, workflow folders left out.
    let examples: [[String]]
    /// How many folders each depth holds, workflow folders left out.
    let folderCounts: [Int]
    /// The workflow folders the map skipped when the draft was made ("05 Final Tagging"), by their path below the
    /// root; the user may stop skipping one (`setSkipped`).
    let workflowFolders: [String]
    /// The folder holding the most files, for the sheet's example of what a file there would show.
    let sampleDirectory: [String]?
    /// The stamp of the map this draft was made from, nil when there was none; the write refuses a map changed since.
    let expecting: ContainerFileStamp?

    /// The roles a depth may take, in the order the menu lists them.
    static let roles: [ContainerLevelRole] = [.repository, .collection, .accession, .series, .box, .folder, .ignore]

    static func roleName(_ role: ContainerLevelRole) -> String {
        switch role {
        case .repository: return "Repository"
        case .collection: return "Collection"
        case .accession: return "Accession"
        case .series: return "Series"
        case .box: return "Box or other container"
        case .folder: return "Folder"
        case .ignore: return "Ignore this level"
        }
    }

    /// A draft from `directories` (each listed file's directory below the root, top first, once per file): the
    /// stored map when there is one (`existing`), else the pre-filled one.
    static func make(directories: [[String]], existing: ContainerLevelMap? = nil,
                     expecting: ContainerFileStamp? = nil) -> ContainerLevelsDraft {
        var map = existing ?? ContainerLevelMap.prefilled(directories: directories)
        // Per depth, each folder (by its path) with the files under it. Depth as the map counts it: a skipped
        // folder takes none.
        var folders: [[String: (name: String, files: Int)]] = []
        for dir in directories {
            let kept = dir.indices.filter { i in
                map.overrides[dir[0...i].joined(separator: "/")]?.role != .ignore
                    && !ContainerPatterns.isWorkflowName(dir[i])
            }
            for (depth, i) in kept.enumerated() {
                while folders.count <= depth { folders.append([:]) }
                folders[depth][dir[0...i].joined(separator: "/"), default: (dir[i], 0)].files += 1
            }
        }
        // A depth the folders do not reach still shows, so a stored map's every entry can be edited.
        while folders.count < map.levels.count { folders.append([:]) }
        if map.levels.count < folders.count {
            map.levels += Array(repeating: .ignore, count: folders.count - map.levels.count)
        }
        let examples = folders.map { depth -> [String] in
            var names: [String] = []
            let ordered = depth.values.sorted {
                $0.files != $1.files ? $0.files > $1.files : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for f in ordered where !names.contains(f.name) && names.count < 3 { names.append(f.name) }
            return names
        }
        let workflow = map.overrides.filter { $0.value.role == .ignore }.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var perDirectory: [[String]: Int] = [:]
        for dir in directories where !dir.isEmpty { perDirectory[dir, default: 0] += 1 }
        let sample = perDirectory.max {
            $0.value != $1.value ? $0.value < $1.value
                                 : $0.key.joined(separator: "/").localizedStandardCompare($1.key.joined(separator: "/")) == .orderedDescending
        }?.key
        return ContainerLevelsDraft(map: map, examples: examples, folderCounts: folders.map(\.count),
                                    workflowFolders: workflow, sampleDirectory: sample, expecting: expecting)
    }

    /// Stop skipping a workflow folder, or skip it again.
    mutating func setSkipped(_ path: String, _ skipped: Bool) {
        if skipped { map.overrides[path] = .init(role: .ignore) } else { map.overrides[path] = nil }
    }

    /// What the folders inside a skipped workflow folder are: by default the level the workflow folder stands at;
    /// `role` names another ("05 Final Tagging/5 Priority 5" holding collections, SPEC §The level map, `children`).
    mutating func setChildren(_ path: String, _ role: ContainerLevelRole?) {
        guard map.overrides[path]?.role == .ignore else { return }
        map.overrides[path] = .init(role: .ignore, children: role)
    }

    /// The roles `setChildren` may name: those `map.levels` holds (a `children` role must be one of them).
    var childRoles: [ContainerLevelRole] {
        Self.roles.filter { $0 != .ignore && map.levels.contains($0) }
    }

    /// What one folder path below the root would give, with the draft as it stands: "Repository: Hoover · Box: Box
    /// 17". For the sheet's example line.
    func preview(_ components: [String]) -> String {
        let fields = map.pathFields(for: components).reduce(into: [ContainerField: ContainerValue]()) { all, set in
            for (field, value) in set.values { all[field] = value }
        }
        let parts = ContainerField.allCases.compactMap { f in
            fields[f]?.shown.map { "\(f.label): \(ContainerDisplay.shown($0))" }
        }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: " · ")
    }
}
